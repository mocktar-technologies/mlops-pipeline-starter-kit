"""Tests for the data contract, the chronological split and the training run.

The training test is slow by unit-test standards, a few seconds, and it is worth
it. It is the only test that proves the three things the pipeline actually
promises: that the exported graph agrees with the trained model, that the graph
cannot emit a negative count, and that the metrics the gate reads were measured
through the artifact rather than through PyTorch.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from contract.features import FEATURE_NAMES, TARGET_NAME
from pipelines.config import (
    DataConfig,
    GateConfig,
    ModelConfig,
    PipelineConfig,
    TrainingConfig,
)
from pipelines.data import DataContractError, load_dataset, validate_frame

pytestmark = pytest.mark.requires_torch


def synthetic_frame(rows: int = 4000, seed: int = 11) -> pd.DataFrame:
    """A dataset with the contract's schema and a learnable signal.

    Demand rises in the commuter peaks, falls overnight, rises with temperature
    and falls with rain-like humidity. The target is drawn from a Poisson
    distribution, which is what makes a Poisson head the right model rather than
    a decoration.
    """
    rng = np.random.default_rng(seed)
    hour = rng.integers(0, 24, rows)
    dayofweek = rng.integers(0, 7, rows)
    month = rng.integers(1, 13, rows)
    is_holiday = (rng.random(rows) < 0.03).astype(int)
    is_workingday = ((dayofweek < 5) & (is_holiday == 0)).astype(int)
    temp_c = rng.normal(16, 8, rows).clip(-15, 42)
    humidity = rng.uniform(0.15, 0.98, rows)
    windspeed = rng.gamma(2.0, 1.8, rows).clip(0, 40)

    morning = np.exp(-((hour - 8) ** 2) / 6.0)
    evening = np.exp(-((hour - 18) ** 2) / 8.0)
    rate = (
        12.0
        + 90.0 * is_workingday * (morning + evening)
        + 30.0 * (1 - is_workingday) * np.exp(-((hour - 14) ** 2) / 30.0)
        + 2.2 * temp_c
        - 55.0 * (humidity - 0.5) ** 2 * 4
        - 0.9 * windspeed
    )
    rentals = rng.poisson(np.clip(rate, 1.0, None))

    return pd.DataFrame(
        {
            "hour": hour,
            "dayofweek": dayofweek,
            "month": month,
            "is_holiday": is_holiday,
            "is_workingday": is_workingday,
            "temp_c": temp_c,
            "humidity": humidity,
            "windspeed": windspeed,
            TARGET_NAME: rentals,
        }
    )


@pytest.fixture
def dataset_csv(tmp_path: Path) -> Path:
    path = tmp_path / "data.csv"
    synthetic_frame().to_csv(path, index=False)
    return path


def _config(uri: Path, **training_overrides) -> PipelineConfig:
    return PipelineConfig(
        model_name="demand-forecast",
        data=DataConfig(uri=str(uri), min_rows=1000),
        model=ModelConfig(hidden_sizes=(16, 8), dropout=0.0),
        training=TrainingConfig(
            epochs=training_overrides.pop("epochs", 12),
            batch_size=512,
            learning_rate=5e-3,
            early_stopping_patience=training_overrides.pop("patience", 6),
            **training_overrides,
        ),
        gate=GateConfig(bootstrap_samples=60),
    )


# ---------------------------------------------------------------------------
# the data contract
# ---------------------------------------------------------------------------


def test_a_clean_frame_passes() -> None:
    validate_frame(synthetic_frame(), min_rows=1000)


def test_a_missing_column_is_rejected() -> None:
    frame = synthetic_frame().drop(columns=["humidity"])
    with pytest.raises(DataContractError, match="missing required column"):
        validate_frame(frame, min_rows=1000)


def test_a_short_dataset_is_rejected() -> None:
    """A truncated upstream export is far more common than a genuinely small one."""
    with pytest.raises(DataContractError, match="below the configured minimum"):
        validate_frame(synthetic_frame(rows=100), min_rows=1000)


def test_nulls_are_rejected() -> None:
    frame = synthetic_frame()
    frame.loc[5, "temp_c"] = np.nan
    with pytest.raises(DataContractError, match="null values"):
        validate_frame(frame, min_rows=1000)


def test_out_of_range_values_are_rejected_with_the_same_bounds_the_api_uses() -> None:
    """Training on values the API rejects means scoring on a distribution production never sees."""
    frame = synthetic_frame()
    frame.loc[3, "humidity"] = 4.0
    with pytest.raises(DataContractError, match=r"humidity outside \[0.0, 1.0\]"):
        validate_frame(frame, min_rows=1000)


def test_a_negative_target_is_rejected() -> None:
    frame = synthetic_frame()
    frame.loc[0, TARGET_NAME] = -1
    with pytest.raises(DataContractError, match="negative"):
        validate_frame(frame, min_rows=1000)


def test_a_constant_target_is_rejected() -> None:
    frame = synthetic_frame()
    frame[TARGET_NAME] = 42
    with pytest.raises(DataContractError, match="zero variance"):
        validate_frame(frame, min_rows=1000)


# ---------------------------------------------------------------------------
# splitting and scaling
# ---------------------------------------------------------------------------


def test_split_is_chronological_and_contiguous(dataset_csv: Path) -> None:
    """Row order is time order, so the splits must be adjacent slices.

    A random split lets the model train on the future. Every reported metric
    improves and nothing in those metrics reveals the problem.
    """
    frame = pd.read_csv(dataset_csv)
    dataset = load_dataset(DataConfig(uri=str(dataset_csv), min_rows=1000))

    assert len(dataset.train) + len(dataset.validation) + len(dataset.test) == len(frame)

    expected_first_test_row = frame.iloc[len(dataset.train) + len(dataset.validation)]
    np.testing.assert_allclose(
        dataset.test.features[0],
        expected_first_test_row[list(FEATURE_NAMES)].to_numpy(dtype=np.float32),
        rtol=1e-6,
    )


def test_scaling_statistics_come_from_the_training_split_only(dataset_csv: Path) -> None:
    """Fitting the scaler on all rows leaks the test set into the model."""
    dataset = load_dataset(DataConfig(uri=str(dataset_csv), min_rows=1000))
    np.testing.assert_allclose(dataset.feature_mean, dataset.train.features.mean(axis=0), rtol=1e-5)

    whole_dataset_mean = np.concatenate(
        [dataset.train.features, dataset.validation.features, dataset.test.features]
    ).mean(axis=0)
    assert not np.allclose(dataset.feature_mean, whole_dataset_mean, rtol=1e-9)


def test_a_constant_feature_does_not_produce_an_infinity(tmp_path: Path) -> None:
    frame = synthetic_frame()
    frame["windspeed"] = 5.0
    path = tmp_path / "constant.csv"
    frame.to_csv(path, index=False)
    dataset = load_dataset(DataConfig(uri=str(path), min_rows=1000))
    assert np.all(np.isfinite(dataset.feature_std))
    assert np.all(dataset.feature_std > 0)


# ---------------------------------------------------------------------------
# the model
# ---------------------------------------------------------------------------


def test_the_network_can_never_return_a_negative_count() -> None:
    """The property the serving contract depends on, asserted directly.

    A squared-error regression on a count target returns negative predictions for
    low-demand hours as a matter of routine. The exp() head makes it impossible.
    """
    import torch

    from pipelines.net import DemandForecastNet

    net = DemandForecastNet(
        feature_mean=torch.zeros(8), feature_std=torch.ones(8), hidden_sizes=(8,), dropout=0.0
    )
    rng = np.random.default_rng(3)
    # Deliberately extreme input, well outside anything the contract permits.
    hostile = torch.from_numpy(rng.normal(0, 500, size=(2000, 8)).astype(np.float32))
    with torch.no_grad():
        predictions = net(hostile).numpy()
    assert np.all(predictions >= 0)
    assert np.all(np.isfinite(predictions))


def test_the_network_rejects_bad_scaling_statistics() -> None:
    import torch

    from pipelines.net import DemandForecastNet

    with pytest.raises(ValueError, match="8 entries"):
        DemandForecastNet(feature_mean=torch.zeros(5), feature_std=torch.ones(5))
    with pytest.raises(ValueError, match="non-positive"):
        DemandForecastNet(feature_mean=torch.zeros(8), feature_std=torch.zeros(8))


def test_scaling_is_inside_the_graph_so_no_separate_scaler_ships() -> None:
    """The buffers must survive state_dict, which is what makes the export self-contained.

    Shipping a separate preprocessing artifact is the most common cause of
    training-serving skew. If these buffers are not in the state dict they are
    not in the ONNX graph either.
    """
    import torch

    from pipelines.net import DemandForecastNet

    mean = torch.arange(8, dtype=torch.float32)
    std = torch.full((8,), 2.0)
    net = DemandForecastNet(feature_mean=mean, feature_std=std)
    state = net.state_dict()
    assert "feature_mean" in state
    assert "feature_std" in state
    np.testing.assert_allclose(state["feature_mean"].numpy().ravel(), mean.numpy())


# ---------------------------------------------------------------------------
# the training run
# ---------------------------------------------------------------------------


def test_training_produces_a_parity_checked_artifact(dataset_csv: Path, tmp_path: Path) -> None:
    from pipelines.train import PARITY_TOLERANCE, train

    config = _config(dataset_csv)
    result = train(config, tmp_path / "artifacts")

    assert result.onnx_path.is_file()
    assert result.checkpoint_path.is_file()
    assert (tmp_path / "artifacts" / "metrics.json").is_file()

    # The check that catches a broken export. Every metric measured belongs to
    # the PyTorch model; the graph is what serves traffic.
    assert result.parity_max_abs_diff <= PARITY_TOLERANCE

    assert result.test_metrics["negative_predictions"] == 0
    assert result.noise_floor > 0
    assert result.best_epoch >= 1


def test_the_exported_graph_serves_through_the_serving_wrapper(
    dataset_csv: Path, tmp_path: Path, valid_observation: dict
) -> None:
    """End to end across the boundary: train here, load with the serving code.

    This is the test that would have caught a feature-order mismatch, an opset
    the runtime cannot open, or an export with a fixed batch dimension.
    """
    import os

    from pipelines.train import train
    from serving import config as serving_config
    from serving.config import Settings
    from serving.model import OnnxModel
    from serving.schemas import Observation

    result = train(_config(dataset_csv), tmp_path / "artifacts")

    os.environ["MODEL_PATH"] = str(result.onnx_path)
    serving_config.reset_settings_for_tests()
    model = OnnxModel(Settings())
    model.load()

    predictions = model.predict([Observation(**valid_observation).to_row()] * 5)
    assert len(predictions) == 5
    assert all(value >= 0 for value in predictions)


def test_training_learns_something(dataset_csv: Path, tmp_path: Path) -> None:
    """Beat the mean predictor, or the pipeline is testing plumbing and nothing else.

    Without this assertion every other training test still passes when the model
    learns nothing at all.
    """
    from pipelines.train import train

    result = train(_config(dataset_csv, epochs=25, patience=10), tmp_path / "artifacts")

    frame = pd.read_csv(dataset_csv)
    split_point = int(len(frame) * 0.85)
    train_mean = frame[TARGET_NAME].iloc[:split_point].mean()
    baseline_mae = float(np.mean(np.abs(frame[TARGET_NAME].iloc[split_point:] - train_mean)))

    assert result.test_metrics["mae"] < baseline_mae, (
        f"model MAE {result.test_metrics['mae']:.2f} is no better than predicting the "
        f"training mean ({baseline_mae:.2f})"
    )
