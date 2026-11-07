"""The only module that talks to the Kubernetes API.

Everything above this layer works on plain dictionaries, which is deliberate:
the official client returns generated model classes whose nesting is awkward to
read and impossible to construct by hand in a test. One conversion happens
here, on the way out, and nothing above has to know the client exists.

Connection is attempted three ways, in the order that is right for the place
this runs:

  1. in-cluster, using the pod's service account - what happens on the cluster
  2. a kubeconfig on disk - what happens on a workstation with ``kubectl``
  3. an explicit API server, host and port - what happens on a workstation
     with a token and no kubeconfig

The third is last because it cannot discover anything: it needs the address to
be configured rather than found.
"""

from __future__ import annotations

import copy
import logging
import secrets
import string
from typing import Any, Protocol

from kubernetes import client, config
from kubernetes.client.rest import ApiException

from config import Settings
from naming import build_run_name, instantiate_annotations, instantiate_labels

LOGGER = logging.getLogger(__name__)

#: The label the Job controller puts on every pod it owns. Selecting pods by it
#: is more reliable than the Job's own ``spec.selector``, which is absent until
#: the controller has written it.
JOB_NAME_LABEL = "job-name"

#: Name label the browser uses to know which project a run belongs to.
APP_NAME_LABEL = "app.kubernetes.io/name"

#: How many alternative names to try when a Job name is already taken. Two
#: clicks in the same second collide; a handful of attempts resolves it without
#: a loop that could spin.
NAME_ATTEMPTS = 5

_DISCRIMINATOR_ALPHABET = string.ascii_lowercase + string.digits
_DISCRIMINATOR_LENGTH = 4


class KubernetesUnavailable(RuntimeError):
    """No API client could be built, so nothing can be served."""


class KubernetesRequestFailed(RuntimeError):
    """The API server answered with an error status."""

    def __init__(self, message: str, status: int = 500, reason: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.reason = reason


class NotFound(KubernetesRequestFailed):
    """The object asked for does not exist."""


def _serialize(api: client.ApiClient, obj: Any) -> dict[str, Any]:
    """Convert a client model into the JSON dictionary the API would return."""
    if obj is None:
        return {}
    return api.sanitize_for_serialization(obj)


def _translate(exc: ApiException, action: str) -> KubernetesRequestFailed:
    """Turn a client exception into one of the two errors above."""
    status = int(exc.status or 500)
    reason = str(exc.reason or "").strip()
    detail = ""
    body = getattr(exc, "body", None)
    if isinstance(body, str) and body:
        detail = body.strip()
    elif isinstance(body, dict):
        detail = str(body.get("message") or "").strip()
    message = f"{action}: {reason or 'request failed'}"
    if detail and detail != reason:
        message = f"{message} ({detail})"
    if status == 404:
        return NotFound(message, status, reason)
    return KubernetesRequestFailed(message, status, reason)


def _discriminator() -> str:
    """A short random token appended to a Job name to break a tie."""
    return "".join(
        secrets.choice(_DISCRIMINATOR_ALPHABET) for _ in range(_DISCRIMINATOR_LENGTH)
    )


class Gateway(Protocol):
    """The operations the front end performs on a namespace.

    Written down as a protocol because there are two implementations: the real
    one below, and the in-memory double the tests and ``tools/dev-server.py``
    pass to :func:`app.create_app`. Neither inherits from the other - the double
    deliberately does not import the Kubernetes client - so this is what makes
    the substitution type-check instead of being an unchecked ``Any``.
    """

    @property
    def connected(self) -> bool: ...

    @property
    def error(self) -> str: ...

    @property
    def server_version(self) -> str: ...

    @property
    def namespace(self) -> str: ...

    def require(self) -> None: ...

    def list_cronjobs(self) -> list[dict[str, Any]]: ...

    def get_cronjob(self, name: str) -> dict[str, Any]: ...

    def set_cronjob_suspended(self, name: str, suspended: bool) -> dict[str, Any]: ...

    def list_jobs(self) -> list[dict[str, Any]]: ...

    def get_job(self, name: str) -> dict[str, Any]: ...

    def create_job_from_cronjob(self, cronjob_name: str) -> dict[str, Any]: ...

    def delete_job(self, name: str) -> None: ...

    def pods_for_job(self, job_name: str) -> list[dict[str, Any]]: ...

    def pod_logs(
        self, job_name: str, container: str = "", tail: int = 2000
    ) -> dict[str, Any]: ...

    def quota_usage(self) -> list[dict[str, Any]]: ...


class KubernetesGateway:
    """Everything the front end can do to the cluster, in one place.

    Deliberately not a general-purpose client. It exposes the seven operations
    this UI performs and nothing else, so the RBAC in
    ``kubernetes/workloads/web-frontend.yaml`` can stay as narrow as it is.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._api: client.ApiClient | None = None
        self._batch: client.BatchV1Api | None = None
        self._core: client.CoreV1Api | None = None
        self._connected = False
        self._error = ""
        self._server_version = ""
        self._timeout = settings.kube_timeout_seconds

    # -- connection ---------------------------------------------------------

    def connect(self) -> None:
        """Try each configuration source in turn and keep the first that works.

        Called once at start-up. A failure is recorded rather than raised: the
        web server should start and report *why* it cannot reach the cluster,
        instead of a crash loop that only shows the reason in a container log
        nobody is watching.
        """
        attempts = (
            ("in-cluster", self._use_incluster),
            ("kubeconfig", self._use_kubeconfig),
            ("configured host", self._use_explicit),
        )
        failures: list[str] = []
        for label, strategy in attempts:
            try:
                strategy()
            except Exception as exc:  # noqa: BLE001 - every failure is reported
                failures.append(f"{label}: {exc}")
                continue
            self._build_clients()
            self._connected = True
            self._error = ""
            self._server_version = self._read_server_version()
            LOGGER.info(
                "connected to the Kubernetes API via %s at %s",
                label,
                self._api.configuration.host if self._api else "?",
            )
            return
        self._connected = False
        self._error = "; ".join(failures) or "no usable Kubernetes configuration"

    def _use_incluster(self) -> None:
        """Inside a pod: the mounted service account and the cluster CA."""
        config.load_incluster_config()

    def _use_kubeconfig(self) -> None:
        """On a workstation: whatever ``kubectl`` already uses."""
        config.load_kube_config()

    def _use_explicit(self) -> None:
        """Configured address and token, for a host with no kubeconfig."""
        configuration = client.Configuration()
        configuration.host = self._settings.api_server
        configuration.verify_ssl = self._settings.verify_ssl
        configuration.api_key = {}
        if self._settings.kube_ca_file:
            configuration.ssl_ca_cert = self._settings.kube_ca_file
        if self._settings.kube_token:
            # The value is a bearer token; the client writes it into the
            # Authorization header. It is never logged.
            configuration.api_key["authorization"] = self._settings.kube_token
        configuration.retries = 0
        client.Configuration.set_default(configuration)

    def _build_clients(self) -> None:
        self._api = client.ApiClient()
        self._batch = client.BatchV1Api(self._api)
        self._core = client.CoreV1Api(self._api)

    def _read_server_version(self) -> str:
        """Best effort: a version string is decoration, not a dependency."""
        try:
            version = client.VersionApi(self._api).get_code()
            return str(version.git_version or "")
        except Exception as exc:  # noqa: BLE001 - never fatal
            LOGGER.debug("could not read the server version: %s", exc)
            return ""

    @property
    def connected(self) -> bool:
        return self._connected

    @property
    def error(self) -> str:
        return self._error

    @property
    def server_version(self) -> str:
        return self._server_version

    @property
    def namespace(self) -> str:
        return self._settings.namespace

    def require(self) -> None:
        """Raise unless a client is ready, so routes fail fast and clearly."""
        if not self._connected or self._batch is None or self._core is None:
            raise KubernetesUnavailable(
                f"Kubernetes API not reachable: {self._error or 'not connected'}"
            )

    # -- CronJobs (build projects) ------------------------------------------

    def list_cronjobs(self) -> list[dict[str, Any]]:
        """Every scheduled build definition in the namespace."""
        self.require()
        try:
            result = self._batch.list_namespaced_cron_job(
                self.namespace, _request_timeout=self._timeout
            )
        except ApiException as exc:
            raise _translate(exc, "listing build projects") from exc
        return [_serialize(self._api, item) for item in (result.items or [])]

    def get_cronjob(self, name: str) -> dict[str, Any]:
        self.require()
        try:
            cronjob = self._batch.read_namespaced_cron_job(
                name, self.namespace, _request_timeout=self._timeout
            )
        except ApiException as exc:
            raise _translate(exc, f"reading build project '{name}'") from exc
        return _serialize(self._api, cronjob)

    def set_cronjob_suspended(self, name: str, suspended: bool) -> dict[str, Any]:
        """Pause or resume a schedule.

        A merge patch, not a replace: the CronJob is one object many people
        touch, and sending the whole spec back would undo any change made
        between our read and our write.
        """
        self.require()
        try:
            cronjob = self._batch.patch_namespaced_cron_job(
                name,
                self.namespace,
                {"spec": {"suspend": bool(suspended)}},
                _request_timeout=self._timeout,
            )
        except ApiException as exc:
            verb = "pausing" if suspended else "resuming"
            raise _translate(exc, f"{verb} build project '{name}'") from exc
        return _serialize(self._api, cronjob)

    # -- Jobs (runs) --------------------------------------------------------

    def list_jobs(self) -> list[dict[str, Any]]:
        """Every run in the namespace, finished or not."""
        self.require()
        try:
            result = self._batch.list_namespaced_job(
                self.namespace, _request_timeout=self._timeout
            )
        except ApiException as exc:
            raise _translate(exc, "listing build runs") from exc
        return [_serialize(self._api, item) for item in (result.items or [])]

    def get_job(self, name: str) -> dict[str, Any]:
        self.require()
        try:
            job = self._batch.read_namespaced_job(
                name, self.namespace, _request_timeout=self._timeout
            )
        except ApiException as exc:
            raise _translate(exc, f"reading build run '{name}'") from exc
        return _serialize(self._api, job)

    def create_job_from_cronjob(self, cronjob_name: str) -> dict[str, Any]:
        """Start one run of a build project, now.

        The same thing ``kubectl create job --from=cronjob`` does: copy the job
        template into a new Job so an on-demand run is identical to a scheduled
        one. The CronJob stays the single definition of how a project builds.
        """
        cronjob = self.get_cronjob(cronjob_name)
        last_error: KubernetesRequestFailed | None = None
        for attempt in range(NAME_ATTEMPTS):
            job_name = build_run_name(
                cronjob_name, discriminator="" if attempt == 0 else _discriminator()
            )
            body = build_job_body(cronjob, job_name)
            try:
                created = self._batch.create_namespaced_job(
                    self.namespace, body, _request_timeout=self._timeout
                )
            except ApiException as exc:
                last_error = _translate(exc, f"starting a build of '{cronjob_name}'")
                # 409 is the name already existing - two clicks in the same
                # second. Anything else is a real refusal and is reported now.
                if int(exc.status or 0) == 409 and attempt < NAME_ATTEMPTS - 1:
                    continue
                raise last_error from exc
            return _serialize(self._api, created)
        raise last_error or KubernetesRequestFailed(
            f"could not find an unused name for a run of '{cronjob_name}'", 409
        )

    def delete_job(self, name: str) -> None:
        """Remove a run and, by background propagation, its pod.

        Background rather than foreground: a foreground delete waits for the
        pod to disappear, and the pod of a stuck build does not always do that
        quickly. Leaving the pod to be reaped afterwards keeps the request
        short and the UI responsive.
        """
        self.require()
        try:
            self._batch.delete_namespaced_job(
                name,
                self.namespace,
                body=client.V1DeleteOptions(propagation_policy="Background"),
                _request_timeout=self._timeout,
            )
        except ApiException as exc:
            raise _translate(exc, f"deleting build run '{name}'") from exc

    # -- pods and logs ------------------------------------------------------

    def pods_for_job(self, job_name: str) -> list[dict[str, Any]]:
        """The pods a Job created, newest first."""
        self.require()
        try:
            result = self._core.list_namespaced_pod(
                self.namespace,
                label_selector=f"{JOB_NAME_LABEL}={job_name}",
                _request_timeout=self._timeout,
            )
        except ApiException as exc:
            raise _translate(exc, f"listing pods for run '{job_name}'") from exc
        pods = [_serialize(self._api, item) for item in (result.items or [])]
        pods.sort(
            key=lambda pod: str((pod.get("metadata") or {}).get("creationTimestamp") or ""),
            reverse=True,
        )
        return pods

    def pod_logs(
        self, job_name: str, container: str = "", tail: int = 2000
    ) -> dict[str, Any]:
        """Logs for one container of a run's newest pod.

        A container that has not started yet makes the API answer 400 rather
        than return an empty log, so that case is turned into a note the UI can
        show instead of an error the user has to interpret.
        """
        pods = self.pods_for_job(job_name)
        if not pods:
            return {
                "logs": "",
                "pod": "",
                "container": "",
                "note": "No pod yet - the run has not been scheduled.",
            }
        pod = pods[0]
        pod_name = str((pod.get("metadata") or {}).get("name") or "")
        pod_spec = pod.get("spec") or {}
        available = [
            str(item.get("name"))
            for item in (pod_spec.get("initContainers") or [])
            + (pod_spec.get("containers") or [])
            if item.get("name")
        ]
        chosen = container if container in available else ""
        if not chosen:
            regular = [
                str(item.get("name"))
                for item in pod_spec.get("containers") or []
                if item.get("name")
            ]
            chosen = regular[-1] if regular else (available[0] if available else "")
        if not chosen:
            return {
                "logs": "",
                "pod": pod_name,
                "container": "",
                "note": "The pod declares no containers yet.",
            }
        try:
            logs = self._core.read_namespaced_pod_log(
                pod_name,
                self.namespace,
                container=chosen,
                tail_lines=tail,
                _request_timeout=self._timeout,
            )
        except ApiException as exc:
            status = int(exc.status or 0)
            if status == 400:
                return {
                    "logs": "",
                    "pod": pod_name,
                    "container": chosen,
                    "note": f"'{chosen}' has not started yet.",
                }
            if status == 404:
                return {
                    "logs": "",
                    "pod": pod_name,
                    "container": chosen,
                    "note": "The pod is gone; its log went with it.",
                }
            raise _translate(exc, f"reading the log of '{chosen}'") from exc
        return {
            "logs": logs or "",
            "pod": pod_name,
            "container": chosen,
            "note": "",
        }

    # -- namespace capacity -------------------------------------------------

    def quota_usage(self) -> list[dict[str, Any]]:
        """ResourceQuota used versus hard, for the namespace.

        This is what explains a run stuck in ``blocked``: the namespace allows
        16 pods and each build holds a virtual machine, so "no capacity" is a
        normal answer and the UI should be able to say so precisely.
        """
        self.require()
        try:
            result = self._core.list_namespaced_resource_quota(
                self.namespace, _request_timeout=self._timeout
            )
        except ApiException as exc:
            raise _translate(exc, "reading namespace capacity") from exc
        quotas: list[dict[str, Any]] = []
        for item in result.items or []:
            serialized = _serialize(self._api, item)
            status = serialized.get("status") or {}
            quotas.append(
                {
                    "name": (serialized.get("metadata") or {}).get("name", ""),
                    "hard": dict(status.get("hard") or {}),
                    "used": dict(status.get("used") or {}),
                }
            )
        return quotas


def build_job_body(cronjob: dict[str, Any], job_name: str) -> dict[str, Any]:
    """The Job to create for one on-demand run of ``cronjob``.

    Faithful to ``kubectl create job --from=cronjob``:

    * the spec is the job template's, deep-copied so the caller's object is
      never mutated;
    * ``selector`` and ``manualSelector`` are dropped. A copied selector would
      name the pods of whichever Job it came from, and the new Job's pods would
      then never be selected. Leaving both unset has the controller generate a
      fresh selector from the pod template's labels, which is the correct
      outcome and what ``kubectl`` relies on too;
    * the pod template's server-populated metadata is dropped for the same
      reason: it describes the object that was read, not the one to create;
    * ``cronjob.kubernetes.io/instantiate: manual`` marks the run as started by
      hand, in the label and the annotation, exactly as ``kubectl`` writes it;
    * the CronJob's own ``packer.io/*`` labels are copied onto the Job, because
      they live on the CronJob (a family, for instance) and not on the job
      template, so without this a run would not say which family it belongs to.

    A pure function: it takes a serialised CronJob and returns the body to
    POST, with no client and no I/O, so it can be checked in a unit test.
    """
    meta = cronjob.get("metadata") or {}
    template = (cronjob.get("spec") or {}).get("jobTemplate") or {}
    template_meta = template.get("metadata") or {}
    job_spec = copy.deepcopy(template.get("spec") or {})

    job_spec.pop("selector", None)
    job_spec.pop("manualSelector", None)

    pod_meta = (job_spec.get("template") or {}).get("metadata")
    if isinstance(pod_meta, dict):
        for key in ("creationTimestamp", "resourceVersion", "uid", "managedFields"):
            pod_meta.pop(key, None)

    labels = instantiate_labels(template_meta.get("labels"))
    cronjob_name = str(meta.get("name") or "")
    if cronjob_name:
        labels[APP_NAME_LABEL] = cronjob_name
    for key, value in (meta.get("labels") or {}).items():
        if key.startswith("packer.io/") and key not in labels:
            labels[key] = value

    body: dict[str, Any] = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": job_name,
            "labels": labels,
            "annotations": instantiate_annotations(template_meta.get("annotations")),
        },
        "spec": job_spec,
    }
    namespace = meta.get("namespace")
    if namespace:
        body["metadata"]["namespace"] = namespace
    return body
