"""Tests for the evaluation metrics, the noise floor, PSI and the promotion gate.

The gate is the only thing standing between an automated retrain and a worse
model in production, so its behaviour is pinned down here in detail: it must
promote a genuinely better model, refuse a worse one, refuse an improvement
inside the noise, and refuse a model that violates the serving contract even when
its headline metric looks good.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from pipelines import metrics as m
from pipelines.config import GateConfig
from pipelines.data import Split
from pipelines.gate import decide

RNG = np.random.default_rng(20260912)


# ---------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------


def test_mae_and_rmse_on_a_known_case() -> None:
    actual = np.array([10.0, 20.0, 30.0])
    predicted = np.array([12.0, 18.0, 33.0])
    assert m.mae(actual, predicted) == pytest.approx((2 + 2 + 3) / 3)
    assert m.rmse(actual, predicted) == pytest.approx(np.sqrt((4 + 4 + 9) / 3))


def test_rmse_punishes_a_single_large_error_more_than_mae() -> None:
    actual = np.zeros(100)
    spread = np.full(100, 2.0)
    concentrated = np.zeros(100)
    concentrated[0] = 200.0
    assert m.mae(actual, spread) == m.mae(actual, concentrated)
    assert m.rmse(actual, concentrated) > m.rmse(actual, spread)


def test_smape_is_finite_when_the_actual_is_zero() -> None:
    """A demand series has zero hours overnight, so plain MAPE is unusable."""
    value = m.smape(np.array([0.0, 0.0, 10.0]), np.array([0.0, 5.0, 10.0]))
    assert np.isfinite(value)
    assert 0.0 < value < 100.0


def test_smape_scores_an_exact_zero_match_as_no_error() -> None:
    assert m.smape(np.array([0.0, 0.0]), np.array([0.0, 0.0])) == pytest.approx(0.0)


def test_negative_prediction_count() -> None:
    assert m.negative_prediction_count(np.array([1.0, -0.5, 0.0, -3.0])) == 2


# ---------------------------------------------------------------------------
# noise floor
# ---------------------------------------------------------------------------


def test_bootstrap_std_is_positive_and_reproducible() -> None:
    actual = RNG.poisson(100, size=800).astype(float)
    predicted = actual + RNG.normal(0, 20, size=800)
    first = m.bootstrap_std(actual, predicted, samples=200)
    second = m.bootstrap_std(actual, predicted, samples=200)
    assert first > 0
    # A gate whose threshold moves between two evaluations of the same
    # predictions is not a gate.
    assert first == second


def test_bootstrap_std_shrinks_as_the_test_set_grows() -> None:
    """More test rows means a more stable metric, so a smaller required margin."""
    small_actual = RNG.poisson(100, size=200).astype(float)
    small = m.bootstrap_std(small_actual, small_actual + RNG.normal(0, 20, 200), samples=200)
    large_actual = RNG.poisson(100, size=4000).astype(float)
    large = m.bootstrap_std(large_actual, large_actual + RNG.normal(0, 20, 4000), samples=200)
    assert large < small


def test_bootstrap_std_refuses_a_test_set_too_small_to_measure() -> None:
    with pytest.raises(ValueError, match="too few"):
        m.bootstrap_std(np.ones(10), np.ones(10))


def test_bootstrap_std_rejects_a_shape_mismatch() -> None:
    with pytest.raises(ValueError, match="shape mismatch"):
        m.bootstrap_std(np.ones(100), np.ones(50))


# ---------------------------------------------------------------------------
# population stability index
# ---------------------------------------------------------------------------


def test_psi_of_a_distribution_against_itself_is_near_zero() -> None:
    sample = RNG.normal(20, 5, size=5000)
    assert m.population_stability_index(sample, sample) < 1e-9


def test_psi_of_two_draws_from_the_same_distribution_is_small() -> None:
    reference = RNG.normal(20, 5, size=20000)
    current = RNG.normal(20, 5, size=20000)
    # Below the conventional 0.10 "no meaningful change" reading.
    assert m.population_stability_index(reference, current) < 0.05


def test_psi_detects_a_mean_shift() -> None:
    reference = RNG.normal(20, 5, size=20000)
    shifted = RNG.normal(28, 5, size=20000)
    assert m.population_stability_index(reference, shifted) > 0.25


def test_psi_grows_monotonically_with_the_size_of_the_shift() -> None:
    reference = RNG.normal(20, 5, size=20000)
    scores = [
        m.population_stability_index(reference, RNG.normal(20 + delta, 5, size=20000))
        for delta in (0, 1, 3, 6)
    ]
    assert scores == sorted(scores)


def test_psi_handles_a_bin_that_is_empty_in_the_current_window() -> None:
    """The empty bin is the signal, so it must produce a large finite value.

    Without an epsilon floor the logarithm goes to infinity and poisons the sum,
    which in an exporter means a gauge of +Inf and an alert nobody can read.
    """
    reference = RNG.uniform(0, 100, size=10000)
    current = RNG.uniform(0, 10, size=10000)
    score = m.population_stability_index(reference, current)
    assert np.isfinite(score)
    assert score > 1.0


def test_psi_of_a_constant_reference_is_zero_rather_than_an_error() -> None:
    """A constant column is a data problem the contract check reports.

    The drift exporter must not crash on it, or one bad column takes down the
    monitoring for every other feature.
    """
    assert m.population_stability_index(np.full(1000, 7.0), RNG.normal(7, 1, 1000)) == 0.0


def test_psi_rejects_an_empty_sample() -> None:
    with pytest.raises(ValueError, match="non-empty"):
        m.population_stability_index(np.array([]), np.ones(10))


# ---------------------------------------------------------------------------
# the gate
# ---------------------------------------------------------------------------


def _split_and_models(tmp_path: Path, champion_error: float, challenger_error: float):
    """Build a test split plus two ONNX models with controlled error levels.

    Both models are constant predictors, which makes the resulting MAE exactly
    the error level asked for and keeps the test about the gate's arithmetic
    rather than about a model's accuracy.
    """
    import onnx
    from onnx import TensorProto, helper, numpy_helper

    rows = 2000
    features = RNG.uniform(0, 1, size=(rows, 8)).astype(np.float32)
    target = np.full(rows, 100.0, dtype=np.float32)
    split = Split(name="test", features=features, target=target)

    def constant_model(value: float, path: Path) -> Path:
        features_info = helper.make_tensor_value_info("features", TensorProto.FLOAT, ["batch", 8])
        output_info = helper.make_tensor_value_info("y", TensorProto.FLOAT, ["batch"])
        nodes = [
            # Multiply by a zero weight vector, then add the constant, so the
            # output has a real dynamic batch axis instead of a fixed shape.
            helper.make_node("MatMul", ["features", "W"], ["zeros"]),
            helper.make_node("Add", ["zeros", "C"], ["biased"]),
            helper.make_node("Squeeze", ["biased", "axes"], ["y"]),
        ]
        graph = helper.make_graph(
            nodes,
            "constant",
            [features_info],
            [output_info],
            initializer=[
                numpy_helper.from_array(np.zeros((8, 1), dtype=np.float32), "W"),
                numpy_helper.from_array(np.array([[value]], dtype=np.float32), "C"),
                numpy_helper.from_array(np.array([1], dtype=np.int64), "axes"),
            ],
        )
        model = helper.make_model(
            graph, opset_imports=[helper.make_operatorsetid("", 17)], ir_version=10
        )
        onnx.checker.check_model(model)
        onnx.save(model, str(path))
        return path

    champion = constant_model(100.0 - champion_error, tmp_path / "champion.onnx")
    challenger = constant_model(100.0 - challenger_error, tmp_path / "challenger.onnx")
    return split, champion, challenger


def test_gate_promotes_a_clearly_better_model(tmp_path: Path) -> None:
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=40.0, challenger_error=10.0
    )
    decision = decide(GateConfig(), split, challenger, champion)
    assert decision.promote is True
    assert decision.observed_improvement == pytest.approx(30.0, abs=0.01)


def test_gate_refuses_a_worse_model(tmp_path: Path) -> None:
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=10.0, challenger_error=25.0
    )
    decision = decide(GateConfig(), split, challenger, champion)
    assert decision.promote is False
    assert any("worse than the champion" in reason for reason in decision.reasons)


def test_gate_refuses_an_improvement_inside_the_noise(tmp_path: Path) -> None:
    """The failure this whole design exists to prevent.

    A 0.1 MAE improvement is not evidence of a better model. A gate that
    promotes it fills the registry with versions that are not improvements while
    everyone believes the process is working.
    """
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=20.0, challenger_error=19.9
    )
    decision = decide(GateConfig(), split, challenger, champion)
    assert decision.promote is False
    assert decision.observed_improvement is not None
    assert 0 < decision.observed_improvement < decision.required_margin


def test_required_margin_is_never_below_the_absolute_floor(tmp_path: Path) -> None:
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=20.0, challenger_error=10.0
    )
    config = GateConfig(noise_multiplier=0.0001, min_absolute_improvement=3.0)
    decision = decide(config, split, challenger, champion)
    assert decision.required_margin >= 3.0


def test_gate_refuses_a_model_above_the_absolute_ceiling(tmp_path: Path) -> None:
    """Protects the case where there is no champion to compare against.

    Without this check the first broken run becomes the baseline that every
    later run is measured against, and the gate then happily promotes models
    that are merely less broken.
    """
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=400.0, challenger_error=300.0
    )
    decision = decide(GateConfig(max_acceptable_mae=120.0), split, challenger, champion)
    assert decision.promote is False
    assert any("absolute ceiling" in reason for reason in decision.reasons)


def test_gate_accepts_the_first_model_when_no_champion_exists(tmp_path: Path) -> None:
    split, _, challenger = _split_and_models(tmp_path, champion_error=0.0, challenger_error=8.0)
    decision = decide(GateConfig(), split, challenger, champion_onnx=None)
    assert decision.promote is True
    assert decision.champion_value is None
    assert any("no champion alias" in reason for reason in decision.reasons)


def test_gate_refuses_the_first_model_if_it_breaks_the_ceiling(tmp_path: Path) -> None:
    split, _, challenger = _split_and_models(tmp_path, champion_error=0.0, challenger_error=500.0)
    decision = decide(GateConfig(), split, challenger, champion_onnx=None)
    assert decision.promote is False


def test_gate_refuses_to_compare_models_with_different_feature_contracts(
    tmp_path: Path, onnx_wrong_arity_path: Path
) -> None:
    """Two models trained on different contracts produce incomparable metrics."""
    split, champion, _ = _split_and_models(tmp_path, champion_error=10.0, challenger_error=10.0)
    with pytest.raises(ValueError, match="different feature contracts"):
        decide(GateConfig(), split, onnx_wrong_arity_path, champion)


def test_decision_serializes_for_the_workflow(tmp_path: Path) -> None:
    """gate.json is read by the CI job, so its keys are part of the interface."""
    split, champion, challenger = _split_and_models(
        tmp_path, champion_error=40.0, challenger_error=10.0
    )
    payload = decide(GateConfig(), split, challenger, champion).as_dict()
    for key in (
        "promote",
        "metric",
        "challenger",
        "champion",
        "noise_floor",
        "required_margin",
        "observed_improvement",
        "reasons",
        "summary",
    ):
        assert key in payload
    assert isinstance(payload["promote"], bool)
