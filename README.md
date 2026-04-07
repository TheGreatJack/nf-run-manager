# nf-run-manager

A lightweight run management framework for launching, tracking, and auditing [Nextflow](https://www.nextflow.io/) pipeline runs across three execution environments:

- **Local** (Docker) via `nf-run.sh`
- **AWS HealthOmics** via `omics-run.sh`
- **AWS Batch** via `batch-run.sh`

Every run is registered in a TSV audit log with its parameters, status, git commit, and post-run notes.

## Quick start

```bash
# 1. Clone
git clone https://github.com/TheGreatJack/nf-run-manager.git
cd nf-run-manager

# 2. Configure
cp .env.example .env
# Edit .env with your AWS profile, S3 buckets, workflow IDs, etc.

# 3. Add your pipeline
git clone https://github.com/your-org/your-pipeline.git workflow/your-pipeline

# 4. Add your dataset
mkdir -p data/test_data/my_dataset
# Copy your samplesheet, params, and genome reference into it

# 5. Run
scripts/nf-run.sh \
  --name smoke-test \
  --dataset my_dataset \
  --nf-version 24.04.0 \
  --params data/test_data/my_dataset/params.json \
  -- -profile docker
```

## Project structure

```
nf-run-manager/
├── .env.example                          # Configuration template (copy to .env)
├── .gitignore
├── data/
│   ├── dataset_registry.tsv              # One row per dataset
│   └── test_data/
│       └── <dataset_name>/               # Your datasets go here
│           ├── fastqs/                   # (gitignored — large)
│           ├── genome/                   # (gitignored — large)
│           ├── samplesheet.csv
│           ├── params.json               # Local paths + resource limits
│           ├── params_s3.json            # S3 paths
│           └── params_omics.json         # S3 paths, HealthOmics-compatible schema only
├── examples/                             # Example params and samplesheet templates
├── nextflow_binaries/                    # (gitignored) Place Nextflow binaries here
├── runs/
│   ├── run_registry.tsv                  # One row per run (audit log)
│   └── YYYY-MM-DD_<dataset>_<name>/      # Created per run
├── scripts/
│   ├── nf-run.sh                         # Local Nextflow runner
│   ├── omics-run.sh                      # AWS HealthOmics launcher
│   ├── omics-check.sh                    # HealthOmics status checker
│   ├── batch-run.sh                      # AWS Batch launcher
│   ├── batch-check.sh                    # Batch status checker
│   └── nf-summarize.sh                   # Fill purpose/summary in registry
└── workflow/                             # (gitignored) Clone your pipeline here
```

## Configuration

All project-specific settings live in a `.env` file (gitignored, never committed). Copy the template and fill in your values:

```bash
cp .env.example .env
```

The `.env` file is automatically sourced by every script. See `.env.example` for all available variables.

| Variable | Used by | Description |
|---|---|---|
| `NF_RUNNER_AWS_PROFILE` | all cloud scripts | AWS CLI SSO profile name |
| `NF_RUNNER_REGION` | all cloud scripts | AWS region (default: `us-east-1`) |
| `NF_RUNNER_WORKFLOW_ID` | `omics-run.sh` | HealthOmics workflow ID |
| `NF_RUNNER_WORKFLOW_VERSION` | `omics-run.sh` | HealthOmics workflow version name |
| `NF_RUNNER_OMICS_OUTPUT_URI` | `omics-run.sh` | S3 URI for HealthOmics outputs |
| `NF_RUNNER_ROLE_ARN` | `omics-run.sh` | IAM role ARN for HealthOmics |
| `NF_RUNNER_PIPELINE` | `batch-run.sh` | GitHub `org/repo` of your pipeline |
| `NF_RUNNER_REVISION` | `batch-run.sh` | Git branch/tag to run (default: `main`) |
| `NF_RUNNER_BATCH_WORKDIR` | `batch-run.sh` | S3 work directory for Batch |
| `NF_RUNNER_BATCH_OUTPUT_URI` | `batch-run.sh` | S3 URI for Batch results |

All variables can also be overridden per-run via CLI flags.

## Scripts

### `nf-run.sh` — Local runner

Executes the pipeline locally using Docker. Requires conda (`nf-core` environment) and a Nextflow binary in `nextflow_binaries/`.

```bash
scripts/nf-run.sh \
  --name smoke-test \
  --dataset my_dataset \
  --nf-version 24.04.0 \
  --params data/test_data/my_dataset/params.json \
  -- -profile docker
```

| Flag | Required | Description |
|---|---|---|
| `--name` | yes | Short label for the run |
| `--dataset` | yes | Dataset key (must exist under `data/test_data/`) |
| `--nf-version` | yes | Nextflow version string (binary located by glob in `nextflow_binaries/`) |
| `--params` | yes | Path to params JSON file |
| `-- [args...]` | no | Extra arguments forwarded to `nextflow run` (e.g. `-profile docker --resume`) |

### `omics-run.sh` — AWS HealthOmics launcher

Submits a workflow to AWS HealthOmics and polls until completion.

```bash
scripts/omics-run.sh \
  --name run1 \
  --dataset my_dataset \
  --params data/test_data/my_dataset/params_omics.json \
  --role-arn arn:aws:iam::123456789012:role/MyRole
```

| Flag | Required | Description |
|---|---|---|
| `--name` | yes | Short label for the run |
| `--dataset` | yes | Dataset key |
| `--params` | yes | HealthOmics-compatible params JSON (S3 paths, schema-only fields) |
| `--role-arn` | yes | IAM execution role ARN |
| `--workflow-id` | no | Overrides `$NF_RUNNER_WORKFLOW_ID` |
| `--workflow-version-name` | no | Overrides `$NF_RUNNER_WORKFLOW_VERSION` |
| `--output-uri` | no | Overrides `$NF_RUNNER_OMICS_OUTPUT_URI` |
| `--no-wait` | no | Submit and exit without polling |
| `--poll-interval` | no | Seconds between status polls (default: 60) |
| `--cache-id` | no | Associate a run cache |
| `--purpose` | no | Pre-fill the purpose field in the registry |

### `batch-run.sh` — AWS Batch launcher

Submits a workflow to AWS Batch via a head job.

```bash
scripts/batch-run.sh \
  --name run1 \
  --dataset my_dataset \
  --params data/test_data/my_dataset/params_s3.json \
  --job-queue nextflow-head-queue \
  --job-definition nextflow-head \
  --no-wait
```

| Flag | Required | Description |
|---|---|---|
| `--name` | yes | Short label for the run |
| `--dataset` | yes | Dataset key |
| `--params` | yes | Params file (stored as audit copy) |
| `--job-queue` | yes | AWS Batch job queue name |
| `--job-definition` | yes | AWS Batch job definition name |
| `--pipeline` | no | Overrides `$NF_RUNNER_PIPELINE` |
| `--revision` | no | Overrides `$NF_RUNNER_REVISION` |
| `--workdir` | no | Overrides `$NF_RUNNER_BATCH_WORKDIR` |
| `--output-uri` | no | Overrides `$NF_RUNNER_BATCH_OUTPUT_URI` |
| `--extra-args` | no | Extra flags for `nextflow run` |
| `--no-wait` | no | Submit and exit without polling |
| `--purpose` | no | Pre-fill the purpose field in the registry |

### `omics-check.sh` / `batch-check.sh` — Status checkers

Check the live status of a submitted run and update the registry if it has reached a terminal state. Use these after submitting with `--no-wait`.

```bash
scripts/omics-check.sh <run_name>
scripts/batch-check.sh <run_name>
```

### `nf-summarize.sh` — Fill purpose and summary

Interactively prompts you to fill in the `purpose` and `summary` fields for a registered run.

```bash
scripts/nf-summarize.sh <run_name>
```

## Params file conventions

Each dataset can have up to three params variants:

| File | Paths | Resource limits | HealthOmics schema |
|---|---|---|---|
| `params.json` | Local absolute paths | Yes (`max_cpus`, `max_memory`, `max_time`) | No |
| `params_s3.json` | S3 URIs | No | No (may include extra Nextflow params) |
| `params_omics.json` | S3 URIs | No | Yes — only params accepted by the HealthOmics workflow schema |

Always use `params_omics.json` for HealthOmics runs. Submitting params not in the workflow schema causes a `ValidationException`.

See `examples/` for template files.

## Registry schemas

### Run registry (`runs/run_registry.tsv`)

Tab-separated, one row per run. Never delete rows.

| # | Column | Description |
|---|---|---|
| 1 | `run_name` | `YYYY-MM-DD_<dataset>_<label>` — matches the run folder under `runs/` |
| 2 | `nf_run_id` | Nextflow name (local), HealthOmics run ID, or Batch job ID |
| 3 | `date` | `YYYY-MM-DD` |
| 4 | `dataset` | Dataset key |
| 5 | `pipeline_version` | Git branch/tag or workflow version name |
| 6 | `git_commit` | Short commit hash of the pipeline at run time |
| 7 | `nextflow_version` | Engine version (set to `unknown` at submission, updated on completion) |
| 8 | `input_params` | Relative path to the params copy in the run folder |
| 9 | `status` | `submitted` / `running` / `completed` / `failed` / `aborted` |
| 10 | `environment` | `local` / `healthomics` / `batch` |
| 11 | `s3_path` | Output S3 URI (cloud runs) or empty (local) |
| 12 | `purpose` | Why was this run initiated? |
| 13 | `summary` | Post-run observations and conclusions |

### Dataset registry (`data/dataset_registry.tsv`)

Tab-separated, one row per dataset.

| Column | Description |
|---|---|
| `dataset_name` | Must match folder name under `data/test_data/` |
| `date_added` | `DD/MM/YYYY` |
| `organism` | Organism name or `-` |
| `data_type` | Sequencing type (e.g. `ddRAD-seq`) |
| `size` | Approximate disk size |
| `source` | Data origin (e.g. `SRA (PRJNA...)`) |
| `description` | Free text |
| `s3_uri` | S3 URI prefix or empty |

## Prerequisites

- **conda** with an `nf-core` environment (for local runs)
- **Docker** (for local runs with `-profile docker`)
- **AWS CLI** configured with SSO (`aws configure sso`)
- **python3** (used to parse JSON responses from AWS APIs)
- **Nextflow binary** placed in `nextflow_binaries/` (for local runs)

## License

MIT
