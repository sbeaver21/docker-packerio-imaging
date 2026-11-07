"""Turning a CronJob into the card a person reads.

The interesting assertions are the ones about what a user is told *before*
pressing Build: which Secrets the pod needs, what it will actually build, and
whether the last attempt worked.
"""

from __future__ import annotations

import unittest

from support import make_cronjob

from projects import (
    family_name,
    group_runs,
    project_health,
    project_name,
    required_config_maps,
    required_secrets,
    sort_projects,
    summarise_project,
    template_parameters,
)


def run(state: str, created: str, name: str = "r") -> dict:
    return {"name": name, "state": state, "createdAt": created}


class NameTests(unittest.TestCase):
    def test_project_comes_from_the_job_template_label(self):
        cronjob = make_cronjob(project="photon-5")
        self.assertEqual(project_name(cronjob), "photon-5")

    def test_project_falls_back_to_the_cronjob_label(self):
        cronjob = make_cronjob(project="photon-5")
        cronjob["spec"]["jobTemplate"]["metadata"]["labels"] = {}
        self.assertEqual(project_name(cronjob), "photon-5")

    def test_project_falls_back_to_the_name_minus_the_prefix(self):
        cronjob = make_cronjob(name="aria-build-rhel-96", project="rhel-96")
        cronjob["spec"]["jobTemplate"]["metadata"]["labels"] = {}
        cronjob["metadata"]["labels"] = {}
        self.assertEqual(project_name(cronjob), "rhel-96")

    def test_family_comes_from_either_label_set(self):
        self.assertEqual(family_name(make_cronjob(family="linux")), "linux")
        cronjob = make_cronjob(family="windows")
        cronjob["spec"]["jobTemplate"]["metadata"]["labels"].pop("packer.io/family", None)
        self.assertEqual(family_name(cronjob), "windows")

    def test_no_family_is_an_empty_string(self):
        self.assertEqual(family_name(make_cronjob(family=None)), "")


class RequirementTests(unittest.TestCase):
    def test_both_kinds_of_secret_are_reported(self):
        secrets = required_secrets(make_cronjob())
        self.assertIn("pkrvars-photon-5", secrets)  # mounted as a volume
        self.assertIn("aria-repo-credentials", secrets)  # envFrom on the checkout

    def test_an_optional_secret_is_not_a_requirement(self):
        cronjob = make_cronjob()
        cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]["volumes"][-1][
            "secret"
        ]["optional"] = True
        self.assertNotIn("pkrvars-photon-5", required_secrets(cronjob))

    def test_no_secret_volume_is_not_reported(self):
        self.assertNotIn("pkrvars-photon-5", required_secrets(make_cronjob(secret=None)))

    def test_config_maps_are_reported(self):
        self.assertIn("aria-image-build-scripts", required_config_maps(make_cronjob()))


class ParameterTests(unittest.TestCase):
    def test_build_parameters_come_from_the_build_container(self):
        parameters = template_parameters(make_cronjob())
        self.assertEqual(parameters["PACKER_BUILD_ARGS"], "-force")
        self.assertEqual(parameters["PACKER_PROJECT"], "builds/linux/photon/5")

    def test_ordinary_configuration_is_not_published(self):
        self.assertNotIn("CHECKPOINT_DISABLE", template_parameters(make_cronjob()))


class HealthTests(unittest.TestCase):
    def test_no_runs_is_never(self):
        self.assertEqual(project_health([], suspended=False), "never")

    def test_last_succeeded(self):
        runs = [run("failed", "2026-10-01T00:00:00Z"), run("succeeded", "2026-10-02T00:00:00Z")]
        self.assertEqual(project_health(runs, suspended=False), "ok")

    def test_last_failed(self):
        runs = [run("succeeded", "2026-10-01T00:00:00Z"), run("failed", "2026-10-02T00:00:00Z")]
        self.assertEqual(project_health(runs, suspended=False), "failing")

    def test_a_live_run_beats_a_paused_schedule(self):
        self.assertEqual(project_health([run("running", "2026-10-02T00:00:00Z")], True), "running")

    def test_a_blocked_run_counts_as_live(self):
        self.assertEqual(project_health([run("blocked", "2026-10-02T00:00:00Z")], False), "running")

    def test_suspended_with_no_live_run(self):
        self.assertEqual(project_health([run("succeeded", "2026-10-01T00:00:00Z")], True), "suspended")


class SummaryTests(unittest.TestCase):
    def test_the_newest_run_is_the_latest(self):
        runs = [
            run("failed", "2026-10-01T00:00:00Z", "old"),
            run("succeeded", "2026-10-03T00:00:00Z", "new"),
            run("running", "2026-10-02T00:00:00Z", "mid"),
        ]
        project = summarise_project(make_cronjob(), runs)
        self.assertEqual(project["latestRun"]["name"], "new")

    def test_first_success_and_first_failure_are_reported_separately(self):
        runs = [
            run("succeeded", "2026-09-01T00:00:00Z", "first-ok"),
            run("failed", "2026-10-01T00:00:00Z", "worst"),
            run("succeeded", "2026-10-03T00:00:00Z", "newest-ok"),
        ]
        project = summarise_project(make_cronjob(), runs)
        self.assertEqual(project["lastSuccess"]["name"], "newest-ok")
        self.assertEqual(project["lastFailure"]["name"], "worst")

    def test_active_runs_are_counted_not_just_flagged(self):
        runs = [run("running", "2026-10-01T00:00:00Z"), run("blocked", "2026-10-02T00:00:00Z")]
        self.assertEqual(summarise_project(make_cronjob(), runs)["activeRuns"], 2)

    def test_run_count_includes_everything(self):
        runs = [run("succeeded", "2026-10-01T00:00:00Z"), run("failed", "2026-10-02T00:00:00Z")]
        self.assertEqual(summarise_project(make_cronjob(), runs)["runCount"], 2)

    def test_schedule_details_are_carried_through(self):
        project = summarise_project(make_cronjob())
        self.assertEqual(project["schedule"], "0 3 * * 0")
        self.assertEqual(project["timezone"], "America/New_York")
        self.assertEqual(project["concurrencyPolicy"], "Forbid")
        self.assertFalse(project["suspend"])

    def test_purpose_annotation_is_surfaced(self):
        self.assertIn("Photon OS 5", summarise_project(make_cronjob())["purpose"])

    def test_an_empty_project_summarises_without_error(self):
        project = summarise_project(make_cronjob())
        self.assertIsNone(project["latestRun"])
        self.assertEqual(project["health"], "never")
        self.assertEqual(project["activeRuns"], 0)


class GroupingTests(unittest.TestCase):
    def test_runs_are_indexed_by_cronjob(self):
        grouped = group_runs(
            [
                {"cronjob": "aria-build-photon-5", "state": "succeeded"},
                {"cronjob": "aria-build-rhel-96", "state": "failed"},
                {"cronjob": "", "state": "failed"},
            ]
        )
        self.assertEqual(len(grouped["aria-build-photon-5"]), 1)
        self.assertEqual(len(grouped["aria-build-rhel-96"]), 1)
        self.assertEqual(len(grouped[""]), 1)

    def test_projects_sort_by_family_then_name(self):
        projects = [
            {"family": "windows", "project": "windows-2022"},
            {"family": "linux", "project": "rhel-96"},
            {"family": "linux", "project": "photon-5"},
            {"family": "", "project": "unknown"},
        ]
        ordered = [(p["family"], p["project"]) for p in sort_projects(projects)]
        self.assertEqual(
            ordered,
            [
                ("linux", "photon-5"),
                ("linux", "rhel-96"),
                ("windows", "windows-2022"),
                ("", "unknown"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
