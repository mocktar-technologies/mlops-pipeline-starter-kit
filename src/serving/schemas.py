"""Request and response models for the inference API.

Validation happens here, at the edge, before a single float reaches the model.
Two reasons that matters more for a model than for an ordinary service:

  1. An ONNX graph will happily consume nonsense. Feed it a humidity of 400 and
     it returns a number with no error and no warning. The only place that can
     be caught is the boundary.

  2. Out-of-range input is the earliest signal that the upstream data pipeline
     has changed. Counting rejections by reason turns a silent data-quality
     regression into an alertable metric.

The field bounds come from contract.features.FEATURE_BOUNDS so that the API, the
training data contract and the drift monitor cannot disagree.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from contract.features import FEATURE_BOUNDS, FEATURE_NAMES

_B = FEATURE_BOUNDS


class Observation(BaseModel):
    """One row of model input.

    extra="forbid" is deliberate. Silently ignoring an unknown field is how a
    caller ends up believing it is sending a feature the model never sees.
    """

    model_config = ConfigDict(extra="forbid")

    hour: Annotated[int, Field(ge=int(_B["hour"][0]), le=int(_B["hour"][1]))]
    dayofweek: Annotated[int, Field(ge=int(_B["dayofweek"][0]), le=int(_B["dayofweek"][1]))]
    month: Annotated[int, Field(ge=int(_B["month"][0]), le=int(_B["month"][1]))]
    is_holiday: Annotated[int, Field(ge=0, le=1)]
    is_workingday: Annotated[int, Field(ge=0, le=1)]
    temp_c: Annotated[float, Field(ge=_B["temp_c"][0], le=_B["temp_c"][1])]
    humidity: Annotated[float, Field(ge=_B["humidity"][0], le=_B["humidity"][1])]
    windspeed: Annotated[float, Field(ge=_B["windspeed"][0], le=_B["windspeed"][1])]

    def to_row(self) -> list[float]:
        """Return the feature values in contract order.

        Ordering is taken from FEATURE_NAMES rather than from the declaration
        order of this class, so reordering fields here can never reorder the
        model input tensor.
        """
        values = self.model_dump()
        return [float(values[name]) for name in FEATURE_NAMES]


class PredictRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    instances: Annotated[list[Observation], Field(min_length=1)]

    @field_validator("instances")
    @classmethod
    def _reject_oversized_batch(cls, value: list[Observation]) -> list[Observation]:
        # Imported here rather than at module import time so that a test can
        # change MAX_BATCH_SIZE and reset the settings cache.
        from serving.config import get_settings

        limit = get_settings().max_batch_size
        if len(value) > limit:
            raise ValueError(f"batch of {len(value)} exceeds MAX_BATCH_SIZE of {limit}")
        return value


class PredictResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Echoing the model identity in the response body, not only in a header,
    # means a consumer logging its own requests can reconstruct which model
    # produced which number months later.
    model_name: str
    model_version: str
    predictions: list[float]


class ModelInfo(BaseModel):
    model_config = ConfigDict(extra="forbid")

    model_name: str
    model_version: str
    git_sha: str
    model_path: str
    feature_names: list[str]
    input_name: str
    output_name: str
    onnx_opset: int | None
    loaded: bool


class ErrorDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    error: Literal[
        "validation_error",
        "batch_too_large",
        "model_not_loaded",
        "inference_failed",
    ]
    message: str
