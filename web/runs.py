"""A Kubernetes Job, described the way the browser needs it.

Runs are the objects the UI is really about: one Job is one attempt at
building one image. The interesting question about a run is not "is the Job
object healthy" but "did the build work, and if not, why not" - so the state
derived here distinguishes four outcomes the raw status does not:

``succeeded``  the Job's Complete condition fired
``failed``     the Job's Failed condition fired, or it hit its deadline
``running``    a pod exists and is doing something
``blocked``    a pod exists but the scheduler will not place it
``pending``    the controller has not created a pod yet

``blocked`` is the one worth having. The namespace has a hard pod quota of 16
and every build holds a virtual machine, so the normal way a build fails is
that it never starts - and a UI that says "pending" for that is lying by
omission. The scheduler's own message is carried through as ``stateMessage``.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any

from k8stime import elapsed_since, parse_timestamp, seconds_between
from naming import FAMILY_LABEL, PROJECT_LABEL, is_manual_run

#: Environment variables that say what a build is actually going to produce.
#: A whitelist, not the whole environment: pod specs also carry ordinary
#: configuration and there is no reason to publish all of it.
INTERESTING_ENV = ("PACKER_PROJECT", "PACKER_BUILD_ARGS", "GIT_REF")

#: Label written by the Job controller onto every pod it owns.
JOB_NAME_LABEL = "job-name"

#: How this repository names its build CronJobs. Used to recover a project name
#: from a Job that carries no ``packer.io/project`` label.
PROJECT_PREFIX = "aria-build-"

#: ``<cronjob>-manual-<yyyymmdd-hhmmss>[-<token>]``: the names this front end
#: generates for an on-demand run.
_MANUAL_NAME = re.compile(r"^(.+?)-manual-\d{8}-\d{6}(?:-[a-z0-9]+)?$")

_TERMINAL_STATES = frozenset({"succeeded", "failed"})


def _metadata(obj: dict[str, Any]) -> dict[str, Any]:
    return obj.get("metadata") or {}


def _status(obj: dict[str, Any]) -> dict[str, Any]:
    return obj.get("status") or {}


def _pod_template(job: dict[str, Any]) -> dict[str, Any]:
    spec = job.get("spec") or {}
    template = spec.get("template") or {}
    return template.get("spec") or {}


def owning_cronjob(job: dict[str, Any]) -> str:
    """The CronJob a Job belongs to, as best it can be determined.

    Three sources, in decreasing order of authority:

    1. ``ownerReferences`` - what the CronJob controller sets on the Jobs its
       own schedule creates. This is the only one that is always right, but it
       is absent on Jobs created by hand.
    2. The ``app.kubernetes.io/name`` label, which this front end stamps on the
       Jobs it starts. It has to: a copied job template carries the pod labels
       but not the Job's own, so nothing else would identify the parent.
    3. The name, for anything named ``<cronjob>-manual-<timestamp>``.

    ``kubectl create job --from=cronjob/X`` produces none of these, so a Job
    started that way is still identified by its ``packer.io/project`` label in
    :func:`build_project`. A Job with neither is simply a run with no CronJob
    behind it, and the UI shows it as such rather than hiding it.
    """
    meta = _metadata(job)
    for reference in meta.get("ownerReferences") or []:
        if reference.get("kind") == "CronJob" and reference.get("name"):
            return str(reference["name"])
    labels = meta.get("labels") or {}
    named = labels.get("app.kubernetes.io/name")
    if named:
        return str(named)
    match = _MANUAL_NAME.match(str(meta.get("name") or ""))
    if match:
        return match.group(1)
    return ""


def build_project(job: dict[str, Any]) -> str:
    """What a Job builds: its project label, else its CronJob's name."""
    labels = _metadata(job).get("labels") or {}
    project = labels.get(PROJECT_LABEL)
    if project:
        return str(project)
    cronjob = owning_cronjob(job)
    if cronjob.startswith(PROJECT_PREFIX):
        return cronjob[len(PROJECT_PREFIX) :]
    return cronjob


def container_names(job: dict[str, Any], key: str) -> list[str]:
    """Names of the regular or init containers in a Job's pod template."""
    return [
        container.get("name", "")
        for container in (_pod_template(job).get(key) or [])
        if container.get("name")
    ]


def default_container(job: dict[str, Any]) -> str:
    """The container whose log a person most likely wants.

    That is the last regular container: the build itself runs in it, while the
    ones before it are sidecars. The init containers are deliberately not
    eligible - they are offered separately because their logs matter only when
    the setup step went wrong, such as a failed repository clone.
    """
    regular = container_names(job, "containers")
    return regular[-1] if regular else ""


def build_parameters(job: dict[str, Any]) -> dict[str, str]:
    """The whitelisted environment of the main container.

    Reads only literal ``value`` entries. Anything sourced from a Secret or a
    ConfigMap (``valueFrom``) has no value in the spec and is skipped - which
    is the point: the Packer credentials never reach this dict.
    """
    target = default_container(job)
    for container in _pod_template(job).get("containers") or []:
        if container.get("name") != target:
            continue
        parameters: dict[str, str] = {}
        for entry in container.get("env") or []:
            name = entry.get("name")
            value = entry.get("value")
            if name in INTERESTING_ENV and isinstance(value, str):
                parameters[name] = value
        return parameters
    return {}


def _condition(conditions: list[dict[str, Any]], wanted: str) -> dict[str, Any] | None:
    for condition in conditions or []:
        if condition.get("type") == wanted and str(condition.get("status")) == "True":
            return condition
    return None


def _scheduling_problem(pods: list[dict[str, Any]]) -> tuple[str, str] | None:
    """The scheduler's refusal for the first pod it will not place."""
    for pod in pods:
        for condition in _status(pod).get("conditions") or []:
            if condition.get("type") != "PodScheduled":
                continue
            if str(condition.get("status")) != "False":
                continue
            if condition.get("reason") != "Unschedulable":
                continue
            message = str(condition.get("message") or "").strip()
            return ("Unschedulable", message or "the scheduler will not place this pod")
    return None


def _pod_summary(pods: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Describe the pod a Job is currently running, if there is one.

    A retried Job can have several pods; the newest is the one that matters,
    which is also the one the logs come from.
    """
    if not pods:
        return None
    newest = max(
        pods,
        key=lambda pod: str(_metadata(pod).get("creationTimestamp") or ""),
    )
    status = _status(newest)
    statuses = status.get("containerStatuses") or []
    restarts = sum(int((entry.get("restartCount") or 0)) for entry in statuses)
    ready = bool(statuses) and all(entry.get("ready") for entry in statuses)
    return {
        "name": _metadata(newest).get("name", ""),
        "phase": status.get("phase", ""),
        "nodeName": (newest.get("spec") or {}).get("nodeName", ""),
        "ready": ready,
        "restarts": restarts,
        "startTime": status.get("startTime", ""),
    }


def derive_state(job: dict[str, Any], pods: list[dict[str, Any]] | None) -> tuple[str, str, str]:
    """Return ``(state, reason, message)`` for a Job.

    ``reason`` is a short machine-ish token, ``message`` is the sentence worth
    showing a person. Both are empty when there is nothing to say.
    """
    status = _status(job)
    conditions = status.get("conditions") or []

    if _condition(conditions, "Complete") is not None:
        return ("succeeded", "Complete", "")
    failed = _condition(conditions, "Failed")
    if failed is not None:
        reason = str(failed.get("reason") or "Failed")
        message = str(failed.get("message") or "").strip()
        return ("failed", reason, message)

    problem = _scheduling_problem(pods or [])
    if problem is not None:
        return ("blocked", problem[0], problem[1])

    active = int(status.get("active") or 0)
    if active > 0:
        return ("running", "Active", "")
    if status.get("startTime"):
        # Started but nothing active and no terminal condition yet: the pod is
        # being created, or was just deleted and the controller is reacting.
        return ("running", "Starting", "")
    return ("pending", "Queued", "")


def summarise_run(
    job: dict[str, Any],
    pods: list[dict[str, Any]] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Turn a Job object into the run dictionary the API returns."""
    meta = _metadata(job)
    status = _status(job)
    spec = job.get("spec") or {}
    labels = dict(meta.get("labels") or {})
    annotations = dict(meta.get("annotations") or {})

    state, reason, message = derive_state(job, pods)

    started = parse_timestamp(status.get("startTime"))
    finished = parse_timestamp(status.get("completionTime"))
    moment = now or datetime.now(timezone.utc)
    duration = (
        seconds_between(started, finished)
        if finished is not None
        else elapsed_since(started, moment)
    )

    cronjob = owning_cronjob(job)
    project = build_project(job)

    return {
        "name": meta.get("name", ""),
        "namespace": meta.get("namespace", ""),
        "cronjob": cronjob,
        "project": project,
        "family": labels.get(FAMILY_LABEL) or "",
        "state": state,
        "stateReason": reason,
        "stateMessage": message,
        "createdAt": meta.get("creationTimestamp") or "",
        "startTime": status.get("startTime") or "",
        "completionTime": status.get("completionTime") or "",
        "durationSeconds": duration,
        "active": int(status.get("active") or 0),
        "succeeded": int(status.get("succeeded") or 0),
        "failed": int(status.get("failed") or 0),
        "manual": is_manual_run(labels, annotations),
        "labels": labels,
        "annotations": annotations,
        "backoffLimit": spec.get("backoffLimit"),
        "activeDeadlineSeconds": spec.get("activeDeadlineSeconds"),
        "ttlSecondsAfterFinished": spec.get("ttlSecondsAfterFinished"),
        "containers": container_names(job, "containers"),
        "initContainers": container_names(job, "initContainers"),
        "defaultContainer": default_container(job),
        "parameters": build_parameters(job),
        "pod": _pod_summary(pods or []),
        "deletionTimestamp": meta.get("deletionTimestamp") or "",
    }


def is_terminal(run: dict[str, Any]) -> bool:
    """Whether a run has finished, one way or the other."""
    return run.get("state") in _TERMINAL_STATES


def sort_key(run: dict[str, Any]) -> str:
    """Newest first, using the same string the API sorts by."""
    return str(run.get("createdAt") or "")
