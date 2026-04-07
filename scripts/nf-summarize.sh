#!/usr/bin/env bash
# nf-summarize.sh — Interactively fill in purpose and summary for a registered run.
#
# Usage:
#   scripts/nf-summarize.sh <run_name>

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/runs/run_registry.tsv"

# ── Argument ──────────────────────────────────────────────────────────────────
RUN_NAME="${1:-}"
[[ -z "$RUN_NAME" ]] && { echo "Usage: $(basename "$0") <run_name>" >&2; exit 1; }

# ── Verify the run exists ─────────────────────────────────────────────────────
if ! grep -qP "^${RUN_NAME}\t" "$REGISTRY"; then
    echo "Error: Run '${RUN_NAME}' not found in run_registry.tsv" >&2
    exit 1
fi

# ── Show current row ──────────────────────────────────────────────────────────
echo "Run found:"
grep -P "^${RUN_NAME}\t" "$REGISTRY"
echo ""

# ── Prompt ────────────────────────────────────────────────────────────────────
read -r -p "Purpose of this run: " PURPOSE
read -r -p "Post-run summary/analysis: " SUMMARY

# Strip embedded tabs to keep TSV valid
PURPOSE="${PURPOSE//$'\t'/ }"
SUMMARY="${SUMMARY//$'\t'/ }"

# ── Update registry in-place ──────────────────────────────────────────────────
# purpose = col 12, summary = col 13
TMP=$(mktemp)
awk -v run="$RUN_NAME" -v purpose="$PURPOSE" -v summary="$SUMMARY" \
    'BEGIN { FS=OFS="\t" }
     $1 == run { $12 = purpose; $13 = summary }
     { print }' "$REGISTRY" > "$TMP"
mv "$TMP" "$REGISTRY"

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "Updated row:"
grep -P "^${RUN_NAME}\t" "$REGISTRY"
