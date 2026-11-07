"""The HTML side: three pages, and a plain-text probe.

The application is three pages rather than one long scroll, because they answer
three different questions and are used at different moments:

``/``       what state is the namespace in, and is anything wrong right now
``/build``  start a run, or pause a schedule
``/runs``   what happened - the run list, logs, and deleting a run

Every page is a shell. Everything inside it is drawn from ``/api/overview`` by
that page's own script, so nothing the server renders comes from Kubernetes and
no page has a template that knows about projects or runs. That keeps every
escaping decision in one place: the browser uses ``textContent`` and
``document.createElement``, never ``innerHTML`` with a value from the cluster.

The pages share ``templates/base.html``, which owns the top bar, the navigation
and the theme. Adding a page means a template that extends it plus one entry in
:data:`PAGES`.
"""

from __future__ import annotations

from flask import Blueprint, Response, render_template

from services import current_services

bp = Blueprint("pages", __name__)

#: page id -> (template, browser script, window title).
#:
#: The page id is also what ``body[data-page]`` carries and what the stylesheet
#: and the nav use, so one name per page is enough.
PAGES: dict[str, tuple[str, str, str]] = {
    "landing": ("landing.html", "landing.js", "Overview"),
    "build": ("build.html", "build.js", "Build"),
    "runs": ("runs.html", "runs.js", "Runs"),
}


def _render(page: str) -> str:
    """Render one page's shell.

    The values baked into the HTML are the ones needed before the first API call
    returns, so a page does not have to flash an empty state while it waits.
    """
    template, script, title = PAGES[page]
    settings = current_services().settings
    return render_template(
        template,
        page=page,
        page_title=title,
        page_script=script,
        namespace=settings.namespace,
        refresh_seconds=settings.refresh_seconds,
        can_mutate=settings.can_mutate,
        log_tail=settings.log_tail_default,
    )


@bp.get("/")
def landing() -> str:
    """The overview: counts, capacity, what needs attention, latest runs."""
    return _render("landing")


@bp.get("/build")
def build() -> str:
    """The build projects, with the controls that start and pause them."""
    return _render("build")


@bp.get("/runs")
def runs() -> str:
    """Every run, with filters, logs and delete.

    The filters are read from the query string by ``static/runs.js`` rather than
    here: they only change what is shown, never what is fetched, so a link such
    as ``/runs?project=aria-build-photon-5&show=failed`` is just this page.
    """
    return _render("runs")


@bp.get("/healthz")
def healthz() -> Response:
    """A probe with no dependencies.

    Separate from ``/api/health`` on purpose: the liveness probe must answer
    "is the web server running", and the moment it also answers "is the cluster
    reachable" it starts restarting a healthy server for an unrelated outage.
    """
    return Response("ok\n", mimetype="text/plain")
