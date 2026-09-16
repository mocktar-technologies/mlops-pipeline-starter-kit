# syntax=docker/dockerfile:1
#
# Training image.
#
# Separate from the serving image on purpose. This one carries PyTorch, which on
# linux/amd64 pulls in the CUDA runtime libraries and lands somewhere around three
# gigabytes before your code is added. None of that belongs on the request path:
# a serving pod that has to pull three gigabytes before it can answer a health
# check turns every scale-up into a multi-minute event, and every CVE in the CUDA
# stack becomes something you have to patch on your production serving image.
#
# The same image runs the training job, the promotion gate and the drift exporter,
# because all three need pandas and MLflow and none of them is on the request path.
#
# Build:
#   docker build -f docker/training.Dockerfile -t training:local .

ARG PYTHON_VERSION=3.12
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-trixie

# ---------------------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# psycopg2-binary ships wheels, but pyarrow and a few transitive packages still
# build from source on some platforms. The toolchain stays in this stage.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y build-essential git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements/serving.txt requirements/serving.txt
COPY requirements/training.txt requirements/training.txt

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade "pip==25.3" \
    && /opt/venv/bin/pip install --require-hashes -r requirements/training.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
ARG IMAGE_VERSION=0.0.0-dev

LABEL org.opencontainers.image.title="demand-forecast-training" \
      org.opencontainers.image.description="Training, promotion gate and drift exporter for the demand-forecast model" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

# OMP_NUM_THREADS and MKL_NUM_THREADS: torch and the BLAS libraries beneath numpy
# both size their thread pools from the host core count. Inside a container with a
# CPU limit that is the wrong number, and the result is many threads contending
# for one core. Raise them in the pod spec to match the CPU limit you actually give
# the training job.
#
# MPLCONFIGDIR, TORCH_HOME and XDG_CACHE_HOME: matplotlib and torch write caches
# under $HOME by default, and this image has no writable home directory.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:${PATH}" \
    GIT_SHA=${GIT_SHA} \
    OMP_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    MPLCONFIGDIR=/tmp/matplotlib \
    TORCH_HOME=/tmp/torch \
    XDG_CACHE_HOME=/tmp/cache

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
    && mkdir -p /app /artifacts /tmp/matplotlib /tmp/torch /tmp/cache \
    && chown -R 10001:10001 /app /artifacts /tmp/matplotlib /tmp/torch /tmp/cache

COPY --from=builder --chown=10001:10001 /opt/venv /opt/venv
COPY --chown=10001:10001 src/contract /app/contract
COPY --chown=10001:10001 src/pipelines /app/pipelines
COPY --chown=10001:10001 src/serving /app/serving
COPY --chown=10001:10001 pipelines/config.yaml /app/pipelines/config.yaml

WORKDIR /app

USER 10001:10001

# The drift exporter listens here. The training entrypoint ignores it.
EXPOSE 9102

# No HEALTHCHECK. Two of the three roles this image plays are batch jobs that run
# to completion, and a health check on a batch container is meaningless. The drift
# exporter's readiness is checked by the Kubernetes probe in the Helm chart, which
# is the right place for it.

ENTRYPOINT ["python", "-m", "pipelines.cli"]
CMD ["--help"]
