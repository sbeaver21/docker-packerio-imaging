"""The names and labels a manual run gets.

Two things matter here and both are checkable without a cluster: the name must
be a legal Kubernetes object name, and two runs started in the same second must
not collide.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone

from support import NAMESPACE  # noqa: F401  - applies the sys.path bootstrap

from naming import (
    MAX_NAME_LENGTH,
    build_run_name,
    instantiate_annotations,
    instantiate_labels,
    is_manual_run,
    sanitize_name,
)

MOMENT = datetime(2026, 10, 26, 15, 8, 0, tzinfo=timezone.utc)


class SanitizeNameTests(unittest.TestCase):
    def test_lowercases_and_replaces_spaces(self):
        self.assertEqual(sanitize_name("Photon 5"), "photon-5")

    def test_collapses_runs_of_invalid_characters(self):
        self.assertEqual(sanitize_name("aria//build___rhel"), "aria-build-rhel")

    def test_strips_leading_and_trailing_separators(self):
        self.assertEqual(sanitize_name("--aria-build--"), "aria-build")

    def test_never_returns_empty(self):
        self.assertEqual(sanitize_name("!!!"), "build")
        self.assertEqual(sanitize_name(""), "build")


class BuildRunNameTests(unittest.TestCase):
    def test_includes_the_cronjob_the_timestamp_and_the_marker(self):
        self.assertEqual(
            build_run_name("aria-build-photon-5", MOMENT),
            "aria-build-photon-5-manual-20261026-150800",
        )

    def test_is_a_valid_dns_label(self):
        name = build_run_name("aria-build-photon-5", MOMENT)
        self.assertLessEqual(len(name), MAX_NAME_LENGTH)
        self.assertRegex(name, r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

    def test_trims_a_long_cronjob_name_to_fit(self):
        long_name = "aria-build-" + "x" * 60
        name = build_run_name(long_name, MOMENT)
        self.assertLessEqual(len(name), MAX_NAME_LENGTH)
        self.assertTrue(name.endswith("-manual-20261026-150800"))

    def test_discriminator_makes_a_second_name_possible(self):
        first = build_run_name("aria-build-photon-5", MOMENT)
        second = build_run_name("aria-build-photon-5", MOMENT, discriminator="a1b2")
        self.assertNotEqual(first, second)
        self.assertRegex(second, r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
        self.assertLessEqual(len(second), MAX_NAME_LENGTH)

    def test_timestamp_is_utc_whatever_the_caller_passed(self):
        eastern = datetime(2026, 10, 26, 11, 8, 0, tzinfo=timezone.utc)
        self.assertTrue(
            build_run_name("aria-build-x", eastern).endswith("-manual-20261026-110800")
        )


class LabelTests(unittest.TestCase):
    def test_labels_keep_the_templates_and_add_the_marker(self):
        labels = instantiate_labels({"packer.io/project": "photon-5"})
        self.assertEqual(labels["packer.io/project"], "photon-5")
        self.assertEqual(labels["cronjob.kubernetes.io/instantiate"], "manual")
        self.assertEqual(labels["aria-automation/created-by"], "web-frontend")

    def test_labels_accept_no_template(self):
        self.assertEqual(
            instantiate_labels(None), 
            {
                "cronjob.kubernetes.io/instantiate": "manual",
                "aria-automation/created-by": "web-frontend",
            },
        )

    def test_labels_do_not_mutate_the_input(self):
        source = {"packer.io/project": "photon-5"}
        instantiate_labels(source)
        self.assertEqual(source, {"packer.io/project": "photon-5"})

    def test_annotations_record_the_same_marker(self):
        annotations = instantiate_annotations(None)
        self.assertEqual(annotations["cronjob.kubernetes.io/instantiate"], "manual")


class ManualRunTests(unittest.TestCase):
    def test_a_label_is_enough(self):
        self.assertTrue(
            is_manual_run({"cronjob.kubernetes.io/instantiate": "manual"}, None)
        )

    def test_an_annotation_is_enough(self):
        self.assertTrue(
            is_manual_run(None, {"cronjob.kubernetes.io/instantiate": "manual"})
        )

    def test_a_scheduled_run_is_not_manual(self):
        self.assertFalse(is_manual_run({"packer.io/project": "photon-5"}, {}))
        self.assertFalse(is_manual_run(None, None))


if __name__ == "__main__":
    unittest.main()
