"""ONNX Runtime model wrapper.

The wrapper does four things the raw session does not:

  1. Loads the artifact once, at startup, and refuses to serve until it has.
     A model loaded lazily on first request turns a cold pod into a slow pod,
     and a rolling update into a latency spike.

  2. Validates the graph against the feature contract. If the artifact expects
     a different number of inputs than contract.features declares, the process
     exits at startup instead of returning wrong numbers for weeks.

  3. Runs a warmup inference. The first call into ONNX Runtime allocates arenas
     and, on some builds, JIT-compiles kernels. Paying that cost before the
     readiness probe passes keeps it out of your p99.

  4. Clamps the output at the configured bounds and counts every clamp. The
     model's own final exp() already makes negative predictions impossible, so
     a non-zero clamp counter means the artifact is not the model this service
     was written for. That is worth an alert.
"""

from __future__ import annotations

import logging
import os
import time

import numpy as np
import onnxruntime as ort

from contract.features import FEATURE_NAMES, N_FEATURES
from serving import metrics
from serving.config import Settings

logger = logging.getLogger(__name__)


class ModelNotLoadedError(RuntimeError):
    """Raised when inference is attempted before a successful load."""


class ModelContractError(RuntimeError):
    """Raised when the artifact does not match the feature contract."""


class OnnxModel:
    """A loaded ONNX model plus the metadata the service reports about it."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._session: ort.InferenceSession | None = None
        self._input_name: str = ""
        self._output_name: str = ""
        self._opset: int | None = None

    # ---- lifecycle ---------------------------------------------------------

    def load(self) -> None:
        """Load and verify the artifact. Raises on any problem."""
        path = self._settings.model_path
        if not os.path.isfile(path):
            metrics.MODEL_LOAD_FAILURES.inc()
            raise FileNotFoundError(
                f"no model artifact at {path}. Set MODEL_PATH, or make sure the "
                f"init container has written {self._settings.model_filename} "
                f"into {self._settings.model_dir}."
            )

        options = ort.SessionOptions()
        # Bound the thread pools explicitly. Left alone, ONNX Runtime sizes them
        # from the host core count, which inside a container with a 1-CPU limit
        # produces dozens of threads fighting over one core. That shows up as
        # tail latency that does not correlate with request rate.
        options.intra_op_num_threads = self._settings.intra_op_threads
        options.inter_op_num_threads = 1
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        # Deterministic compute, so the same input gives the same output across
        # replicas. Without it a canary can appear to disagree with the
        # baseline for reasons that have nothing to do with the model.
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL

        try:
            session = ort.InferenceSession(
                path, sess_options=options, providers=["CPUExecutionProvider"]
            )
        except Exception:
            metrics.MODEL_LOAD_FAILURES.inc()
            logger.exception("onnxruntime failed to open %s", path)
            raise

        inputs = session.get_inputs()
        outputs = session.get_outputs()
        if len(inputs) != 1:
            metrics.MODEL_LOAD_FAILURES.inc()
            raise ModelContractError(
                f"expected exactly one graph input, found {len(inputs)}: "
                f"{[i.name for i in inputs]}"
            )
        if len(outputs) < 1:
            metrics.MODEL_LOAD_FAILURES.inc()
            raise ModelContractError("the graph declares no outputs")

        # Shape is typically [None, N_FEATURES] for a dynamic batch axis. Only
        # the feature axis is checked; the batch axis is expected to be dynamic.
        shape = inputs[0].shape
        if len(shape) != 2:
            metrics.MODEL_LOAD_FAILURES.inc()
            raise ModelContractError(
                f"expected a rank-2 input of shape (batch, {N_FEATURES}), got {shape}"
            )
        feature_axis = shape[1]
        if isinstance(feature_axis, int) and feature_axis != N_FEATURES:
            metrics.MODEL_LOAD_FAILURES.inc()
            raise ModelContractError(
                f"artifact expects {feature_axis} features but the contract in "
                f"contract.features declares {N_FEATURES}: {list(FEATURE_NAMES)}. "
                "Retrain against the current contract rather than editing the contract."
            )

        self._session = session
        self._input_name = inputs[0].name
        self._output_name = outputs[0].name

        # opset is metadata, not a guarantee, so a missing value is not fatal.
        try:
            self._opset = int(session.get_modelmeta().custom_metadata_map.get("opset", "0")) or None
        except (ValueError, AttributeError):
            self._opset = None

        self._warmup()

        metrics.MODEL_LOADED.set(1)
        metrics.MODEL_INFO.info(
            {
                "model_name": self._settings.model_name,
                "model_version": self._settings.model_version,
                "git_sha": self._settings.git_sha,
                "path": path,
            }
        )
        logger.info(
            "loaded model name=%s version=%s path=%s input=%s output=%s threads=%d",
            self._settings.model_name,
            self._settings.model_version,
            path,
            self._input_name,
            self._output_name,
            self._settings.intra_op_threads,
        )

    def _warmup(self) -> None:
        """Run one throwaway inference so the first real request is not the first."""
        if self._session is None:
            # Not an assert: assert statements are removed under python -O, and a
            # container is exactly the place someone sets that flag.
            raise ModelNotLoadedError("warmup called before the session was created")
        probe = np.zeros((1, N_FEATURES), dtype=np.float32)
        started = time.perf_counter()
        self._session.run([self._output_name], {self._input_name: probe})
        logger.info("warmup inference took %.1f ms", (time.perf_counter() - started) * 1000)

    def close(self) -> None:
        """Release the session on shutdown."""
        self._session = None
        metrics.MODEL_LOADED.set(0)

    # ---- introspection -----------------------------------------------------

    @property
    def loaded(self) -> bool:
        return self._session is not None

    @property
    def input_name(self) -> str:
        return self._input_name

    @property
    def output_name(self) -> str:
        return self._output_name

    @property
    def opset(self) -> int | None:
        return self._opset

    # ---- inference ---------------------------------------------------------

    def predict(self, rows: list[list[float]]) -> list[float]:
        """Run inference on a batch of contract-ordered rows.

        Returns one float per row, clamped to the configured bounds.
        """
        if self._session is None:
            raise ModelNotLoadedError("no model is loaded")

        batch = np.asarray(rows, dtype=np.float32)
        if batch.ndim != 2 or batch.shape[1] != N_FEATURES:
            raise ValueError(f"expected a (batch, {N_FEATURES}) matrix, got {batch.shape}")

        version = self._settings.model_version
        started = time.perf_counter()
        raw = self._session.run([self._output_name], {self._input_name: batch})[0]
        metrics.MODEL_LATENCY.labels(model_version=version).observe(time.perf_counter() - started)

        # Squeeze a trailing singleton axis; a regression head is commonly
        # exported as (batch, 1).
        flat = np.asarray(raw, dtype=np.float64).reshape(batch.shape[0], -1)[:, 0]

        # A NaN or infinity would serialize to invalid JSON and, worse, would be
        # accepted downstream as a number. Treat it as an inference failure.
        if not np.all(np.isfinite(flat)):
            raise ValueError("model produced a non-finite prediction")

        low, high = self._settings.clamp_min, self._settings.clamp_max
        below = int(np.count_nonzero(flat < low))
        above = int(np.count_nonzero(flat > high))
        if below:
            metrics.PREDICTION_CLAMPED.labels(model_version=version, bound="lower").inc(below)
            logger.warning(
                "clamped %d prediction(s) below %s. The exported model should not be "
                "able to produce a negative count; check which artifact is loaded.",
                below,
                low,
            )
        if above:
            metrics.PREDICTION_CLAMPED.labels(model_version=version, bound="upper").inc(above)
            logger.warning("clamped %d prediction(s) above %s", above, high)

        clamped = np.clip(flat, low, high)

        metrics.PREDICTIONS_TOTAL.labels(model_version=version).inc(clamped.size)
        prediction_metric = metrics.PREDICTION.labels(model_version=version)
        for value in clamped:
            prediction_metric.observe(float(value))

        return [float(value) for value in clamped]
