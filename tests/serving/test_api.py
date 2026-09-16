"""API tests.

The most valuable test in this file is test_invocations_and_predict_agree. The
SageMaker route and the friendly route are two names for one operation, and the
classic way that breaks is a validation rule or a metric added to one handler and
not the other. The bug is invisible on EKS, where nothing calls /invocations, and
appears the day a SageMaker endpoint is created from the same image.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from serving import config as serving_config
from serving.app import create_app
from serving.config import Settings


def _client(model_path: Path, **environment: object) -> TestClient:
    os.environ["MODEL_PATH"] = str(model_path)
    for key, value in environment.items():
        os.environ[key] = str(value)
    serving_config.reset_settings_for_tests()
    # The context manager is what runs the lifespan, which is what loads the
    # model. A TestClient used without it serves 503 from an unloaded app and the
    # tests would pass for the wrong reason.
    return TestClient(create_app(Settings()))


def test_ping_is_200_when_a_model_is_loaded(onnx_model_path: Path) -> None:
    with _client(onnx_model_path) as client:
        response = client.get("/ping")
    assert response.status_code == 200
    # SageMaker specifies an empty body. Returning JSON here works today and is
    # the kind of thing that quietly stops working.
    assert response.content == b""


def test_readyz_and_healthz(onnx_model_path: Path) -> None:
    with _client(onnx_model_path) as client:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 200


def test_invocations_returns_predictions(onnx_model_path: Path, valid_observation: dict) -> None:
    with _client(onnx_model_path, MODEL_VERSION="7") as client:
        response = client.post("/invocations", json={"instances": [valid_observation]})

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["model_version"] == "7"
    assert len(body["predictions"]) == 1
    assert body["predictions"][0] > 0


def test_invocations_and_predict_agree(onnx_model_path: Path, valid_observation: dict) -> None:
    """Both routes must produce byte-identical bodies for the same payload."""
    payload = {"instances": [valid_observation, valid_observation]}
    with _client(onnx_model_path) as client:
        sagemaker_route = client.post("/invocations", json=payload)
        friendly_route = client.post("/predict", json=payload)

    assert sagemaker_route.status_code == friendly_route.status_code == 200
    assert sagemaker_route.json() == friendly_route.json()


def test_invocations_rejects_the_same_bad_input_as_predict(onnx_model_path: Path) -> None:
    """Validation must not live in only one of the two handlers."""
    bad = {
        "instances": [
            {
                "hour": 99,
                "dayofweek": 2,
                "month": 6,
                "is_holiday": 0,
                "is_workingday": 1,
                "temp_c": 21.0,
                "humidity": 0.5,
                "windspeed": 3.0,
            }
        ]
    }
    with _client(onnx_model_path) as client:
        assert client.post("/invocations", json=bad).status_code == 422
        assert client.post("/predict", json=bad).status_code == 422


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("hour", 24),
        ("hour", -1),
        ("dayofweek", 7),
        ("month", 0),
        ("month", 13),
        ("humidity", 1.5),
        ("humidity", -0.1),
        ("temp_c", 99.0),
        ("windspeed", -1.0),
        ("is_holiday", 2),
    ],
)
def test_out_of_range_values_are_rejected(
    onnx_model_path: Path, valid_observation: dict, field: str, value: float
) -> None:
    payload = {"instances": [{**valid_observation, field: value}]}
    with _client(onnx_model_path) as client:
        response = client.post("/predict", json=payload)
    assert response.status_code == 422
    assert response.json()["error"] == "validation_error"


def test_unknown_field_is_rejected(onnx_model_path: Path, valid_observation: dict) -> None:
    """Ignoring an unknown field lets a caller believe it is sending a feature."""
    payload = {"instances": [{**valid_observation, "temperature_f": 70.0}]}
    with _client(onnx_model_path) as client:
        response = client.post("/predict", json=payload)
    assert response.status_code == 422


def test_missing_field_is_rejected(onnx_model_path: Path, valid_observation: dict) -> None:
    incomplete = {key: value for key, value in valid_observation.items() if key != "windspeed"}
    with _client(onnx_model_path) as client:
        response = client.post("/predict", json={"instances": [incomplete]})
    assert response.status_code == 422


def test_empty_batch_is_rejected(onnx_model_path: Path) -> None:
    with _client(onnx_model_path) as client:
        assert client.post("/predict", json={"instances": []}).status_code == 422


def test_oversized_batch_is_rejected_with_its_own_reason(
    onnx_model_path: Path, valid_observation: dict
) -> None:
    with _client(onnx_model_path, MAX_BATCH_SIZE=4) as client:
        response = client.post("/predict", json={"instances": [valid_observation] * 5})
        assert response.status_code == 422
        assert response.json()["error"] == "batch_too_large"

        metrics_body = client.get("/metrics").text
    # The distinct reason label is the point: a client sending oversized batches
    # and an upstream pipeline emitting out-of-range values need different
    # responses, so they cannot share one counter.
    assert 'inference_input_rejected_total{reason="batch_too_large"}' in metrics_body


def test_batch_at_the_limit_is_accepted(onnx_model_path: Path, valid_observation: dict) -> None:
    with _client(onnx_model_path, MAX_BATCH_SIZE=4) as client:
        response = client.post("/predict", json={"instances": [valid_observation] * 4})
    assert response.status_code == 200
    assert len(response.json()["predictions"]) == 4


def test_model_endpoint_reports_the_contract(onnx_model_path: Path) -> None:
    from contract.features import FEATURE_NAMES

    with _client(onnx_model_path, MODEL_VERSION="12", GIT_SHA="abc1234") as client:
        body = client.get("/model").json()

    assert body["loaded"] is True
    assert body["model_version"] == "12"
    assert body["git_sha"] == "abc1234"
    # A consumer should be able to read the expected input order off the service
    # rather than reading the training code.
    assert body["feature_names"] == list(FEATURE_NAMES)


def test_metrics_exposes_every_series_the_alerts_query(
    onnx_model_path: Path, valid_observation: dict
) -> None:
    """Guard against a renamed metric silently emptying a dashboard or alert.

    Every name below is queried by the PrometheusRule in the Helm chart or by a
    panel in monitoring/dashboards. A rename here with no rename there produces
    an empty graph, which looks exactly like a healthy system.
    """
    with _client(onnx_model_path, MODEL_VERSION="3") as client:
        client.post("/predict", json={"instances": [valid_observation] * 3})
        body = client.get("/metrics").text

    for series in (
        "inference_requests_total",
        "inference_request_duration_seconds_bucket",
        "inference_model_latency_seconds_bucket",
        "inference_prediction_bucket",
        "inference_predictions_total",
        "inference_batch_size_bucket",
        "inference_model_loaded",
        "inference_model_info",
    ):
        assert series in body, f"{series} is queried by an alert or dashboard but not emitted"

    assert "inference_model_loaded 1.0" in body
    assert 'model_version="3"' in body


def test_metrics_route_is_not_counted_as_a_request(
    onnx_model_path: Path, valid_observation: dict
) -> None:
    """Scrapes must not appear in the request rate.

    A 15-second scrape from every replica otherwise dominates the request-rate
    graph and dilutes the error ratio an alert fires on.
    """
    with _client(onnx_model_path) as client:
        client.post("/predict", json={"instances": [valid_observation]})
        for _ in range(5):
            client.get("/metrics")
        body = client.get("/metrics").text

    assert 'route="/metrics"' not in body
    assert 'route="/predict"' in body


def test_prediction_clamp_bounds_are_configurable(
    onnx_model_path: Path, valid_observation: dict
) -> None:
    with _client(onnx_model_path, PREDICTION_CLAMP_MAX=1.0) as client:
        response = client.post("/predict", json={"instances": [valid_observation]})
    assert response.status_code == 200
    assert response.json()["predictions"][0] == 1.0


def test_startup_fails_loudly_when_the_model_is_missing(tmp_path: Path) -> None:
    """A pod with no model must crash, not serve 503 forever.

    A permanently unready pod looks like a scheduling problem and gets
    investigated as one. A crash loop names the real cause in kubectl output.
    """
    with pytest.raises(FileNotFoundError):
        with _client(tmp_path / "absent.onnx"):
            pass
