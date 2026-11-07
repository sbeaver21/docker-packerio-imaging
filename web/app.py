"""Application factory and entrypoint for the image builder web front end.

Run it from this directory:

    python app.py

or, in the cluster, through the ConfigMap that ``kubernetes/workloads/
web-frontend.yaml`` mounts at ``/app``.

The factory takes its collaborators as arguments so the tests can build an
application around a fake gateway without a cluster anywhere in sight.
"""

from __future__ import annotations

import logging
import os

from flask import Flask
from flask.json.provider import DefaultJSONProvider

from api import bp as api_blueprint
from config import Settings, load_settings
from kube import Gateway, KubernetesGateway
from pages import bp as pages_blueprint
from services import Services, register

LOGGER = logging.getLogger(__name__)

#: Threads for the production server. The front end spends its time waiting on
#: the API server, so a handful of threads covers far more users than this
#: internal tool will ever have.
SERVER_THREADS = 8


def create_app(
    settings: Settings | None = None,
    gateway: Gateway | None = None,
) -> Flask:
    """Build the application.

    ``gateway`` is injected by the tests. When it is omitted the real one is
    built and connected here, once, so every request shares one API client
    instead of rebuilding TLS material per call.
    """
    settings = settings or load_settings()

    app = Flask(__name__)
    # Insertion order matters to a reader of the JSON; this keeps runs listed
    # newest first in the raw response too, not just in the table. The setting
    # belongs to the default provider - a replacement provider is left alone
    # rather than having an attribute it may not define written onto it.
    json_provider = app.json
    if isinstance(json_provider, DefaultJSONProvider):
        json_provider.sort_keys = False

    if gateway is None:
        gateway = KubernetesGateway(settings)
        gateway.connect()

    register(app, Services(settings=settings, gateway=gateway))
    app.register_blueprint(pages_blueprint)
    app.register_blueprint(api_blueprint)

    @app.after_request
    def _no_store(response):
        """Never let a proxy cache a snapshot of cluster state."""
        if response.mimetype == "application/json":
            response.headers["Cache-Control"] = "no-store"
        return response

    LOGGER.info(
        "serving namespace %s; Kubernetes %s",
        settings.namespace,
        "connected" if gateway.connected else f"unavailable ({gateway.error})",
    )
    return app


def main() -> None:
    """Start the server the way the container runs it."""
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    settings = load_settings()
    app = create_app(settings)

    if not app.extensions["aria.services"].gateway.connected:
        # Not fatal: the page loads and says so, which is more useful than a
        # container that dies and can only explain itself in a restart count.
        LOGGER.warning(
            "no Kubernetes API available: %s",
            app.extensions["aria.services"].gateway.error,
        )

    try:
        from waitress import serve
    except ImportError:
        LOGGER.warning("waitress is not installed; using the development server")
        app.run(
            host=settings.http_host,
            port=settings.http_port,
            threaded=True,
            use_reloader=False,
        )
        return

    LOGGER.info("listening on %s:%s", settings.http_host, settings.http_port)
    serve(
        app,
        host=settings.http_host,
        port=settings.http_port,
        threads=SERVER_THREADS,
        ident="aria-image-builder",
        channel_timeout=60,
    )


if __name__ == "__main__":
    main()
