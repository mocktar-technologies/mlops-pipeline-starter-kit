"""Dataset loading, validation and splitting.

The data contract is enforced here, on the way in, and it is the same contract
the serving API validates against. That is the point: if the training data can
contain a humidity of 4.0 but the API rejects it, the model has learned from a
distribution it will never see, and nothing in the pipeline would tell you.

Two decisions in this file are worth arguing about, so they are stated plainly:

  The split is chronological. Row order is time order, and the first 70 percent
  becomes training, the next 15 percent validation, the last 15 percent test. A
  random split on a time series lets the model see the future, which raises every
  reported metric and cannot be detected by looking at those metrics.

  Scaling statistics are computed on the training split only. Computing them
  over the whole dataset leaks information from the test set into the model. The
  effect is small and it is still leakage: the test score stops being an
  estimate of production performance, which is the only thing it was for.
"""

from __future__ import annotations

import io
import logging
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import numpy as np
import pandas as pd

from contract.features import (
    FEATURE_BOUNDS,
    FEATURE_NAMES,
    TARGET_NAME,
    assert_contract_intact,
)
from pipelines.config import DataConfig

logger = logging.getLogger(__name__)

REQUIRED_COLUMNS = (*FEATURE_NAMES, TARGET_NAME)


class DataContractError(ValueError):
    """Raised when the dataset does not satisfy the contract."""


@dataclass(frozen=True)
class Split:
    """One chronological slice of the dataset."""

    name: str
    features: np.ndarray  # (rows, n_features) float32, contract order
    target: np.ndarray  # (rows,) float32

    def __len__(self) -> int:
        return int(self.features.shape[0])


@dataclass(frozen=True)
class Dataset:
    train: Split
    validation: Split
    test: Split
    # Mean and standard deviation per feature, from the training split only.
    # Carried here so train, export and drift all use the same numbers.
    feature_mean: np.ndarray
    feature_std: np.ndarray
    row_count: int
    source_uri: str


def _read_csv(uri: str) -> pd.DataFrame:
    """Read a CSV from a local path or an s3:// URI."""
    parsed = urlparse(uri)
    if parsed.scheme in ("", "file"):
        path = Path(parsed.path if parsed.scheme == "file" else uri)
        if not path.is_file():
            raise FileNotFoundError(f"no dataset at {path}")
        return pd.read_csv(path)

    if parsed.scheme == "s3":
        # boto3 rather than a pandas s3 extra, so the only AWS dependency in the
        # training image is the SDK the rest of the pipeline already uses.
        import boto3

        bucket = parsed.netloc
        key = parsed.path.lstrip("/")
        logger.info("reading s3://%s/%s", bucket, key)
        body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
        return pd.read_csv(io.BytesIO(body))

    raise ValueError(f"unsupported scheme {parsed.scheme!r} in DATA_URI {uri!r}")


def validate_frame(frame: pd.DataFrame, min_rows: int) -> None:
    """Enforce the data contract. Raises DataContractError on any violation.

    This runs before training, and a failure here fails the pipeline. A training
    run on data that violates its own contract produces a model that cannot be
    served, so there is nothing to gain by continuing.
    """
    assert_contract_intact()

    missing = [column for column in REQUIRED_COLUMNS if column not in frame.columns]
    if missing:
        raise DataContractError(
            f"dataset is missing required column(s) {missing}. "
            f"Expected {list(REQUIRED_COLUMNS)}, found {list(frame.columns)}."
        )

    if len(frame) < min_rows:
        raise DataContractError(
            f"dataset has {len(frame)} rows, below the configured minimum of {min_rows}. "
            "A short dataset usually means a truncated upstream export rather than a "
            "genuinely small dataset, so this fails rather than training on it."
        )

    null_counts = frame[list(REQUIRED_COLUMNS)].isna().sum()
    populated = null_counts[null_counts > 0]
    if not populated.empty:
        raise DataContractError(
            f"null values are not accepted in the contract columns: {populated.to_dict()}"
        )

    for name, (low, high) in FEATURE_BOUNDS.items():
        column = frame[name]
        out_of_range = int(((column < low) | (column > high)).sum())
        if out_of_range:
            raise DataContractError(
                f"{out_of_range} row(s) have {name} outside [{low}, {high}] "
                f"(observed min {column.min()}, max {column.max()}). The serving API "
                f"rejects these values, so a model trained on them would be scored on "
                f"a distribution it will never see in production."
            )

    target = frame[TARGET_NAME]
    if (target < 0).any():
        raise DataContractError(
            f"{int((target < 0).sum())} row(s) have a negative {TARGET_NAME}. "
            "The target is a count."
        )
    if target.std() == 0:
        raise DataContractError(
            f"{TARGET_NAME} has zero variance, so there is nothing to learn. "
            "This is normally a broken join upstream."
        )


def _slice(frame: pd.DataFrame, name: str, start: int, stop: int) -> Split:
    window = frame.iloc[start:stop]
    return Split(
        name=name,
        features=window[list(FEATURE_NAMES)].to_numpy(dtype=np.float32, copy=True),
        target=window[TARGET_NAME].to_numpy(dtype=np.float32, copy=True),
    )


def load_dataset(config: DataConfig) -> Dataset:
    """Read, validate and chronologically split the dataset."""
    frame = _read_csv(config.uri)
    validate_frame(frame, config.min_rows)

    total = len(frame)
    train_end = int(total * config.train_fraction)
    validation_end = train_end + int(total * config.validation_fraction)

    train = _slice(frame, "train", 0, train_end)
    validation = _slice(frame, "validation", train_end, validation_end)
    test = _slice(frame, "test", validation_end, total)

    for split in (train, validation, test):
        if len(split) == 0:
            raise DataContractError(
                f"the {split.name} split is empty after applying the configured "
                f"fractions to {total} rows"
            )

    mean = train.features.mean(axis=0)
    std = train.features.std(axis=0)
    # A constant feature has zero standard deviation. Dividing by it produces
    # infinities that propagate into the exported graph, so it is floored. The
    # feature is then simply centred and contributes nothing, which is the
    # correct outcome for a column with no variation.
    zero_variance = std < 1e-8
    if zero_variance.any():
        constant = [FEATURE_NAMES[i] for i in np.flatnonzero(zero_variance)]
        logger.warning(
            "feature(s) %s are constant in the training split and carry no signal",
            constant,
        )
    std = np.where(zero_variance, 1.0, std)

    logger.info(
        "loaded %d rows from %s: train=%d validation=%d test=%d",
        total,
        config.uri,
        len(train),
        len(validation),
        len(test),
    )

    return Dataset(
        train=train,
        validation=validation,
        test=test,
        feature_mean=mean.astype(np.float32),
        feature_std=std.astype(np.float32),
        row_count=total,
        source_uri=config.uri,
    )
