#!/usr/bin/env bash
# Fail the Minoa release preflight before handing the candidate to Argo CD.
set -euo pipefail
umask 077

if (( $# != 4 && $# != 5 )); then
    echo "Usage: $0 CHECKER SCHEDULES.json DEFINITIONS_DIR WORKERS.json [CANDIDATE_VALUES.yaml]" >&2
    exit 2
fi

checker=$1
schedules=$2
definitions=$3
workers=$4
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rendered=$(mktemp)
trap 'rm -f -- "$rendered"' EXIT

values=()
if (( $# == 5 )); then
    values=(-f "$5")
fi

helm template minoa "$repo_root" --namespace minoa-bank "${values[@]}" > "$rendered"
"$checker" "$schedules" "$definitions" "$rendered" "$workers"
