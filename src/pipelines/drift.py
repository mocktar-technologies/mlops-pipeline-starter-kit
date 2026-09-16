"""Drift monitoring as a Prometheus exporter.

Why a long-running exporter and not a CronJob: Prometheus scrapes, and a pod that
exits cannot be scraped. A CronJob that computes a drift score and exits leaves
the value nowhere Prometheus can see it, which is why teams reach for a
Pushgateway and then inherit its staleness problems. A small always-on Deployment
that recomputes on a timer and holds the current value in a gauge fits the
scrape model directly, and its own last-success timestamp becomes the signal that
tells you when the monitor itself has stopped working.

That last point is the one that gets skipped. A drift gauge stuck at a healthy
0.03 because the exporter has been failing for three days looks exactly like a
healthy system. model_drift_last_success_timestamp_seconds is what turns that
into an alert, and the DriftMonitorStale rule in the Helm chart fires on it.

What is compared: the training reference sample, written to S3 by the training
pipeline, against a recent window of production inference inputs. Both are read
from S3 rather than from the serving pods, so the exporter needs no access to
live traffic and can be restarted freely.
"""

from __future__ import annotations

import logging
import signal
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from types import FrameType
from urllib.parse import urlparse

import numpy as np
import pandas as pd
from prometheus_client import CollectorRegistry, Counter, Gauge, start_http_server

from contract.features import DRIFT_FEATURES
from pipelines.config import DriftConfig
from pipelines.metrics import population_stability_index

logger = logging.getLogger(__name__)

REGISTRY = CollectorRegistry()

# Objects read from the capture prefix per cycle. The exporter runs every fifteen
# minutes, so an unbounded list turns a monitoring job into a significant S3 bill.
# The window_rows setting then trims the concatenated frame to the configured size.
_MAX_OBJECTS_PER_CYCLE = 200

DRIFT_PSI = Gauge(
    "model_drift_psi",
    "Population stability index per feature, reference against the recent window.",
    labelnames=("feature",),
    registry=REGISTRY,
)

DRIFT_PSI_MAX = Gauge(
    "model_drift_psi_max",
    "Highest per-feature PSI in the last successful run. Alert on this one.",
    registry=REGISTRY,
)

REFERENCE_ROWS = Gauge(
    "model_drift_reference_rows",
    "Rows in the training reference sample.",
    registry=REGISTRY,
)

WINDOW_ROWS = Gauge(
    "model_drift_window_rows",
    "Rows in the recent production window compared against the reference.",
    registry=REGISTRY,
)

LAST_SUCCESS = Gauge(
    "model_drift_last_success_timestamp_seconds",
    "Unix timestamp of the last successful drift computation.",
    registry=REGISTRY,
)

RUN_DURATION = Gauge(
    "model_drift_run_duration_seconds",
    "Duration of the last drift computation.",
    registry=REGISTRY,
)

FAILURES = Counter(
    "model_drift_failures_total",
    "Failed drift computations, by reason.",
    labelnames=("reason",),
    registry=REGISTRY,
)

# Set once at startup so the thresholds a dashboard draws its lines at come from
# the same config the alert rules were rendered from, instead of being retyped
# into the dashboard JSON where they can drift apart.
THRESHOLD = Gauge(
    "model_drift_threshold",
    "Configured PSI thresholds, exposed so dashboards and alerts agree.",
    labelnames=("level",),
    registry=REGISTRY,
)


@dataclass(frozen=True)
class DriftReport:
    per_feature: dict[str, float]
    reference_rows: int
    window_rows: int

    @property
    def worst(self) -> tuple[str, float]:
        if not self.per_feature:
            return ("none", 0.0)
        return max(self.per_feature.items(), key=lambda item: item[1])


def _read_parquet_or_csv(uri: str) -> pd.DataFrame:
    """Read a dataset from a local path or s3:// prefix.

    An s3:// URI that ends in a slash is treated as a prefix and every object
    under it is concatenated, which is the shape the serving pods write inference
    inputs in: one small object per interval.
    """
    parsed = urlparse(uri)

    if parsed.scheme in ("", "file"):
        path = Path(uri if parsed.scheme == "" else parsed.path)
        if not path.is_dir():
            return _read_local_file(path)
        local_frames = [
            _read_local_file(child) for child in sorted(path.iterdir()) if child.is_file()
        ]
        if not local_frames:
            raise FileNotFoundError(f"no files under {path}")
        return pd.concat(local_frames, ignore_index=True)

    if parsed.scheme != "s3":
        raise ValueError(f"unsupported scheme {parsed.scheme!r} in {uri!r}")

    # Imported here rather than at module scope so that the PSI functions and the
    # local-file path stay importable in a test environment with no boto3.
    import boto3

    client = boto3.client("s3")
    bucket = parsed.netloc
    prefix = parsed.path.lstrip("/")

    if not prefix.endswith("/"):
        body = client.get_object(Bucket=bucket, Key=prefix)["Body"].read()
        return _read_bytes(prefix, body)

    # List everything under the prefix, then take the newest objects. Sorting by
    # LastModified rather than by key matters: the serving pods write one object per
    # interval with a timestamped name, and lexical order and time order stop
    # agreeing the moment a naming scheme changes.
    objects: list[dict] = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        objects.extend(page.get("Contents", []))
    objects.sort(key=lambda item: item["LastModified"], reverse=True)

    # A cap on the number of objects read per cycle, because the exporter runs every
    # fifteen minutes and an unbounded list turns a monitoring job into a
    # significant S3 bill.
    remote_frames: list[pd.DataFrame] = []
    for item in objects[:_MAX_OBJECTS_PER_CYCLE]:
        if item["Key"].endswith("/"):
            continue
        body = client.get_object(Bucket=bucket, Key=item["Key"])["Body"].read()
        remote_frames.append(_read_bytes(item["Key"], body))

    if not remote_frames:
        raise FileNotFoundError(f"no objects under s3://{bucket}/{prefix}")
    return pd.concat(remote_frames, ignore_index=True)


def _read_local_file(path: Path) -> pd.DataFrame:
    if path.suffix in (".parquet", ".pq"):
        return pd.read_parquet(path)
    return pd.read_csv(path)


def _read_bytes(key: str, body: bytes) -> pd.DataFrame:
    import io

    if key.endswith((".parquet", ".pq")):
        return pd.read_parquet(io.BytesIO(body))
    return pd.read_csv(io.BytesIO(body))


def compute(reference: pd.DataFrame, window: pd.DataFrame, config: DriftConfig) -> DriftReport:
    """Compute per-feature PSI for the features listed in the contract."""
    per_feature: dict[str, float] = {}
    for feature in DRIFT_FEATURES:
        if feature not in reference.columns:
            raise KeyError(f"the reference sample has no {feature!r} column")
        if feature not in window.columns:
            raise KeyError(f"the production window has no {feature!r} column")
        per_feature[feature] = population_stability_index(
            reference[feature].to_numpy(dtype=np.float64),
            window[feature].to_numpy(dtype=np.float64),
            bins=config.bins,
        )
    return DriftReport(
        per_feature=per_feature,
        reference_rows=len(reference),
        window_rows=len(window),
    )


def run_once(reference_uri: str, window_uri: str, config: DriftConfig) -> DriftReport:
    """One computation cycle, updating every gauge on success."""
    started = time.time()
    reference = _read_parquet_or_csv(reference_uri)
    window = _read_parquet_or_csv(window_uri)

    if len(window) > config.window_rows:
        window = window.tail(config.window_rows)

    # A PSI computed from a handful of rows swings wildly and would page someone
    # for nothing. Reporting a failure reason is more useful than reporting a
    # meaningless number, and the DriftMonitorStale rule will catch it if the
    # condition persists.
    if len(window) < 200:
        FAILURES.labels(reason="window_too_small").inc()
        raise ValueError(
            f"the production window has only {len(window)} rows, too few for a stable PSI"
        )

    report = compute(reference, window, config)

    for feature, value in report.per_feature.items():
        DRIFT_PSI.labels(feature=feature).set(value)
    worst_feature, worst_value = report.worst
    DRIFT_PSI_MAX.set(worst_value)
    REFERENCE_ROWS.set(report.reference_rows)
    WINDOW_ROWS.set(report.window_rows)
    RUN_DURATION.set(time.time() - started)
    LAST_SUCCESS.set(time.time())

    level = (
        "alert"
        if worst_value >= config.alert_threshold
        else "warn" if worst_value >= config.warn_threshold else "ok"
    )
    logger.info(
        "drift %s: worst feature %s psi=%.4f over %d window rows against %d reference rows",
        level,
        worst_feature,
        worst_value,
        report.window_rows,
        report.reference_rows,
    )
    return report


def serve(reference_uri: str, window_uri: str, config: DriftConfig, port: int = 9102) -> int:
    """Run the exporter until SIGTERM.

    The first computation happens before the HTTP server starts serving useful
    values, but the server starts first so the readiness probe has something to
    talk to and a slow first S3 read does not look like a crash.
    """
    THRESHOLD.labels(level="warn").set(config.warn_threshold)
    THRESHOLD.labels(level="alert").set(config.alert_threshold)

    start_http_server(port, registry=REGISTRY)
    logger.info("drift exporter listening on :%d, interval %ds", port, config.interval_seconds)

    stopping = False

    def _handle(signum: int, frame: FrameType | None) -> None:
        nonlocal stopping
        logger.info("received signal %d, finishing the current cycle", signum)
        stopping = True

    signal.signal(signal.SIGTERM, _handle)
    signal.signal(signal.SIGINT, _handle)

    while not stopping:
        try:
            run_once(reference_uri, window_uri, config)
        except FileNotFoundError as exc:
            FAILURES.labels(reason="missing_data").inc()
            logger.error("drift data unavailable: %s", exc)
        except (KeyError, ValueError) as exc:
            FAILURES.labels(reason="bad_data").inc()
            logger.error("drift computation rejected the data: %s", exc)
        except Exception:
            FAILURES.labels(reason="unexpected").inc()
            # Do not exit. An exporter that dies on a transient S3 error takes
            # the signal down with it, and the gauge then reports the last
            # healthy value forever. Staying up keeps the stale-monitor alert
            # able to fire.
            logger.exception("unexpected failure during a drift cycle")

        slept = 0
        while slept < config.interval_seconds and not stopping:
            time.sleep(min(5, config.interval_seconds - slept))
            slept += 5

    logger.info("drift exporter stopped")
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by the container
    import os

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
    sys.exit(
        serve(
            reference_uri=os.environ["DRIFT_REFERENCE_URI"],
            window_uri=os.environ["DRIFT_WINDOW_URI"],
            config=DriftConfig(),
            port=int(os.environ.get("DRIFT_EXPORTER_PORT", "9102")),
        )
    )
