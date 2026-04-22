#!/usr/bin/env bash
# omics-run.sh — Submit a Nextflow workflow to AWS HealthOmics Workflows and
#                track its status in the project run registry.
#
# Usage:
#   scripts/omics-run.sh --name <label> --dataset <dataset> \
#                        --params <file> --role-arn <arn> \
#                        [options]
#
# Required
#   --name <label>                     Human label appended to the run name (date_dataset_<label>)
#   --dataset <name>                   Dataset key (must exist under data/test_data/)
#   --params <file>                    Pipeline params JSON (must use S3 paths)
#   --role-arn <arn>                   IAM role ARN for HealthOmics execution [$NF_RUNNER_ROLE_ARN]
#
# Optional — HealthOmics workflow (defaults from .env)
#   --workflow-id <id>                 [$NF_RUNNER_WORKFLOW_ID]
#   --workflow-version-name <name>     [$NF_RUNNER_WORKFLOW_VERSION]
#   --output-uri <s3://...>            [$NF_RUNNER_OMICS_OUTPUT_URI]
#   --region <aws-region>              [$NF_RUNNER_REGION or us-east-1]
#
# Optional — run settings
#   --log-level OFF|FATAL|ERROR|ALL    [ALL]
#   --storage-type DYNAMIC|STATIC      [DYNAMIC]
#   --storage-capacity <gib>           Only meaningful with --storage-type STATIC
#   --run-group-id <id>                Cap compute via a run group
#   --cache-id <id>                    Associate a run cache
#   --cache-behavior CACHE_ON_FAILURE|CACHE_ALWAYS
#
# Optional — script behaviour
#   --no-wait                          Submit and exit; skip status polling
#   --poll-interval <sec>              Seconds between get-run polls [60]
#   --purpose <text>                   Pre-fill the purpose field in the run registry

set -uo pipefail

# ── Project paths ─────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/runs/run_registry.tsv"
# ── Source project config ─────────────────────────────────────────────────────
CONFIG_FILE="${PROJECT_ROOT}/.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

WORKFLOW_DIR="${NF_RUNNER_WORKFLOW_DIR:-${PROJECT_ROOT}/workflow}"

# ── AWS / project defaults (overridable via .env or CLI flags) ────────────────
AWS_PROFILE="${NF_RUNNER_AWS_PROFILE:-}"
DEFAULT_WORKFLOW_ID="${NF_RUNNER_WORKFLOW_ID:-}"
DEFAULT_WORKFLOW_VERSION_NAME="${NF_RUNNER_WORKFLOW_VERSION:-}"
DEFAULT_OUTPUT_URI="${NF_RUNNER_OMICS_OUTPUT_URI:-}"
DEFAULT_REGION="${NF_RUNNER_REGION:-us-east-1}"
DEFAULT_LOG_LEVEL="ALL"
DEFAULT_STORAGE_TYPE="DYNAMIC"
DEFAULT_POLL_INTERVAL=60

# ── Argument parsing ──────────────────────────────────────────────────────────
NAME=""
DATASET=""
PARAMS=""
ROLE_ARN="${NF_RUNNER_ROLE_ARN:-}"
WORKFLOW_ID="${DEFAULT_WORKFLOW_ID}"
WORKFLOW_VERSION_NAME="${DEFAULT_WORKFLOW_VERSION_NAME}"
OUTPUT_URI="${DEFAULT_OUTPUT_URI}"
REGION="${DEFAULT_REGION}"
LOG_LEVEL="${DEFAULT_LOG_LEVEL}"
STORAGE_TYPE="${DEFAULT_STORAGE_TYPE}"
STORAGE_CAPACITY=""
RUN_GROUP_ID=""
CACHE_ID=""
CACHE_BEHAVIOR=""
NO_WAIT=false
POLL_INTERVAL="${DEFAULT_POLL_INTERVAL}"
PURPOSE="FILL_ME"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)                   NAME="${2}";                   shift 2 ;;
        --dataset)                DATASET="${2}";                shift 2 ;;
        --params)                 PARAMS="${2}";                 shift 2 ;;
        --role-arn)               ROLE_ARN="${2}";               shift 2 ;;
        --workflow-id)            WORKFLOW_ID="${2}";            shift 2 ;;
        --workflow-version-name)  WORKFLOW_VERSION_NAME="${2}";  shift 2 ;;
        --output-uri)             OUTPUT_URI="${2}";             shift 2 ;;
        --region)                 REGION="${2}";                 shift 2 ;;
        --log-level)              LOG_LEVEL="${2}";              shift 2 ;;
        --storage-type)           STORAGE_TYPE="${2}";           shift 2 ;;
        --storage-capacity)       STORAGE_CAPACITY="${2}";       shift 2 ;;
        --run-group-id)           RUN_GROUP_ID="${2}";           shift 2 ;;
        --cache-id)               CACHE_ID="${2}";               shift 2 ;;
        --cache-behavior)         CACHE_BEHAVIOR="${2}";         shift 2 ;;
        --no-wait)                NO_WAIT=true;                  shift   ;;
        --poll-interval)          POLL_INTERVAL="${2}";          shift 2 ;;
        --purpose)                PURPOSE="${2}";                shift 2 ;;
        *) echo "Error: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate required arguments ───────────────────────────────────────────────
[[ -z "${NAME}" ]]     && { echo "Error: --name is required" >&2;     exit 1; }
[[ -z "${DATASET}" ]]  && { echo "Error: --dataset is required" >&2;  exit 1; }
[[ -z "${PARAMS}" ]]   && { echo "Error: --params is required" >&2;   exit 1; }
[[ -z "${ROLE_ARN}" ]] && { echo "Error: --role-arn is required" >&2; exit 1; }

[[ ! -f "${PARAMS}" ]] && {
    echo "Error: Params file '${PARAMS}' not found" >&2
    exit 1
}

# ── Strip tabs from purpose to keep TSV valid ─────────────────────────────────
PURPOSE="${PURPOSE//$'\t'/ }"

# ── Derive run name ───────────────────────────────────────────────────────────
DATE=$(date +%Y-%m-%d)
RUN_NAME="${DATE}_${DATASET}_${NAME}"
RUN_DIR="${PROJECT_ROOT}/runs/${RUN_NAME}"

[[ -d "${RUN_DIR}" ]] && {
    echo "Error: Run folder already exists: runs/${RUN_NAME}" >&2
    exit 1
}

# ── Extract version info ──────────────────────────────────────────────────────
# Workflow version names follow the pattern <label>_<short-sha>
# e.g. "Onionomics_dev_e6c0bc828" → git_commit = e6c0bc828
PIPELINE_VERSION="${WORKFLOW_VERSION_NAME}"
GIT_COMMIT=$(echo "${WORKFLOW_VERSION_NAME}" | grep -oP '[a-f0-9]{7,}$' || true)
if [[ -z "${GIT_COMMIT}" ]]; then
    GIT_COMMIT=$(git -C "${WORKFLOW_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

# ── Create run folder and copy params ────────────────────────────────────────
mkdir -p "${RUN_DIR}"
PARAMS_FILENAME=$(basename "${PARAMS}")
cp "${PARAMS}" "${RUN_DIR}/${PARAMS_FILENAME}"
INPUT_PARAMS="runs/${RUN_NAME}/${PARAMS_FILENAME}"

# ── Build tags JSON ───────────────────────────────────────────────────────────
TAGS=$(python3 -c "import json; print(json.dumps({'project': 'rnaseq-omics', 'runName': '${RUN_NAME}'}))")

# ── Build start-run argument list ────────────────────────────────────────────
START_RUN_ARGS=(
    --profile  "${AWS_PROFILE}"
    --region   "${REGION}"
    --workflow-id             "${WORKFLOW_ID}"
    --output-uri              "${OUTPUT_URI}"
    --role-arn                "${ROLE_ARN}"
    --name                    "${RUN_NAME}"
    --log-level               "${LOG_LEVEL}"
    --storage-type            "${STORAGE_TYPE}"
    --parameters              "file://${RUN_DIR}/${PARAMS_FILENAME}"
    --tags                    "${TAGS}"
)
[[ -n "${WORKFLOW_VERSION_NAME}" ]] && START_RUN_ARGS+=(--workflow-version-name "${WORKFLOW_VERSION_NAME}")
[[ -n "${STORAGE_CAPACITY}" ]] && START_RUN_ARGS+=(--storage-capacity "${STORAGE_CAPACITY}")
[[ -n "${RUN_GROUP_ID}" ]]     && START_RUN_ARGS+=(--run-group-id     "${RUN_GROUP_ID}")
[[ -n "${CACHE_ID}" ]]         && START_RUN_ARGS+=(--cache-id         "${CACHE_ID}")
[[ -n "${CACHE_BEHAVIOR}" ]]   && START_RUN_ARGS+=(--cache-behavior   "${CACHE_BEHAVIOR}")

# ── Print summary ─────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────"
echo "  Run name      : ${RUN_NAME}"
echo "  Dataset       : ${DATASET}"
echo "  Params        : ${PARAMS_FILENAME}"
echo "  Workflow ID   : ${WORKFLOW_ID}"
echo "  Version       : ${WORKFLOW_VERSION_NAME}"
echo "  Output URI    : ${OUTPUT_URI}"
echo "  Region        : ${REGION}"
echo "  Role ARN      : ${ROLE_ARN}"
echo "  Log level     : ${LOG_LEVEL}"
echo "  Storage type  : ${STORAGE_TYPE}"
[[ -n "${STORAGE_CAPACITY}" ]] && echo "  Storage cap.  : ${STORAGE_CAPACITY} GiB"
[[ -n "${RUN_GROUP_ID}" ]]     && echo "  Run group     : ${RUN_GROUP_ID}"
[[ -n "${CACHE_ID}" ]]         && echo "  Cache ID      : ${CACHE_ID}"
[[ -n "${CACHE_BEHAVIOR}" ]]   && echo "  Cache behavior: ${CACHE_BEHAVIOR}"
echo "──────────────────────────────────────────────"

# ── Submit the run ────────────────────────────────────────────────────────────
# Note: bash does not trigger set -e for failed command substitutions inside
# variable assignments, so we capture stderr and check exit code explicitly.
echo "Submitting run to AWS HealthOmics..."
set +e
RESPONSE=$(aws omics start-run "${START_RUN_ARGS[@]}" 2>&1)
START_EXIT=$?
set -e

if [[ ${START_EXIT} -ne 0 ]]; then
    echo ""
    echo "Error: start-run failed (exit ${START_EXIT}):" >&2
    echo "${RESPONSE}" >&2
    echo ""
    echo "Run folder kept at: runs/${RUN_NAME}/"
    echo "Registry NOT updated (submission never reached HealthOmics)."
    exit ${START_EXIT}
fi

OMICS_RUN_ID=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
INITIAL_STATUS=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")

echo ""
echo "  HealthOmics run ID : ${OMICS_RUN_ID}"
echo "  Initial status     : ${INITIAL_STATUS}"
echo ""

echo "${RESPONSE}" > "${RUN_DIR}/start_run_response.json"

# ── Register initial entry in run_registry.tsv ────────────────────────────────
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${RUN_NAME}" "${OMICS_RUN_ID}" "${DATE}" "${DATASET}" \
    "${PIPELINE_VERSION}" "${GIT_COMMIT}" "unknown" \
    "${INPUT_PARAMS}" "submitted" "healthomics" \
    "${OUTPUT_URI}" \
    "${PURPOSE}" "FILL_ME" \
    >> "${REGISTRY}"
echo "Registered in run_registry.tsv (status: submitted)"

# ── Exit early if --no-wait ───────────────────────────────────────────────────
if [[ "${NO_WAIT}" == "true" ]]; then
    echo ""
    echo "→ --no-wait set. Monitor status with:"
    echo "    aws omics get-run --id ${OMICS_RUN_ID} --profile ${AWS_PROFILE} --region ${REGION}"
    echo "→ Update the registry when done:"
    echo "    scripts/nf-summarize.sh ${RUN_NAME}"
    exit 0
fi

# ── Poll for status ───────────────────────────────────────────────────────────
echo "Polling for run status every ${POLL_INTERVAL}s (Ctrl-C to stop)..."
echo ""

TERMINAL_STATES=("COMPLETED" "FAILED" "CANCELLED" "DELETED")
FINAL_STATUS=""
ENGINE_VERSION="unknown"

_on_interrupt() {
    echo ""
    echo "Polling interrupted. Run ${OMICS_RUN_ID} may still be running."
    echo "→ Check status with:"
    echo "    aws omics get-run --id ${OMICS_RUN_ID} --profile ${AWS_PROFILE} --region ${REGION}"
    echo "→ Update the registry when done:"
    echo "    scripts/nf-summarize.sh ${RUN_NAME}"
    exit 0
}
trap _on_interrupt INT TERM

while true; do
    set +e
    RUN_DETAILS=$(aws omics get-run \
        --id      "${OMICS_RUN_ID}" \
        --profile "${AWS_PROFILE}" \
        --region  "${REGION}" 2>&1)
    GET_EXIT=$?
    set -e

    if [[ ${GET_EXIT} -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: get-run failed (will retry): ${RUN_DETAILS}"
        sleep "${POLL_INTERVAL}"
        continue
    fi

    CURRENT_STATUS=$(echo "${RUN_DETAILS}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['status'])")
    STATUS_MSG=$(echo "${RUN_DETAILS}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('statusMessage',''))" 2>/dev/null || true)

    if [[ -n "${STATUS_MSG}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${CURRENT_STATUS} — ${STATUS_MSG}"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${CURRENT_STATUS}"
    fi

    for ts in "${TERMINAL_STATES[@]}"; do
        if [[ "${CURRENT_STATUS}" == "${ts}" ]]; then
            FINAL_STATUS="${CURRENT_STATUS}"
            ENGINE_VERSION=$(echo "${RUN_DETAILS}" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('engineVersion','unknown'))" \
                2>/dev/null || echo "unknown")
            echo "${RUN_DETAILS}" > "${RUN_DIR}/final_run_details.json"
            break 2
        fi
    done

    sleep "${POLL_INTERVAL}"
done

trap - INT TERM

# ── Update registry with final status and engine version ─────────────────────
LOWER_STATUS=$(echo "${FINAL_STATUS}" | tr '[:upper:]' '[:lower:]')
TMP=$(mktemp)
awk -v run="${RUN_NAME}" -v status="${LOWER_STATUS}" -v eng_ver="${ENGINE_VERSION}" \
    'BEGIN { FS=OFS="\t" }
     $1 == run { $7 = eng_ver; $9 = status }
     { print }' "${REGISTRY}" > "${TMP}"
mv "${TMP}" "${REGISTRY}"

echo ""
echo "──────────────────────────────────────────────"
echo "  Final status  : ${FINAL_STATUS}"
echo "  Engine version: ${ENGINE_VERSION}"
echo "  Registry updated."
echo "──────────────────────────────────────────────"
echo ""
echo "→ Fill in purpose and summary:"
echo "    scripts/nf-summarize.sh ${RUN_NAME}"
echo ""

[[ "${FINAL_STATUS}" == "COMPLETED" ]] && exit 0 || exit 1
