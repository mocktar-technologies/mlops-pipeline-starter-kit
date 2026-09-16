"""Training and ONNX export.

The run produces four things, in this order, and the order is deliberate:

  1. A trained checkpoint, selected by validation loss rather than by the last
     epoch. Taking the last epoch means shipping whatever the model looked like
     when the loop happened to stop.
  2. An ONNX artifact exported from that checkpoint.
  3. A parity check between PyTorch and ONNX Runtime on held-out rows. This is
     the step most pipelines skip and it is the one that catches a broken export.
     An export can succeed and still produce a graph that disagrees with the
     model you trained, because an unsupported op was silently approximated or a
     buffer was folded to the wrong constant. Every metric you measured belongs
     to the PyTorch model; the thing you deploy is the graph.
  4. Test-set metrics computed through the ONNX graph, not through PyTorch, so
     the numbers the promotion gate reads describe the artifact that will serve
     traffic.

Nothing here promotes anything. Training produces a candidate; src/pipelines/gate.py
decides whether it is better than the champion, and registry.py moves the alias.
Keeping those apart is what lets a retrain run on a schedule without a human and
still not be able to put a worse model in front of customers.
"""

from __future__ import annotations

import json
import logging
import os
import random
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from torch.utils.data import DataLoader, TensorDataset

from contract.features import FEATURE_NAMES, N_FEATURES
from pipelines import metrics as metric_functions
from pipelines.config import PipelineConfig
from pipelines.data import Dataset, load_dataset
from pipelines.net import DemandForecastNet, build_loss

logger = logging.getLogger(__name__)

# Opset 17 is the floor that the exported graph needs and is supported by every
# ONNX Runtime 1.16 and later. Pinning it rather than letting torch choose means
# a PyTorch upgrade cannot silently change the artifact format.
ONNX_OPSET = 17

# Maximum absolute disagreement tolerated between PyTorch and ONNX Runtime on the
# same input. Float32 arithmetic reordered by graph optimisation produces a
# difference on the order of 1e-5 for predictions in the hundreds; anything
# larger is a broken export, not rounding.
PARITY_TOLERANCE = 1e-3


@dataclass(frozen=True)
class TrainingResult:
    onnx_path: Path
    checkpoint_path: Path
    best_epoch: int
    best_validation_loss: float
    test_metrics: dict[str, float]
    noise_floor: float
    parity_max_abs_diff: float
    row_count: int
    feature_names: list[str]


def _seed_everything(seed: int) -> None:
    """Make a run reproducible enough to compare two of them.

    Seeding three generators is not the whole story: cudnn autotuning and
    non-deterministic kernels can still shift the result. Setting
    use_deterministic_algorithms makes that visible as an error instead of as an
    unexplained metric change between two runs of the same commit.
    """
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
        torch.backends.cudnn.benchmark = False
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    try:
        torch.use_deterministic_algorithms(True, warn_only=True)
    except (AttributeError, RuntimeError):  # pragma: no cover - older torch builds
        logger.warning("this torch build cannot enforce deterministic algorithms")


def _pick_device() -> torch.device:
    if torch.cuda.is_available():
        logger.info("training on cuda: %s", torch.cuda.get_device_name(0))
        return torch.device("cuda")
    logger.info("training on cpu")
    return torch.device("cpu")


def _loader(features: np.ndarray, target: np.ndarray, batch_size: int, shuffle: bool) -> DataLoader:
    dataset = TensorDataset(torch.from_numpy(features), torch.from_numpy(target))
    return DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=shuffle,
        # drop_last only while training. Dropping a partial batch during
        # evaluation would quietly change which rows the reported metric covers.
        drop_last=shuffle,
        num_workers=0,
    )


def _predict_with_torch(
    model: DemandForecastNet, features: np.ndarray, device: torch.device
) -> np.ndarray:
    model.eval()
    with torch.no_grad():
        tensor = torch.from_numpy(features).to(device)
        return model(tensor).cpu().numpy().astype(np.float64)


def _predict_with_onnx(session: ort.InferenceSession, features: np.ndarray) -> np.ndarray:
    input_name = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name
    raw = session.run([output_name], {input_name: features.astype(np.float32)})[0]
    return np.asarray(raw, dtype=np.float64).reshape(features.shape[0], -1)[:, 0]


def export_onnx(model: DemandForecastNet, destination: Path) -> None:
    """Export the model with a dynamic batch axis.

    The dynamic axis is what allows one artifact to serve a single online request
    and a ten-thousand-row batch transform. Exporting with a fixed batch of 1
    produces a graph that raises on every batch call, and the failure appears
    only when a batch job runs, typically at night.
    """
    model.eval()
    example = torch.zeros((2, N_FEATURES), dtype=torch.float32)
    destination.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        model,
        (example,),
        str(destination),
        input_names=["features"],
        output_names=["predicted_rentals"],
        # dynamic_shapes, not the older dynamic_axes. From torch 2.6 the default
        # exporter is the dynamo one, and it deprecates dynamic_axes in favour of
        # this form. Dim.AUTO lets the exporter infer the constraint on axis 0
        # rather than making us assert a minimum batch size that the example
        # tensor then has to satisfy.
        dynamic_shapes={"features": {0: torch.export.Dim.AUTO}},
        opset_version=ONNX_OPSET,
        dynamo=True,
    )


def train(
    config: PipelineConfig, output_dir: Path, dataset: Dataset | None = None
) -> TrainingResult:
    """Run one training job end to end and return everything the gate needs."""
    config.validate()
    _seed_everything(config.training.seed)
    device = _pick_device()

    data = dataset if dataset is not None else load_dataset(config.data)

    model = DemandForecastNet(
        feature_mean=torch.from_numpy(data.feature_mean),
        feature_std=torch.from_numpy(data.feature_std),
        hidden_sizes=tuple(config.model.hidden_sizes),
        dropout=config.model.dropout,
    ).to(device)

    loss_function = build_loss(config.model.loss)
    optimizer = torch.optim.AdamW(
        model.parameters(),
        lr=config.training.learning_rate,
        weight_decay=config.training.weight_decay,
    )

    train_loader = _loader(
        data.train.features, data.train.target, config.training.batch_size, shuffle=True
    )
    validation_features = torch.from_numpy(data.validation.features).to(device)
    validation_target = torch.from_numpy(data.validation.target).to(device)

    output_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_path = output_dir / "model.pt"

    best_loss = float("inf")
    best_epoch = -1
    epochs_without_improvement = 0

    for epoch in range(1, config.training.epochs + 1):
        model.train()
        running = 0.0
        batches = 0
        for features, target in train_loader:
            features = features.to(device)
            target = target.to(device)
            optimizer.zero_grad(set_to_none=True)
            # The loss consumes log(rate) directly. Passing model(features),
            # which is already exponentiated, would apply exp twice.
            loss = loss_function(model.log_rate(features), target)
            loss.backward()
            # Poisson NLL on a count target produces occasional large gradients
            # when a rare very busy hour appears in a batch. Clipping keeps one
            # outlier from undoing an epoch of progress.
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()
            running += float(loss.detach())
            batches += 1

        model.eval()
        with torch.no_grad():
            validation_loss = float(
                loss_function(model.log_rate(validation_features), validation_target)
            )

        if validation_loss < best_loss - 1e-6:
            best_loss = validation_loss
            best_epoch = epoch
            epochs_without_improvement = 0
            # Save on improvement, so the file on disk is always the best model
            # seen and a crashed run still leaves a usable checkpoint.
            torch.save(
                {
                    "state_dict": model.state_dict(),
                    "feature_names": list(FEATURE_NAMES),
                    "hidden_sizes": list(config.model.hidden_sizes),
                    "dropout": config.model.dropout,
                    "epoch": epoch,
                    "validation_loss": validation_loss,
                },
                checkpoint_path,
            )
        else:
            epochs_without_improvement += 1

        if epoch == 1 or epoch % 5 == 0 or epochs_without_improvement == 0:
            logger.info(
                "epoch %3d train_loss=%.4f validation_loss=%.4f best=%.4f@%d",
                epoch,
                running / max(batches, 1),
                validation_loss,
                best_loss,
                best_epoch,
            )

        if epochs_without_improvement >= config.training.early_stopping_patience:
            logger.info(
                "early stop at epoch %d, no improvement for %d epochs",
                epoch,
                epochs_without_improvement,
            )
            break

    if best_epoch < 0:
        raise RuntimeError(
            "validation loss never improved, so there is no checkpoint to export. "
            "This normally means the learning rate is too high or the target column "
            "is not what the contract expects."
        )

    # Reload the best checkpoint. Without this the exported graph is whatever
    # epoch the loop ended on, which is not the model the metrics describe.
    model.load_state_dict(torch.load(checkpoint_path, map_location=device)["state_dict"])
    model.eval()

    onnx_path = output_dir / "model.onnx"
    export_onnx(model, onnx_path)

    # ---- parity check ------------------------------------------------------
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    sample = data.test.features[: min(512, len(data.test))]
    torch_predictions = _predict_with_torch(model, sample, device)
    onnx_predictions = _predict_with_onnx(session, sample)
    parity = float(np.max(np.abs(torch_predictions - onnx_predictions)))
    if parity > PARITY_TOLERANCE:
        raise RuntimeError(
            f"the exported ONNX graph disagrees with the trained model by {parity:.6f}, "
            f"above the tolerance of {PARITY_TOLERANCE}. Do not register this artifact: "
            "the measured metrics describe the PyTorch model and not the graph that "
            "would serve traffic."
        )
    logger.info("onnx parity check passed, max abs diff %.2e", parity)

    # ---- test metrics, measured through the artifact -----------------------
    test_predictions = _predict_with_onnx(session, data.test.features)
    test_metrics = metric_functions.evaluate(data.test.target, test_predictions)
    if test_metrics["negative_predictions"] > 0:
        raise RuntimeError(
            "the exported graph produced a negative rental count, which the serving "
            "contract treats as impossible. Check that the final exp() survived export."
        )

    noise_floor = metric_functions.bootstrap_std(
        data.test.target,
        test_predictions,
        metric=config.gate.metric,
        samples=config.gate.bootstrap_samples,
    )

    (output_dir / "metrics.json").write_text(
        json.dumps(
            {
                "test": test_metrics,
                "noise_floor": noise_floor,
                "best_epoch": best_epoch,
                "best_validation_loss": best_loss,
                "parity_max_abs_diff": parity,
                "rows": data.row_count,
                "source_uri": data.source_uri,
                "config": {
                    "model": asdict(config.model),
                    "training": asdict(config.training),
                    "gate": asdict(config.gate),
                },
            },
            indent=2,
            sort_keys=True,
        ),
        encoding="utf-8",
    )

    logger.info(
        "test %s=%.3f (noise floor %.3f) rmse=%.3f smape=%.2f%%",
        config.gate.metric,
        test_metrics[config.gate.metric],
        noise_floor,
        test_metrics["rmse"],
        test_metrics["smape"],
    )

    return TrainingResult(
        onnx_path=onnx_path,
        checkpoint_path=checkpoint_path,
        best_epoch=best_epoch,
        best_validation_loss=best_loss,
        test_metrics=test_metrics,
        noise_floor=noise_floor,
        parity_max_abs_diff=parity,
        row_count=data.row_count,
        feature_names=list(FEATURE_NAMES),
    )


def train_to_temp(config: PipelineConfig) -> TrainingResult:
    """Convenience wrapper used by tests; writes into a temporary directory."""
    return train(config, Path(tempfile.mkdtemp(prefix="train-")))
