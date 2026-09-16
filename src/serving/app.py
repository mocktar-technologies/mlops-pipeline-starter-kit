"""FastAPI application for online inference.

Route map, and why there are two names for one operation:

  POST /invocations   SageMaker hosting calls this path and no other. It is not
  POST /predict       configurable. /predict is the same operation under a name
                      that reads better from a Kubernetes client. Both routes
                      call the same _predict function, so there is exactly one
                      validation path and one metrics path. Two handlers that
                      drift apart is a real failure mode: the friendly route
                      gets the new validation rule, the SageMaker route does not,
                      and the difference only shows up in production.

  GET  /ping          SageMaker health check. Must answer 200 with an empty body
                      when ready. It gets two seconds, so it does no work beyond
                      reading a boolean.
  GET  /healthz       Kubernetes liveness. Answers 200 whenever the process can
                      serve HTTP. It deliberately does NOT check the model: a
                      liveness probe that fails on a missing model restarts the
                      pod in a loop instead of leaving it up and out of service
                      where you can inspect it.
  GET  /readyz        Kubernetes readiness. Fails when no model is loaded, which
                      takes the pod out of the Service endpoints without killing it.
  GET  /model         The loaded artifact's identity and input signature.
  GET  /metrics       Prometheus exposition for this pod.
"""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from contract.features import FEATURE_NAMES
from serving import metrics
from serving.config import Settings, get_settings
from serving.model import ModelNotLoadedError, OnnxModel
from serving.schemas import ErrorDetail, ModelInfo, PredictRequest, PredictResponse

logger = logging.getLogger(__name__)

# Routes excluded from request metrics. Scraping /metrics every 15 seconds from
# every pod would otherwise dominate the request-rate graph and dilute the error
# ratio that alerts fire on.
_UNMEASURED_ROUTES = frozenset({"/metrics", "/healthz", "/ping", "/readyz"})


def _normalize_route(request: Request) -> str:
    """Return the route template, not the concrete path.

    Using request.url.path as a label is how a metrics backend ends up with one
    series per distinct URL. This service has no path parameters today, but the
    guard costs nothing and prevents the next person from introducing unbounded
    cardinality by adding /predict/{model_id}.
    """
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path or "unmatched"


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the application. Takes settings so tests can inject their own."""
    resolved = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # Loading here rather than in a request handler is what makes the
        # readiness probe meaningful: by the time /readyz answers 200 the model
        # is in memory and has already run once.
        model = OnnxModel(resolved)
        app.state.model = model
        app.state.settings = resolved
        try:
            model.load()
        except Exception:
            # Do not swallow this. A pod that starts without a model and serves
            # 503 forever is worse than a pod that crash-loops, because a
            # crash-loop is visible in kubectl get pods and in an alert, while a
            # permanently unready pod looks like a scheduling problem.
            logger.exception("startup aborted: the model could not be loaded")
            raise
        try:
            yield
        finally:
            model.close()

    app = FastAPI(
        title="demand-forecast inference",
        version=resolved.model_version,
        lifespan=lifespan,
        # No interactive docs in the serving image. They are a needless surface
        # on an internal service, and the OpenAPI schema is generated in CI
        # instead, where consumers can fetch it from the artifact store.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    # ---- middleware --------------------------------------------------------

    @app.middleware("http")
    async def record_request_metrics(request: Request, call_next):
        route_hint = request.url.path
        if route_hint in _UNMEASURED_ROUTES:
            return await call_next(request)

        started = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            # An unhandled exception still has to be counted, or the error rate
            # a dashboard shows is only the errors the app remembered to record.
            metrics.REQUESTS.labels(
                route=route_hint, status="5xx", model_version=resolved.model_version
            ).inc()
            metrics.REQUEST_DURATION.labels(
                route=route_hint, model_version=resolved.model_version
            ).observe(time.perf_counter() - started)
            raise

        route = _normalize_route(request)
        metrics.REQUESTS.labels(
            route=route,
            status=metrics.status_class(response.status_code),
            model_version=resolved.model_version,
        ).inc()
        metrics.REQUEST_DURATION.labels(route=route, model_version=resolved.model_version).observe(
            time.perf_counter() - started
        )
        return response

    # ---- error handling ----------------------------------------------------

    @app.exception_handler(RequestValidationError)
    async def on_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        # The batch-size limit is enforced by a pydantic validator, so it
        # surfaces here. Splitting it out by reason is what lets you tell a
        # client sending oversized batches apart from an upstream pipeline that
        # has started emitting out-of-range humidity.
        rendered = str(exc)
        if "MAX_BATCH_SIZE" in rendered:
            reason, code = "batch_too_large", "batch_too_large"
        else:
            reason, code = "schema", "validation_error"
        metrics.INPUT_REJECTED.labels(reason=reason).inc()
        logger.info("rejected request on %s: %s", request.url.path, rendered)
        return JSONResponse(
            status_code=422,
            content=ErrorDetail(
                error=code,  # type: ignore[arg-type]
                message=rendered,
            ).model_dump(),
        )

    @app.exception_handler(ModelNotLoadedError)
    async def on_model_not_loaded(request: Request, exc: ModelNotLoadedError) -> JSONResponse:
        metrics.INPUT_REJECTED.labels(reason="model_not_loaded").inc()
        return JSONResponse(
            status_code=503,
            content=ErrorDetail(error="model_not_loaded", message=str(exc)).model_dump(),
        )

    # ---- shared inference path ---------------------------------------------

    def _predict(app_state_model: OnnxModel, payload: PredictRequest) -> PredictResponse:
        """The one and only inference implementation.

        Both /invocations and /predict call this. Nothing about SageMaker or
        Kubernetes appears below this line.
        """
        rows = [observation.to_row() for observation in payload.instances]
        metrics.BATCH_SIZE.observe(len(rows))
        predictions = app_state_model.predict(rows)
        return PredictResponse(
            model_name=resolved.model_name,
            model_version=resolved.model_version,
            predictions=predictions,
        )

    # ---- routes ------------------------------------------------------------

    @app.post("/invocations", response_model=PredictResponse)
    async def invocations(payload: PredictRequest, request: Request) -> PredictResponse:
        return _predict(request.app.state.model, payload)

    @app.post("/predict", response_model=PredictResponse)
    async def predict(payload: PredictRequest, request: Request) -> PredictResponse:
        return _predict(request.app.state.model, payload)

    @app.get("/ping")
    async def ping(request: Request) -> Response:
        # Empty body, as the SageMaker contract specifies. 503 rather than 500
        # while the model is absent, so a load balancer treats it as
        # unavailable rather than broken.
        model: OnnxModel = request.app.state.model
        return Response(status_code=200 if model.loaded else 503)

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz() -> str:
        return "ok"

    @app.get("/readyz", response_class=PlainTextResponse)
    async def readyz(request: Request) -> Response:
        model: OnnxModel = request.app.state.model
        if model.loaded:
            return PlainTextResponse("ready")
        return PlainTextResponse("model not loaded", status_code=503)

    @app.get("/model", response_model=ModelInfo)
    async def model_info(request: Request) -> ModelInfo:
        model: OnnxModel = request.app.state.model
        return ModelInfo(
            model_name=resolved.model_name,
            model_version=resolved.model_version,
            git_sha=resolved.git_sha,
            model_path=resolved.model_path,
            feature_names=list(FEATURE_NAMES),
            input_name=model.input_name,
            output_name=model.output_name,
            onnx_opset=model.opset,
            loaded=model.loaded,
        )

    @app.get("/metrics")
    async def prometheus_metrics() -> Response:
        if not resolved.metrics_enabled:
            return Response(status_code=404)
        return Response(
            content=generate_latest(metrics.REGISTRY),
            media_type=CONTENT_TYPE_LATEST,
        )

    return app
