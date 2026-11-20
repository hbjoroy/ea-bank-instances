#!/usr/bin/env bash
# Read the prepared schedule plan through the normal authenticated admin API.
set -euo pipefail
umask 077

if (( $# != 1 )) || [[ ! "$1" =~ ^https://[^/]+/?$ && ! "$1" =~ ^http://127\.0\.0\.1:[0-9]+/?$ ]]; then
  echo "Usage: $0 https://BANK_ADMIN_HOST < session-token-file" >&2
  exit 2
fi
base=${1%/}
IFS= read -r token
if [[ ! "$token" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Supply a valid admin session token on standard input" >&2
  exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
request() {
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --fail --silent --show-error --max-time 20 "$base/api/$1"
}
request schedules > "$scratch/schedules.json"
request schedules/dependencies > "$scratch/dependencies.json"

jq -e --slurpfile dependencies "$scratch/dependencies.json" '
  . as $schedules | $dependencies[0] as $edges |
  if type != "array" or ($edges | type) != "array" then
    error("admin API did not return schedule and dependency arrays")
  elif any($edges[]; . as $edge |
    (any($schedules[]; .id == $edge.schedule_id) | not) or
    (any($schedules[]; .id == $edge.depends_on and .name == $edge.depends_on_name) | not)) then
    error("admin API returned a dependency outside the schedule plan")
  else
    map(.id as $schedule | {
      name, definition_namespace, definition_name, definition_version, enabled, schedule_type,
      dependencies: [$edges[] | select(.schedule_id == $schedule) | .depends_on_name] | sort
    }) | sort_by(.name)
  end
' "$scratch/schedules.json"
