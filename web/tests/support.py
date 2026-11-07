"""Fixtures and a fake Kubernetes gateway for the unit tests.

The subject under test is the layer *above* the Kubernetes client, so nothing
here touches a cluster. The builders below produce the same dictionaries the
API server returns for the build manifests - that is what makes the tests
meaningful: if the real manifests ever change shape, these are the objects that
have to change with them.

Run the tests from ``web/``. Discovery alone does not work: this directory has no
``__init__.py`` (it must not, since ``web/`` is mounted as a flat ``/app``), so
the modules are named explicitly and both this directory and ``web/`` are on the
path:

    set PYTHONPATH=.;tests
    python -m unittest test_api test_job_body test_k8stime test_manifest ^
        test_naming test_projects test_quantities test_runs test_theme
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# The application modules are top-level inside web/, because that is how the
# ConfigMap mounts them in the cluster: /app/app.py next to /app/kube.py.
WEB_ROOT = Path(__file__).resolve().parent.parent
if str(WEB_ROOT) not in sys.path:
    sys.path.insert(0, str(WEB_ROOT))

from kube import KubernetesRequestFailed, NotFound, build_job_body  # noqa: E402

#: The namespace the fixtures live in: the build namespace, not the one this
#: front end is deployed into. Everything the page reads is here.
NAMESPACE = "packer-imaging"

#: Timestamps used throughout. Fixed, so a duration assertion is exact rather
#: than approximately right on a fast machine.
CREATED = "2026-10-25T03:00:00Z"
STARTED = "2026-10-25T03:00:05Z"
FINISHED = "2026-10-25T03:42:05Z"  # 42 minutes, about what a Photon build takes


def labels_for(project: str, family: str | None = None) -> dict[str, str]:
    labels = {
        "app.kubernetes.io/part-of": "aria-automation",
        "packer.io/project": project,
    }
    if family:
        labels["packer.io/family"] = family
    return labels


def make_cronjob(
    name: str = "aria-build-photon-5",
    project: str = "photon-5",
    family: str | None = "linux",
    schedule: str = "0 3 * * 0",
    suspend: bool = False,
    purpose: str = "Weekly rebuild of the Photon OS 5 node template",
    secret: str | None = "pkrvars-photon-5",
    packer_project: str = "builds/linux/photon/5",
) -> dict[str, Any]:
    """A CronJob shaped like the ones the build manifests define.

    ``packer_project`` is the directory Packer builds, which the page shows as
    the card's ``path``. It has to be passed whenever the fixture stands for a
    project other than Photon 5, or every card in the demo claims to build the
    Photon template.
    """
    template_labels = labels_for(project)
    env = [
        {"name": "PACKER_PROJECT", "value": packer_project},
        {"name": "PACKER_BUILD_ARGS", "value": "-force"},
        {"name": "CHECKPOINT_DISABLE", "value": "1"},
    ]
    volumes: list[dict[str, Any]] = [
        {"name": "workspace", "emptyDir": {}},
        {
            "name": "build-scripts",
            "configMap": {"name": "aria-image-build-scripts", "defaultMode": 0o755},
        },
    ]
    if secret:
        volumes.append({"name": "pkrvars", "secret": {"secretName": secret}})

    return {
        "apiVersion": "batch/v1",
        "kind": "CronJob",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "labels": labels_for(project, family),
            "annotations": {"aria-automation/purpose": purpose},
            "creationTimestamp": "2026-01-04T12:00:00Z",
        },
        "spec": {
            "schedule": schedule,
            "timeZone": "America/New_York",
            "concurrencyPolicy": "Forbid",
            "startingDeadlineSeconds": 7200,
            "successfulJobsHistoryLimit": 2,
            "failedJobsHistoryLimit": 3,
            "suspend": suspend,
            "jobTemplate": {
                "metadata": {"labels": template_labels},
                "spec": {
                    "backoffLimit": 0,
                    "activeDeadlineSeconds": 7200,
                    "ttlSecondsAfterFinished": 21600,
                    "template": {
                        "metadata": {"labels": {**template_labels, "app.kubernetes.io/name": name}},
                        "spec": {
                            "restartPolicy": "Never",
                            "initContainers": [
                                {
                                    "name": "checkout",
                                    "image": "alpine/git:2.45.2",
                                    "envFrom": [
                                        {"secretRef": {"name": "aria-repo-credentials"}}
                                    ],
                                    "env": [
                                        {"name": "GIT_REF", "value": "main"},
                                        {"name": "WORKSPACE", "value": "/workspace"},
                                    ],
                                }
                            ],
                            "containers": [
                                {
                                    "name": "packer",
                                    "image": "hashicorp/packer:1.15.0",
                                    "env": env,
                                }
                            ],
                            "volumes": volumes,
                        },
                    },
                },
            },
        },
        "status": {},
    }


def make_job(
    name: str = "aria-build-photon-5-29000000",
    project: str = "photon-5",
    state: str = "succeeded",
    owner: str | None = "aria-build-photon-5",
    manual: bool = False,
    labels: dict[str, str] | None = None,
    state_message: str = "",
) -> dict[str, Any]:
    """A Job shaped like one the CronJob controller - or this front end - made.

    ``owner`` sets ``ownerReferences``, which is how a scheduled Job is linked
    to its CronJob. ``manual`` sets the instantiate marker instead, which is
    all a Job from ``kubectl create job --from=cronjob`` has.
    """
    job_labels = dict(labels) if labels is not None else labels_for(project)
    annotations: dict[str, str] = {}
    if manual:
        job_labels["cronjob.kubernetes.io/instantiate"] = "manual"
        annotations["cronjob.kubernetes.io/instantiate"] = "manual"

    meta: dict[str, Any] = {
        "name": name,
        "namespace": NAMESPACE,
        "labels": job_labels,
        "annotations": annotations,
        "creationTimestamp": CREATED,
    }
    if owner:
        meta["ownerReferences"] = [
            {
                "apiVersion": "batch/v1",
                "kind": "CronJob",
                "name": owner,
                "controller": True,
                "uid": "00000000-0000-0000-0000-000000000000",
            }
        ]

    status: dict[str, Any] = {}
    spec: dict[str, Any] = {
        "backoffLimit": 0,
        "activeDeadlineSeconds": 7200,
        "ttlSecondsAfterFinished": 21600,
        "template": {
            "metadata": {"labels": {**job_labels, "app.kubernetes.io/name": project}},
            "spec": {
                "restartPolicy": "Never",
                "initContainers": [{"name": "checkout", "image": "alpine/git:2.45.2"}],
                "containers": [
                    {
                        "name": "packer",
                        "image": "hashicorp/packer:1.15.0",
                        "env": [
                            {"name": "PACKER_PROJECT", "value": "builds/linux/photon/5"},
                            {"name": "PACKER_BUILD_ARGS", "value": "-force"},
                        ],
                    }
                ],
            },
        },
    }

    if state == "succeeded":
        status = {
            "startTime": STARTED,
            "completionTime": FINISHED,
            "succeeded": 1,
            "conditions": [
                {"type": "Complete", "status": "True", "reason": "CompletionsReached"}
            ],
        }
    elif state == "failed":
        status = {
            "startTime": STARTED,
            "completionTime": FINISHED,
            "failed": 1,
            "conditions": [
                {
                    "type": "Failed",
                    "status": "True",
                    "reason": "BackoffLimitExceeded",
                    "message": state_message or "Job has reached the specified backoff limit",
                }
            ],
        }
    elif state == "running":
        status = {"startTime": STARTED, "active": 1}
    elif state == "pending":
        status = {}

    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": meta,
        "spec": spec,
        "status": status,
    }


def make_pod(
    name: str = "aria-build-photon-5-29000000-abcde",
    job: str = "aria-build-photon-5-29000000",
    phase: str = "Running",
    unschedulable: str | None = None,
    containers: tuple[str, ...] = ("packer",),
    init_containers: tuple[str, ...] = ("checkout",),
) -> dict[str, Any]:
    """A Pod, optionally one the scheduler refuses to place."""
    conditions = [
        {"type": "PodScheduled", "status": "True"} if unschedulable is None else
        {
            "type": "PodScheduled",
            "status": "False",
            "reason": "Unschedulable",
            "message": unschedulable,
        }
    ]
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "labels": {"job-name": job},
            "creationTimestamp": STARTED,
        },
        "spec": {
            "nodeName": "kube-node-1" if unschedulable is None else "",
            "initContainers": [{"name": item} for item in init_containers],
            "containers": [{"name": item} for item in containers],
        },
        "status": {
            "phase": phase,
            "startTime": STARTED,
            "conditions": conditions,
            "containerStatuses": [
                {"name": item, "ready": unschedulable is None, "restartCount": 0}
                for item in containers
            ],
        },
    }


def make_quota(
    pods_hard: str = "16",
    pods_used: str = "3",
    jobs_hard: str = "80",
    jobs_used: str = "11",
) -> dict[str, Any]:
    return {
        "name": "packer-imaging-quota",
        "hard": {
            "pods": pods_hard,
            "requests.cpu": "8",
            "requests.memory": "16Gi",
            "limits.cpu": "16",
            "limits.memory": "32Gi",
            "count/jobs.batch": jobs_hard,
        },
        "used": {
            "pods": pods_used,
            "requests.cpu": "2",
            "requests.memory": "4Gi",
            "limits.cpu": "6",
            "limits.memory": "8Gi",
            "count/jobs.batch": jobs_used,
        },
    }


class FakeGateway:
    """An in-memory stand-in for :class:`kube.KubernetesGateway`.

    Implements the same surface the API layer calls, and nothing more, so the
    test double fails loudly if the real gateway grows an operation the routes
    start depending on without a test covering it.
    """

    def __init__(
        self,
        cronjobs: list[dict[str, Any]] | None = None,
        jobs: list[dict[str, Any]] | None = None,
        pods: dict[str, list[dict[str, Any]]] | None = None,
        quota: list[dict[str, Any]] | None = None,
        connected: bool = True,
        server_version: str = "v1.31.4",
        namespace: str = NAMESPACE,
    ) -> None:
        self.cronjobs = cronjobs if cronjobs is not None else [make_cronjob()]
        self.jobs = jobs if jobs is not None else []
        self.pods = pods or {}
        self.quota = quota if quota is not None else [make_quota()]
        self._connected = connected
        self._error = "" if connected else "no API client: test double"
        self._server_version = server_version
        self._namespace = namespace
        self.deleted: list[str] = []
        self.created: list[dict[str, Any]] = []
        self.suspended: dict[str, bool] = {}
        self.logs: dict[str, str] = {}

    # -- connection ---------------------------------------------------------

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
        return self._namespace

    def require(self) -> None:
        if not self._connected:
            from kube import KubernetesUnavailable

            raise KubernetesUnavailable(f"Kubernetes API not reachable: {self._error}")

    # -- CronJobs -----------------------------------------------------------

    def list_cronjobs(self) -> list[dict[str, Any]]:
        self.require()
        return [dict(item) for item in self.cronjobs]

    def _find_cronjob(self, name: str) -> dict[str, Any]:
        for item in self.cronjobs:
            if (item.get("metadata") or {}).get("name") == name:
                return item
        raise NotFound(f"reading build project '{name}': not found", 404)

    def get_cronjob(self, name: str) -> dict[str, Any]:
        self.require()
        return dict(self._find_cronjob(name))

    def set_cronjob_suspended(self, name: str, suspended: bool) -> dict[str, Any]:
        self.require()
        cronjob = self._find_cronjob(name)
        cronjob["spec"]["suspend"] = bool(suspended)
        self.suspended[name] = bool(suspended)
        return dict(cronjob)

    # -- Jobs ---------------------------------------------------------------

    def list_jobs(self) -> list[dict[str, Any]]:
        self.require()
        return [dict(item) for item in self.jobs]

    def get_job(self, name: str) -> dict[str, Any]:
        self.require()
        for item in self.jobs:
            if (item.get("metadata") or {}).get("name") == name:
                return dict(item)
        raise NotFound(f"reading build run '{name}': not found", 404)

    def create_job_from_cronjob(self, cronjob_name: str) -> dict[str, Any]:
        """Build the body with the real function, then store it as if created."""
        self.require()
        cronjob = self._find_cronjob(cronjob_name)
        job_name = f"{cronjob_name}-manual-20261026-150000"
        body = build_job_body(cronjob, job_name)
        created = {
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": body["metadata"],
            "spec": body["spec"],
            "status": {},
        }
        self.created.append(created)
        self.jobs.append(created)
        return created

    def delete_job(self, name: str) -> None:
        self.require()
        for index, item in enumerate(self.jobs):
            if (item.get("metadata") or {}).get("name") == name:
                self.jobs.pop(index)
                self.deleted.append(name)
                self.pods.pop(name, None)
                return
        raise NotFound(f"deleting build run '{name}': not found", 404)

    # -- pods and logs ------------------------------------------------------

    def pods_for_job(self, job_name: str) -> list[dict[str, Any]]:
        self.require()
        return list(self.pods.get(job_name, []))

    def pod_logs(
        self, job_name: str, container: str = "", tail: int = 2000
    ) -> dict[str, Any]:
        self.require()
        pods = self.pods.get(job_name) or []
        if not pods:
            return {
                "logs": "",
                "pod": "",
                "container": "",
                "note": "No pod yet - the run has not been scheduled.",
            }
        text = self.logs.get(f"{job_name}/{container}") or self.logs.get(job_name) or ""
        return {
            "logs": text,
            "pod": (pods[0].get("metadata") or {}).get("name", ""),
            "container": container or "packer",
            "note": "",
        }

    # -- capacity -----------------------------------------------------------

    def quota_usage(self) -> list[dict[str, Any]]:
        self.require()
        return [dict(item) for item in self.quota]


def make_failing_gateway(message: str = "connection refused") -> FakeGateway:
    """A gateway that exists but cannot reach the API server."""
    gateway = FakeGateway(connected=False)
    gateway._error = message
    return gateway


#: A run of base64 this long is a key or a certificate, not a name or a path.
_BASE64_BLOB = re.compile(r"[A-Za-z0-9+/]{60,}={0,2}")


def assert_no_secret_values(payload: Any) -> None:
    """Fail if a response carries a credential *value*.

    Checks the shape of a leak rather than a keyword: the API deliberately
    reports the *names* of the Secrets a build needs (``requiredSecrets``), so
    matching on the word "secret" would fail on correct output. A PEM header or
    a long base64 run is what an actual leak looks like.
    """
    text = repr(payload)
    if "BEGIN " in text and "PRIVATE KEY" in text:
        raise AssertionError("response contains a private key")
    match = _BASE64_BLOB.search(text)
    if match is not None:
        raise AssertionError(f"response contains a base64 blob: {match.group(0)[:20]}...")


__all__ = [
    "CREATED",
    "FINISHED",
    "FakeGateway",
    "KubernetesRequestFailed",
    "NAMESPACE",
    "STARTED",
    "assert_no_secret_values",
    "build_job_body",
    "labels_for",
    "make_cronjob",
    "make_failing_gateway",
    "make_job",
    "make_pod",
    "make_quota",
]
