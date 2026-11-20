"""Promote reviewed OCI bytes without publishing private source coordinates."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import time
from urllib.parse import urlsplit
import zipfile

import requests

REGISTRY = "oci.bjoroy.me"
SHA = re.compile(r"sha256:[0-9a-f]{64}")
TAG = re.compile(r"(?:[0-9]+\.[0-9]+\.[0-9]+|git-[0-9a-f]{40})")
REPO = re.compile(r"(?:heart/(?:api|heart-chart)|bank/(?:admin-ui(?:-chart)?|treasury-(?:api|chart)|accounting-(?:api|chart)|bjoroy-bank|bank-(?:core-api|admin-api|scheduler|definitions-service|payment-engine))|bank-platform/(?:products|treasury|accounting)/[a-z0-9-]+)")
ACCEPT = ",".join(["application/vnd.oci.image.manifest.v1+json","application/vnd.oci.image.index.v1+json","application/vnd.docker.distribution.manifest.v2+json","application/vnd.docker.distribution.manifest.list.v2+json"])
MAX_BYTES = 1 << 30


def require(condition, message):
    if not condition:
        raise ValueError(message)


def file_hash(path):
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


def validate():
    plan = json.loads(Path("plan.json").read_text())
    require(isinstance(plan, list) and 1 <= len(plan) <= 80, "Invalid plan size")
    seen = set()
    for row in plan:
        require(isinstance(row, dict) and set(row) in ({"repo","tag","format","asset_sha256","digest"},{"repo","tag","format","asset_sha256","digest","layout"}), "Invalid plan fields")
        require(REPO.fullmatch(row["repo"]) and TAG.fullmatch(row["tag"]), "Unapproved registry target")
        require(all(SHA.fullmatch(row[k]) for k in ("asset_sha256","digest")), "Invalid expected digest")
        require(row["format"] in ("chart","image","layout"), "Unknown input format")
        if row["format"] == "chart":
            require(row["asset_sha256"] == row["digest"], "Chart package digest differs")
        layout = row.get("layout", ".")
        require(layout == "." or re.fullmatch(r"[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)*",layout), "Invalid layout path")
        key = (row["repo"],row["tag"])
        require(key not in seen, "Repeated registry target")
        seen.add(key)
    return plan


def receive():
    repo = os.environ["GITHUB_REPOSITORY"]
    run, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    headers = {"Authorization":"Bearer " + os.environ["GH_TOKEN"],"Accept":"application/vnd.github+json"}
    session = requests.Session()
    def api(path):
        result = session.get("https://api.github.com/repos/"+repo+"/"+path, headers=headers,timeout=25)
        require(result.ok, "GitHub artifact lookup failed")
        return result.json()
    for _ in range(120):
        candidates = api(f"actions/artifacts?name=sealed-{run}-{attempt}&per_page=30")
        for asset in candidates["artifacts"]:
            source = api("actions/runs/"+str(asset["workflow_run"]["id"]))
            trusted = (source["event"]=="workflow_dispatch" and source["head_branch"]=="master"
                       and source["actor"]["login"]==os.environ["GITHUB_ACTOR"]
                       and source["head_repository"]["full_name"]==repo
                       and source["path"]==".github/workflows/supply-sealed-bank-release.yml"
                       and source["conclusion"]=="success")
            if not trusted:
                continue
            require(asset["size_in_bytes"]<65536,"Sealed packet exceeds limit")
            result = session.get(f"https://api.github.com/repos/{repo}/actions/artifacts/{asset['id']}/zip",headers=headers,timeout=30)
            require(result.ok and len(result.content)<65536,"Sealed packet unavailable")
            with zipfile.ZipFile(io.BytesIO(result.content)) as archive:
                require(archive.namelist()==["packet.age"] and archive.getinfo("packet.age").file_size<=48000, "Unexpected sealed envelope")
                Path("packet.age").write_bytes(archive.read("packet.age"))
            return
        time.sleep(10)
    raise ValueError("No matching encrypted packet received before timeout")


def download(item, target):
    url = urlsplit(item["url"])
    allowed = url.hostname in {"release-assets.githubusercontent.com","objects.githubusercontent.com"} or re.fullmatch(r"productionresults[a-z0-9]+\.blob\.core\.windows\.net",url.hostname or "")
    require(allowed and url.scheme=="https" and url.port in (443,None) and not url.username and not url.password, "Invalid signed asset delivery endpoint")
    with requests.get(item["url"], stream=True, timeout=(10,90), allow_redirects=False) as response:
        require(response.status_code == 200, f"Signed asset download returned {response.status_code}")
        length = 0
        with target.open("xb") as output:
            for chunk in response.iter_content(1<<20):
                length += len(chunk)
                require(length <= MAX_BYTES, "Asset exceeds size limit")
                output.write(chunk)
    require(file_hash(target)==item["sha256"], "Source asset checksum mismatch")


def unpack(source, target):
    if target.exists():
        return
    target.mkdir()
    size = 0
    with tarfile.open(source) as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts, "Unsafe archive member")
            dest = target.joinpath(*path.parts)
            if member.isdir():
                dest.mkdir(parents=True,exist_ok=True)
                continue
            require(member.isfile(), "Unexpected archive member type")
            size += member.size
            require(size <= 2*MAX_BYTES, "Expanded asset exceeds limit")
            dest.parent.mkdir(parents=True,exist_ok=True)
            with archive.extractfile(member) as src, dest.open("xb") as dst:
                import shutil
                shutil.copyfileobj(src,dst)


def command(args):
    proc = subprocess.run(args, stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    require(proc.returncode==0, f"{args[0]} {args[1]} failed")
    return proc.stdout


def manifest(row):
    result = requests.get(f"https://{REGISTRY}/v2/{row['repo']}/manifests/{row['tag']}",
                          headers={"Accept":ACCEPT},auth=(os.environ["OCI_USERNAME"],os.environ["OCI_PASSWORD"]), timeout=30,allow_redirects=False)
    if result.status_code==404:
        return None
    require(result.status_code==200, f"Registry manifest lookup returned {result.status_code}")
    return result.content


def matches(row, raw):
    if not raw:
        return False
    if row["format"]=="chart":
        layers=json.loads(raw).get("layers",[])
        return len(layers)==1 and layers[0]["mediaType"]=="application/vnd.cncf.helm.chart.content.v1.tar+gzip" and layers[0]["digest"]==row["digest"]
    return "sha256:"+hashlib.sha256(raw).hexdigest()==row["digest"]


def publish():
    plan = validate()
    packet = json.loads(Path("packet.json").read_text())
    require(packet["run_id"] == os.environ["GITHUB_RUN_ID"] and packet["attempt"] == os.environ["GITHUB_RUN_ATTEMPT"], "Sealed session mismatch")
    expected={r["asset_sha256"] for r in plan}
    require(len(packet["assets"])==len(expected) and {a["sha256"] for a in packet["assets"]}==expected, "Source set differs from approved plan")
    for asset in packet["assets"]:
        download(asset,Path(asset["sha256"][7:]))
    Path("packet.json").unlink()
    prepared=[]
    for row in plan:
        asset=Path(row["asset_sha256"][7:])
        if row["format"]=="chart":
            import yaml
            chart=yaml.safe_load(command(["helm","show","chart",str(asset)]))
            require(chart["name"]==row["repo"].split("/")[-1] and str(chart["version"])==row["tag"], "Chart identity differs")
            payload=Path(chart["name"]+"-"+row["tag"]+".tgz")
            os.link(asset,payload)
        else:
            directory=Path(str(asset)+".layout")
            unpack(asset,directory)
            layout=directory/row.get("layout",".")
            index=json.loads((layout/"index.json").read_text())
            require(any(d.get("digest")==row["digest"] for d in index["manifests"]), "Layout descriptor differs")
            require(file_hash(layout/"blobs"/"sha256"/row["digest"][7:])==row["digest"], "Manifest blob differs")
            payload=str(layout)+"@"+row["digest"]
        current=manifest(row)
        require(current is None or matches(row,current),"Conflicting released tag; no writes issued")
        prepared.append((row,payload))
    for row,payload in prepared:
        current=manifest(row)
        require(current is None or matches(row,current),"Target changed after verification")
        if current is None:
            if row["format"]=="chart":
                command(["helm","push",str(payload),"oci://"+REGISTRY+"/"+row["repo"].rsplit("/",1)[0]])
            else:
                command(["oras","cp","--from-oci-layout",payload,f"{REGISTRY}/{row['repo']}:{row['tag']}"])
        actual=manifest(row)
        require(matches(row,actual),"Published manifest differs from review")
        identity="sha256:"+hashlib.sha256(actual).hexdigest()
        print(f"Verified {REGISTRY}/{row['repo']}:{row['tag']}@{identity}",flush=True)


if __name__=="__main__":
    try:
        {"check":validate,"receive":receive,"publish":publish}[sys.argv[1]]()
    except ValueError as error:
        # JSON/registry parsers may include private data; disclose only our controlled messages.
        if type(error) is ValueError and len(str(error))<100:
            sys.exit(str(error))
        sys.exit("Invalid release data")
    except Exception as error:
        sys.exit("Release validation failed ("+type(error).__name__+")")
