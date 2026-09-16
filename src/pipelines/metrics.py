"""Evaluation metrics and the noise floor that the promotion gate compares against.

The important function here is `bootstrap_std`. Without it, a gate compares two
point estimates: champion MAE 41.8 against challenger MAE 41.6, concludes the
challenger is better, and promotes it. Run the same training twice with different
seeds and the difference between the two runs is often larger than that. A gate
built that way promotes noise about half the time, and the registry fills with
versions that are not improvements while everyone believes the process is
working.

Measuring how much the metric moves under resampling of the test set gives you a
number to beat. It is not a hypothesis test and it does not pretend to be; it is
an estimate of the metric's own variability, used as a minimum margin.
"""

from __future__ import annotations

import numpy as np

Array = np.ndarray


def mae(actual: Array, predicted: Array) -> float:
    """Mean absolute error, in bikes. The primary gate metric."""
    return float(np.mean(np.abs(np.asarray(actual, dtype=np.float64) - predicted)))


def rmse(actual: Array, predicted: Array) -> float:
    """Root mean squared error. Reported, not gated on.

    RMSE punishes the rare very busy hour far harder than MAE does, so it moves
    a lot between runs on a count target with a long tail. That volatility is
    why the gate uses MAE and RMSE is only logged.
    """
    residual = np.asarray(actual, dtype=np.float64) - predicted
    return float(np.sqrt(np.mean(residual**2)))


def smape(actual: Array, predicted: Array) -> float:
    """Symmetric mean absolute percentage error, as a percentage.

    Plain MAPE is undefined for a zero actual, and a demand series has plenty of
    zero hours overnight. The symmetric form stays finite. Rows where both actual
    and predicted are zero are a perfect prediction and are scored as zero error
    rather than dropped.
    """
    actual_array = np.asarray(actual, dtype=np.float64)
    predicted_array = np.asarray(predicted, dtype=np.float64)
    denominator = (np.abs(actual_array) + np.abs(predicted_array)) / 2.0
    ratio = np.where(
        denominator == 0,
        0.0,
        np.abs(actual_array - predicted_array) / np.where(denominator == 0, 1.0, denominator),
    )
    return float(np.mean(ratio) * 100.0)


def negative_prediction_count(predicted: Array) -> int:
    """How many predictions are below zero.

    Should always be zero, because the graph ends in exp(). It is asserted on
    every evaluation anyway: this is the constraint the whole serving contract
    rests on, and a silent regression here would reach callers as a negative
    bike count.
    """
    return int(np.count_nonzero(np.asarray(predicted) < 0))


def evaluate(actual: Array, predicted: Array) -> dict[str, float]:
    """The full metric set recorded for a run."""
    return {
        "mae": mae(actual, predicted),
        "rmse": rmse(actual, predicted),
        "smape": smape(actual, predicted),
        "mean_prediction": float(np.mean(predicted)),
        "mean_actual": float(np.mean(actual)),
        "negative_predictions": float(negative_prediction_count(predicted)),
    }


def bootstrap_std(
    actual: Array,
    predicted: Array,
    metric: str = "mae",
    samples: int = 400,
    seed: int = 7,
) -> float:
    """Estimate the standard deviation of a metric under resampling of the test set.

    Resample the test rows with replacement, recompute the metric, repeat, and
    take the standard deviation of the results. That number is the noise floor:
    a difference smaller than it is not evidence of a better model.

    The seed is fixed so two evaluations of the same predictions produce the same
    floor. A gate whose threshold moves between runs is not a gate.
    """
    actual_array = np.asarray(actual, dtype=np.float64)
    predicted_array = np.asarray(predicted, dtype=np.float64)
    if actual_array.shape != predicted_array.shape:
        raise ValueError(
            f"shape mismatch: actual {actual_array.shape} vs predicted {predicted_array.shape}"
        )
    n = actual_array.size
    if n < 30:
        raise ValueError(
            f"{n} rows is too few to estimate a noise floor from; widen the test split"
        )

    functions = {"mae": mae, "rmse": rmse, "smape": smape}
    if metric not in functions:
        raise ValueError(f"unknown metric {metric!r}, expected one of {sorted(functions)}")
    function = functions[metric]

    generator = np.random.default_rng(seed)
    draws = np.empty(samples, dtype=np.float64)
    for index in range(samples):
        rows = generator.integers(0, n, size=n)
        draws[index] = function(actual_array[rows], predicted_array[rows])
    return float(draws.std(ddof=1))


def population_stability_index(
    reference: Array,
    current: Array,
    bins: int = 10,
    epsilon: float = 1e-6,
) -> float:
    """Population stability index between a reference and a current sample.

    Bin edges come from the reference distribution's quantiles, so each reference
    bin holds roughly the same share of rows. Using equal-width bins instead
    makes PSI dominated by whichever bin happens to hold the bulk of the data.

    epsilon replaces a zero share so the logarithm stays finite. A bin that is
    empty in the current window but not in the reference is exactly the signal
    PSI exists to catch, so it must contribute a large value rather than an
    infinity that poisons the sum.
    """
    reference_array = np.asarray(reference, dtype=np.float64)
    current_array = np.asarray(current, dtype=np.float64)
    if reference_array.size == 0 or current_array.size == 0:
        raise ValueError("both samples must be non-empty")
    if bins < 2:
        raise ValueError("bins must be at least 2")

    quantiles = np.linspace(0.0, 1.0, bins + 1)
    edges = np.unique(np.quantile(reference_array, quantiles))
    if edges.size < 2:
        # A constant reference feature has no distribution to compare against.
        # Report zero rather than raising: a constant column is a data problem
        # the contract check already reports, and the drift exporter should not
        # crash because of it.
        return 0.0

    # Open the outer edges so values beyond the reference range are counted in
    # the end bins instead of being dropped.
    edges[0], edges[-1] = -np.inf, np.inf

    reference_counts, _ = np.histogram(reference_array, bins=edges)
    current_counts, _ = np.histogram(current_array, bins=edges)

    reference_share = np.maximum(reference_counts / reference_array.size, epsilon)
    current_share = np.maximum(current_counts / current_array.size, epsilon)

    return float(
        np.sum((current_share - reference_share) * np.log(current_share / reference_share))
    )
