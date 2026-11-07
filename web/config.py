"""Runtime configuration for the image builder web front end.

Everything is read from the environment so the same code runs in three places
without a rebuild:

  * in the cluster, against the pod's service account (the defaults are correct)
  * on an operator's workstation, against whatever ``kubectl`` uses
  * in tests, against a fake gateway

The namespace default is ``packer-imaging`` because that is where the build
CronJobs actually live, and a local run against the cluster should just work.
Getting this wrong is invisible until the UI shows an empty project list, so it
is a constant here rather than a literal repeated across the codebase.

Note that this is *not* the namespace the front end is deployed into: the
Deployment in ``kubernetes/workloads/web-frontend.yaml`` runs in
``packer-frontend`` and sets ``KUBE_NAMESPACE=packer-imaging`` so the page reads
the builds rather than its own (empty) namespace.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping

DEFAULT_NAMESPACE = "packer-imaging"
DEFAULT_KUBE_PORT = 6443
DEFAULT_HTTP_HOST = "0.0.0.0"
DEFAULT_HTTP_PORT = 8080
DEFAULT_REFRESH_SECONDS = 15
DEFAULT_LOG_TAIL = 2000

#: A browser tab polling every 5 seconds is already chatty; anything below this
#: is a denial of service on the API server performed by a single user.
MIN_REFRESH_SECONDS = 5
MAX_REFRESH_SECONDS = 300

#: Log requests are capped so one job with a huge log cannot exhaust the
#: front end's memory building a JSON response.
MIN_LOG_TAIL = 50
MAX_LOG_TAIL = 20000

_TRUE_VALUES = frozenset({"1", "true", "yes", "on"})
_FALSE_VALUES = frozenset({"0", "false", "no", "off"})


def _bool_env(env: Mapping[str, str], key: str, default: bool) -> bool:
    """Read a boolean, accepting the spellings people actually type."""
    raw = (env.get(key) or "").strip().lower()
    if not raw:
        return default
    if raw in _TRUE_VALUES:
        return True
    if raw in _FALSE_VALUES:
        return False
    return default


def _int_env(
    env: Mapping[str, str], key: str, default: int, minimum: int, maximum: int
) -> int:
    """Read an integer and clamp it into ``[minimum, maximum]``.

    Clamping rather than raising keeps a mistyped environment variable from
    stopping a container from starting: an out-of-range value falls back to a
    sane edge instead of a crash loop.
    """
    raw = (env.get(key) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw, 10)
    except ValueError:
        return default
    return max(minimum, min(maximum, value))


def _text_env(env: Mapping[str, str], key: str, default: str) -> str:
    raw = (env.get(key) or "").strip()
    return raw or default


@dataclass(frozen=True)
class Settings:
    """Everything the application needs to know about its environment."""

    namespace: str
    kube_host: str
    kube_port: int
    kube_token: str
    kube_ca_file: str
    verify_ssl: bool
    http_host: str
    http_port: int
    refresh_seconds: int
    log_tail_default: int
    read_only: bool
    kube_timeout_seconds: int

    @property
    def api_server(self) -> str:
        return f"https://{self.kube_host}:{self.kube_port}"

    @property
    def can_mutate(self) -> bool:
        """Whether this deployment may start builds, delete jobs or suspend."""
        return not self.read_only


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    """Build :class:`Settings` from ``env`` (defaults to ``os.environ``)."""
    source: Mapping[str, str] = os.environ if env is None else env
    return Settings(
        namespace=_text_env(source, "KUBE_NAMESPACE", DEFAULT_NAMESPACE),
        kube_host=_text_env(source, "KUBE_HOST", "10.3.48.245"),
        kube_port=_int_env(source, "KUBE_PORT", DEFAULT_KUBE_PORT, 1, 65535),
        kube_token=_text_env(source, "KUBE_TOKEN", ""),
        kube_ca_file=_text_env(source, "KUBE_CA_FILE", ""),
        # Off by default: the cluster serves a self-signed certificate and there
        # is no DNS name to put in it. Set KUBE_VERIFY_SSL=1 once a trusted
        # certificate is in place.
        verify_ssl=_bool_env(source, "KUBE_VERIFY_SSL", False),
        http_host=_text_env(source, "FLASK_HOST", DEFAULT_HTTP_HOST),
        http_port=_int_env(source, "FLASK_PORT", DEFAULT_HTTP_PORT, 1, 65535),
        refresh_seconds=_int_env(
            source,
            "REFRESH_SECONDS",
            DEFAULT_REFRESH_SECONDS,
            MIN_REFRESH_SECONDS,
            MAX_REFRESH_SECONDS,
        ),
        log_tail_default=_int_env(
            source, "LOG_TAIL_DEFAULT", DEFAULT_LOG_TAIL, MIN_LOG_TAIL, MAX_LOG_TAIL
        ),
        # A read-only deployment is the safe way to publish this UI more widely:
        # everyone can see builds and logs, nobody can start one by accident.
        read_only=_bool_env(source, "READ_ONLY", False),
        kube_timeout_seconds=_int_env(source, "KUBE_TIMEOUT_SECONDS", 20, 1, 120),
    )
