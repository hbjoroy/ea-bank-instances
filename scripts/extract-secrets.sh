#!/bin/bash
# Extract DB credentials secrets from running bank instances.
# Run BEFORE ArgoCD first sync to back up existing passwords.
#
# Usage: ./scripts/extract-secrets.sh [namespace...]
# If no namespaces given, extracts from all bank instance namespaces.
#
# Output: one YAML file per namespace in ./secrets-backup/

set -euo pipefail

BACKUP_DIR="./secrets-backup"
mkdir -p "$BACKUP_DIR"

# Default namespaces (all bank instances)
if [ $# -eq 0 ]; then
  NAMESPACES=(minoa-bank isdalen bragd-rtgs)
else
  NAMESPACES=("$@")
fi

echo "╭──────────────────────────────────────────────────╮"
echo "│  Extracting DB credential secrets                │"
echo "╰──────────────────────────────────────────────────╯"
echo ""

for NS in "${NAMESPACES[@]}"; do
  echo "── Namespace: $NS ──"

  # Find all secrets
  SECRETS=$(kubectl get secrets -n "$NS" -o name 2>/dev/null || echo "")

  if [ -z "$SECRETS" ]; then
    echo "  ⚠  No secrets found (namespace may not exist)"
    continue
  fi

  OUTFILE="$BACKUP_DIR/${NS}-secrets.yaml"
  > "$OUTFILE"

  for SECRET in $SECRETS; do
    SECRET_NAME=$(echo "$SECRET" | sed 's|secret/||')

    # Skip default service account tokens and helm release secrets
    case "$SECRET_NAME" in
      default-token-*|sh.helm.release.*) continue ;;
    esac

    echo "  Extracting: $SECRET_NAME"
    kubectl get "$SECRET" -n "$NS" -o yaml >> "$OUTFILE"
    echo "---" >> "$OUTFILE"
  done

  echo "  → Saved to $OUTFILE"
  echo ""
done

echo "╭──────────────────────────────────────────────────╮"
echo "│  ✓ Backup complete: $BACKUP_DIR/                 │"
echo "│                                                  │"
echo "│  To restore a secret after ArgoCD overwrites it: │"
echo "│  kubectl apply -f $BACKUP_DIR/<ns>-secrets.yaml  │"
echo "╰──────────────────────────────────────────────────╯"
