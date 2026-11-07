"""A CronJob, described as the build project a user sees.

One CronJob is one thing a user can ask for: "rebuild the Photon OS 5
template". Everything a person needs in order to decide whether to press the
button belongs here - when it last ran, whether that worked, how it is
scheduled, and what it will actually build - so the browser does not have to
join anything together itself.

The ``health`` field collapses the run history into the one thing a user
glances at:

``ok``         the last run succeeded
``failing``    the last run failed
``running``    a run is in progress right now
``suspended``  the schedule is disabled, so nothing will start by itself
``never``      it has never run
"""

from __future__ import annotations

from typing import Any

from naming import FAMILY_LABEL, PROJECT_LABEL
from runs import PROJECT_PREFIX

#: Annotation this repository uses to say what a project is for.
PURPOSE_ANNOTATION = "aria-automation/purpose"

#: Environment variables worth showing: they say what a build produces.
BUILD_PARAMETER_NAMES = ("PACKER_PROJECT", "PACKER_BUILD_ARGS", "GIT_REF")

_ACTIVE_STATES = frozenset({"running", "blocked", "pending"})


def _metadata(obj: dict[str, Any]) -> dict[str, Any]:
    return obj.get("metadata") or {}


def _spec(obj: dict[str, Any]) -> dict[str, Any]:
    return obj.get("spec") or {}


def _job_template(cronjob: dict[str, Any]) -> dict[str, Any]:
    return _spec(cronjob).get("jobTemplate") or {}


def _pod_spec(cronjob: dict[str, Any]) -> dict[str, Any]:
    """The pod template, buried at ``jobTemplate.spec.template.spec``.

    Three levels, not two: ``jobTemplate`` has its own ``spec`` (the Job's) and
    the pod template is inside that. Reaching for ``jobTemplate.template``
    finds nothing, which silently reports a project with no containers, no
    volumes and therefore no required Secrets - an empty card rather than an
    error, which is the worst way for this to fail.
    """
    job_spec = _job_template(cronjob).get("spec") or {}
    template = job_spec.get("template") or {}
    return template.get("spec") or {}


def project_name(cronjob: dict[str, Any]) -> str:
    """What the project builds, from the labels then the CronJob's name.

    ``packer.io/project`` is set on the job template in every CronJob in this
    repository, so the label is normally enough. The name is the fallback for a
    CronJob someone added without following the convention - a slightly ugly
    project name beats an empty column.
    """
    template_labels = (_job_template(cronjob).get("metadata") or {}).get("labels") or {}
    cronjob_labels = _metadata(cronjob).get("labels") or {}
    for source in (template_labels, cronjob_labels):
        value = source.get(PROJECT_LABEL)
        if value:
            return str(value)
    name = str(_metadata(cronjob).get("name") or "")
    if name.startswith(PROJECT_PREFIX):
        return name[len(PROJECT_PREFIX) :]
    return name


def family_name(cronjob: dict[str, Any]) -> str:
    """``linux``, ``windows``, or nothing if the CronJob does not say."""
    template_labels = (_job_template(cronjob).get("metadata") or {}).get("labels") or {}
    cronjob_labels = _metadata(cronjob).get("labels") or {}
    for source in (template_labels, cronjob_labels):
        value = source.get(FAMILY_LABEL)
        if value:
            return str(value)
    return ""


def required_secrets(cronjob: dict[str, Any]) -> list[str]:
    """Secrets the pod cannot start without.

    Both ways a build job gets a Secret are used in this repository: a volume
    (``pkrvars-<project>``) and ``envFrom`` (``aria-repo-credentials`` on the
    checkout init container). A missing one leaves the pod Pending for ever
    with a message that says so - worth showing before the user presses Build,
    not after.
    """
    pod = _pod_spec(cronjob)
    names: list[str] = []
    for volume in pod.get("volumes") or []:
        secret = volume.get("secret") or {}
        name = secret.get("secretName")
        # ``optional: true`` means the pod starts without it by design.
        if name and not secret.get("optional"):
            names.append(str(name))
    for container in (pod.get("initContainers") or []) + (pod.get("containers") or []):
        for source in container.get("envFrom") or []:
            reference = source.get("secretRef") or {}
            name = reference.get("name")
            if name and not reference.get("optional"):
                names.append(str(name))
    return sorted(set(names))


def required_config_maps(cronjob: dict[str, Any]) -> list[str]:
    """ConfigMaps mounted into the pod, which is how its scripts arrive."""
    pod = _pod_spec(cronjob)
    names: list[str] = []
    for volume in pod.get("volumes") or []:
        config_map = volume.get("configMap") or {}
        name = config_map.get("name")
        if name and not config_map.get("optional"):
            names.append(str(name))
    return sorted(set(names))


def template_parameters(cronjob: dict[str, Any]) -> dict[str, str]:
    """The build parameters declared on the CronJob's own container.

    A whitelist, and only literal ``value`` entries: anything from a Secret or
    a ConfigMap has no value in the spec and is skipped, which is the point -
    the Packer credentials never reach the browser.
    """
    containers = _pod_spec(cronjob).get("containers") or []
    if not containers:
        return {}
    found: dict[str, str] = {}
    for entry in containers[-1].get("env") or []:
        name = entry.get("name")
        value = entry.get("value")
        if name in BUILD_PARAMETER_NAMES and isinstance(value, str):
            found[name] = value
    return found


def project_health(runs: list[dict[str, Any]], suspended: bool) -> str:
    """The one-word state of a project, from its runs and its schedule.

    A live run wins over everything: a project whose schedule has been paused
    while a build is still going is not "suspended" to the person watching it.
    """
    if any(run.get("state") in _ACTIVE_STATES for run in runs):
        return "running"
    if suspended:
        return "suspended"
    if not runs:
        return "never"
    latest = max(runs, key=lambda run: str(run.get("createdAt") or ""))
    return "ok" if latest.get("state") == "succeeded" else "failing"


def summarise_project(
    cronjob: dict[str, Any],
    runs: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Turn a CronJob and its runs into the project dictionary the API returns.

    ``runs`` must already be summarised and already filtered to this CronJob -
    see :func:`group_runs`. Doing the join in the caller keeps this function
    free of any Kubernetes access and therefore testable as a pure function.
    """
    meta = _metadata(cronjob)
    spec = _spec(cronjob)
    status = cronjob.get("status") or {}
    ordered = sorted(
        runs or [], key=lambda run: str(run.get("createdAt") or ""), reverse=True
    )

    suspended = bool(spec.get("suspend", False))
    active = [run for run in ordered if run.get("state") in _ACTIVE_STATES]

    return {
        "name": meta.get("name", ""),
        "namespace": meta.get("namespace", ""),
        "project": project_name(cronjob),
        "family": family_name(cronjob),
        "purpose": (meta.get("annotations") or {}).get(PURPOSE_ANNOTATION, ""),
        "schedule": spec.get("schedule", ""),
        "timezone": spec.get("timeZone", "") or spec.get("timezone", ""),
        "suspend": suspended,
        "concurrencyPolicy": spec.get("concurrencyPolicy", ""),
        "startingDeadlineSeconds": spec.get("startingDeadlineSeconds"),
        "successfulJobsHistoryLimit": spec.get("successfulJobsHistoryLimit"),
        "failedJobsHistoryLimit": spec.get("failedJobsHistoryLimit"),
        "lastScheduleTime": status.get("lastScheduleTime", ""),
        "createdAt": meta.get("creationTimestamp", ""),
        "health": project_health(ordered, suspended),
        "latestRun": ordered[0] if ordered else None,
        "lastSuccess": next(
            (run for run in ordered if run.get("state") == "succeeded"), None
        ),
        "lastFailure": next(
            (run for run in ordered if run.get("state") == "failed"), None
        ),
        "activeRuns": len(active),
        "runCount": len(ordered),
        "parameters": template_parameters(cronjob),
        "containers": [
            container.get("name", "")
            for container in _pod_spec(cronjob).get("containers") or []
            if container.get("name")
        ],
        "initContainers": [
            container.get("name", "")
            for container in _pod_spec(cronjob).get("initContainers") or []
            if container.get("name")
        ],
        "requiredSecrets": required_secrets(cronjob),
        "requiredConfigMaps": required_config_maps(cronjob),
        "annotations": dict(meta.get("annotations") or {}),
        "labels": dict(meta.get("labels") or {}),
    }


def group_runs(runs: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """Index already-summarised runs by the CronJob they belong to."""
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        cronjob = str(run.get("cronjob") or "")
        grouped.setdefault(cronjob, []).append(run)
    return grouped


def sort_projects(projects: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Family, then project name: the order the cards are read in.

    ``zzz`` for a project with no family sorts those last rather than first,
    which would be the result of sorting on an empty string.
    """
    return sorted(
        projects,
        key=lambda project: (
            str(project.get("family") or "zzz"),
            str(project.get("project") or ""),
        ),
    )
