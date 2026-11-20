"""Check authenticated archive reads without exposing artifact coordinates."""
import os
import re
import sys
from urllib.parse import urlsplit

import requests

node = os.environ["ASSET_NODE"]
if not re.fullmatch(r"RA_[A-Za-z0-9_-]{8,100}", node):
    sys.exit("Expected an opaque release asset node")
query = """query($id:ID!) {
  node(id:$id) { ... on ReleaseAsset {
    databaseId size release {repository {nameWithOwner isPrivate}} } }
}"""
for name in ("BANK_RELEASE_READ_TOKEN", "GH_PAT", "WORKFLOW_TOKEN"):
    token = os.environ.get(name)
    if not token:
        print(f"{name} is unconfigured")
        continue
    headers = {"Authorization": f"Bearer {token}"}
    result = requests.post("https://api.github.com/graphql", json={"query": query, "variables": {"id": node}}, headers=headers, timeout=30)
    asset = (result.json().get("data") or {}).get("node") if result.ok else None
    if not asset:
        print(f"{name} cannot read the candidate")
        continue
    repo = asset["release"]["repository"]
    if not repo["isPrivate"] or not 1 <= asset["size"] <= 512:
        sys.exit("Expected a small private checksum asset")
    owner = os.environ["GITHUB_REPOSITORY_OWNER"]
    slug = repo["nameWithOwner"]
    if not slug.startswith(owner + "/"):
        sys.exit("Unexpected release owner")
    url = f"https://api.github.com/repos/{slug}/releases/assets/{asset['databaseId']}"
    response = requests.get(url, headers={**headers, "Accept":"application/octet-stream"}, allow_redirects=False, timeout=30)
    if response.is_redirect:
        target = response.headers["Location"]
        parsed = urlsplit(target)
        if parsed.scheme != "https" or parsed.hostname not in {"release-assets.githubusercontent.com","objects.githubusercontent.com"}:
            sys.exit("Unexpected asset delivery host")
        response = requests.get(target, timeout=30)
    if response.ok and len(response.content) == asset["size"] and re.fullmatch(rb"sha256:[0-9a-f]{64}\s*", response.content):
        print(f"Authenticated private archive download verified with {name}")
        break
    print(f"{name} cannot download the candidate")
else:
    sys.exit("Private sibling release access is unavailable")
