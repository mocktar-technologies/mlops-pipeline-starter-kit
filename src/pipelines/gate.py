"""The promotion gate.

This is the module that stops a scheduled retrain from being dangerous. A
retraining pipeline that registers and deploys whatever it produced is an
automated way to make production worse, because a training run can succeed
technically and still yield a worse model: the window it trained on was unusual,
an upstream join dropped rows, a feature went constant.

The rule implemented here has four parts, and all four have to pass:

  1. The challenger produces no negative predictions. This is the serving
     contract, and a violation is a hard stop rather than a metric to weigh.
  2. The challenger's absolute error is under max_acceptable_mae. This is what
     protects you when there is no champion yet: without it, the first broken
     run becomes the baseline every later run is measured against.
  3. If a champion exists, both are scored on the same test split, in the same
     process, through their ONNX graphs.
  4. The challenger beats the champion by more than the noise floor, measured by
     bootstrapping the test set, and by at least a fixed absolute margin.

Part 4 is the one people leave out. Comparing two point estimates promotes noise
roughly half the time. The alerting margin must sit above the measured noise, not
below it, or the gate is decoration.

The gate returns a decision object. It does not register, promote, or deploy
anything. Keeping the decision separate from the action is what allows the same
logic to run in a pull request as a check and in the retrain pipeline as a gate.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import onnxruntime as ort

from pipelines import metrics as metric_functions
from pipelines.config import GateConfig
from pipelines.data import Split

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class GateDecision:
    promote: bool
    metric: str
    challenger_value: float
    champion_value: float | None
    noise_floor: float
    required_margin: float
    observed_improvement: float | None
    reasons: list[str] = field(default_factory=list)

    @property
    def summary(self) -> str:
        verdict = "PROMOTE" if self.promote else "HOLD"
        if self.champion_value is None:
            comparison = "no champion"
        else:
            comparison = (
                f"champion {self.metric}={self.champion_value:.3f}, "
                f"improvement {self.observed_improvement:+.3f} against a required "
                f"margin of {self.required_margin:.3f}"
            )
        return f"{verdict}: challenger {self.metric}={self.challenger_value:.3f}, " f"{comparison}"

    def as_dict(self) -> dict[str, object]:
        """Shape written to gate.json and read by the CI job that gates deploys."""
        return {
            "promote": self.promote,
            "metric": self.metric,
            "challenger": self.challenger_value,
            "champion": self.champion_value,
            "noise_floor": self.noise_floor,
            "required_margin": self.required_margin,
            "observed_improvement": self.observed_improvement,
            "reasons": list(self.reasons),
            "summary": self.summary,
        }


def _score(onnx_path: Path, split: Split) -> np.ndarray:
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    inputs = session.get_inputs()
    if len(inputs) != 1 or (
        isinstance(inputs[0].shape[1], int) and inputs[0].shape[1] != split.features.shape[1]
    ):
        raise ValueError(
            f"{onnx_path} expects input shape {inputs[0].shape}, which does not match the "
            f"{split.features.shape[1]}-feature test split. The two models were trained "
            "against different feature contracts and their metrics are not comparable."
        )
    output_name = session.get_outputs()[0].name
    raw = session.run([output_name], {inputs[0].name: split.features})[0]
    return np.asarray(raw, dtype=np.float64).reshape(split.features.shape[0], -1)[:, 0]


def decide(
    config: GateConfig,
    test_split: Split,
    challenger_onnx: Path,
    champion_onnx: Path | None,
) -> GateDecision:
    """Score both candidates on the same split and return the decision."""
    challenger_predictions = _score(challenger_onnx, test_split)
    challenger_metrics = metric_functions.evaluate(test_split.target, challenger_predictions)
    challenger_value = challenger_metrics[config.metric]

    reasons: list[str] = []
    hard_failures = 0

    negative = int(challenger_metrics["negative_predictions"])
    if negative:
        hard_failures += 1
        reasons.append(
            f"the challenger returned {negative} negative prediction(s), which the "
            "serving contract does not allow"
        )

    if challenger_value > config.max_acceptable_mae:
        hard_failures += 1
        reasons.append(
            f"challenger {config.metric} of {challenger_value:.3f} is above the absolute "
            f"ceiling of {config.max_acceptable_mae}"
        )

    # The noise floor is measured on the challenger's own predictions, which is
    # the distribution the comparison is actually drawn from.
    noise_floor = metric_functions.bootstrap_std(
        test_split.target,
        challenger_predictions,
        metric=config.metric,
        samples=config.bootstrap_samples,
    )
    required_margin = max(config.noise_multiplier * noise_floor, config.min_absolute_improvement)

    if champion_onnx is None:
        promote = hard_failures == 0
        if promote:
            reasons.append(
                "no champion alias exists, so the challenger becomes the baseline after "
                "passing the absolute checks"
            )
        return GateDecision(
            promote=promote,
            metric=config.metric,
            challenger_value=challenger_value,
            champion_value=None,
            noise_floor=noise_floor,
            required_margin=required_margin,
            observed_improvement=None,
            reasons=reasons,
        )

    champion_value = metric_functions.evaluate(
        test_split.target, _score(champion_onnx, test_split)
    )[config.metric]

    # Lower is better for every metric this gate supports. If a higher-is-better
    # metric is ever added, this sign is the line that has to change, and the
    # config validation in config.py is where the guard belongs.
    improvement = champion_value - challenger_value

    if improvement <= 0:
        reasons.append(
            f"the challenger is worse than the champion by {abs(improvement):.3f} {config.metric}"
        )
    elif improvement < required_margin:
        reasons.append(
            f"the challenger improves {config.metric} by {improvement:.3f}, which is inside "
            f"the noise floor of {noise_floor:.3f} (required margin {required_margin:.3f}). "
            "An improvement this small is not distinguishable from run-to-run variation."
        )
    else:
        reasons.append(
            f"the challenger improves {config.metric} by {improvement:.3f}, clearing the "
            f"required margin of {required_margin:.3f}"
        )

    promote = hard_failures == 0 and improvement >= required_margin

    decision = GateDecision(
        promote=promote,
        metric=config.metric,
        challenger_value=challenger_value,
        champion_value=champion_value,
        noise_floor=noise_floor,
        required_margin=required_margin,
        observed_improvement=improvement,
        reasons=reasons,
    )
    logger.info(decision.summary)
    for reason in decision.reasons:
        logger.info("  %s", reason)
    return decision
