"""Supply Material's icon index to ``pymdownx.emoji`` without PyYAML tags.

The emoji index and generator are Python callables, so ``mkdocs.yml`` cannot
express them as plain YAML data. The usual workaround is PyYAML's
``!!python/name:`` tag, but that is a Python-specific construct: any generic
YAML parser (editor validators, ``yamllint``, ``check-yaml``, Kubernetes/CI
tooling) reports it as an unresolved tag.

This hook attaches the callables at load time instead, so the configuration
file stays parseable by every YAML tool while icon shortcodes such as
``:material-linux:``, ``:octicons-cloud-24:`` and ``:simple-ubuntu:`` still
resolve to the Material icon sets.
"""

from __future__ import annotations

from typing import Any

from material.extensions.emoji import to_svg, twemoji

EMOJI_EXTENSION = "pymdownx.emoji"


def on_config(config: Any) -> Any:
    """Attach Material's Twemoji index and SVG generator to the emoji extension."""
    emoji_config: dict[str, Any] = dict(config["mdx_configs"].get(EMOJI_EXTENSION) or {})
    emoji_config["emoji_index"] = twemoji
    emoji_config["emoji_generator"] = to_svg
    config["mdx_configs"][EMOJI_EXTENSION] = emoji_config
    return config
