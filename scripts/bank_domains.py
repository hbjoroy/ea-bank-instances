"""Verify six immutable financial-process definitions and activate them for one bank."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import requests
import yaml

HOST = "oci.bjoroy.me"
MANIFEST_TYPE = "application/vnd.bank.definition-manifest.v1+yaml"
DEFINITION_TYPE = "application/vnd.heart.definition.v1+yaml"
MEDIA = "application/vnd.oci.image.manifest.v1+json"
DIGEST = re.compile("sha256:[0-9a-f]{64}")
VERSIONS = {
    "products": {"daily-savings-interest":"1.0.0","daily-savings-batch":"1.0.0"},
    "treasury": {"daily-position":"2.0.0"},
    "accounting": {"eod-batch":"2.0.0","month-end-batch":"2.0.0","gl-sync":"1.0.0"},
}


def check(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def fetch(repo, kind, reference, missing=False):
    url = f"https://{HOST}/v2/{repo}/{kind}/{reference}"
    response = requests.get(url, headers={"Accept":MEDIA if kind=="manifests" else "*/*"}, timeout=30)
    if missing and response.status_code==404:
        return None
    check(response.ok, f"Registry read returned {response.status_code}")
    data = response.content
    if reference.startswith("sha256:"):
        check(sha(data)==reference, "Registry bytes differ from the approved digest")
    return data


def head(repo, tag):
    raw=fetch(repo,"manifests",tag,missing=True)
    return sha(raw) if raw is not None else None


def artifact(repo, reference, expected_type):
    manifest=json.loads(fetch(repo,"manifests",reference))
    layers=manifest.get("layers",[])
    check(manifest.get("artifactType")==expected_type and len(layers)==1, "Wrong OCI artifact type or layer count")
    layer=layers[0]
    check(layer.get("mediaType")=="application/x-yaml" and DIGEST.fullmatch(layer.get("digest","")), "Invalid YAML layer")
    data=fetch(repo,"blobs",layer["digest"])
    check(len(data)==layer["size"] and len(data)<=4*1024*1024, "Invalid content size")
    return data


def choose(document, domain, selected):
    check(document.get("domain")==domain and isinstance(document.get("definitions"),list), "Bank domain identity differs")
    result=deepcopy(document)
    for name, version in VERSIONS[domain].items():
        rows=[r for r in result["definitions"] if r["name"]==name]
        check(len({r["version"] for r in rows})==len(rows) and sum(r["state"]=="production" for r in rows)<=1, "Ambiguous bank definition history")
        current=None
        for row in rows:
            if row["version"]==version:
                current=row
            elif row["state"]=="production":
                row["state"]="replaced"
        if current is None:
            current={"name":name,"version":version}
            result["definitions"].append(current)
        current.update(state="production",ref=f"{domain}/{name}@{selected[name]['digest']}")
    return result


def oras(*args,cwd=None):
    status=subprocess.run(["oras",*args],cwd=cwd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    check(status.returncode==0, "Registry copy or tag operation failed")


def immutable_copy(source,target,digest):
    tag="release-"+digest[7:]
    prior=head(target,tag)
    check(prior in (None,digest),"Immutable bank artifact tag conflict")
    if prior is None:
        oras("cp",f"{HOST}/{source}@{digest}",f"{HOST}/{target}:{tag}")
    check(head(target,tag)==digest,"Copied artifact digest differs")


def review(bank, domain, selection):
    check(set(selection)=={"expected_manifest","definitions"}, "Unexpected selection fields")
    prior=selection["expected_manifest"]
    check(prior is None or DIGEST.fullmatch(prior),"Invalid previous manifest digest")
    selected=selection["definitions"]
    check(set(selected)==set(VERSIONS[domain]), "Selection differs from required definitions")
    manifest=f"{bank}/{domain}/manifest"
    current=head(manifest,"latest")
    document=yaml.safe_load(artifact(manifest,current,MANIFEST_TYPE)) if current else {"domain":domain,"definitions":[]}
    copies=[]
    for name, version in VERSIONS[domain].items():
        d=selected[name]
        check(set(d)=={"digest","content_digest"} and all(DIGEST.fullmatch(v) for v in d.values()), "Missing reviewed manifest or content digest")
        source=f"bank-platform/{domain}/{name}"
        target=f"{bank}/{domain}/{name}"
        raw=artifact(source,d["digest"],DEFINITION_TYPE)
        identity=yaml.safe_load(raw)
        check(sha(raw)==d["content_digest"] and (identity.get("namespace"),identity.get("name"),identity.get("version"))==("default",name,version), "Selected definition identity or content differs")
        for existing in document["definitions"]:
            if existing["name"]!=name or existing["version"]!=version:
                continue
            prefix=f"{domain}/{name}"
            ref=existing["ref"]
            if ref.startswith(prefix+"@") and DIGEST.fullmatch(ref[len(prefix)+1:]):
                old=ref[len(prefix)+1:]
            elif ref.startswith(prefix+":") and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}",ref[len(prefix)+1:]):
                old=head(target,ref[len(prefix)+1:])
            else:
                raise RuntimeError("Unsupported existing bank definition reference")
            check(old and artifact(target,old,DEFINITION_TYPE)==raw,"Existing version has different content")
        copies.append((source,target,d["digest"]))
    updated=choose(document,domain,selected)
    changed=updated!=document
    check(not changed or current==prior, "Bank manifest changed since approval")
    print(f"{bank}/{domain} expected={prior} observed={current} changed={changed}",flush=True)
    return manifest,current,changed,updated,copies


def activate(plan):
    repo, previous, changed, updated, copies=plan
    if not changed:
        return
    for source,target,digest in copies:
        immutable_copy(source,target,digest)
    payload=(json.dumps(updated,ensure_ascii=False,sort_keys=True,separators=(",",":"))+"\n").encode()
    candidate_tag="reviewed-"+sha(payload)[7:]
    desired=head(repo,candidate_tag)
    if desired is None:
        with tempfile.TemporaryDirectory() as folder:
            Path(folder,"manifest.json").write_bytes(payload)
            oras("push","--artifact-type",MANIFEST_TYPE,"--annotation","org.opencontainers.image.created=1970-01-01T00:00:00Z",f"{HOST}/{repo}:{candidate_tag}","manifest.json:application/x-yaml",cwd=folder)
        desired=head(repo,candidate_tag)
    check(desired and artifact(repo,desired,MANIFEST_TYPE)==payload, "Prepared bank manifest differs from reviewed content")
    if previous:
        saved="before-"+previous[7:]
        oldcopy=head(repo,saved)
        check(oldcopy in (None,previous),"Rollback tag conflict")
        if oldcopy is None:
            oras("tag",f"{HOST}/{repo}@{previous}",saved)
        check(head(repo,saved)==previous,"Previous bank manifest was not retained")
    check(head(repo,"latest")==previous,"Bank manifest changed during preparation")
    oras("tag",f"{HOST}/{repo}@{desired}","latest")
    check(head(repo,"latest")==desired and artifact(repo,desired,MANIFEST_TYPE)==payload, "Bank activation readback differs")
    print(f"Verified {repo}:latest@{desired}",flush=True)


def main():
    bank=os.environ["BANK"]
    check(bank in {"minoa","isdalen"}, "Unknown bank")
    selection=json.loads(os.environ["SELECTION"])
    check(set(selection)==set(VERSIONS),"Expected all three reviewed domains")
    plans=[review(bank,domain,selection[domain]) for domain in VERSIONS]
    if os.environ.get("APPLY")=="true":
        for plan in plans:
            activate(plan)


if __name__=="__main__":
    try:
        main()
    except RuntimeError as exc:
        sys.exit(str(exc))
    except Exception as exc:
        sys.exit(f"Bank domain validation failed ({type(exc).__name__})")
