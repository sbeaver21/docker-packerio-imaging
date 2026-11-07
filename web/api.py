"""The JSON API the browser talks to.

Everything a page needs comes from one call, ``GET /api/overview``. A dashboard
that fetched projects, runs and capacity separately would show three
inconsistent snapshots for a moment on every refresh, and the moment when the
run list is one poll behind the project list is precisely when someone decides
a build did not start.

The routes below are thin: they shape the response and translate errors into
status codes. The work is in :mod:`projects` and :mod:`runs`, which are pure
functions over the dictionaries :mod:`kube` returns.
"""

from __future__ import annotations

from datetime import datetime, timezone
from functools import wraps
from typing import Any, Callable

from flask import Blueprint, Response, jsonify, request
from flask.typing import ResponseReturnValue

import quantities
from kube import Gateway, KubernetesRequestFailed, KubernetesUnavailable, NotFound
from projects import group_runs, project_name, sort_projects, summarise_project
from runs import summarise_run
from services import current_services

bp = Blueprint("api", __name__, url_prefix="/api")

#: The quota keys worth showing, with the label each one gets.
#: ``pods`` first because that is what a stuck build runs out of.
CAPACITY_RESOURCES: tuple[tuple[str, str], ...] = (
    ("pods", "Pods"),
    ("requests.cpu", "CPU requested"),
    ("requests.memory", "Memory requested"),
    ("limits.cpu", "CPU limit"),
    ("limits.memory", "Memory limit"),
    ("count/jobs.batch", "Jobs"),
)

_TERMINAL_CONDITIONS = ("Complete", "Failed")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _error(message: str, status: int = 400) -> tuple[Response, int]:
    return jsonify({"error": message}), status


def _writes_enabled() -> bool:
    return current_services().settings.can_mutate


def requires_write(view: Callable[..., ResponseReturnValue]) -> Callable[..., ResponseReturnValue]:
    """Refuse a mutating view on a read-only deployment."""

    @wraps(view)
    def wrapper(*args: Any, **kwargs: Any) -> ResponseReturnValue:
        if not _writes_enabled():
            return _error(
                "this deployment is read-only: builds cannot be started, runs "
                "cannot be deleted and schedules cannot be changed",
                403,
            )
        return view(*args, **kwargs)

    return wrapper


# ---------------------------------------------------------------------------
# Collecting a snapshot
# ---------------------------------------------------------------------------


def _job_is_finished(job: dict[str, Any]) -> bool:
    """Whether a Job already has a terminal condition."""
    for condition in (job.get("status") or {}).get("conditions") or []:
        if condition.get("type") in _TERMINAL_CONDITIONS:
            if str(condition.get("status")) == "True":
                return True
    return False


def _pods_for_unfinished(gateway: Gateway, jobs: list[dict[str, Any]]) -> dict[str, list]:
    """Pods for the Jobs that have not finished.

    Only unfinished Jobs are looked at: a finished Job's pods cannot be
    unschedulable, and asking for them on every poll would multiply the API
    calls by the size of the build history for no answer.
    """
    pods: dict[str, list] = {}
    for job in jobs:
        if _job_is_finished(job):
            continue
        name = str((job.get("metadata") or {}).get("name") or "")
        if not name:
            continue
        try:
            pods[name] = gateway.pods_for_job(name)
        except KubernetesRequestFailed:
            # A pod list that cannot be read is not a reason to fail the whole
            # page: the run simply cannot be classified as blocked.
            pods[name] = []
    return pods


def _summarise_orphans(orphans: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One card per CronJob that has runs but no definition left.

    A project whose CronJob was deleted keeps its finished Jobs until their TTL
    removes them. Those belong on the page - someone may still be waiting on
    one - but they cannot be started again, so they are marked ``orphan`` and
    rendered without a Build button.
    """
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in orphans:
        # Keyed by whatever identifies the run: its CronJob when it has one,
        # otherwise its project label, otherwise a marker so that a run with
        # neither still gets a card rather than disappearing.
        key = str(run.get("cronjob") or run.get("project") or "unassigned")
        grouped.setdefault(key, []).append(run)

    cards = []
    for key, group in grouped.items():
        latest = max(group, key=lambda run: str(run.get("createdAt") or ""))
        cards.append(
            {
                "name": latest.get("cronjob") or "",
                "project": latest.get("project") or key,
                "family": latest.get("family") or "",
                "health": "orphan",
                "runCount": len(group),
            }
        )
    return sort_projects(cards)


def _capacity(gateway: Gateway) -> dict[str, Any]:
    """The namespace quota, shaped for a progress bar.

    One quota is normally defined per namespace in this repository, so the
    values from every quota are merged: a key present in two of them keeps the
    tightest hard limit, which is the one that will actually stop a pod.
    """
    quotas = gateway.quota_usage()
    hard_by_key: dict[str, str] = {}
    used_by_key: dict[str, str] = {}
    for quota in quotas:
        for key, value in (quota.get("hard") or {}).items():
            existing = quantities.parse(hard_by_key.get(key))
            candidate = quantities.parse(value)
            if existing is None or (candidate is not None and candidate.value < existing.value):
                hard_by_key[key] = value
        for key, value in (quota.get("used") or {}).items():
            current = quantities.parse(used_by_key.get(key))
            candidate = quantities.parse(value)
            if current is None or (candidate is not None and candidate.value > current.value):
                used_by_key[key] = value

    resources: list[dict[str, Any]] = []
    for key, label in CAPACITY_RESOURCES:
        if key not in hard_by_key:
            continue
        hard = hard_by_key[key]
        used = used_by_key.get(key, "0")
        percent = quantities.percent_used(used, hard)
        resources.append(
            {
                "key": key,
                "label": label,
                "used": quantities.humanise(used),
                "hard": quantities.humanise(hard),
                "percent": percent,
                # A quota at its limit is not an error, but it is the reason a
                # run will sit in "blocked", so the UI marks it.
                "saturated": percent is not None and percent >= 100,
            }
        )

    return {
        "quotas": [quota.get("name", "") for quota in quotas],
        "resources": resources,
        "podsUsed": used_by_key.get("pods", ""),
        "podsHard": hard_by_key.get("pods", ""),
    }


def _attach_runs_to_projects(
    runs: list[dict[str, Any]], cronjobs: list[dict[str, Any]]
) -> None:
    """Give an unowned run the CronJob it almost certainly belongs to.

    A Job started from the terminal with
    ``kubectl create job --from=cronjob/X`` carries no ``ownerReferences`` and
    no ``app.kubernetes.io/name`` - only ``packer.io/project``. Without this it
    would be shown as an orphan even though the CronJob that defines it is
    right there.

    Matching on that label is a heuristic, so it is deliberately narrow: it
    applies only when the run names no CronJob at all, and only when exactly
    one CronJob claims that project. A project claimed by two is left alone
    rather than guessed at.
    """
    owners: dict[str, str] = {}
    ambiguous: set[str] = set()
    names: set[str] = set()
    for cronjob in cronjobs:
        name = str((cronjob.get("metadata") or {}).get("name") or "")
        if not name:
            continue
        names.add(name)
        project = project_name(cronjob)
        if not project:
            continue
        if project in owners:
            ambiguous.add(project)
        else:
            owners[project] = name

    for run in runs:
        if str(run.get("cronjob") or "") in names:
            continue
        project = str(run.get("project") or "")
        if project in ambiguous:
            continue
        matched = owners.get(project)
        if matched:
            run["cronjob"] = matched


def _snapshot() -> dict[str, Any]:
    """Read the cluster once and return everything the dashboard shows.

    Raises :class:`KubernetesUnavailable` when there is no client, which the
    error handler turns into a 503 with the reason in it.
    """
    gateway = current_services().gateway
    gateway.require()
    moment = _now()

    cronjobs = gateway.list_cronjobs()
    jobs = gateway.list_jobs()
    pods_by_job = _pods_for_unfinished(gateway, jobs)

    runs = [
        summarise_run(
            job,
            pods_by_job.get(str((job.get("metadata") or {}).get("name") or ""), []),
            moment,
        )
        for job in jobs
    ]
    runs.sort(key=lambda run: str(run.get("createdAt") or ""), reverse=True)

    _attach_runs_to_projects(runs, cronjobs)

    by_cronjob = group_runs(runs)
    projects = sort_projects(
        [
            summarise_project(
                cronjob,
                by_cronjob.get(str((cronjob.get("metadata") or {}).get("name") or ""), []),
            )
            for cronjob in cronjobs
        ]
    )

    # Runs that no CronJob claims: a pipeline run, or a Job someone made by
    # hand. They are shown rather than dropped, because a run that is invisible
    # in the UI is worse than one with no project card.
    known = {project["name"] for project in projects}
    orphans = [run for run in runs if run.get("cronjob") not in known]
    orphan_projects = _summarise_orphans(orphans)

    return {
        "namespace": gateway.namespace,
        "serverVersion": gateway.server_version,
        "generatedAt": moment.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "canMutate": current_services().settings.can_mutate,
        "refreshSeconds": current_services().settings.refresh_seconds,
        "projects": projects,
        "runs": runs,
        "orphanRuns": orphans,
        "orphanProjects": orphan_projects,
        "capacity": _capacity(gateway),
        "counts": {
            "projects": len(projects),
            "runs": len(runs),
            "active": sum(
                1 for run in runs if run.get("state") in {"running", "blocked", "pending"}
            ),
        },
    }


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


@bp.errorhandler(KubernetesUnavailable)
def _handle_unavailable(exc: KubernetesUnavailable) -> tuple[Response, int]:
    return _error(str(exc), 503)


@bp.errorhandler(NotFound)
def _handle_not_found(exc: NotFound) -> tuple[Response, int]:
    return _error(str(exc), 404)


@bp.errorhandler(KubernetesRequestFailed)
def _handle_request_failed(exc: KubernetesRequestFailed) -> tuple[Response, int]:
    # A refusal the API server made for a reason the caller can act on (403,
    # 409, 422) is passed through; anything else means the cluster is not
    # answering, which is a bad gateway, not a bad request.
    status = exc.status if 400 <= exc.status < 500 else 502
    return _error(str(exc), status)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@bp.get("/health")
def health() -> Response:
    """Liveness and connectivity, in one request.

    Always 200: this is what the container's probe calls, and a probe that
    fails because the cluster is unreachable would restart a web server that is
    working perfectly and simply has nothing to show.
    """
    services = current_services()
    gateway = services.gateway
    return jsonify(
        {
            "status": "ok" if gateway.connected else "degraded",
            "kubernetes": "connected" if gateway.connected else "unavailable",
            "error": gateway.error,
            "namespace": services.settings.namespace,
            "serverVersion": gateway.server_version,
            "canMutate": services.settings.can_mutate,
            "refreshSeconds": services.settings.refresh_seconds,
            "utc": _now().strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
    )


@bp.get("/overview")
def overview() -> Response:
    """Everything the dashboard needs, from one consistent read."""
    return jsonify(_snapshot())


@bp.get("/projects")
def list_projects() -> Response:
    snapshot = _snapshot()
    return jsonify(
        {
            "namespace": snapshot["namespace"],
            "projects": snapshot["projects"],
            "orphanProjects": snapshot["orphanProjects"],
            "generatedAt": snapshot["generatedAt"],
        }
    )


@bp.get("/projects/<name>")
def get_project(name: str) -> Response:
    """One project, with its run history."""
    gateway = current_services().gateway
    gateway.require()
    cronjob = gateway.get_cronjob(name)
    snapshot = _snapshot()
    runs = [run for run in snapshot["runs"] if run.get("cronjob") == name]
    project = summarise_project(cronjob, runs)
    return jsonify({"project": project, "runs": runs})


@bp.post("/projects/<name>/runs")
@requires_write
def start_run(name: str) -> ResponseReturnValue:
    """Start one run of a build project, now.

    Returns 202: the Job exists and the request is done, but the build itself
    has only been asked for. Its state arrives on the next poll.
    """
    gateway = current_services().gateway
    gateway.require()
    job = gateway.create_job_from_cronjob(name)
    run = summarise_run(job, [], _now())
    return (
        jsonify(
            {
                "run": run,
                "message": f"Build started: {run['name']}",
            }
        ),
        202,
    )


@bp.patch("/projects/<name>")
@requires_write
def update_project(name: str) -> ResponseReturnValue:
    """Pause or resume a project's schedule.

    Only ``suspend`` is accepted. Rejecting anything else rather than ignoring
    it means a typo in the browser is reported, not silently swallowed.
    """
    body = request.get_json(silent=True) or {}
    if "suspend" not in body:
        return _error("expected a JSON body with a boolean 'suspend'", 400)
    if not isinstance(body["suspend"], bool):
        return _error("'suspend' must be true or false", 400)
    gateway = current_services().gateway
    gateway.require()
    cronjob = gateway.set_cronjob_suspended(name, body["suspend"])
    verb = "paused" if body["suspend"] else "resumed"
    return jsonify(
        {
            "project": summarise_project(cronjob, []),
            "message": f"Schedule {verb} for '{name}'",
        }
    )


@bp.get("/runs")
def list_runs() -> Response:
    snapshot = _snapshot()
    return jsonify(
        {
            "namespace": snapshot["namespace"],
            "runs": snapshot["runs"],
            "generatedAt": snapshot["generatedAt"],
        }
    )


@bp.get("/runs/<name>")
def get_run(name: str) -> Response:
    gateway = current_services().gateway
    gateway.require()
    job = gateway.get_job(name)
    pods = gateway.pods_for_job(name)
    run = summarise_run(job, pods, _now())
    return jsonify({"run": run, "pods": pods})


@bp.get("/runs/<name>/logs")
def get_run_logs(name: str) -> Response:
    """Logs for one container of a run.

    ``tail`` is clamped, not rejected: a browser asking for more than allowed
    should get an answer, not an error it has to explain to the user.
    """
    services = current_services()
    gateway = services.gateway
    gateway.require()
    settings = services.settings
    tail = request.args.get("tail", type=int) or settings.log_tail_default
    tail = max(50, min(20000, tail))
    container = (request.args.get("container") or "").strip()
    result = gateway.pod_logs(name, container=container, tail=tail)
    result["job"] = name
    return jsonify(result)


@bp.delete("/runs/<name>")
@requires_write
def delete_run(name: str) -> ResponseReturnValue:
    gateway = current_services().gateway
    gateway.require()
    gateway.delete_job(name)
    return jsonify({"message": f"Run '{name}' deleted"}), 202


@bp.get("/capacity")
def capacity() -> Response:
    gateway = current_services().gateway
    gateway.require()
    return jsonify(_capacity(gateway))
