"""Shared fixtures.

The ONNX fixture is hand-built rather than exported from PyTorch. The serving test
suite runs against the serving requirements only, which is the point: if a test
needs the training image to run, it is not testing the serving container.

The fixture graph has the same shape as the real artifact, including the final
exp(), so the contract checks in serving.model exercise real behaviour rather
than a mock that agrees with them by construction.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import onnx
import pytest
from onnx import TensorProto, helper, numpy_helper

N_FIXTURE_FEATURES = 8


def _build_graph(
    n_features: int, weights: np.ndarray, bias: float, apply_exp: bool
) -> onnx.ModelProto:
    """exp(features @ weights + bias), or the linear form without the exp."""
    features = helper.make_tensor_value_info("features", TensorProto.FLOAT, ["batch", n_features])
    output = helper.make_tensor_value_info("predicted_rentals", TensorProto.FLOAT, ["batch"])

    initializers = [
        numpy_helper.from_array(weights.astype(np.float32).reshape(n_features, 1), "W"),
        numpy_helper.from_array(np.array([[bias]], dtype=np.float32), "B"),
    ]

    nodes = [
        helper.make_node("MatMul", ["features", "W"], ["linear"]),
        helper.make_node("Add", ["linear", "B"], ["biased"]),
    ]
    last = "biased"
    if apply_exp:
        nodes.append(helper.make_node("Exp", ["biased"], ["rate"]))
        last = "rate"
    # Flatten (batch, 1) to (batch,) so the output rank matches the real export.
    nodes.append(helper.make_node("Squeeze", [last, "squeeze_axes"], ["predicted_rentals"]))
    initializers.append(numpy_helper.from_array(np.array([1], dtype=np.int64), "squeeze_axes"))

    graph = helper.make_graph(nodes, "fixture", [features], [output], initializer=initializers)
    model = helper.make_model(
        graph,
        opset_imports=[helper.make_operatorsetid("", 17)],
        ir_version=10,
    )
    onnx.checker.check_model(model)
    return model


@pytest.fixture
def onnx_model_path(tmp_path: Path) -> Path:
    """A well-formed 8-feature model whose output is always positive."""
    # Small weights so a plausible input produces a plausible rental count
    # rather than exp(large).
    weights = np.array([0.05, 0.02, 0.01, -0.10, 0.15, 0.03, -0.20, -0.01])
    model = _build_graph(N_FIXTURE_FEATURES, weights, bias=3.0, apply_exp=True)
    path = tmp_path / "model.onnx"
    onnx.save(model, str(path))
    return path


@pytest.fixture
def onnx_wrong_arity_path(tmp_path: Path) -> Path:
    """A model expecting five features, used to prove the contract check bites."""
    model = _build_graph(5, np.ones(5) * 0.1, bias=1.0, apply_exp=True)
    path = tmp_path / "wrong.onnx"
    onnx.save(model, str(path))
    return path


@pytest.fixture
def onnx_negative_capable_path(tmp_path: Path) -> Path:
    """A linear model with no exp, which can and will predict below zero.

    Stands in for the mistake the whole design guards against: a squared-error
    regression on a count target. Used to prove the serving clamp and its counter
    actually fire.
    """
    weights = np.array([-5.0, -5.0, -5.0, -5.0, -5.0, -5.0, -5.0, -5.0])
    model = _build_graph(N_FIXTURE_FEATURES, weights, bias=-10.0, apply_exp=False)
    path = tmp_path / "linear.onnx"
    onnx.save(model, str(path))
    return path


@pytest.fixture
def valid_observation() -> dict[str, float | int]:
    """One request row that satisfies every bound in the contract."""
    return {
        "hour": 17,
        "dayofweek": 2,
        "month": 6,
        "is_holiday": 0,
        "is_workingday": 1,
        "temp_c": 21.5,
        "humidity": 0.55,
        "windspeed": 3.2,
    }


@pytest.fixture(autouse=True)
def clean_serving_environment(monkeypatch: pytest.MonkeyPatch):
    """Isolate every test from the ambient environment and the settings cache.

    Without this, a test that sets MAX_BATCH_SIZE leaks into the next one through
    the module-level settings cache, and the suite passes or fails depending on
    the order pytest happened to choose.
    """
    for name in list(os.environ):
        if name.startswith(
            ("SERVING_", "MODEL_", "PREDICTION_", "MAX_BATCH", "METRICS_", "LOG_LEVEL")
        ):
            monkeypatch.delenv(name, raising=False)

    from serving import config as serving_config

    serving_config.reset_settings_for_tests()
    yield
    serving_config.reset_settings_for_tests()
