#!/usr/bin/env python3
"""Generate a synthetic dataset with the contract's schema.

This exists so the pipeline can be run, tested and demonstrated with no network
access and no dataset licence to read. It is not a substitute for real data and it
is not pretending to be: a model trained on it learns the relationships written
below, which is only useful for proving that the plumbing works.

For real use, point DATA_URI at your own hourly demand data with the columns in
contract.features, or at a public dataset with the same shape. The UCI Bike Sharing
dataset is the obvious candidate and is released under CC BY 4.0; download it
yourself, map its columns onto this contract, and check the licence terms for your
use rather than taking a script's word for them.

The generated series is deliberately realistic in the ways that matter to an MLOps
pipeline rather than to a data scientist:

  it is ordered in time, so the chronological split in data.py is meaningful
  the target is Poisson distributed, so a Poisson head is the right model
  demand has commuter peaks on working days and a midday peak otherwise
  weather effects are non-linear, so a linear model is visibly worse
  there is a slow upward trend, so a model trained on old data degrades

That last property is the point of the --drift option: it shifts the distribution
of the tail of the series, which gives the drift exporter something real to detect.
"""

from __future__ import annotations

import argparse
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from contract.features import FEATURE_NAMES, TARGET_NAME

# A fixed set of dates treated as holidays, spread across the year. Real holiday
# calendars are regional and this is a synthetic generator, so it uses a plausible
# density rather than pretending to be any country's calendar.
HOLIDAY_DAY_OF_YEAR = frozenset({1, 19, 50, 90, 148, 185, 246, 315, 331, 359, 360})


def generate(rows: int, seed: int, start: datetime, drift_fraction: float) -> pd.DataFrame:
    rng = np.random.default_rng(seed)

    timestamps = [start + timedelta(hours=index) for index in range(rows)]
    hour = np.array([timestamp.hour for timestamp in timestamps])
    dayofweek = np.array([timestamp.weekday() for timestamp in timestamps])
    month = np.array([timestamp.month for timestamp in timestamps])
    day_of_year = np.array([timestamp.timetuple().tm_yday for timestamp in timestamps])

    is_holiday = np.isin(day_of_year, list(HOLIDAY_DAY_OF_YEAR)).astype(int)
    is_workingday = ((dayofweek < 5) & (is_holiday == 0)).astype(int)

    # Seasonal temperature with daily variation and noise.
    seasonal = 14.0 + 11.0 * np.sin(2 * np.pi * (day_of_year - 110) / 365.0)
    daily = 4.5 * np.sin(2 * np.pi * (hour - 4) / 24.0)
    temp_c = np.clip(seasonal + daily + rng.normal(0, 2.2, rows), -18.0, 42.0)

    # Humidity is higher overnight and in winter, and is anti-correlated with
    # temperature, which is what makes a model that ignores the interaction worse.
    humidity = np.clip(
        0.72
        - 0.010 * (temp_c - 14.0)
        + 0.12 * np.cos(2 * np.pi * hour / 24.0)
        + rng.normal(0, 0.07, rows),
        0.15,
        0.99,
    )

    windspeed = np.clip(rng.gamma(2.1, 1.9, rows), 0.0, 38.0)

    # Demand. Two commuter peaks on a working day, one broad midday peak otherwise.
    morning_peak = np.exp(-((hour - 8.0) ** 2) / 5.5)
    evening_peak = np.exp(-((hour - 17.5) ** 2) / 7.0)
    leisure_peak = np.exp(-((hour - 14.0) ** 2) / 28.0)

    # A slow upward trend, so a model trained on the first months is measurably
    # worse on the last ones. This is what makes retraining worth doing here.
    trend = 1.0 + 0.25 * (np.arange(rows) / max(rows - 1, 1))

    rate = (
        14.0
        + 105.0 * is_workingday * (morning_peak + 0.95 * evening_peak)
        + 46.0 * (1 - is_workingday) * leisure_peak
        + 2.6 * np.clip(temp_c, -5.0, 30.0)
        # Non-linear, and it bites hardest at the extremes.
        - 130.0 * (humidity - 0.45) ** 2
        - 1.1 * windspeed
        - 9.0 * is_holiday
    ) * trend

    if drift_fraction > 0:
        # Shift the tail: warmer, wetter, and demand no longer follows the same
        # relationship. This is what the drift exporter should detect, and what a
        # retrain should fix.
        cut = int(rows * (1 - drift_fraction))
        temp_c[cut:] += 6.5
        humidity[cut:] = np.clip(humidity[cut:] + 0.14, 0.15, 0.99)
        rate[cut:] *= 0.76

    rentals = rng.poisson(np.clip(rate, 1.0, None))

    frame = pd.DataFrame(
        {
            "timestamp": [timestamp.isoformat() for timestamp in timestamps],
            "hour": hour,
            "dayofweek": dayofweek,
            "month": month,
            "is_holiday": is_holiday,
            "is_workingday": is_workingday,
            "temp_c": np.round(temp_c, 2),
            "humidity": np.round(humidity, 4),
            "windspeed": np.round(windspeed, 3),
            TARGET_NAME: rentals,
        }
    )

    # Fail here rather than in the pipeline. A generator that drifts away from the
    # contract produces a dataset that fails validation, and finding that out in
    # the training job wastes a job.
    missing = [name for name in FEATURE_NAMES if name not in frame.columns]
    if missing:
        raise AssertionError(
            f"the generator does not produce {missing}, which the contract requires"
        )

    return frame


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=20_000, help="hours of data to generate")
    parser.add_argument("--seed", type=int, default=20260912)
    parser.add_argument("--output", type=Path, default=Path("data/sample.csv"))
    parser.add_argument(
        "--start",
        default="2024-01-01T00:00:00+00:00",
        help="ISO timestamp of the first row",
    )
    parser.add_argument(
        "--drift",
        type=float,
        default=0.0,
        metavar="FRACTION",
        help=(
            "shift the distribution of the last FRACTION of rows, so the drift "
            "exporter has something real to detect. Try 0.15."
        ),
    )
    arguments = parser.parse_args()

    if arguments.rows < 2000:
        parser.error("at least 2000 rows: the pipeline's data contract rejects less")
    if not 0.0 <= arguments.drift < 0.5:
        parser.error("--drift must be between 0.0 and 0.5")

    start = datetime.fromisoformat(arguments.start)
    if start.tzinfo is None:
        start = start.replace(tzinfo=UTC)

    frame = generate(arguments.rows, arguments.seed, start, arguments.drift)

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(arguments.output, index=False)

    print(f"wrote {len(frame)} rows to {arguments.output}")
    print(f"  period:  {frame['timestamp'].iloc[0]} to {frame['timestamp'].iloc[-1]}")
    print(f"  target:  mean {frame[TARGET_NAME].mean():.1f}, max {frame[TARGET_NAME].max()}")
    print(f"  zeros:   {(frame[TARGET_NAME] == 0).sum()} hours with no demand")
    if arguments.drift:
        print(f"  drift:   the last {arguments.drift:.0%} of rows are shifted")
    print()
    print("This is synthetic data for proving the pipeline works. Point DATA_URI at")
    print("real data before drawing any conclusion from a metric.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
