"""Prometheus metrics for the inference service.

This module is the single definition of every metric name and label the service
exposes. The alert rules in the Helm chart, the Grafana dashboard in
monitoring/dashboards and the deployment gate in the CI pipeline all reference
these names. If you rename a metric here, grep for the old name across the repo
before you commit; a dashboard panel that silently queries a metric nobody emits
renders an empty graph, which reads exactly like a healthy system.

Four layers are represented, and the last two are the ones a DevOps engineer
does not get for free from an existing monitoring stack:

  infrastructure  CPU, memory, restarts. Not emitted here. kube-state-metrics
                  and node-exporter already cover it.
  application     request rate, error rate, latency. The familiar layer.
  data            what is arriving: rejected inputs by reason, batch sizes.
  model           what is going out: prediction distribution, model identity,
                  whether a model is loaded at all.

Cardinality note: every label value here is bounded. model_version is the only
label that changes over time and it changes on deploy, not per request. No label
carries a user id, a request id or a raw feature value, because each of those
would multiply the series count without bound.
"""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, Info

# A dedicated registry rather than the global default. The default registry is
# process-global state that a test can pollute and that a second import can
# double-register, which raises at import time and crash-loops the pod.
REGISTRY = CollectorRegistry()

# ---------------------------------------------------------------------------
# Application layer
# ---------------------------------------------------------------------------

REQUESTS = Counter(
    "inference_requests_total",
    "Inference HTTP requests handled, by route, status class and model version.",
    labelnames=("route", "status", "model_version"),
    registry=REGISTRY,
)

# Buckets are chosen for a CPU inference path with a single-digit-millisecond
# floor and a one-second SLO ceiling, not copied from a web framework default.
# Prometheus histogram quantiles are only as good as the bucket you land in, so
# the buckets have to bracket the latency you actually intend to alert on.
REQUEST_DURATION = Histogram(
    "inference_request_duration_seconds",
    "Wall-clock duration of an inference request, including validation.",
    labelnames=("route", "model_version"),
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
    registry=REGISTRY,
)

# Separated from request duration so you can see how much of the latency is the
# model and how much is everything around it. When p99 request latency rises
# and p99 model latency does not, the model is not the problem.
MODEL_LATENCY = Histogram(
    "inference_model_latency_seconds",
    "Time spent inside the ONNX Runtime session run call.",
    labelnames=("model_version",),
    buckets=(0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0),
    registry=REGISTRY,
)

# ---------------------------------------------------------------------------
# Data layer
# ---------------------------------------------------------------------------

INPUT_REJECTED = Counter(
    "inference_input_rejected_total",
    "Requests rejected before inference, by reason.",
    labelnames=("reason",),
    registry=REGISTRY,
)

BATCH_SIZE = Histogram(
    "inference_batch_size",
    "Number of rows per accepted inference request.",
    buckets=(1, 2, 4, 8, 16, 32, 64, 128, 256, 512),
    registry=REGISTRY,
)

# ---------------------------------------------------------------------------
# Model layer
# ---------------------------------------------------------------------------

# The prediction distribution is the cheapest early warning you can emit. A
# model that has quietly started predicting near zero for everything still
# returns 200s in single-digit milliseconds, so the application layer stays
# green. A shift in this histogram is the first thing that moves.
PREDICTION = Histogram(
    "inference_prediction",
    "Distribution of predicted rental counts.",
    labelnames=("model_version",),
    buckets=(0, 5, 10, 25, 50, 100, 200, 400, 800, 1600),
    registry=REGISTRY,
)

PREDICTIONS_TOTAL = Counter(
    "inference_predictions_total",
    "Individual predictions returned, which is rows rather than requests.",
    labelnames=("model_version",),
    registry=REGISTRY,
)

PREDICTION_CLAMPED = Counter(
    "inference_prediction_clamped_total",
    "Predictions clamped at the configured bounds before being returned.",
    labelnames=("model_version", "bound"),
    registry=REGISTRY,
)

MODEL_LOADED = Gauge(
    "inference_model_loaded",
    "1 when a model is loaded and ready to serve, 0 otherwise.",
    registry=REGISTRY,
)

MODEL_LOAD_FAILURES = Counter(
    "inference_model_load_failures_total",
    "Failed attempts to load a model artifact.",
    registry=REGISTRY,
)

# An Info metric rather than a Gauge with labels. It renders as
# inference_model_info{model_name=...,model_version=...} 1.0, which is what you
# join against in a dashboard to label a panel with the running version.
MODEL_INFO = Info(
    "inference_model",
    "Identity of the loaded model artifact.",
    registry=REGISTRY,
)


def status_class(status_code: int) -> str:
    """Collapse a status code to its class.

    Recording the exact code would add a label value for every 4xx a
    misbehaving client can invent. The class is what alerts fire on.
    """
    return f"{status_code // 100}xx"
