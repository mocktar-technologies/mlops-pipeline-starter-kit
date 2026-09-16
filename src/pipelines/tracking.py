"""MLflow tracking.

Kept in its own module so that train.py has no MLflow import and can run in a
unit test with no tracking server reachable. That separation is worth the extra
file: a training function that cannot be executed without a running server is a
training function nobody writes tests for.

What gets logged, and why each item is there rather than for completeness:

  params      the full config, so a run can be reproduced from the record alone
  metrics     the gate metric plus the ones that explain it
  tags        the git SHA, the dataset URI and the row count, which are the three
              questions asked first when two runs disagree
  artifacts   the ONNX graph as an MLflow model, plus metrics.json

Verified against MLflow 3.16.0: mlflow.onnx.log_model takes `name` (the older
`artifact_path` parameter is deprecated), and model stages are deprecated in
favour of aliases, which is why nothing here calls transition_model_version_stage.
"""

from __future__ import annotations

import logging
from dataclasses import asdict
from pathlib import Path

import mlflow
import numpy as np
import onnx
from mlflow.models import infer_signature

from contract.features import FEATURE_NAMES
from pipelines.config import PipelineConfig, RuntimeEnv
from pipelines.train import ONNX_OPSET, TrainingResult

logger = logging.getLogger(__name__)

# The artifact subdirectory inside the run. registry.py builds
# runs:/<run_id>/<MODEL_ARTIFACT_NAME> from it, so the two must agree.
MODEL_ARTIFACT_NAME = "model"


def configure(env: RuntimeEnv, experiment: str) -> None:
    """Point the client at the tracking server and select the experiment."""
    mlflow.set_tracking_uri(env.tracking_uri)
    mlflow.set_experiment(experiment)
    logger.info("tracking to %s experiment=%s", env.tracking_uri, experiment)


def log_run(
    config: PipelineConfig,
    env: RuntimeEnv,
    result: TrainingResult,
    run_name: str,
    extra_tags: dict[str, str] | None = None,
) -> str:
    """Record a completed training run. Returns the MLflow run id."""
    signature_input = np.zeros((1, len(FEATURE_NAMES)), dtype=np.float32)
    signature_output = np.zeros((1,), dtype=np.float32)

    with mlflow.start_run(run_name=run_name) as run:
        mlflow.log_params(
            {
                # Flattened rather than nested, because MLflow params are a flat
                # string map and a nested dict would be logged as one unreadable
                # blob you cannot filter or sort a run list by.
                **{f"model.{key}": value for key, value in asdict(config.model).items()},
                **{f"training.{key}": value for key, value in asdict(config.training).items()},
                **{f"gate.{key}": value for key, value in asdict(config.gate).items()},
                "data.train_fraction": config.data.train_fraction,
                "data.validation_fraction": config.data.validation_fraction,
                "onnx_opset": ONNX_OPSET,
            }
        )

        mlflow.log_metrics(
            {
                **{f"test_{key}": value for key, value in result.test_metrics.items()},
                "noise_floor": result.noise_floor,
                "best_epoch": float(result.best_epoch),
                "best_validation_loss": result.best_validation_loss,
                "parity_max_abs_diff": result.parity_max_abs_diff,
            }
        )

        mlflow.set_tags(
            {
                "git_sha": env.git_sha,
                "dataset_uri": str(config.data.uri),
                "dataset_rows": str(result.row_count),
                "feature_contract": ",".join(result.feature_names),
                "framework": "pytorch+onnxruntime",
                **(extra_tags or {}),
            }
        )

        # infer_signature records the input and output schema in the MLmodel
        # file. A consumer can then read the expected shape without opening the
        # graph, and MLflow refuses a serving request whose schema disagrees.
        mlflow.onnx.log_model(
            onnx.load(str(result.onnx_path)),
            name=MODEL_ARTIFACT_NAME,
            signature=infer_signature(signature_input, signature_output),
            input_example=signature_input,
        )

        metrics_file = result.onnx_path.parent / "metrics.json"
        if metrics_file.is_file():
            mlflow.log_artifact(str(metrics_file), artifact_path="evaluation")

        logger.info("logged run %s", run.info.run_id)
        return run.info.run_id


def model_uri_for_run(run_id: str) -> str:
    """The model URI that registry.py registers."""
    return f"runs:/{run_id}/{MODEL_ARTIFACT_NAME}"


def download_champion_onnx(model_name: str, alias: str, destination: Path) -> Path | None:
    """Fetch the ONNX file behind an alias, or None if the alias does not exist.

    Used by the gate to score the current champion on the same test split as the
    challenger. Comparing a fresh challenger metric against a metric recorded
    months ago on a different split is the most common way a gate reaches the
    wrong conclusion: the two numbers are not measurements of the same thing.
    """
    from mlflow import MlflowClient
    from mlflow.exceptions import MlflowException

    client = MlflowClient()
    try:
        version = client.get_model_version_by_alias(model_name, alias)
    except MlflowException as exc:
        logger.info("no %r alias on %s (%s)", alias, model_name, exc.message)
        return None

    destination.mkdir(parents=True, exist_ok=True)
    local_root = Path(
        mlflow.artifacts.download_artifacts(artifact_uri=version.source, dst_path=str(destination))
    )
    candidates = sorted(local_root.rglob("*.onnx"))
    if not candidates:
        logger.warning(
            "the %s@%s artifact contains no .onnx file under %s", model_name, alias, local_root
        )
        return None
    logger.info("downloaded champion %s version %s", model_name, version.version)
    return candidates[0]
