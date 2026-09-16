# syntax=docker/dockerfile:1
#
# MLflow tracking server.
#
# Built here rather than pulled from a public registry, for three reasons that all
# matter in a production account:
#
#   1. The version is the one pinned in requirements/training.txt, so the client in
#      your pipeline and the server it talks to are the same release. A client and
#      server that differ by a major version disagree about the registry API, and
#      the error you get names a missing endpoint rather than a version mismatch.
#   2. It contains exactly what the deployment needs: the mlflow CLI, a Postgres
#      driver, the AWS CLI for resolving the database secret, and nothing else.
#   3. It is in your ECR, scanned on push, and immutable by tag. A public image
#      pulled at pod start is a supply-chain dependency on someone else's registry
#      in your critical path.
#
# Build:
#   docker build -f docker/mlflow.Dockerfile -t mlflow-server:local .

ARG PYTHON_VERSION=3.12
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-trixie

# ---------------------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements/serving.txt requirements/serving.txt
COPY requirements/mlflow-server.txt requirements/mlflow-server.txt

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade "pip==25.3" \
    && /opt/venv/bin/pip install --require-hashes -r requirements/mlflow-server.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown

LABEL org.opencontainers.image.title="mlflow-tracking-server" \
      org.opencontainers.image.description="MLflow tracking server with a Postgres backend store and an S3 artifact store" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    HOME=/tmp

# The AWS CLI is needed because the pod resolves its database credentials from
# Secrets Manager at start time with its IRSA identity, rather than having a
# password injected as a Kubernetes Secret. That is the whole reason the password
# never appears in terraform state, in a manifest, or in git.
#
# awscli comes from the distribution here rather than from pip, so it does not
# pull a second botocore into the same virtual environment as MLflow's.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y awscli curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 mlflow \
    && useradd --system --uid 10001 --gid mlflow --no-create-home --shell /usr/sbin/nologin mlflow

COPY --from=builder --chown=10001:10001 /opt/venv /opt/venv

WORKDIR /tmp

USER 10001:10001

EXPOSE 5000

# /health is MLflow's own endpoint and it answers without touching the database,
# which is what makes it safe as a liveness probe: a brief database failover must
# not restart every replica and destroy the evidence.
HEALTHCHECK --interval=20s --timeout=5s --start-period=60s --retries=3 \
    CMD ["curl", "--fail", "--silent", "http://127.0.0.1:5000/health"]

# No ENTRYPOINT. The deployment passes the full `mlflow server` command, because
# the backend store URI has to be assembled at start time from the resolved
# secret, and baking a command here that the manifest then overrides is two places
# to look for one behaviour.
CMD ["mlflow", "--help"]
