"""Runtime configuration for the inference service.

Configuration comes from the environment only. Nothing is read from a file in
the image and nothing is baked in at build time, so the same image artifact runs
in dev, staging and production. That is the property that makes an image
promotable: if the image changes between environments you are no longer testing
what you ship.

Secrets are never read here. The service needs no credentials of its own; it
reads the model from S3 using the IAM role attached to its service account
(IRSA), and the AWS SDK resolves that automatically.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _env_str(name: str, default: str) -> str:
    value = os.environ.get(name, default).strip()
    return value or default


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    """Immutable settings snapshot, resolved once at process start."""

    # ---- serving -----------------------------------------------------------
    # SageMaker hosting requires the container to listen on 8080. Kubernetes has
    # no such requirement, but using the same port everywhere means one number
    # appears in the Dockerfile, the Helm chart, the ServiceMonitor and the
    # SageMaker model definition instead of four.
    port: int = field(default_factory=lambda: _env_int("SERVING_PORT", 8080))
    host: str = field(default_factory=lambda: _env_str("SERVING_HOST", "0.0.0.0"))

    # One uvicorn worker per pod. Scale with replicas, not with workers: a
    # second worker in the same pod doubles memory for the loaded model and
    # hides per-pod saturation from the horizontal autoscaler.
    workers: int = field(default_factory=lambda: _env_int("SERVING_WORKERS", 1))

    # ONNX Runtime sizes its thread pool from the host core count, which is the
    # wrong number inside a CPU-limited container. Set this to the pod's CPU
    # limit, rounded down, never higher.
    intra_op_threads: int = field(default_factory=lambda: _env_int("SERVING_INTRA_OP_THREADS", 1))

    log_level: str = field(default_factory=lambda: _env_str("LOG_LEVEL", "info").lower())

    # ---- model -------------------------------------------------------------
    # MODEL_PATH wins when set. Otherwise the model is expected at
    # MODEL_DIR/MODEL_FILENAME, which is where SageMaker unpacks model.tar.gz
    # and where the init container in the Helm chart writes it on EKS.
    model_dir: str = field(default_factory=lambda: _env_str("MODEL_DIR", "/opt/ml/model"))
    model_filename: str = field(default_factory=lambda: _env_str("MODEL_FILENAME", "model.onnx"))
    model_path_override: str = field(default_factory=lambda: _env_str("MODEL_PATH", ""))

    # Reported on /model and attached to every metric as a label, so a latency
    # or error-rate change can be attributed to a specific model version rather
    # than to "the service".
    model_name: str = field(default_factory=lambda: _env_str("MODEL_NAME", "demand-forecast"))
    model_version: str = field(default_factory=lambda: _env_str("MODEL_VERSION", "unknown"))
    git_sha: str = field(default_factory=lambda: _env_str("GIT_SHA", "unknown"))

    # ---- request limits ----------------------------------------------------
    # A hard cap on batch size. Without it one caller can push a 100k-row batch
    # through a pod sized for single-digit batches and take the pod out of its
    # latency budget for everyone else. SageMaker gives the model 60 seconds
    # per /invocations call, so the cap also protects against a timeout that
    # would look like a model failure.
    max_batch_size: int = field(default_factory=lambda: _env_int("MAX_BATCH_SIZE", 512))

    # Predictions are counts of bikes and cannot be negative. The model's final
    # exp() already guarantees that, so this clamp only ever fires if the model
    # is replaced by one without that property. It is cheap insurance at the
    # boundary where a wrong value would reach a caller.
    clamp_min: float = field(default_factory=lambda: _env_float("PREDICTION_CLAMP_MIN", 0.0))
    clamp_max: float = field(default_factory=lambda: _env_float("PREDICTION_CLAMP_MAX", 100_000.0))

    # ---- observability -----------------------------------------------------
    metrics_enabled: bool = field(default_factory=lambda: _env_bool("METRICS_ENABLED", True))

    @property
    def model_path(self) -> str:
        if self.model_path_override:
            return self.model_path_override
        return os.path.join(self.model_dir, self.model_filename)

    def validate(self) -> None:
        """Fail fast on a configuration that cannot work.

        Called from the entrypoint before the server binds, so a bad value
        shows up as a crash-looping pod with a clear message rather than as
        wrong predictions in production.
        """
        if self.clamp_min > self.clamp_max:
            raise ValueError(
                f"PREDICTION_CLAMP_MIN ({self.clamp_min}) is above "
                f"PREDICTION_CLAMP_MAX ({self.clamp_max})"
            )
        if self.log_level not in {"critical", "error", "warning", "info", "debug", "trace"}:
            raise ValueError(f"LOG_LEVEL {self.log_level!r} is not a uvicorn log level")
        if self.workers != 1:
            # Not fatal, but it changes the meaning of every per-pod metric, so
            # it should be a deliberate choice recorded in the chart values.
            pass


_settings: Settings | None = None


def get_settings() -> Settings:
    """Return the process-wide settings, building them on first use."""
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


def reset_settings_for_tests() -> None:
    """Drop the cached settings so a test can change the environment."""
    global _settings
    _settings = None
