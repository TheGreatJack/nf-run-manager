#!/usr/bin/env bash
# batch-check.sh — Check the current status of an AWS Batch run and update
#                  the project run registry if it has reached a terminal state.
#
# Use this after submitting with --no-wait, or to resume tracking a run whose
# polling loop was interrupted (e.g. terminal closed, timeout).
#
# Usage:
#   scripts/batch-check.sh <run_name>
#
# <run_name> is the local run label as it appears in run_registry.tsv,
# e.g. 2026-03-20_medium_onion_batch-run1

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/runs/run_registry.tsv"

# ── Source project config ─────────────────────────────────────────────────────
CONFIG_FILE="${PROJECT_ROOT}/.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

AWS_PROFILE="${NF_RUNNER_AWS_PROFILE:-}"
AWS_REGION="${NF_RUNNER_REGION:-us-east-1}"

TERMINAL_STATES=("SUCCEEDED" "FAILED")

# ── Argument ──────────────────────────────────────────────────────────────────
RUN_NAME="${1:-}"
[[ -z "${RUN_NAME}" ]] && { echo "Usage: $(basename "$0") <run_name>" >&2; exit 1; }

# ── Look up Batch job ID from registry ────────────────────────────────────────
ROW=$(grep -P "^${RUN_NAME}\t" "${REGISTRY}" || true)
[[ -z "${ROW}" ]] && { echo "Error: '${RUN_NAME}' not found in run_registry.tsv" >&2; exit 1; }

JOB_ID=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $2}')
CURRENT_REG_STATUS=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $9}')
ENV=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $10}')

[[ "${ENV}" != "batch" ]] && {
    echo "Error: Run '${RUN_NAME}' is not a Batch run (environment: ${ENV})" >&2
    exit 1
}

[[ -z "${JOB_ID}" || "${JOB_ID}" == "n/a" ]] && {
    echo "Error: No valid Batch job ID in registry for '${RUN_NAME}'" >&2
    exit 1
}

echo "Run name   : ${RUN_NAME}"
echo "Job ID     : ${JOB_ID}"
echo "Reg status : ${CURRENT_REG_STATUS}"
echo ""

# ── Call describe-jobs ────────────────────────────────────────────────────────
set +e
JOB_DETAILS=$(aws batch describe-jobs \
    --jobs    "${JOB_ID}" \
    --profile "${AWS_PROFILE}" \
    --region  "${AWS_REGION}" 2>&1)
DESCRIBE_EXIT=$?
set -e

if [[ ${DESCRIBE_EXIT} -ne 0 ]]; then
    echo "Error: describe-jobs failed:" >&2
    echo "${JOB_DETAILS}" >&2
    exit ${DESCRIBE_EXIT}
fi

CURRENT_STATUS=$(echo "${JOB_DETAILS}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['jobs'][0]['status'])" 2>/dev/null || echo "UNKNOWN")
STATUS_REASON=$(echo "${JOB_DETAILS}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['jobs'][0].get('statusReason',''))" 2>/dev/null || true)

echo "Live status: ${CURRENT_STATUS}${STATUS_REASON:+ — ${STATUS_REASON}}"

# ── If terminal, update the registry ─────────────────────────────────────────
IS_TERMINAL=false
for ts in "${TERMINAL_STATES[@]}"; do
    [[ "${CURRENT_STATUS}" == "${ts}" ]] && IS_TERMINAL=true && break
done

if [[ "${IS_TERMINAL}" == "true" ]]; then
    RUN_DIR="${PROJECT_ROOT}/runs/${RUN_NAME}"
    echo "${JOB_DETAILS}" > "${RUN_DIR}/final_job_details.json"

    if [[ "${CURRENT_STATUS}" == "SUCCEEDED" ]]; then
        LOWER_STATUS="completed"
    else
        LOWER_STATUS="failed"
    fi

    TMP=$(mktemp)
    awk -v run="${RUN_NAME}" -v status="${LOWER_STATUS}" \
        'BEGIN { FS=OFS="\t" }
         $1 == run { $9 = status }
         { print }' "${REGISTRY}" > "${TMP}"
    mv "${TMP}" "${REGISTRY}"

    echo ""
    echo "Registry updated → status: ${LOWER_STATUS}"
    echo ""
    echo "→ Fill in summary when ready:"
    echo "    scripts/nf-summarize.sh ${RUN_NAME}"
else
    echo ""
    echo "Run is still active — registry not modified."
    echo "Re-run this script later to update when it reaches a terminal state."
fi
