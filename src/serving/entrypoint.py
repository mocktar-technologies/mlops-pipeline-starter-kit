"""Process entrypoint.

Run as `python -m serving.entrypoint`. The Dockerfile uses the exec form so this
is PID 1 and receives SIGTERM directly from the kubelet, which is what lets
uvicorn drain in-flight requests instead of being killed at the end of the
termination grace period.

Configuration is validated before the socket is bound. A bad value should be a
crash at startup with a readable message, not a surprise at the first request.
"""

from __future__ import annotations

import logging
import sys

import uvicorn

from serving.app import create_app
from serving.config import get_settings


def main() -> int:
    settings = get_settings()

    logging.basicConfig(
        level=settings.log_level.upper() if settings.log_level != "trace" else "DEBUG",
        format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
    )
    log = logging.getLogger("serving.entrypoint")

    try:
        settings.validate()
    except ValueError as exc:
        log.error("invalid configuration: %s", exc)
        return 78  # EX_CONFIG, so an operator can tell this apart from a crash

    log.info(
        "starting on %s:%d model=%s version=%s",
        settings.host,
        settings.port,
        settings.model_name,
        settings.model_version,
    )

    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        workers=settings.workers if settings.workers > 1 else None,
        log_level=settings.log_level,
        # Access logs are off. The metrics middleware already records every
        # request, and a per-request log line from every replica is a
        # significant share of a cluster's log bill for information you can
        # read off a dashboard.
        access_log=False,
        # Longer than the longest expected request so a keep-alive connection is
        # not closed mid-batch, shorter than a load balancer idle timeout.
        timeout_keep_alive=65,
        server_header=False,
        date_header=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
