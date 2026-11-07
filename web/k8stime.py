"""Timestamps as the Kubernetes API writes them, and as the UI wants them.

The API server emits RFC 3339 in UTC with a trailing ``Z`` and optional
fractional seconds. Everything this front end parses comes from there, and
everything it emits is the same shape so the browser can sort runs as strings
when it needs to.

Kept apart from the summary modules because both of them need it and neither
should have to import the other to get it.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


def parse_timestamp(value: Any) -> datetime | None:
    """Parse an API timestamp, returning ``None`` for anything unreadable.

    ``None`` rather than an exception: a Job that has not started yet has no
    ``startTime``, and a malformed one is not a reason to fail the whole list
    response. The caller renders an em dash for an unknown time.
    """
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    # Python 3.11+ accepts a trailing Z directly, but the explicit replacement
    # keeps this working on the 3.9/3.10 interpreter an operator may have
    # locally.
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_timestamp(moment: datetime | None) -> str | None:
    """Render a moment the way the API does, or ``None``."""
    if moment is None:
        return None
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def seconds_between(start: datetime | None, end: datetime | None) -> int | None:
    """Whole seconds from ``start`` to ``end``, or ``None`` if unknown."""
    if start is None or end is None:
        return None
    delta = (end - start).total_seconds()
    if delta < 0:
        return 0
    return int(delta)


def elapsed_since(start: datetime | None, now: datetime | None = None) -> int | None:
    """Seconds a still-running object has been running."""
    if start is None:
        return None
    return seconds_between(start, now or datetime.now(timezone.utc))
