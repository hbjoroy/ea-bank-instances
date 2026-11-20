#!/usr/bin/env bash
# Check the exact Accounting OCI release pair against a rendered bank candidate.
set -euo pipefail
umask 077

if (( $# != 6 && $# != 9 )); then
  echo "Usage: $0 CHECKER SCHEDULES.json ACCOUNTING_MANIFEST@sha256:DIGEST OTHER_DEFINITIONS OTHER_WORKERS.json CANDIDATE_VALUES.yaml [INSTANCE_CHART RELEASE_NAME KUBE_NAMESPACE]" >&2
  exit 2
fi
checker=$1
schedules=$2
manifest_ref=$3
other_definitions=$4
other_workers=$5
values=$6

if [[ ! "$manifest_ref" =~ ^([^/]+)/bank-platform/accounting/manifest@sha256:[a-f0-9]{64}$ ]]; then
  echo "Use the digest-pinned Accounting Heart manifest from Accounting CI" >&2
  exit 1
fi
registry=${BASH_REMATCH[1]}
chart=${7:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
release_name=${8:-minoa}
kube_namespace=${9:-minoa-bank}
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
oras_opts=()
case "$registry" in localhost:*|127.0.0.1:*) oras_opts=(--plain-http) ;; esac

oras pull "${oras_opts[@]}" --output "$scratch/manifest" "$manifest_ref" >&2
manifest="$scratch/manifest/manifest.json"
revision=$(jq -er 'select(.domain == "accounting") | .revision | select(test("^[a-f0-9]{40}$"))' "$manifest")
image=$(jq -er .image "$manifest")
jq -e --slurpfile manifest "$manifest" '
  all(.[] | select(.enabled and .definition_name == "month-end-batch");
    . as $plan | any($manifest[0].definitions[];
      .name == $plan.definition_name and .namespace == $plan.definition_namespace and
      .version == $plan.definition_version))
' "$schedules" >/dev/null || {
  echo "The enabled month-end definition is missing from the Accounting OCI candidate" >&2
  exit 1
}
image_base="$registry/bank/accounting-api:git-$revision@"
if [[ "$image" != "$image_base"* || ! "${image#"$image_base"}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "Accounting manifest does not identify a digest-pinned worker from the same revision" >&2
  exit 1
fi

helm template "$release_name" "$chart" --namespace "$kube_namespace" -f "$values" > "$scratch/rendered.yaml"
namespace=$(python3 - "$scratch/rendered.yaml" "$image" "$schedules" <<'PY'
import json
import sys
import yaml

rendering, image, schedules = sys.argv[1:]
with open(rendering) as source:
    workers = [
        container
        for doc in yaml.safe_load_all(source)
        if doc and doc.get("kind") == "Deployment" and doc["spec"].get("replicas", 1) > 0
        for container in doc["spec"]["template"]["spec"]["containers"]
        if container["name"] == "accounting-api"
    ]
if len(workers) != 1 or workers[0]["image"] != image:
    found = [worker["image"] for worker in workers]
    raise SystemExit(f"Candidate must render the running Accounting worker {image}; found {found}")
environment = {entry["name"]: entry.get("value") for entry in workers[0].get("env", [])}
if not environment.get("HEART_API_URL") or not environment.get("HEART_NAMESPACE", "default"):
    raise SystemExit("Render Accounting's Heart endpoint and namespace explicitly for preflight")
with open(schedules) as source:
    month_end = any(plan["enabled"] and plan["definition_name"] == "month-end-batch"
                    for plan in json.load(source))
if month_end and environment.get("ACCOUNTING_BANK_TIMEZONE") != "Europe/Oslo":
    raise SystemExit("Month-end requires the Accounting deployment to render ACCOUNTING_BANK_TIMEZONE=Europe/Oslo")
print(environment.get("HEART_NAMESPACE", "default"))
PY
)

mkdir "$scratch/staged"
cp -a "$other_definitions/." "$scratch/staged/"
jq -er --arg tag "git-$revision" '
  .definitions | select(length > 0) | .[] |
  if .state == "candidate" and (.name | test("^[a-z][a-z0-9-]*$")) and
     .ref == ("accounting/" + .name + ":" + $tag) and
     (.digest | test("^sha256:[a-f0-9]{64}$")) and
     (.content_digest | test("^sha256:[a-f0-9]{64}$"))
  then [.name, .namespace, .version, .digest, .content_digest] | @tsv
  else error("invalid Accounting definition in candidate manifest")
  end
' "$manifest" > "$scratch/definitions.tsv"
while IFS=$'\t' read -r name definition_namespace version digest content_digest; do
  destination="$scratch/staged/accounting-candidate/$name"
  mkdir -p "$destination"
  oras pull "${oras_opts[@]}" --output "$destination" \
    "$registry/bank-platform/accounting/$name@$digest" >&2
  checksum=sha256:$(sha256sum "$destination/$name.yaml" | cut -d ' ' -f 1)
  if [[ "$checksum" != "$content_digest" ]]; then
    echo "Wrong YAML content digest for Accounting process $name" >&2
    exit 1
  fi
  python3 - "$destination" "$name" "$definition_namespace" "$version" <<'PY'
from pathlib import Path
import sys
import yaml

path, name, namespace, version = sys.argv[1:]
artifact = Path(path) / f"{name}.yaml"
if list(Path(path).iterdir()) != [artifact]:
    raise SystemExit(f"Unexpected files in Accounting artifact {name}")
definition = yaml.safe_load(artifact.read_text())
if (definition["name"], definition.get("namespace", "default"), definition["version"]) != (name, namespace, version):
    raise SystemExit(f"Identity mismatch in Accounting artifact {name}")
PY
done < "$scratch/definitions.tsv"

# Inspect the deployed entrypoint's queue registry, without network or database access.
docker run --rm --pull=always --network=none --entrypoint /usr/local/bin/service \
  -e "HEART_NAMESPACE=$namespace" "$image" --print-heart-queues |
  jq -e --arg image "$image" --arg namespace "$namespace" '
    select(.namespace == $namespace and (.queues | type) == "array") + {image: $image}
  ' > "$scratch/accounting-worker.json"
jq -e --slurpfile accounting "$scratch/accounting-worker.json" '. + $accounting' \
  "$other_workers" > "$scratch/workers.json"
"$checker" "$schedules" "$scratch/staged" "$scratch/rendered.yaml" "$scratch/workers.json"
