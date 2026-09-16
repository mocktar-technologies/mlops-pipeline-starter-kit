"""Tests for the feature contract and the artifact checks built on it.

These are the cheapest tests in the repository and they cover the failure that
costs the most to find in production: training and serving disagreeing about what
column three means. Nothing raises when that happens, so only a test can catch it.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from contract.features import (
    DRIFT_FEATURES,
    FEATURE_BOUNDS,
    FEATURE_NAMES,
    N_FEATURES,
    TARGET_NAME,
    assert_contract_intact,
)
from serving.config import Settings
from serving.model import ModelContractError, ModelNotLoadedError, OnnxModel
from serving.schemas import Observation


def test_contract_is_internally_consistent() -> None:
    assert_contract_intact()


def test_feature_count_matches_names() -> None:
    assert N_FEATURES == len(FEATURE_NAMES) == 8


def test_every_feature_has_bounds() -> None:
    assert set(FEATURE_BOUNDS) == set(FEATURE_NAMES)


def test_drift_features_are_a_subset() -> None:
    assert set(DRIFT_FEATURES) <= set(FEATURE_NAMES)


def test_target_is_not_a_feature() -> None:
    # A target that appears in the feature list is label leakage, and the model
    # would score perfectly in testing and be useless in production.
    assert TARGET_NAME not in FEATURE_NAMES


def test_observation_row_order_follows_the_contract(valid_observation: dict) -> None:
    """The request schema must serialize in contract order, not declaration order."""
    row = Observation(**valid_observation).to_row()
    assert len(row) == N_FEATURES
    for index, name in enumerate(FEATURE_NAMES):
        assert row[index] == pytest.approx(
            float(valid_observation[name])
        ), f"position {index} should carry {name}"


def _settings(model_path: Path, **overrides: object) -> Settings:
    import os

    os.environ["MODEL_PATH"] = str(model_path)
    for key, value in overrides.items():
        os.environ[key] = str(value)
    from serving import config as serving_config

    serving_config.reset_settings_for_tests()
    return Settings()


def test_model_loads_and_predicts(onnx_model_path: Path, valid_observation: dict) -> None:
    model = OnnxModel(_settings(onnx_model_path))
    model.load()
    assert model.loaded
    predictions = model.predict([Observation(**valid_observation).to_row()])
    assert len(predictions) == 1
    assert predictions[0] > 0


def test_model_rejects_an_artifact_with_the_wrong_feature_count(
    onnx_wrong_arity_path: Path,
) -> None:
    """A five-feature artifact must be refused, not served.

    This is the check that turns a silent wrongness into a crash-looping pod.
    """
    model = OnnxModel(_settings(onnx_wrong_arity_path))
    with pytest.raises(ModelContractError, match="expects 5 features"):
        model.load()
    assert not model.loaded


def test_predict_before_load_raises(onnx_model_path: Path, valid_observation: dict) -> None:
    model = OnnxModel(_settings(onnx_model_path))
    with pytest.raises(ModelNotLoadedError):
        model.predict([Observation(**valid_observation).to_row()])


def test_missing_artifact_reports_the_path(tmp_path: Path) -> None:
    absent = tmp_path / "not-there.onnx"
    model = OnnxModel(_settings(absent))
    with pytest.raises(FileNotFoundError, match=r"not-there\.onnx"):
        model.load()


def test_negative_predictions_are_clamped_and_counted(
    onnx_negative_capable_path: Path, valid_observation: dict
) -> None:
    """The clamp is the last line of defence, so prove it fires and is observable.

    The fixture is a linear model with no exp, which is exactly what a
    squared-error regression on a count target produces. It predicts well below
    zero for an ordinary input.
    """
    from serving import metrics

    before = metrics.PREDICTION_CLAMPED.labels(model_version="unknown", bound="lower")._value.get()

    model = OnnxModel(_settings(onnx_negative_capable_path))
    model.load()
    predictions = model.predict([Observation(**valid_observation).to_row()])

    assert predictions[0] == 0.0, "a negative count must never reach the caller"
    after = metrics.PREDICTION_CLAMPED.labels(model_version="unknown", bound="lower")._value.get()
    assert after > before, "a clamp must increment its counter so an alert can see it"


def test_batch_shape_is_validated(onnx_model_path: Path) -> None:
    model = OnnxModel(_settings(onnx_model_path))
    model.load()
    with pytest.raises(ValueError, match=r"expected a \(batch, 8\) matrix"):
        model.predict([[1.0, 2.0, 3.0]])


def test_dynamic_batch_axis(onnx_model_path: Path, valid_observation: dict) -> None:
    """One artifact has to serve a single row and a large batch.

    An export with a fixed batch dimension passes every online test and then
    fails the first time a batch transform runs, typically overnight.
    """
    model = OnnxModel(_settings(onnx_model_path))
    model.load()
    row = Observation(**valid_observation).to_row()
    for size in (1, 2, 37, 256):
        predictions = model.predict([row] * size)
        assert len(predictions) == size
        assert np.all(np.asarray(predictions) > 0)
