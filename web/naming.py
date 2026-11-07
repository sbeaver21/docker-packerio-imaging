"""Names and labels for a manual run.

``kubectl create job --from=cronjob/X Y`` is the behaviour this module
reproduces, because the pipeline uses exactly that command and a run started
from the browser has to be indistinguishable from one started from a terminal.

What ``kubectl`` does that a naive copy of ``jobTemplate.spec`` does not:

  * gives the Job a name of its own, since the template has none;
  * stamps ``cronjob.kubernetes.io/instantiate: manual`` on it, which is how a
    person later tells an on-demand run apart from a scheduled one;
  * clears the object metadata that cannot be re-submitted
    (``resourceVersion``, ``uid``, ``creationTimestamp``, ``managedFields``);
  * leaves ``spec.selector`` unset so the Job controller generates one from the
    pod template's labels. Copying a selector would be copied from a Job that
    already exists and would collide.

Kubernetes object names are DNS-1123 labels: lowercase alphanumerics and
``-``, starting and ending alphanumeric, at most 63 characters.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone

#: Kubernetes' limit for most object names, including Jobs.
MAX_NAME_LENGTH = 63

#: The label and annotation that mark a Job as an on-demand instantiation.
INSTANTIATE_KEY = "cronjob.kubernetes.io/instantiate"
INSTANTIATE_VALUE = "manual"

#: Set by this front end so the source of a run is visible in ``kubectl get``.
CREATED_BY_KEY = "aria-automation/created-by"
CREATED_BY_VALUE = "web-frontend"

#: Labels copied from a CronJob that describe what a run builds.
PROJECT_LABEL = "packer.io/project"
FAMILY_LABEL = "packer.io/family"

_INVALID_NAME_CHARS = re.compile(r"[^a-z0-9-]+")
_REPEATED_DASHES = re.compile(r"-{2,}")


def sanitize_name(value: str) -> str:
    """Coerce ``value`` into a DNS-1123 label, never returning an empty string.

    Used for the pieces a Job name is built from. ``"Photon 5"`` becomes
    ``"photon-5"``; anything that sanitises to nothing becomes ``"build"`` so
    the caller still has a usable stem.
    """
    lowered = (value or "").strip().lower()
    replaced = _INVALID_NAME_CHARS.sub("-", lowered)
    collapsed = _REPEATED_DASHES.sub("-", replaced).strip("-")
    return collapsed or "build"


def _timestamp_suffix(moment: datetime) -> str:
    """``20261026-150800`` - sortable, and unambiguous in a list of runs."""
    return moment.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%S")


def build_run_name(
    cronjob_name: str,
    moment: datetime | None = None,
    discriminator: str = "",
) -> str:
    """Name for an on-demand Job started from ``cronjob_name``.

    ``discriminator`` exists because two clicks inside the same second would
    otherwise produce the same name and the second would be rejected with a
    409. The caller passes a short token and retries with another one.

    The result is always a valid, non-empty DNS-1123 label of at most 63
    characters - the CronJob's own name is trimmed if the timestamp would push
    it over.
    """
    when = moment or datetime.now(timezone.utc)
    stem = sanitize_name(cronjob_name)
    suffix = f"-manual-{_timestamp_suffix(when)}"
    if discriminator:
        suffix = f"{suffix}-{sanitize_name(discriminator)}"

    room = MAX_NAME_LENGTH - len(suffix)
    if room < 1:
        # The suffix alone is 22 characters, so this cannot happen with a real
        # CronJob; trimming anyway keeps the function total.
        return suffix.lstrip("-")[:MAX_NAME_LENGTH]
    trimmed = stem[:room].rstrip("-")
    return f"{trimmed or 'build'}{suffix}"


def instantiate_labels(base_labels: dict[str, str] | None) -> dict[str, str]:
    """Labels for a manual run: the template's, plus the manual-run marker."""
    labels = dict(base_labels or {})
    labels[INSTANTIATE_KEY] = INSTANTIATE_VALUE
    labels[CREATED_BY_KEY] = CREATED_BY_VALUE
    return labels


def instantiate_annotations(base_annotations: dict[str, str] | None) -> dict[str, str]:
    """Annotations for a manual run.

    ``cronjob.kubernetes.io/instantiate`` is also recorded as an annotation
    because that is what ``kubectl`` writes, and tooling (and people) look for
    it in both places.
    """
    annotations = dict(base_annotations or {})
    annotations[INSTANTIATE_KEY] = INSTANTIATE_VALUE
    return annotations


def is_manual_run(labels: dict[str, str] | None, annotations: dict[str, str] | None) -> bool:
    """Whether a Job was started on demand rather than by its schedule."""
    for source in (labels or {}, annotations or {}):
        if source.get(INSTANTIATE_KEY) == INSTANTIATE_VALUE:
            return True
    return False
