"""The long-lived objects a request needs, attached to the app at start-up.

Passing the configuration and the Kubernetes gateway through Flask's
``app.extensions`` keeps the blueprints free of module-level globals - two
applications in one process (which is how the tests run) do not share state.
"""

from __future__ import annotations

from dataclasses import dataclass

from flask import current_app

from config import Settings
from kube import Gateway

#: Key under which the services are registered in ``app.extensions``.
EXTENSION_KEY = "aria.services"


@dataclass(frozen=True)
class Services:
    """Everything a view needs that is not part of the request."""

    settings: Settings
    gateway: Gateway


def register(app, services: Services) -> None:
    """Attach the services to an app, once, before it serves anything."""
    app.extensions[EXTENSION_KEY] = services


def current_services() -> Services:
    """The services for the app handling this request."""
    services: Services = current_app.extensions[EXTENSION_KEY]
    return services
