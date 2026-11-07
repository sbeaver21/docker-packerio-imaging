"""Parse the quantity strings Kubernetes writes in its API.

A container asks for ``500m`` of CPU and ``4Gi`` of memory; a ResourceQuota
says it will allow ``16`` pods and ``32Gi`` of memory. Those are not numbers,
and comparing them needs the units resolved first.

Only two things are needed here: turn a quantity into a number of base units,
and know whether it is a decimal or a binary one so it can be printed back the
way it arrived. Nothing in this module raises on unexpected input - a quantity
the API wrote that this cannot read becomes ``None``, and the caller shows the
raw string instead of a percentage.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Kubernetes' suffixes. The binary ones (``Ki``) are powers of 1024 and the
#: decimal ones (``k``) powers of 1000 - mixing them up understates memory by
#: about 2.4% per step, which is enough to make a full namespace look empty.
_BINARY = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4, "Pi": 1024**5, "Ei": 1024**6}
_DECIMAL = {"k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18}
_SUBNORMAL = {"n": 1e-9, "u": 1e-6, "m": 1e-3}

_QUANTITY = re.compile(r"^(?P<number>[+-]?\d+(?:\.\d+)?)(?P<suffix>[A-Za-z]*)$")


@dataclass(frozen=True)
class Quantity:
    """A parsed quantity: its value in base units, and its original text."""

    value: float
    suffix: str
    raw: str

    @property
    def is_binary(self) -> bool:
        return self.suffix in _BINARY

    def ratio_to(self, other: "Quantity | None") -> float | None:
        """This value as a fraction of ``other``, clamped to ``0..1``.

        Returns ``None`` when the comparison cannot be made - an empty quota,
        or one measured in different units, where a percentage would be a
        fabrication.
        """
        if other is None or other.value <= 0:
            return None
        return max(0.0, min(1.0, self.value / other.value))


def parse(raw: str | None) -> Quantity | None:
    """Parse a Kubernetes quantity, or ``None`` if it is not one."""
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    match = _QUANTITY.match(text)
    if match is None:
        return None
    number = float(match.group("number"))
    suffix = match.group("suffix")
    if suffix in _BINARY:
        return Quantity(number * _BINARY[suffix], suffix, text)
    if suffix in _DECIMAL:
        return Quantity(number * _DECIMAL[suffix], suffix, text)
    if suffix in _SUBNORMAL:
        return Quantity(number * _SUBNORMAL[suffix], suffix, text)
    if suffix:
        # Something with a unit this module does not know, such as a percentage.
        # Reported as unparseable rather than guessed at.
        return None
    return Quantity(number, "", text)


def percent_used(used: str | None, hard: str | None) -> int | None:
    """``used`` as a whole percentage of ``hard``, or ``None``.

    Integer percentages, not floats: the caller writes this into a bar width
    and a rounded number is all it needs.
    """
    used_quantity = parse(used)
    hard_quantity = parse(hard)
    ratio = used_quantity.ratio_to(hard_quantity) if used_quantity else None
    if ratio is None:
        return None
    return int(round(ratio * 100))


def humanise(value: str | None) -> str:
    """``4Gi`` stays ``4Gi``; an unreadable quantity is shown as it arrived."""
    return str(value) if value not in (None, "") else "0"
