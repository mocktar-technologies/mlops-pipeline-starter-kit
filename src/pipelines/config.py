"""Pipeline configuration.

Everything that decides what a training run produces lives in one YAML file that
is committed to git: the split boundaries, the hyperparameters, the gate
thresholds. A run is then identified by a commit and a config, which is what
makes it reproducible. Anything that varies per environment (bucket names,
tracking URI, credentials) comes from the environment instead, because those are
not part of the experiment.

Read that distinction the other way round and you get the two classic failures:
hyperparameters passed as environment variables, so nobody can say afterwards
what produced a model; and bucket names committed to git, so the pipeline only
runs in the account it was written in.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass(frozen=True)
class DataConfig:
    # A local path or an s3:// URI. Left to the environment because it differs
    # per account; the schema it must satisfy does not and is asserted in data.py.
    uri: str
    # Fractions of the time-ordered rows. The split is chronological, never
    # random: shuffling a time series lets the model train on the future and
    # score itself on the past, which inflates every metric and cannot be
    # detected from the metrics alone.
    train_fraction: float = 0.70
    validation_fraction: float = 0.15
    # The remainder is the test set, untouched until the gate runs.
    min_rows: int = 2_000


@dataclass(frozen=True)
class ModelConfig:
    hidden_sizes: tuple[int, ...] = (64, 32)
    dropout: float = 0.10
    # Poisson regression on a log link. The head predicts log(rate) and the
    # graph exponentiates it, which makes a negative prediction structurally
    # impossible rather than something you clamp afterwards. For a target that
    # is a count, this is both more accurate and safer than squared error.
    loss: str = "poisson_nll"


@dataclass(frozen=True)
class TrainingConfig:
    epochs: int = 60
    batch_size: int = 256
    learning_rate: float = 1e-3
    weight_decay: float = 1e-4
    # Stop when validation loss has not improved for this many epochs. Keeps a
    # scheduled retrain from burning GPU hours on a run that converged in
    # epoch 12.
    early_stopping_patience: int = 8
    seed: int = 1337


@dataclass(frozen=True)
class GateConfig:
    """The promotion gate.

    A challenger is promoted only if it beats the champion by more than the
    measured noise in the metric. Comparing raw point estimates promotes noise
    roughly half the time, which is how a registry fills up with versions that
    are not improvements.
    """

    metric: str = "mae"
    # Bootstrap resamples of the test set used to estimate how much the metric
    # moves for reasons unrelated to the model.
    bootstrap_samples: int = 400
    # The challenger must beat the champion by more than this multiple of the
    # bootstrap standard deviation.
    noise_multiplier: float = 2.0
    # And by at least this absolute amount, so a very stable metric does not
    # let a rounding-level difference through.
    min_absolute_improvement: float = 0.5
    # An absolute ceiling. A model worse than this is rejected even if there is
    # no champion to compare it against, which is what stops the very first
    # broken run from becoming the baseline everything else is measured on.
    max_acceptable_mae: float = 120.0


@dataclass(frozen=True)
class DriftConfig:
    # Population stability index thresholds. These two values are the
    # conventional reading of PSI and are documented as such in the runbook:
    # below 0.10 no meaningful change, 0.10 to 0.25 worth investigating, above
    # 0.25 a material shift. They are a heuristic, not a statistical test.
    warn_threshold: float = 0.10
    alert_threshold: float = 0.25
    bins: int = 10
    # How often the exporter recomputes. Every recompute reads the recent window
    # from S3, so this is a cost knob as well as a freshness knob.
    interval_seconds: int = 900
    # Rows of recent traffic compared against the training reference.
    window_rows: int = 20_000


@dataclass(frozen=True)
class PipelineConfig:
    model_name: str
    data: DataConfig
    model: ModelConfig = field(default_factory=ModelConfig)
    training: TrainingConfig = field(default_factory=TrainingConfig)
    gate: GateConfig = field(default_factory=GateConfig)
    drift: DriftConfig = field(default_factory=DriftConfig)

    @property
    def test_fraction(self) -> float:
        return 1.0 - self.data.train_fraction - self.data.validation_fraction

    def validate(self) -> None:
        total = self.data.train_fraction + self.data.validation_fraction
        if not 0.0 < total < 1.0:
            raise ValueError(
                f"train_fraction + validation_fraction must leave room for a test "
                f"split, got {total}"
            )
        if self.test_fraction < 0.05:
            raise ValueError(
                f"the test split is only {self.test_fraction:.1%} of the data, which is "
                "too small to gate a promotion on"
            )
        if self.model.loss != "poisson_nll":
            raise ValueError(
                f"loss {self.model.loss!r} is not implemented. The serving contract "
                "assumes a non-negative count prediction; changing the loss means "
                "revisiting src/serving/model.py."
            )
        if self.gate.noise_multiplier <= 0:
            raise ValueError("gate.noise_multiplier must be positive")


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(
            f"{name} is not set. Environment-specific values are not committed to "
            "the config file; see .env.example and the README."
        )
    return value


def load_config(path: str | Path) -> PipelineConfig:
    """Load pipelines/config.yaml and overlay the environment."""
    raw: dict[str, Any] = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}

    data_block = dict(raw.get("data") or {})
    # DATA_URI in the environment always wins, so the same committed config runs
    # against a sample file locally and the real dataset in the cluster.
    data_block["uri"] = os.environ.get("DATA_URI", "").strip() or data_block.get("uri", "")
    if not data_block["uri"]:
        raise RuntimeError("no dataset location. Set DATA_URI, or set data.uri in the config file.")

    config = PipelineConfig(
        model_name=raw.get("model_name") or "demand-forecast",
        data=DataConfig(**data_block),
        model=ModelConfig(**(raw.get("model") or {})),
        training=TrainingConfig(**(raw.get("training") or {})),
        gate=GateConfig(**(raw.get("gate") or {})),
        drift=DriftConfig(**(raw.get("drift") or {})),
    )
    config.validate()
    return config


@dataclass(frozen=True)
class RuntimeEnv:
    """Environment-supplied locations and identities for a pipeline run."""

    tracking_uri: str
    artifact_bucket: str
    aws_region: str
    git_sha: str

    @staticmethod
    def from_environment() -> RuntimeEnv:
        return RuntimeEnv(
            tracking_uri=_require_env("MLFLOW_TRACKING_URI"),
            artifact_bucket=_require_env("ARTIFACT_BUCKET"),
            aws_region=os.environ.get("AWS_REGION", "us-east-1"),
            git_sha=os.environ.get("GIT_SHA", "unknown"),
        )
