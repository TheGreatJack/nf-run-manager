#!/usr/bin/env bash
# omics-check.sh — Check the current status of a HealthOmics run and update
#                  the project run registry if it has reached a terminal state.
#
# Use this after submitting with --no-wait, or to resume tracking a run whose
# polling loop was interrupted (e.g. terminal closed, timeout).
#
# Usage:
#   scripts/omics-check.sh <run_name>
#
# <run_name> is the local run label as it appears in run_registry.tsv,
# e.g. 2026-03-02_minimal_nf-core_cloud-smoke-test-v2

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/runs/run_registry.tsv"

# ── Source project config ─────────────────────────────────────────────────────
CONFIG_FILE="${PROJECT_ROOT}/.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

AWS_PROFILE="${NF_RUNNER_AWS_PROFILE:-}"
AWS_REGION="${NF_RUNNER_REGION:-us-east-1}"

TERMINAL_STATES=("COMPLETED" "FAILED" "CANCELLED" "DELETED")

# ── Argument ──────────────────────────────────────────────────────────────────
RUN_NAME="${1:-}"
[[ -z "${RUN_NAME}" ]] && { echo "Usage: $(basename "$0") <run_name>" >&2; exit 1; }

# ── Look up HealthOmics run ID from registry ──────────────────────────────────
ROW=$(grep -P "^${RUN_NAME}\t" "${REGISTRY}" || true)
[[ -z "${ROW}" ]] && { echo "Error: '${RUN_NAME}' not found in run_registry.tsv" >&2; exit 1; }

OMICS_RUN_ID=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $2}')
CURRENT_REG_STATUS=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $9}')
ENV=$(echo "${ROW}" | awk 'BEGIN{FS="\t"}{print $10}')

[[ "${ENV}" != "healthomics" ]] && {
    echo "Error: Run '${RUN_NAME}' is not a HealthOmics run (environment: ${ENV})" >&2
    exit 1
}

[[ -z "${OMICS_RUN_ID}" || "${OMICS_RUN_ID}" == "n/a" ]] && {
    echo "Error: No valid HealthOmics run ID in registry for '${RUN_NAME}'" >&2
    exit 1
}

echo "Run name   : ${RUN_NAME}"
echo "Omics ID   : ${OMICS_RUN_ID}"
echo "Reg status : ${CURRENT_REG_STATUS}"
echo ""

# ── Call get-run ──────────────────────────────────────────────────────────────
set +e
RUN_DETAILS=$(aws omics get-run \
    --id      "${OMICS_RUN_ID}" \
    --profile "${AWS_PROFILE}" \
    --region  "${AWS_REGION}" 2>&1)
GET_EXIT=$?
set -e

if [[ ${GET_EXIT} -ne 0 ]]; then
    echo "Error: get-run failed:" >&2
    echo "${RUN_DETAILS}" >&2
    exit ${GET_EXIT}
fi

CURRENT_STATUS=$(echo "${RUN_DETAILS}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['status'])")
STATUS_MSG=$(echo "${RUN_DETAILS}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('statusMessage',''))" 2>/dev/null || true)

echo "Live status: ${CURRENT_STATUS}${STATUS_MSG:+ — ${STATUS_MSG}}"

# ── If terminal, update the registry ─────────────────────────────────────────
IS_TERMINAL=false
for ts in "${TERMINAL_STATES[@]}"; do
    [[ "${CURRENT_STATUS}" == "${ts}" ]] && IS_TERMINAL=true && break
done

if [[ "${IS_TERMINAL}" == "true" ]]; then
    RUN_DIR="${PROJECT_ROOT}/runs/${RUN_NAME}"
    echo "${RUN_DETAILS}" > "${RUN_DIR}/final_run_details.json"

    ENGINE_VERSION=$(echo "${RUN_DETAILS}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('engineVersion','unknown'))" \
        2>/dev/null || echo "unknown")

    LOWER_STATUS=$(echo "${CURRENT_STATUS}" | tr '[:upper:]' '[:lower:]')
    TMP=$(mktemp)
    awk -v run="${RUN_NAME}" -v status="${LOWER_STATUS}" -v eng_ver="${ENGINE_VERSION}" \
        'BEGIN { FS=OFS="\t" }
         $1 == run { $7 = eng_ver; $9 = status }
         { print }' "${REGISTRY}" > "${TMP}"
    mv "${TMP}" "${REGISTRY}"

    echo ""
    echo "Registry updated → status: ${LOWER_STATUS}, engine: ${ENGINE_VERSION}"
    echo ""
    echo "→ Fill in summary when ready:"
    echo "    scripts/nf-summarize.sh ${RUN_NAME}"
else
    echo ""
    echo "Run is still active — registry not modified."
    echo "Re-run this script later to update when it reaches a terminal state."
fi
