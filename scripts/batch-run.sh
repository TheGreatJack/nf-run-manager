#!/usr/bin/env bash
# batch-run.sh — Submit a Nextflow workflow to AWS Batch and track its
#                status in the project run registry.
#
# Usage:
#   scripts/batch-run.sh --name <label> --dataset <dataset> \
#                        --params <file> \
#                        --job-queue <queue> --job-definition <def> \
#                        [options]
#
# Required
#   --name <label>                 Human label appended to run name (date_dataset_<label>)
#   --dataset <name>               Dataset key (used as a label — no local validation)
#   --params <file>                Local params file stored as audit copy in the run folder
#   --job-queue <name>             AWS Batch head job queue name
#                                  [$NF_RUNNER_BATCH_JOB_QUEUE or --job-queue flag]
#   --job-definition <name>        AWS Batch job definition name
#                                  [$NF_RUNNER_BATCH_JOB_DEFINITION or --job-definition flag]
#
# Optional — Nextflow pipeline settings (defaults from .env)
#   --pipeline <repo>              Pipeline to run          [$NF_RUNNER_PIPELINE]
#   --revision <tag/branch>        Pipeline revision/branch [$NF_RUNNER_REVISION or main]
#   --nf-profile <profiles>        Nextflow profiles (comma-separated) [docker]
#   --workdir <s3://...>           S3 URI for Nextflow work dir
#                                  [$NF_RUNNER_BATCH_WORKDIR]
#   --output-uri <s3://...>        S3 URI for pipeline results
#                                  [$NF_RUNNER_BATCH_OUTPUT_URI]
#   --extra-args <args>            Extra flags appended to the nextflow run command
#                                  e.g. "--max_memory 16.GB --max_cpus 8 -params-file s3://..."
#   --config-s3 <s3://...>         S3 URI of a custom nextflow.config (NXF_CONFIG_S3)
#   --input-s3 <s3://...>          S3 URI of the samplesheet (NF_INPUT)
#   --params-s3 <s3://...>         S3 URI of a Nextflow params JSON (NF_PARAMS_S3)
#                                  Downloaded to the instance before Nextflow launches
#
# Optional — AWS settings
#   --profile <name>               AWS CLI SSO profile  [$NF_RUNNER_AWS_PROFILE]
#   --region <aws-region>          AWS region           [$NF_RUNNER_REGION or us-east-1]
#
# Optional — script behaviour
#   --no-wait                      Submit and exit; skip status polling
#   --poll-interval <sec>          Seconds between describe-jobs polls [60]
#   --purpose <text>               Pre-fill the purpose field in the run registry

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
DEFAULT_PIPELINE="${NF_RUNNER_PIPELINE:-}"
DEFAULT_REVISION="${NF_RUNNER_REVISION-main}"
DEFAULT_NF_PROFILE="docker"
DEFAULT_WORKDIR="${NF_RUNNER_BATCH_WORKDIR:-}"
DEFAULT_OUTPUT_URI="${NF_RUNNER_BATCH_OUTPUT_URI:-}"
DEFAULT_REGION="${NF_RUNNER_REGION:-us-east-1}"
DEFAULT_JOB_QUEUE="${NF_RUNNER_BATCH_JOB_QUEUE:-}"
DEFAULT_JOB_DEFINITION="${NF_RUNNER_BATCH_JOB_DEFINITION:-}"
DEFAULT_POLL_INTERVAL=60

# ── Argument parsing ──────────────────────────────────────────────────────────
NAME=""
DATASET=""
PARAMS=""
JOB_QUEUE="${DEFAULT_JOB_QUEUE}"
JOB_DEFINITION="${DEFAULT_JOB_DEFINITION}"
PIPELINE="${DEFAULT_PIPELINE}"
REVISION="${DEFAULT_REVISION}"
NF_PROFILE="${DEFAULT_NF_PROFILE}"
WORKDIR="${DEFAULT_WORKDIR}"
OUTPUT_URI="${DEFAULT_OUTPUT_URI}"
EXTRA_ARGS=""
CONFIG_S3=""
INPUT_S3=""
PARAMS_S3=""
REGION="${DEFAULT_REGION}"
NO_WAIT=false
POLL_INTERVAL="${DEFAULT_POLL_INTERVAL}"
PURPOSE="FILL_ME"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)            NAME="${2}";            shift 2 ;;
        --dataset)         DATASET="${2}";         shift 2 ;;
        --params)          PARAMS="${2}";          shift 2 ;;
        --job-queue)       JOB_QUEUE="${2}";       shift 2 ;;
        --job-definition)  JOB_DEFINITION="${2}";  shift 2 ;;
        --pipeline)        PIPELINE="${2}";        shift 2 ;;
        --revision)        REVISION="${2}";        shift 2 ;;
        --nf-profile)      NF_PROFILE="${2}";      shift 2 ;;
        --workdir)         WORKDIR="${2}";          shift 2 ;;
        --output-uri)      OUTPUT_URI="${2}";      shift 2 ;;
        --extra-args)      EXTRA_ARGS="${2}";      shift 2 ;;
        --config-s3)       CONFIG_S3="${2}";       shift 2 ;;
        --input-s3)        INPUT_S3="${2}";        shift 2 ;;
        --params-s3)       PARAMS_S3="${2}";       shift 2 ;;
        --profile)         AWS_PROFILE="${2}";     shift 2 ;;
        --region)          REGION="${2}";          shift 2 ;;
        --no-wait)         NO_WAIT=true;           shift   ;;
        --poll-interval)   POLL_INTERVAL="${2}";   shift 2 ;;
        --purpose)         PURPOSE="${2}";         shift 2 ;;
        *) echo "Error: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate required arguments ───────────────────────────────────────────────
[[ -z "${NAME}" ]]           && { echo "Error: --name is required" >&2;           exit 1; }
[[ -z "${DATASET}" ]]        && { echo "Error: --dataset is required" >&2;        exit 1; }
[[ -z "${PARAMS}" ]]         && { echo "Error: --params is required" >&2;         exit 1; }
[[ -z "${JOB_QUEUE}" ]]      && { echo "Error: --job-queue is required" >&2;      exit 1; }
[[ -z "${JOB_DEFINITION}" ]] && { echo "Error: --job-definition is required" >&2; exit 1; }

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
OUTPUT_URI_RUN="${OUTPUT_URI%/}/${RUN_NAME}"

[[ -d "${RUN_DIR}" ]] && {
    echo "Error: Run folder already exists: runs/${RUN_NAME}" >&2
    exit 1
}

# ── Extract git info from workflow repo (best-effort) ─────────────────────────
GIT_COMMIT=$(git -C "${WORKFLOW_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
PIPELINE_VERSION="${PIPELINE}@${REVISION}"

# ── Create run folder and copy params ────────────────────────────────────────
mkdir -p "${RUN_DIR}"
PARAMS_FILENAME=$(basename "${PARAMS}")
cp "${PARAMS}" "${RUN_DIR}/${PARAMS_FILENAME}"
INPUT_PARAMS="runs/${RUN_NAME}/${PARAMS_FILENAME}"

# ── Build container-overrides JSON ───────────────────────────────────────────
# Variables are passed as env vars to Python to avoid shell quoting issues.
CONTAINER_OVERRIDES=$(
    NF_PIPELINE="${PIPELINE}" \
    NF_REVISION="${REVISION}" \
    NF_PROFILE="${NF_PROFILE}" \
    NF_OUTDIR="${OUTPUT_URI_RUN}" \
    NF_WORKDIR="${WORKDIR}" \
    NF_EXTRA_ARGS="${EXTRA_ARGS}" \
    NXF_CONFIG_S3="${CONFIG_S3}" \
    NF_INPUT="${INPUT_S3}" \
    NF_PARAMS_S3="${PARAMS_S3}" \
    python3 -c '
import json, os

env = [
    {"name": "NF_PIPELINE", "value": os.environ["NF_PIPELINE"]},
    {"name": "NF_REVISION",  "value": os.environ["NF_REVISION"]},
    {"name": "NF_PROFILE",   "value": os.environ["NF_PROFILE"]},
    {"name": "NF_OUTDIR",    "value": os.environ["NF_OUTDIR"]},
    {"name": "NF_WORKDIR",   "value": os.environ["NF_WORKDIR"]},
]

extra = os.environ.get("NF_EXTRA_ARGS", "").strip()
if extra:
    env.append({"name": "NF_EXTRA_ARGS", "value": extra})

config_s3 = os.environ.get("NXF_CONFIG_S3", "").strip()
if config_s3:
    env.append({"name": "NXF_CONFIG_S3", "value": config_s3})

input_s3 = os.environ.get("NF_INPUT", "").strip()
if input_s3:
    env.append({"name": "NF_INPUT", "value": input_s3})

params_s3 = os.environ.get("NF_PARAMS_S3", "").strip()
if params_s3:
    env.append({"name": "NF_PARAMS_S3", "value": params_s3})

print(json.dumps({"environment": env}))
'
)

# ── Build tags JSON ───────────────────────────────────────────────────────────
TAGS=$(python3 -c "import json; print(json.dumps({'project': 'rnaseq-batch', 'runName': '${RUN_NAME}'}))")

# ── Save container-overrides JSON to run folder ──────────────────────────────
echo "${CONTAINER_OVERRIDES}" > "${RUN_DIR}/container_overrides.json"

# ── Print summary ─────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────"
echo "  Run name       : ${RUN_NAME}"
echo "  Dataset        : ${DATASET}"
echo "  Params         : ${PARAMS_FILENAME}"
echo "  Pipeline       : ${PIPELINE} @ ${REVISION}"
echo "  NF profile     : ${NF_PROFILE}"
echo "  Output URI     : ${OUTPUT_URI_RUN}"
echo "  Work dir       : ${WORKDIR}"
echo "  Job queue      : ${JOB_QUEUE}"
echo "  Job definition : ${JOB_DEFINITION}"
echo "  Region         : ${REGION}"
[[ -n "${EXTRA_ARGS}" ]] && echo "  Extra args     : ${EXTRA_ARGS}"
[[ -n "${CONFIG_S3}" ]]  && echo "  Config S3      : ${CONFIG_S3}"
[[ -n "${INPUT_S3}" ]]   && echo "  Input S3       : ${INPUT_S3}"
[[ -n "${PARAMS_S3}" ]]  && echo "  Params S3      : ${PARAMS_S3}"
echo "──────────────────────────────────────────────"

# ── Save the full submit-job command ─────────────────────────────────────────
cat > "${RUN_DIR}/submit_job_cmd.sh" <<EOF
#!/usr/bin/env bash
aws batch submit-job \\
    --profile             "${AWS_PROFILE}" \\
    --region              "${REGION}" \\
    --job-name            "${RUN_NAME}" \\
    --job-queue           "${JOB_QUEUE}" \\
    --job-definition      "${JOB_DEFINITION}" \\
    --tags                '${TAGS}' \\
    --container-overrides "file://\$(dirname "\$0")/container_overrides.json"
EOF
chmod +x "${RUN_DIR}/submit_job_cmd.sh"

# ── Submit the job ─────────────────────────────────────────────────────────────
echo "Submitting job to AWS Batch..."
set +e
RESPONSE=$(aws batch submit-job \
    --profile             "${AWS_PROFILE}" \
    --region              "${REGION}" \
    --job-name            "${RUN_NAME}" \
    --job-queue           "${JOB_QUEUE}" \
    --job-definition      "${JOB_DEFINITION}" \
    --tags                "${TAGS}" \
    --container-overrides "${CONTAINER_OVERRIDES}" 2>&1)
SUBMIT_EXIT=$?
set -e

if [[ ${SUBMIT_EXIT} -ne 0 ]]; then
    echo ""
    echo "Error: submit-job failed (exit ${SUBMIT_EXIT}):" >&2
    echo "${RESPONSE}" >&2
    echo ""
    echo "Run folder kept at: runs/${RUN_NAME}/"
    echo "Registry NOT updated (submission never reached Batch)."
    exit ${SUBMIT_EXIT}
fi

JOB_ID=$(echo "${RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobId'])")

echo ""
echo "  Batch job ID : ${JOB_ID}"
echo ""

echo "${RESPONSE}" > "${RUN_DIR}/submit_job_response.json"

# ── Register initial entry in run_registry.tsv ────────────────────────────────
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${RUN_NAME}" "${JOB_ID}" "${DATE}" "${DATASET}" \
    "${PIPELINE_VERSION}" "${GIT_COMMIT}" "unknown" \
    "${INPUT_PARAMS}" "submitted" "batch" \
    "${OUTPUT_URI_RUN}" \
    "${PURPOSE}" "FILL_ME" \
    >> "${REGISTRY}"
echo "Registered in run_registry.tsv (status: submitted)"

# ── Exit early if --no-wait ───────────────────────────────────────────────────
if [[ "${NO_WAIT}" == "true" ]]; then
    echo ""
    echo "→ --no-wait set. Monitor status with:"
    echo "    aws batch describe-jobs --jobs ${JOB_ID} --profile ${AWS_PROFILE} --region ${REGION}"
    echo "→ Or update the registry when done:"
    echo "    scripts/batch-check.sh ${RUN_NAME}"
    exit 0
fi

# ── Poll for status ───────────────────────────────────────────────────────────
echo "Polling for job status every ${POLL_INTERVAL}s (Ctrl-C to stop)..."
echo ""

TERMINAL_STATES=("SUCCEEDED" "FAILED")
FINAL_STATUS=""

_on_interrupt() {
    echo ""
    echo "Polling interrupted. Job ${JOB_ID} may still be running."
    echo "→ Check status with:"
    echo "    aws batch describe-jobs --jobs ${JOB_ID} --profile ${AWS_PROFILE} --region ${REGION}"
    echo "→ Update the registry when done:"
    echo "    scripts/batch-check.sh ${RUN_NAME}"
    exit 0
}
trap _on_interrupt INT TERM

while true; do
    set +e
    JOB_DETAILS=$(aws batch describe-jobs \
        --jobs    "${JOB_ID}" \
        --profile "${AWS_PROFILE}" \
        --region  "${REGION}" 2>&1)
    DESCRIBE_EXIT=$?
    set -e

    if [[ ${DESCRIBE_EXIT} -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: describe-jobs failed (will retry): ${JOB_DETAILS}"
        sleep "${POLL_INTERVAL}"
        continue
    fi

    CURRENT_STATUS=$(echo "${JOB_DETAILS}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['jobs'][0]['status'])" 2>/dev/null || echo "UNKNOWN")
    STATUS_REASON=$(echo "${JOB_DETAILS}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['jobs'][0].get('statusReason',''))" 2>/dev/null || true)

    if [[ -n "${STATUS_REASON}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${CURRENT_STATUS} — ${STATUS_REASON}"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${CURRENT_STATUS}"
    fi

    for ts in "${TERMINAL_STATES[@]}"; do
        if [[ "${CURRENT_STATUS}" == "${ts}" ]]; then
            FINAL_STATUS="${CURRENT_STATUS}"
            echo "${JOB_DETAILS}" > "${RUN_DIR}/final_job_details.json"
            break 2
        fi
    done

    sleep "${POLL_INTERVAL}"
done

trap - INT TERM

# ── Update registry with final status ─────────────────────────────────────────
# Map Batch status to registry status: SUCCEEDED → completed, FAILED → failed
if [[ "${FINAL_STATUS}" == "SUCCEEDED" ]]; then
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
echo "──────────────────────────────────────────────"
echo "  Final status : ${FINAL_STATUS} → ${LOWER_STATUS}"
echo "  Registry updated."
echo "──────────────────────────────────────────────"
echo ""
echo "→ Fill in purpose and summary:"
echo "    scripts/nf-summarize.sh ${RUN_NAME}"
echo ""

[[ "${FINAL_STATUS}" == "SUCCEEDED" ]] && exit 0 || exit 1
