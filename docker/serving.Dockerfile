# syntax=docker/dockerfile:1
#
# Serving image for the demand-forecast model.
#
# Two stages. The builder stage owns the compiler toolchain and the pip cache and
# produces a self-contained virtual environment. The runtime stage copies that
# virtual environment and nothing else, so no build tooling, no package index
# credentials and no source archives reach production.
#
# The runtime holds ONNX Runtime, not PyTorch. Training happens in
# docker/training.Dockerfile, which is the only image that needs PyTorch. Keeping
# them apart removes roughly a gigabyte of CUDA libraries from every inference pod
# and shrinks the vulnerability surface you have to patch on the serving path.
#
# Build:
#   docker build -f docker/serving.Dockerfile -t inference:local .
#
# Pin the base image by digest before you promote this to production. The
# `make pin-digests` target resolves the current digest for the tag below and
# rewrites these FROM lines in place.

ARG PYTHON_VERSION=3.12
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-trixie

# ---------------------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

# Fail the build on a pip resolution problem rather than silently continuing,
# and keep pip from writing a cache layer we are about to throw away.
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# onnxruntime and numpy publish manylinux wheels for CPython 3.12 on x86_64, so
# no compiler is needed on that platform. build-essential is installed anyway
# because arm64 builders still fall back to a source build for some transitive
# dependencies, and a build that works on both architectures is worth the
# builder-stage weight. Nothing from this stage is shipped.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements/serving.txt requirements/serving.txt

# --require-hashes is enforced by the requirements file itself. If a hash is
# missing or wrong, this layer fails, which is the behavior you want.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade "pip==25.3" \
    && /opt/venv/bin/pip install --require-hashes -r requirements/serving.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# OCI labels. The CI pipeline overrides the mutable ones with --build-arg.
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
ARG IMAGE_VERSION=0.0.0-dev

LABEL org.opencontainers.image.title="demand-forecast-inference" \
      org.opencontainers.image.description="ONNX Runtime inference service for the demand-forecast model" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

# OMP_NUM_THREADS and OPENBLAS_NUM_THREADS: ONNX Runtime and the BLAS libraries
# underneath numpy both size their thread pools from the host core count, which is
# the wrong number inside a CPU-limited container. Oversubscription there is the
# most common cause of tail latency in a Python inference pod. The app sets ONNX
# Runtime's own session threads from SERVING_INTRA_OP_THREADS; these two cover the
# libraries the app does not control.
#
# MODEL_DIR: where the app looks for the model unless MODEL_PATH overrides it.
#
# SERVING_PORT: SageMaker hosting requires 8080. Kubernetes does not care, so the
# same number is used in both places to keep one contract.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:${PATH}" \
    OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MODEL_DIR=/opt/ml/model \
    SERVING_PORT=8080

# curl is the health-probe dependency. It is the only package added to the
# runtime, and it is added because the Docker HEALTHCHECK below needs an HTTP
# client; Kubernetes probes do not, so if you serve only on EKS you can drop
# both this install and the HEALTHCHECK.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
    && mkdir -p /opt/ml/model /app \
    && chown -R 10001:10001 /opt/ml /app

COPY --from=builder --chown=10001:10001 /opt/venv /opt/venv
# Both packages. serving imports contract.features for the feature order, so an
# image with only src/serving fails at import time with ModuleNotFoundError, at
# pod start, after a successful build and a successful push.
COPY --chown=10001:10001 src/contract /app/contract
COPY --chown=10001:10001 src/serving /app/serving

WORKDIR /app

# Everything below runs unprivileged. The numeric form is used rather than the
# name so a Kubernetes runAsUser check and a reviewer reading the manifest see
# the same value.
USER 10001:10001

EXPOSE 8080

# SageMaker gives /ping two seconds and stops launching an instance that has not
# passed a health check eight minutes after start, so the check has to be cheap.
# /ping only reports whether the model is loaded; it does not run inference.
# Exec form, so no shell is spawned for every check. curl already exits non-zero
# on an HTTP error with --fail, which is what the "|| exit 1" in the shell form
# was doing.
HEALTHCHECK --interval=15s --timeout=3s --start-period=40s --retries=3 \
    CMD ["curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:8080/ping"]

# exec form, so uvicorn is PID 1 and receives SIGTERM directly. Without that,
# a Kubernetes rolling update waits out the full termination grace period on
# every pod.
ENTRYPOINT ["python", "-m", "serving.entrypoint"]
