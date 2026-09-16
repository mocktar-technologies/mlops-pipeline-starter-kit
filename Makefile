# MLOps Pipeline Starter Kit
#
# Run `make` with no target for the list.
#
# Two conventions worth knowing before you use this file:
#
#   TF  is the Terraform binary. It defaults to tofu, and every target works
#       identically with terraform: `make plan TF=terraform`.
#   ENV is the environment directory under terraform/envs. It defaults to dev.
#
# Targets that change anything in AWS print what they are about to do and, for the
# destructive ones, require you to type the environment name. That is not
# ceremony: `make destroy` on the wrong terminal tab takes the model registry
# database with it.

# make does not read a shebang, so SHELL has to be a real path. Resolving it
# rather than hardcoding /bin/bash keeps this working on systems where bash lives
# elsewhere, which includes most Nix and some BSD setups.
SHELL := $(shell command -v bash 2>/dev/null || echo /bin/bash)
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.ONESHELL:

TF ?= tofu
ENV ?= dev
TF_DIR := terraform/envs/$(ENV)
PYTHON ?= python3
VENV := .venv
VENV_BIN := $(VENV)/bin
CHART := deploy/charts/inference
NAMESPACE ?= inference
# --verify, because plain `git rev-parse HEAD` in a repository with no commits
# prints "HEAD" on stdout and then fails, which makes the fallback concatenate.
GIT_SHA := $(shell git rev-parse --verify HEAD 2>/dev/null || echo unknown)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Overridable at the command line for a local build against a local registry.
IMAGE_TAG ?= sha-$(GIT_SHA)
SERVING_IMAGE ?= inference:$(IMAGE_TAG)
TRAINING_IMAGE ?= training:$(IMAGE_TAG)
MLFLOW_IMAGE ?= mlflow-server:$(IMAGE_TAG)

.PHONY: help
help: ## Show this help
	@echo "MLOps Pipeline Starter Kit"
	@echo
	@echo "Usage: make <target> [ENV=dev] [TF=tofu]"
	@echo
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Current: ENV=$(ENV) TF=$(TF) GIT_SHA=$(GIT_SHA)"

# ---------------------------------------------------------------------------
# Local development
# ---------------------------------------------------------------------------

.PHONY: venv
venv: ## Create the local virtual environment and install everything
	@if [ ! -d "$(VENV)" ]; then $(PYTHON) -m venv $(VENV); fi
	$(VENV_BIN)/pip install --upgrade pip
	# --require-hashes, so a compromised or typo-squatted package cannot be
	# installed even if the index serves one.
	$(VENV_BIN)/pip install --require-hashes -r requirements/training.txt
	$(VENV_BIN)/pip install --require-hashes -r requirements/dev.txt
	@echo "ready: source $(VENV_BIN)/activate"

.PHONY: lock
lock: ## Recompile every requirements lock file from its .in
	@command -v uv >/dev/null || { echo "uv is required: pip install uv"; exit 1; }
	# Order matters: serving.txt is a constraint file for the other two, so it has
	# to exist and be current before they are compiled.
	uv pip compile requirements/serving.in --generate-hashes --python-version 3.12 \
		--no-strip-extras -o requirements/serving.txt
	uv pip compile requirements/training.in --generate-hashes --python-version 3.12 \
		--no-strip-extras -o requirements/training.txt
	uv pip compile requirements/mlflow-server.in --generate-hashes --python-version 3.12 \
		--no-strip-extras -o requirements/mlflow-server.txt
	uv pip compile requirements/dev.in --generate-hashes --python-version 3.12 \
		--no-strip-extras -o requirements/dev.txt
	@echo "locks regenerated; review the diff before committing"

.PHONY: fmt
fmt: ## Format Python and Terraform in place
	$(VENV_BIN)/black src tests scripts
	$(VENV_BIN)/ruff check --fix src tests scripts
	$(TF) fmt -recursive terraform/

.PHONY: lint
lint: ## Every static check the CI pipeline runs
	$(VENV_BIN)/black --check --diff src tests scripts
	$(VENV_BIN)/ruff check src tests scripts
	$(VENV_BIN)/mypy
	$(TF) fmt -check -recursive terraform/
	@# These three catch what fmt and a unit test cannot: a module input that no
	@# longer exists, a Helm value that renders empty, and a metric a dashboard
	@# queries that nothing emits. The last is the one that matters most, because
	@# an empty panel looks exactly like a healthy system.
	$(VENV_BIN)/python scripts/tf_lint.py
	$(VENV_BIN)/python scripts/helm_lint.py
	$(VENV_BIN)/python scripts/check_metric_names.py
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed, skipping"
	@command -v hadolint >/dev/null && hadolint docker/*.Dockerfile || echo "hadolint not installed, skipping"

.PHONY: test
test: ## Run the full test suite with coverage
	$(VENV_BIN)/pytest --cov=src --cov-report=term-missing -q

.PHONY: test-fast
test-fast: ## Run only the tests that do not train a model
	$(VENV_BIN)/pytest -q -m "not requires_torch"

.PHONY: sample-data
sample-data: ## Generate a synthetic dataset so the pipeline runs offline
	$(VENV_BIN)/python scripts/make_sample_data.py --rows 20000 --output data/sample.csv
	@echo "set DATA_URI=data/sample.csv to train against it"

.PHONY: train-local
train-local: sample-data ## Train, export and gate locally against the sample data
	@# No MLflow and no AWS. This proves the pipeline works before you point it at
	@# a cluster, which is the cheapest place to find a broken export.
	DATA_URI=data/sample.csv $(VENV_BIN)/python -c "
	from pathlib import Path
	from pipelines.config import load_config
	from pipelines.train import train
	config = load_config('pipelines/config.yaml')
	result = train(config, Path('artifacts/local'))
	print()
	print('onnx:          ', result.onnx_path)
	print('test metrics:  ', result.test_metrics)
	print('noise floor:   ', round(result.noise_floor, 4))
	print('onnx parity:   ', f'{result.parity_max_abs_diff:.2e}')
	"

.PHONY: serve-local
serve-local: ## Run the inference service locally against the last local model
	MODEL_PATH=artifacts/local/model.onnx \
	MODEL_VERSION=local \
	GIT_SHA=$(GIT_SHA) \
	PYTHONPATH=src \
	$(VENV_BIN)/python -m serving.entrypoint

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Build all three container images locally
	docker build -f docker/serving.Dockerfile \
		--build-arg GIT_SHA=$(GIT_SHA) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(SERVING_IMAGE) .
	docker build -f docker/training.Dockerfile \
		--build-arg GIT_SHA=$(GIT_SHA) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(TRAINING_IMAGE) .
	docker build -f docker/mlflow.Dockerfile \
		--build-arg GIT_SHA=$(GIT_SHA) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(MLFLOW_IMAGE) .
	@docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}' \
		| grep -E '^(inference|training|mlflow-server):' || true

.PHONY: build-serving
build-serving: ## Build only the serving image
	docker build -f docker/serving.Dockerfile \
		--build-arg GIT_SHA=$(GIT_SHA) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(SERVING_IMAGE) .

.PHONY: smoke
smoke: build-serving ## Start the serving container and exercise its API
	@# The check that catches the mistakes a unit test cannot: a missing package in
	@# the runtime stage, a file the non-root user cannot read, a port mismatch.
	docker run --rm -d --name inference-smoke -p 8080:8080 \
		-e MODEL_PATH=/model/model.onnx \
		-e MODEL_VERSION=smoke \
		-v "$$PWD/artifacts/local:/model:ro" \
		$(SERVING_IMAGE)
	trap 'docker rm -f inference-smoke >/dev/null 2>&1 || true' EXIT
	for i in $$(seq 1 40); do
		if curl -sf http://127.0.0.1:8080/ping >/dev/null 2>&1; then break; fi
		sleep 1
	done
	echo "--- /model"
	curl -sf http://127.0.0.1:8080/model | $(PYTHON) -m json.tool
	echo "--- /predict"
	curl -sf -X POST http://127.0.0.1:8080/predict \
		-H 'content-type: application/json' \
		-d '{"instances":[{"hour":17,"dayofweek":2,"month":6,"is_holiday":0,"is_workingday":1,"temp_c":21.5,"humidity":0.55,"windspeed":3.2}]}' \
		| $(PYTHON) -m json.tool
	echo "--- /metrics (model layer only)"
	curl -sf http://127.0.0.1:8080/metrics | grep -E '^inference_(model_loaded|prediction_count|predictions_total)' || true
	echo
	echo "smoke test passed"

.PHONY: pin-digests
pin-digests: ## Resolve the base image tags to digests and rewrite the Dockerfiles
	@# A tag is a mutable pointer. Until the FROM lines are digest-pinned, the image
	@# you rebuild next month is not the image you tested. Run this before promoting
	@# to an environment where "what is running" has to be answerable.
	bash scripts/pin_digests.sh

.PHONY: scan
scan: build-serving ## Scan the serving image for vulnerabilities
	@command -v trivy >/dev/null || { echo "trivy is required: https://trivy.dev"; exit 1; }
	trivy image --severity HIGH,CRITICAL --exit-code 1 $(SERVING_IMAGE)

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

.PHONY: bootstrap-state
bootstrap-state: ## Create the state bucket and lock table (run once per account)
	@# These cannot be managed by the state they hold, so they are created by a
	@# script rather than by Terraform. It is idempotent and prints the values to
	@# put in backend.tf and terraform.tfvars.
	bash scripts/bootstrap_state.sh

.PHONY: init
init: ## terraform init for $(ENV)
	$(TF) -chdir=$(TF_DIR) init -input=false $(if $(UPGRADE),-upgrade,)

.PHONY: validate
validate: ## terraform validate for $(ENV)
	$(TF) -chdir=$(TF_DIR) validate

.PHONY: plan
plan: ## terraform plan for $(ENV)
	$(TF) -chdir=$(TF_DIR) plan -input=false -out=tfplan
	@echo
	@echo "Read the IAM section of that plan before applying. A widened trust policy"
	@echo "or a new iam:PassRole is the change most worth a second pair of eyes."

.PHONY: apply
apply: ## terraform apply for $(ENV), from the saved plan when there is one
	@if [ -f "$(TF_DIR)/tfplan" ]; then
		echo "applying the saved plan"
		$(TF) -chdir=$(TF_DIR) apply -input=false tfplan
		rm -f "$(TF_DIR)/tfplan"
	else
		echo "no saved plan; run make plan first, or confirm below"
		$(TF) -chdir=$(TF_DIR) apply -input=false
	fi
	@echo
	@$(MAKE) --no-print-directory outputs

.PHONY: outputs
outputs: ## Print the outputs you need to configure GitHub and the Helm values
	@echo "=== repository variables to set in GitHub ==="
	@$(TF) -chdir=$(TF_DIR) output -json github_repository_configuration \
		| $(PYTHON) -c 'import json,sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin)["vars"].items()]'
	@echo
	@echo "=== IRSA role ARNs for the Helm values ==="
	@$(TF) -chdir=$(TF_DIR) output -json irsa_role_arns | $(PYTHON) -m json.tool
	@echo
	@echo "=== who can assume the CI roles ==="
	@echo "Read this after every apply. An unexpected subject here is the difference"
	@echo "between 'main can deploy' and 'anyone who opens a pull request can deploy'."
	@$(TF) -chdir=$(TF_DIR) output -json ci_trust_review | $(PYTHON) -m json.tool

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster for $(ENV)
	aws eks update-kubeconfig \
		--name "$$($(TF) -chdir=$(TF_DIR) output -raw cluster_name)" \
		--region "$$($(TF) -chdir=$(TF_DIR) output -raw aws_region 2>/dev/null || echo us-east-1)"

.PHONY: destroy
destroy: ## Destroy $(ENV). Asks you to type the environment name.
	@echo "About to destroy every resource in $(TF_DIR)."
	@echo
	@echo "Two things survive on purpose and will make this fail until you turn them"
	@echo "off deliberately:"
	@echo "  the MLflow database has deletion_protection, because it holds the record"
	@echo "    of which model version served production"
	@echo "  the artifact bucket has force_destroy=false and is not empty"
	@echo
	@echo "The Kubernetes-scoped resources are removed first, because once the cluster"
	@echo "is gone the providers can no longer reach it to delete them and the destroy"
	@echo "strands halfway through."
	@echo
	@read -r -p "Type '$(ENV)' to continue: " answer
	@if [ "$$answer" != "$(ENV)" ]; then echo "aborted"; exit 1; fi
	-$(TF) -chdir=$(TF_DIR) destroy -input=false -auto-approve \
		-target=module.observability -target=module.mlflow
	$(TF) -chdir=$(TF_DIR) destroy -input=false -auto-approve

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

.PHONY: helm-lint
helm-lint: ## helm lint and render the chart with the dev values
	helm lint $(CHART) --values $(CHART)/values-dev.yaml
	helm template inference $(CHART) --values $(CHART)/values-dev.yaml \
		--set image.repository=example --set model.version=0 \
		--set model.s3Uri=s3://example/model.onnx \
		--set serviceAccount.roleArn=arn:aws:iam::000000000000:role/example \
		--set drift.image=example --set drift.serviceAccount.roleArn=arn:aws:iam::000000000000:role/example \
		--set drift.referenceUri=s3://example/ref.csv --set drift.windowUri=s3://example/window/ \
		--set aws.artifactBucket=example \
		> /dev/null
	@echo "chart renders"

.PHONY: deploy
deploy: ## Deploy the chart. Requires MODEL_VERSION and IMAGE_DIGEST.
	@test -n "$(MODEL_VERSION)" || { echo "MODEL_VERSION is required: make deploy MODEL_VERSION=7 IMAGE_DIGEST=sha256:..."; exit 1; }
	@test -n "$(IMAGE_DIGEST)" || { echo "IMAGE_DIGEST is required. A tag is a mutable pointer; deploy the digest."; exit 1; }
	helm upgrade --install inference $(CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--values $(CHART)/values-dev.yaml \
		--set image.repository="$$($(TF) -chdir=$(TF_DIR) output -json ecr_repository_urls | $(PYTHON) -c 'import json,sys;print(json.load(sys.stdin)["inference"])')" \
		--set image.digest="$(IMAGE_DIGEST)" \
		--set image.requireDigestPinning=true \
		--set image.gitSha="$(GIT_SHA)" \
		--set model.version="$(MODEL_VERSION)" \
		--set aws.artifactBucket="$$($(TF) -chdir=$(TF_DIR) output -raw artifact_bucket)" \
		--set serviceAccount.roleArn="$$($(TF) -chdir=$(TF_DIR) output -json irsa_role_arns | $(PYTHON) -c 'import json,sys;print(json.load(sys.stdin)["inference"])')" \
		--wait --timeout 10m --atomic

.PHONY: verify
verify: ## Check the deployed service end to end, including the Prometheus target
	bash scripts/verify_deployment.sh $(NAMESPACE)

.PHONY: rollback
rollback: ## Point the champion alias at the previous version (model rollback)
	@echo "This rolls back the MODEL, not the application. The pods keep running the"
	@echo "same container image; they will pick up the previous model on the next"
	@echo "deploy. To roll back the application instead: helm rollback inference"
	@echo
	bash scripts/kube_run.sh mlops-pipelines pipelines \
		"$$($(TF) -chdir=$(TF_DIR) output -json ecr_repository_urls | $(PYTHON) -c 'import json,sys;print(json.load(sys.stdin)["training"])'):$(IMAGE_TAG)" \
		-e "MLFLOW_TRACKING_URI=$$($(TF) -chdir=$(TF_DIR) output -raw mlflow_tracking_uri)" \
		-e "ARTIFACT_BUCKET=$$($(TF) -chdir=$(TF_DIR) output -raw artifact_bucket)" \
		-- rollback

.PHONY: port-forward
port-forward: ## Forward MLflow, Grafana and Prometheus to localhost
	@echo "mlflow      http://localhost:5000"
	@echo "grafana     http://localhost:3000"
	@echo "prometheus  http://localhost:9090"
	@echo "ctrl-c to stop all three"
	kubectl -n mlflow port-forward svc/mlflow 5000:5000 &
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
	wait

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove local build and test artifacts
	rm -rf artifacts .pytest_cache .mypy_cache .ruff_cache .coverage coverage.xml
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	@echo "kept: $(VENV), data/, terraform/**/.terraform"

.PHONY: clean-all
clean-all: clean ## Also remove the virtual environment and provider plugins
	rm -rf $(VENV) data/sample.csv
	find terraform -type d -name .terraform -prune -exec rm -rf {} +
