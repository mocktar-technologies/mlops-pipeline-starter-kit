# MLOps Pipeline Starter Kit

Infrastructure, containers, pipelines and observability for running a machine
learning model in production on AWS. Written for DevOps and platform engineers: it
assumes you know Terraform, Kubernetes and CI/CD, and it does not assume you have
trained a model before.

The model here is deliberately small. The point of the repository is everything
around it.

## What this gives you

- **Terraform** for a VPC, an EKS cluster with separate CPU and spot GPU node
  groups, an encrypted artifact bucket with lifecycle rules, ECR with immutable
  tags, an MLflow tracking server on RDS Postgres, a SageMaker execution role, and
  IRSA roles scoped to one prefix each.
- **Three container images**: a small ONNX Runtime serving image, a PyTorch training
  image, and an MLflow server image. Multi-stage, non-root, hash-pinned dependencies.
- **A training pipeline** that exports to ONNX, verifies the exported graph against
  the trained model, and refuses to promote a model that is not better than the one
  already serving by more than the measured noise in the metric.
- **Two GitHub Actions workflows**: lint, test, scan, sign, build, deploy; and a
  retraining workflow that trains automatically and promotes only behind a human
  approval.
- **Observability across four layers**: infrastructure, application, data and model.
  A ServiceMonitor, eleven alert rules, seven recording rules, and a Grafana
  dashboard whose lower half shows the things a normal monitoring stack cannot see.
- **A runbook** in [docs/RUNBOOK.md](docs/RUNBOOK.md) with a procedure per alert.

## The idea this is built around

A model serving traffic can be wrong while every signal you already monitor is
green. The pods are healthy, latency is flat, the error rate is zero, and the
predictions are quietly bad because the data arriving today does not look like the
data the model was trained on. Nothing throws an exception. No dashboard turns red.

So the repository is organised around two things that ordinary application delivery
does not need:

**Three versioned inputs, not one.** Code, data and the model are separate artifacts
with separate lifecycles. You roll back a model without rebuilding a container, and
you rebuild a container without changing the model. Everything in `deploy/` and the
`model.version` value exists to keep those two independent.

**Promotion is a decision, not a consequence.** Training produces a challenger.
A gate compares it against the champion on the same held-out data and requires the
improvement to exceed the metric's own bootstrap noise. Only then does an alias
move, and only behind an environment approval. A pipeline that deploys whatever it
trained is an automated way to make production worse.

## Repository structure

```
.
├── Makefile                      init, plan, apply, build, test, destroy and more
├── README.md
├── docs/
│   ├── ARCHITECTURE.md           what each piece is, and the decisions behind them
│   └── RUNBOOK.md                one procedure per alert, plus rollback and DR
│
├── terraform/
│   ├── envs/dev/                 the only place modules meet; read this first
│   │   ├── main.tf               composition, and every IAM policy in one view
│   │   ├── variables.tf          every input, with the cost and security trade-offs
│   │   ├── outputs.tf            including the GitHub variables to copy
│   │   ├── providers.tf          aws, kubernetes and helm (note: different syntax)
│   │   ├── backend.tf            S3 state and DynamoDB locking
│   │   └── terraform.tfvars.example
│   └── modules/
│       ├── network/              VPC, three subnet tiers, VPC endpoints, flow logs
│       ├── artifacts/            KMS, S3 with per-prefix lifecycle, ECR
│       ├── eks/                  cluster, add-ons, system/inference/GPU node groups
│       ├── irsa/                 one generic module, instantiated per workload
│       ├── mlflow/               RDS, the tracking server, NetworkPolicy
│       ├── sagemaker/            training execution role, optional registry mirror
│       ├── observability/        kube-prometheus-stack, NVIDIA plugin, dashboards
│       └── cicd_identity/        GitHub OIDC, a read-only role and a deploy role
│
├── docker/
│   ├── serving.Dockerfile        FastAPI + ONNX Runtime, non-root, no PyTorch
│   ├── training.Dockerfile       PyTorch, MLflow, pandas. Also runs the gate
│   └── mlflow.Dockerfile         the tracking server, built rather than pulled
│
├── src/
│   ├── contract/features.py      the feature contract. Shared by both images
│   ├── serving/                  the inference service
│   │   ├── app.py                /invocations, /predict, /ping, /readyz, /metrics
│   │   ├── model.py              ONNX session, contract checks, warmup, clamping
│   │   ├── metrics.py            every metric name, in one place
│   │   ├── schemas.py            request validation at the edge
│   │   └── config.py             environment only, validated at startup
│   └── pipelines/
│       ├── data.py               the data contract and the chronological split
│       ├── net.py                the model, with scaling inside the graph
│       ├── train.py              train, export, ONNX parity check, metrics
│       ├── metrics.py            MAE, RMSE, sMAPE, bootstrap noise floor, PSI
│       ├── gate.py               the promotion decision
│       ├── registry.py           MLflow aliases: challenger, champion, previous
│       ├── tracking.py           MLflow logging, isolated so train.py stays testable
│       ├── drift.py              PSI as a Prometheus exporter
│       └── cli.py                train, promote, rollback, resolve, drift
│
├── tests/                        79 tests. The valuable ones are named in the code
│
├── deploy/charts/inference/      Helm chart: Deployment, HPA, PDB, NetworkPolicy,
│                                 ServiceMonitor, PrometheusRule, drift exporter
│
├── monitoring/
│   ├── README.md                 how the alert routing and retrain webhook work
│   └── dashboards/               Grafana JSON, loaded by the Terraform module
│
├── pipelines/config.yaml         hyperparameters and gate thresholds, in git
├── requirements/                 *.in are the inputs, *.txt are hash-pinned locks
├── scripts/                      bootstrap, verification and the static linters
└── .github/workflows/
    ├── ci-cd-pipeline.yml        lint, test, scan, sign, build, deploy, verify
    └── model-retrain-trigger.yml train, gate, approve, promote, redeploy
```

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| Terraform or OpenTofu | >= 1.9 / >= 1.8 | Every target works with either; `make plan TF=terraform` |
| AWS CLI | v2 | The scripts and the workflows use it |
| kubectl | within one minor of the cluster | |
| Helm | 3.x | |
| Docker | with buildx | Multi-stage builds |
| Python | 3.12 | The lock files are resolved for 3.12 |
| uv | any recent | Only for `make lock` |

Plus an AWS account with permission to create a VPC, EKS, RDS, S3, KMS, ECR and IAM
roles, and a GitHub repository you can set variables on.

**Cost warning.** Applied as configured, this stack runs an EKS control plane, four
on-demand nodes, an RDS instance, a NAT gateway and seven VPC interface endpoints.
That is a real monthly bill before a single GPU hour. `terraform.tfvars.example`
marks every lever, in rough order of how much each one matters, and `make destroy`
removes it all. Read the cost section of
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before you apply in an account you pay
for personally.

## Setup

### 1. Local first, before any cloud spend

```bash
make venv
make test           # 79 tests, about 20 seconds
make train-local    # generates synthetic data, trains, exports ONNX, checks parity
```

`make train-local` runs the entire pipeline with no AWS account and no MLflow. If
it works, the code is fine and anything that fails later is configuration. That is
the cheapest place to find a broken export.

```bash
make build          # all three images
make smoke          # runs the serving container and exercises its API
```

### 2. State

```bash
make bootstrap-state
```

Creates the state bucket and lock table, which cannot be managed by the state they
hold. It is idempotent and prints the exact values to paste into `backend.tf` and
`terraform.tfvars`.

### 3. Configure

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
$EDITOR terraform/envs/dev/terraform.tfvars    # five required values
$EDITOR terraform/envs/dev/backend.tf          # bucket, region, lock table
```

### 4. Apply, in two passes

There is a genuine chicken-and-egg here and the kit does not pretend otherwise: the
MLflow module needs an image, and the ECR repository that image lives in is created
by this same stack.

```bash
make init

# Pass one: everything except the MLflow server.
tofu -chdir=terraform/envs/dev apply \
  -target=module.network -target=module.artifacts -target=module.eks \
  -target=module.irsa_ebs_csi -target=module.sagemaker -target=module.cicd_identity

# Push the MLflow image to the repository that now exists.
MLFLOW_REPO=$(tofu -chdir=terraform/envs/dev output -json ecr_repository_urls \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["mlflow"])')
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${MLFLOW_REPO%%/*}"
docker build -f docker/mlflow.Dockerfile -t "${MLFLOW_REPO}:bootstrap" .
docker push "${MLFLOW_REPO}:bootstrap"

# Put the digest in terraform.tfvars as mlflow_image, then:
make plan
make apply
```

`make apply` ends by printing `make outputs`, which gives you the GitHub repository
variables, the IRSA role ARNs, and a review of exactly which OIDC subjects can
assume the CI roles.

### 5. Wire up GitHub

Set the repository variables that `make outputs` printed. There are no secrets to
set: CI authenticates with OIDC and holds no long-lived AWS credential.

Then create two GitHub environments, `dev` and `production`, and add required
reviewers to `production`. That reviewer requirement is what turns "the workflow can
promote a model" into "a named person approved this model", and it composes with the
OIDC trust policy: the job cannot obtain AWS credentials until the approval lands.

If your cluster endpoint stays private, which is the default, set `RUNNER_LABEL` to
a self-hosted runner inside the VPC. A GitHub-hosted runner cannot reach a private
EKS endpoint, and the deploy job will fail with a connection timeout that reads like
a cluster outage. This is stated in a comment on the job itself as well.

### 6. First model

Push to `main`. The CI pipeline builds and signs both images. Then run the retrain
workflow from the Actions tab with a reason. It trains, registers a challenger, runs
the gate, and waits for your approval before moving the champion alias.

```bash
make verify         # rollout, loaded version, a prediction, and the Prometheus target
make port-forward   # MLflow on 5000, Grafana on 3000, Prometheus on 9090
```

## Daily commands

```bash
make plan                       # what would change
make apply                      # apply, then print the outputs you need
make deploy MODEL_VERSION=7 IMAGE_DIGEST=sha256:...
make verify                     # five checks, including whether Prometheus sees it
make rollback                   # point the champion alias at the previous version
make lint                       # everything CI runs, locally
make destroy                    # asks you to type the environment name
```

`make` on its own lists all thirty targets with a one-line description each.

## When something is wrong

[docs/RUNBOOK.md](docs/RUNBOOK.md) has a section per alert, reached directly from the
`runbook_url` annotation on every rule. The two you will meet first:

**High latency.** Compare `inference:latency_p99:5m` against
`inference:model_latency_p99:5m` on the dashboard. If total latency rose and model
latency did not, the time is being spent outside the model, and rolling back the
model changes nothing. The usual causes are CPU throttling and a larger batch size,
and both have a panel.

**Model drift.** `model_drift_psi` rising is a statement about the input data, not a
verdict on the model. Check the drift freshness panel first: a stale exporter holds
its last healthy value, which is indistinguishable from health. Then check whether
predictions actually moved. Drift with no change in prediction distribution and no
change in business outcome is worth understanding before it is worth retraining for.

## Where the important decisions are written down

The comments in this repository explain reasoning rather than restating code, and a
few of them are worth finding before you change something:

- `src/contract/features.py`: why one shared ordered tuple prevents the most
  expensive failure in production ML.
- `src/pipelines/metrics.py`: `bootstrap_std`, and why a gate without it promotes
  noise about half the time.
- `src/pipelines/gate.py`: the four conditions, and which one protects the very
  first model you ever train.
- `src/pipelines/net.py`: why the scaler lives inside the graph and the output is
  `exp(linear)`.
- `terraform/modules/observability/main.tf`: `serviceMonitorSelectorNilUsesHelmValues`,
  the single value most often responsible for a team believing their model metrics
  are collected when they are not.
- `terraform/modules/irsa/main.tf`: the three trust policy conditions, and the one
  character that turns a scoped identity into a cluster-wide one.
- `.github/workflows/model-retrain-trigger.yml`: why retraining is automatic and
  promotion is not.

## Adapting it

**Your own model.** Edit `src/contract/features.py`, `src/pipelines/net.py` and
`pipelines/config.yaml`. The contract file is the one to change first: the tests
will tell you everywhere else that needs to follow.

**Your own data.** Point `DATA_URI` at a CSV with the contract's columns, locally or
on S3. `src/pipelines/data.py` enforces the same bounds the API enforces, so a
dataset that would train a model the API cannot serve fails before the GPU starts.

**No GPU.** Set `gpu_max_size = 0`. The node group is created at zero either way, so
it costs nothing idle; setting zero also skips the NVIDIA device plugin.

**SageMaker endpoints instead of EKS.** The serving image already implements the
`/ping` and `/invocations` contract, so this is a deployment change rather than a
rewrite. Read the note at the top of `terraform/modules/sagemaker/main.tf` first:
Prometheus cannot scrape a managed endpoint, and the model and data layers of the
dashboard come from that scrape.

## Licence

Apache 2.0. See [LICENSE](LICENSE).

The synthetic data generator in `scripts/make_sample_data.py` produces its own data
and carries no dataset licence. If you substitute a public dataset, check its terms
yourself.
