"""The model.

A small multilayer perceptron with a Poisson head. Three properties of this
definition matter more than its accuracy, because they are what make it safe to
operate:

  Scaling is inside the graph. The training split's mean and standard deviation
  are registered as buffers, so they are saved with the checkpoint and exported
  into the ONNX file. The serving container therefore needs one artifact and no
  scaler, and it is impossible for serving to scale differently from training.
  Shipping a separate preprocessing artifact is the most common source of
  training-serving skew in production ML, and this removes the possibility.

  The output is exp(linear), so a prediction is strictly positive. The target is
  a count of bikes; a model that can return a negative count is wrong in a way
  no threshold can fix. Squared-error regression on a count does exactly that,
  routinely, for low-demand hours.

  Nothing in forward() depends on the batch size, so the ONNX export has a
  genuinely dynamic batch axis and one artifact serves both a single online
  request and a large batch transform.
"""

from __future__ import annotations

import torch
from torch import nn

from contract.features import N_FEATURES


class DemandForecastNet(nn.Module):
    """Predicts an expected rental count from the eight contract features."""

    # Declared, because register_buffer gives a type checker no way to know that
    # self.feature_mean is a Tensor rather than a Module, and every arithmetic use
    # of it below is then flagged. These annotations are the documented way to tell
    # it, and they also state the shape contract for a reader.
    feature_mean: torch.Tensor
    feature_std: torch.Tensor

    def __init__(
        self,
        feature_mean: torch.Tensor,
        feature_std: torch.Tensor,
        hidden_sizes: tuple[int, ...] = (64, 32),
        dropout: float = 0.1,
    ) -> None:
        super().__init__()

        if feature_mean.numel() != N_FEATURES or feature_std.numel() != N_FEATURES:
            raise ValueError(
                f"scaling statistics must have {N_FEATURES} entries, got "
                f"{feature_mean.numel()} and {feature_std.numel()}"
            )
        if torch.any(feature_std <= 0):
            raise ValueError("feature_std contains a non-positive value")

        # register_buffer, not a plain attribute: buffers move with .to(device),
        # are saved in state_dict, and are captured by torch.onnx.export.
        self.register_buffer("feature_mean", feature_mean.reshape(1, -1).float())
        self.register_buffer("feature_std", feature_std.reshape(1, -1).float())

        layers: list[nn.Module] = []
        in_features = N_FEATURES
        for width in hidden_sizes:
            layers.append(nn.Linear(in_features, width))
            layers.append(nn.ReLU())
            if dropout > 0:
                layers.append(nn.Dropout(dropout))
            in_features = width
        self.body = nn.Sequential(*layers)

        # Predicts log(rate). Initialising the bias at zero means the model
        # starts by predicting a rate of 1 rather than a rate of exp(large),
        # which keeps the first few Poisson loss values finite.
        self.head = nn.Linear(in_features, 1)
        nn.init.zeros_(self.head.bias)
        nn.init.xavier_uniform_(self.head.weight, gain=0.1)

    def log_rate(self, features: torch.Tensor) -> torch.Tensor:
        """Return log(expected count). This is what the loss consumes."""
        scaled = (features - self.feature_mean) / self.feature_std
        return self.head(self.body(scaled)).squeeze(-1)

    def forward(self, features: torch.Tensor) -> torch.Tensor:
        """Return the expected count. This is what gets exported and served.

        clamp before exp bounds the graph against an overflow to infinity if the
        model is fed input far outside the training range. exp(30) is about 1e13,
        which is already absurd for a bike count but is still a finite float32
        and will serialize to JSON instead of crashing the response.
        """
        return torch.exp(torch.clamp(self.log_rate(features), min=-20.0, max=30.0))


def build_loss(name: str) -> nn.Module:
    """Return the configured loss, which consumes log(rate) directly.

    log_input=True means PyTorch applies exp internally in a numerically stable
    way, so the training path never materialises exp(log_rate) and cannot
    overflow. full=False drops the Stirling term, which is a constant with
    respect to the parameters and therefore changes the reported loss value but
    not a single gradient.
    """
    if name != "poisson_nll":
        raise ValueError(f"unsupported loss {name!r}")
    return nn.PoissonNLLLoss(log_input=True, full=False, reduction="mean")
