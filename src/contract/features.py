"""The feature contract.

This module is the single definition of which features the model consumes and
in what order. The training pipeline imports it, the serving path imports it,
and the tests assert that both agree.

Why this file exists at all: an ONNX graph accepts a float tensor of shape
(batch, 8). It cannot tell you that column 5 is supposed to be temperature. If
training builds the matrix in one order and serving builds it in another, every
prediction is wrong, nothing raises, latency is unchanged and every dashboard
stays green. That failure is training-serving skew, and a shared ordered tuple
is the cheapest defence against it.

Change this list and you have changed the model's input signature. That is a
breaking change: retrain, bump the model version, and let the evaluation gate
decide whether the new model is better. Never edit the order to match a caller.
"""

from __future__ import annotations

from typing import Final

# Ordered. Index in this tuple is the column index in the model input tensor.
FEATURE_NAMES: Final[tuple[str, ...]] = (
    "hour",  # 0-23, local time of the observation
    "dayofweek",  # 0 = Monday through 6 = Sunday
    "month",  # 1-12
    "is_holiday",  # 0 or 1
    "is_workingday",  # 0 or 1, that is a weekday that is not a holiday
    "temp_c",  # air temperature in degrees Celsius
    "humidity",  # relative humidity, 0.0 to 1.0
    "windspeed",  # wind speed in metres per second
)

N_FEATURES: Final[int] = len(FEATURE_NAMES)

TARGET_NAME: Final[str] = "rentals"

# Inclusive bounds used for input validation at the serving boundary and for
# the data contract in the training pipeline. These are domain facts, not
# statistics learned from a particular dataset, which is why they live in code
# and not in a fitted artifact.
FEATURE_BOUNDS: Final[dict[str, tuple[float, float]]] = {
    "hour": (0.0, 23.0),
    "dayofweek": (0.0, 6.0),
    "month": (1.0, 12.0),
    "is_holiday": (0.0, 1.0),
    "is_workingday": (0.0, 1.0),
    "temp_c": (-40.0, 55.0),
    "humidity": (0.0, 1.0),
    "windspeed": (0.0, 80.0),
}

# Features whose drift is tracked by the drift exporter. Binary flags are
# excluded because a population stability index over two categories is noisy
# and easy to misread; their shift shows up in is_workingday counts instead.
DRIFT_FEATURES: Final[tuple[str, ...]] = (
    "hour",
    "dayofweek",
    "month",
    "temp_c",
    "humidity",
    "windspeed",
)


def assert_contract_intact() -> None:
    """Guard against a partial edit of this file.

    Imported by both the training and serving test suites. If someone adds a
    feature to FEATURE_NAMES and forgets its bounds, this raises at test time
    rather than at 3 a.m.
    """
    missing = [name for name in FEATURE_NAMES if name not in FEATURE_BOUNDS]
    if missing:
        raise AssertionError(f"FEATURE_BOUNDS is missing bounds for: {missing}")

    extra = [name for name in FEATURE_BOUNDS if name not in FEATURE_NAMES]
    if extra:
        raise AssertionError(f"FEATURE_BOUNDS has bounds for unknown features: {extra}")

    unknown_drift = [name for name in DRIFT_FEATURES if name not in FEATURE_NAMES]
    if unknown_drift:
        raise AssertionError(f"DRIFT_FEATURES names unknown features: {unknown_drift}")

    if len(set(FEATURE_NAMES)) != len(FEATURE_NAMES):
        raise AssertionError("FEATURE_NAMES contains a duplicate")

    if TARGET_NAME in FEATURE_NAMES:
        raise AssertionError(
            f"the target {TARGET_NAME!r} is listed as a feature, which leaks the label"
        )
