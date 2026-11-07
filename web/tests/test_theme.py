"""The light and dark presentation, checked where it can be checked.

A stylesheet is not worth asserting on line by line, but a few things about the
theme are load-bearing and silently breakable:

* the theme is resolved in the document head, before anything paints, or every
  load flashes the wrong palette;
* the preference and the ``?theme=`` override share one storage key and one
  vocabulary across the template and the script, or the toggle and the deep link
  disagree;
* the dark palette is selected by an attribute the bootstrap actually sets,
  rather than by a media query the toggle cannot influence;
* the dark rules do not outrank the accent fills. A blanket ``background`` on
  ``.btn`` inside the dark block paints every primary button black on black -
  the sort of thing a screenshot catches and a diff does not.

The rest is colour and taste; these are the parts that fail. The theme lives in
the shared shell, so it is asserted once against ``base.html`` and then checked
on each rendered page, since every page extends it.
"""

from __future__ import annotations

import re
import unittest

from support import WEB_ROOT

from app import create_app
from config import load_settings

TEMPLATES = WEB_ROOT / "templates"
BASE = TEMPLATES / "base.html"
STYLESHEET = WEB_ROOT / "static" / "style.css"
CORE = WEB_ROOT / "static" / "core.js"
PAGES = ("landing", "build", "runs")
#: One route per page, for the checks that need the rendered HTML.
ROUTES = {"landing": "/", "build": "/build", "runs": "/runs"}

#: Shared between the head script and core.js, so it is written once here.
STORAGE_KEY = "aria-image-builder-theme"


class _OfflineGateway:
    """Enough gateway for a page to render; no cluster is contacted."""

    connected = False
    error = "offline"
    server_version = ""
    namespace = "packer-imaging"

    def require(self):
        from kube import KubernetesUnavailable

        raise KubernetesUnavailable("offline")


def render(path: str) -> str:
    settings = load_settings({"KUBE_NAMESPACE": "packer-imaging"})
    app = create_app(settings, _OfflineGateway())
    app.config.update(TESTING=True)
    response = app.test_client().get(path)
    assert response.status_code == 200, (path, response.status_code)
    return response.get_data(as_text=True)


class HeadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = BASE.read_text(encoding="utf-8")
        cls.head = cls.source.split("</head>", 1)[0]

    def test_the_theme_is_resolved_in_the_head(self):
        self.assertIn("data-theme", self.head)
        self.assertIn(STORAGE_KEY, self.head)

    def test_the_theme_is_resolved_before_the_body_paints(self):
        self.assertLess(self.source.index("data-theme"), self.source.index("<body"))

    def test_the_stylesheet_is_linked_before_the_theme_resolves(self):
        # The stylesheet has to be in hand by the time the attribute is set, or
        # the first paint uses no palette at all.
        self.assertLess(self.source.index("style.css"), self.source.index(STORAGE_KEY))

    def test_the_override_is_read_from_the_query_string(self):
        self.assertIn("URLSearchParams", self.head)
        self.assertIn("'theme'", self.head)

    def test_all_three_modes_are_accepted(self):
        for mode in ("dark", "light", "auto"):
            with self.subTest(mode=mode):
                self.assertIn(f"'{mode}'", self.head)

    def test_every_page_inherits_the_head_rather_than_repeating_it(self):
        for name in PAGES:
            with self.subTest(template=name):
                source = (TEMPLATES / f"{name}.html").read_text(encoding="utf-8")
                self.assertIn('{% extends "base.html" %}', source)
                # Two copies of the bootstrap would drift the first time one of
                # them was edited.
                self.assertNotIn("data-theme", source)
                self.assertNotIn("<html", source)


class ToggleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bodies = {name: render(path) for name, path in ROUTES.items()}

    def test_the_toggle_is_on_every_page(self):
        for name, body in self.bodies.items():
            with self.subTest(page=name):
                self.assertIn('id="theme-button"', body)

    def test_the_toggle_is_labelled_for_a_screen_reader(self):
        body = self.bodies["landing"]
        self.assertRegex(body, r'id="theme-button"[^>]*aria-label="[^"]+"')

    def test_the_toggle_carries_one_icon_per_mode(self):
        body = self.bodies["landing"]
        for mode in ("auto", "dark", "light"):
            with self.subTest(mode=mode):
                self.assertIn(f"theme-icon-{mode}", body)

    def test_the_toggle_is_not_a_form_submit(self):
        self.assertRegex(self.bodies["landing"], r'type="button"[^>]*id="theme-button"')

    def test_the_toggle_sits_in_the_top_bar_not_the_body(self):
        # The button must be in the shell, so a future page cannot be built
        # without a way back to the other palette.
        for name, body in self.bodies.items():
            with self.subTest(page=name):
                header = body.split("</header>", 1)[0]
                self.assertIn('id="theme-button"', header)


class StylesheetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.css = STYLESHEET.read_text(encoding="utf-8")

    def test_both_palettes_are_defined_on_the_same_token_names(self):
        light = set(re.findall(r"(--[a-z-]+)\s*:", self._block(r":root\s*\{")))
        dark = set(re.findall(r"(--[a-z-]+)\s*:", self._block(r':root\[data-theme="dark"\]\s*\{')))
        self.assertTrue(dark)
        # Every token the dark theme overrides must exist in the light one, or
        # something references a colour only one palette defines.
        self.assertTrue(dark <= light, sorted(dark - light))

    def test_the_dark_theme_is_selected_by_the_attribute_the_script_sets(self):
        self.assertIn(':root[data-theme="dark"]', self.css)

    def test_the_light_theme_is_the_default(self):
        self.assertIn("--surface: #ffffff", self._block(r":root\s*\{"))

    def test_the_dark_theme_is_a_terminal_not_a_grey_page(self):
        self.assertIn("--surface: #000000", self._dark())

    def test_the_dark_theme_is_monospaced_throughout(self):
        self.assertIn("--font-ui: ui-monospace", self._dark())

    def test_the_dark_theme_has_no_rounded_corners(self):
        self.assertIn("--radius: 2px", self._dark())

    def test_the_dark_theme_does_not_outrank_the_accent_fills(self):
        # The regression this exists for: `.btn { background: ... }` inside the
        # dark block wins over `.btn-primary` and hides the primary action.
        for selector in re.findall(r':root\[data-theme="dark"\]\s+\.btn[^{,]*', self.css):
            with self.subTest(selector=selector.strip()):
                self.assertNotIn("background", self._rule(selector))

    def test_a_hidden_theme_icon_is_actually_hidden(self):
        # `hidden` is an HTML attribute and does nothing at all to an SVG.
        self.assertIn(".theme-icon[hidden]", self.css)

    def test_the_page_is_styled_without_javascript(self):
        # Nothing sets data-theme until the head script runs, so the default
        # must already be the light theme rather than unstyled markup.
        self.assertIn("color-scheme: light", self.css)

    def test_the_navigation_marks_its_current_entry(self):
        self.assertIn('.mainnav a[aria-current="page"]', self.css)

    def _block(self, opener: str) -> str:
        match = re.search(opener, self.css)
        self.assertIsNotNone(match, opener)
        start = match.end()
        return self.css[start:self.css.index("}", start)]

    def _dark(self) -> str:
        return self._block(r':root\[data-theme="dark"\]\s*\{')

    def _rule(self, selector: str) -> str:
        match = re.search(re.escape(selector.strip()) + r"\s*\{([^}]*)\}", self.css)
        self.assertIsNotNone(match, selector)
        return match.group(1)


class ThemeScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.js = CORE.read_text(encoding="utf-8")

    def test_the_toggle_is_wired_at_startup(self):
        self.assertIn("wireTheme();", self.js)

    def test_startup_honours_the_override(self):
        # The bug this guards: wiring the toggle with the stored preference
        # alone silently discards ?theme= once the page has loaded.
        self.assertIn("forcedTheme() || storedTheme()", self.js)

    def test_the_override_and_the_template_agree_on_the_key(self):
        self.assertIn(STORAGE_KEY, self.js)

    def test_a_click_clears_the_override_from_the_address_bar(self):
        self.assertIn("searchParams.delete", self.js)

    def test_the_page_still_works_with_storage_disabled(self):
        # Private browsing throws on localStorage access; that must not stop
        # the page loading or the toggle working.
        self.assertGreaterEqual(self.js.count("catch (error)"), 2)

    def test_auto_follows_the_operating_system(self):
        self.assertIn("prefers-color-scheme: dark", self.js)
        self.assertIn('addEventListener("change"', self.js)


if __name__ == "__main__":
    unittest.main()
