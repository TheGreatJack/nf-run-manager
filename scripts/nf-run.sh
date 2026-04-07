#!/usr/bin/env bash
# nf-run.sh — Wraps a local Nextflow run with full bookkeeping.
#
# Usage:
#   scripts/nf-run.sh --name <label> --dataset <dataset> \
#                     --nf-version <version> --params <file> \
#                     [-- <extra nextflow args>]
#
# Everything after -- is forwarded verbatim to `nextflow run`, allowing
# arbitrary pipeline parameters or Nextflow options to be passed through.
# Examples:
#   -- --resume
#   -- --resume --max_cpus 8
#   -- -with-dag runs/dag.html
#
# The script resolves the project root from its own location, so it can be
# invoked from anywhere.

set -uo pipefail

# ── Project paths ─────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/runs/run_registry.tsv"
WORKFLOW_DIR="${PROJECT_ROOT}/workflow/onionomics-nextflow"

# ── Source project config ─────────────────────────────────────────────────────
CONFIG_FILE="${PROJECT_ROOT}/.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# ── Argument parsing ──────────────────────────────────────────────────────────
NAME=""
DATASET=""
NF_VERSION=""
PARAMS=""
EXTRA_NF_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       NAME="$2";       shift 2 ;;
        --dataset)    DATASET="$2";    shift 2 ;;
        --nf-version) NF_VERSION="$2"; shift 2 ;;
        --params)     PARAMS="$2";     shift 2 ;;
        --)           shift; EXTRA_NF_ARGS=("$@"); break ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate required arguments ───────────────────────────────────────────────
[[ -z "$NAME" ]]       && { echo "Error: --name is required" >&2;       exit 1; }
[[ -z "$DATASET" ]]    && { echo "Error: --dataset is required" >&2;    exit 1; }
[[ -z "$NF_VERSION" ]] && { echo "Error: --nf-version is required" >&2; exit 1; }
[[ -z "$PARAMS" ]]     && { echo "Error: --params is required" >&2;     exit 1; }

# ── Validate preconditions ────────────────────────────────────────────────────
[[ ! -d "${PROJECT_ROOT}/data/test_data/${DATASET}" ]] && {
    echo "Error: Dataset '${DATASET}' not found in data/test_data/" >&2
    exit 1
}

NF_BINARY=$(ls "${PROJECT_ROOT}/nextflow_binaries/nextflow-${NF_VERSION}"* 2>/dev/null | head -1)
[[ -z "$NF_BINARY" ]] && {
    echo "Error: No binary matching nextflow-${NF_VERSION}* in nextflow_binaries/" >&2
    exit 1
}

[[ ! -f "$PARAMS" ]] && {
    echo "Error: Params file '${PARAMS}' not found" >&2
    exit 1
}

# ── Derive run name ───────────────────────────────────────────────────────────
DATE=$(date +%Y-%m-%d)
RUN_NAME="${DATE}_${DATASET}_${NAME}"
RUN_DIR="${PROJECT_ROOT}/runs/${RUN_NAME}"

[[ -d "$RUN_DIR" ]] && {
    echo "Error: Run folder already exists: runs/${RUN_NAME}" >&2
    exit 1
}

# ── Collect git info from workflow repo ───────────────────────────────────────
PIPELINE_VERSION=$(git -C "$WORKFLOW_DIR" branch --show-current 2>/dev/null \
    || git -C "$WORKFLOW_DIR" describe --tags 2>/dev/null \
    || echo "unknown")
GIT_COMMIT=$(git -C "$WORKFLOW_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ── Create run folder structure ───────────────────────────────────────────────
mkdir -p "${RUN_DIR}/outputs" "${RUN_DIR}/workdir" "${RUN_DIR}/publishDir"
PARAMS_FILENAME=$(basename "$PARAMS")
cp "$PARAMS" "${RUN_DIR}/${PARAMS_FILENAME}"
INPUT_PARAMS="runs/${RUN_NAME}/${PARAMS_FILENAME}"

echo "──────────────────────────────────────────────"
echo "  Run name  : ${RUN_NAME}"
echo "  Workflow  : ${PIPELINE_VERSION} @ ${GIT_COMMIT}"
echo "  NF binary : $(basename "$NF_BINARY")"
echo "  Dataset   : ${DATASET}"
echo "  Params    : ${PARAMS_FILENAME}"
echo "  Outdir    : runs/${RUN_NAME}/publishDir"
if [[ ${#EXTRA_NF_ARGS[@]} -gt 0 ]]; then
    echo "  Extra args: ${EXTRA_NF_ARGS[*]}"
fi
echo "──────────────────────────────────────────────"

# ── Activate conda environment ────────────────────────────────────────────────
CONDA_BASE=$(conda info --base 2>/dev/null) || {
    echo "Error: conda not found in PATH" >&2
    exit 1
}
# shellcheck disable=SC1091
source "${CONDA_BASE}/etc/profile.d/conda.sh"
conda activate nf-core

# ── Run Nextflow ──────────────────────────────────────────────────────────────
set +e
"$NF_BINARY" -log "${RUN_DIR}/nextflow.log" \
    run "$WORKFLOW_DIR" \
    -w "${RUN_DIR}/workdir" \
    -params-file "$PARAMS" \
    -with-report "${RUN_DIR}/outputs/report.html" \
    -with-timeline "${RUN_DIR}/outputs/timeline.html" \
    --outdir "${RUN_DIR}/publishDir" \
    ${EXTRA_NF_ARGS[@]+"${EXTRA_NF_ARGS[@]}"}
NF_EXIT=$?
set -e

# ── Determine status ──────────────────────────────────────────────────────────
if [[ $NF_EXIT -eq 0 ]]; then
    STATUS="completed"
else
    STATUS="failed"
fi

# ── Extract Nextflow-assigned run ID from log ─────────────────────────────────
# Log line format: ... [main] INFO ... Launching `main.nf` [chubby_curie] DSL2 ...
# The thread name [main] appears before the run ID, so we anchor after the backtick path.
NF_RUN_ID=$(grep -m1 "Launching" "${RUN_DIR}/nextflow.log" 2>/dev/null \
    | grep -oP 'Launching\s+`[^`]+`\s+\[\K[^\]]+' || true)
NF_RUN_ID="${NF_RUN_ID:-unknown}"

# ── Append row to run registry ────────────────────────────────────────────────
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$RUN_NAME" "$NF_RUN_ID" "$DATE" "$DATASET" \
    "$PIPELINE_VERSION" "$GIT_COMMIT" "$NF_VERSION" \
    "$INPUT_PARAMS" "$STATUS" "local" "" \
    "FILL_ME" "FILL_ME" \
    >> "$REGISTRY"

echo ""
echo "Status     : ${STATUS} (exit code: ${NF_EXIT})"
echo "Registered : runs/run_registry.tsv"
echo ""
echo "→ Fill in purpose and summary when ready:"
echo "    scripts/nf-summarize.sh ${RUN_NAME}"
echo ""

exit $NF_EXIT
