"""Deriving a run's state, identity and parameters from a Job.

This is the state machine the whole UI rests on, so it is tested against the
Job shapes the cluster actually produces: a completed schedule run, a failed
one, a run in progress, a run with no pod yet, and - the case that matters most
operationally - a run whose pod the scheduler will not place.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone

from support import (
    CREATED,
    FINISHED,
    STARTED,
    labels_for,
    make_job,
    make_pod,
)

from runs import (
    build_parameters,
    build_project,
    container_names,
    default_container,
    derive_state,
    is_terminal,
    owning_cronjob,
    sort_key,
    summarise_run,
)

#: A fixed "now" after every fixture timestamp, so elapsed durations are exact.
NOW = datetime(2026, 10, 25, 5, 0, 0, tzinfo=timezone.utc)


class StateTests(unittest.TestCase):
    def test_complete_condition_is_succeeded(self):
        state, reason, message = derive_state(make_job(state="succeeded"), [])
        self.assertEqual(state, "succeeded")
        self.assertEqual(reason, "Complete")
        self.assertEqual(message, "")

    def test_failed_condition_carries_the_controllers_message(self):
        job = make_job(state="failed", state_message="build.sh exited 1")
        state, reason, message = derive_state(job, [])
        self.assertEqual(state, "failed")
        self.assertEqual(reason, "BackoffLimitExceeded")
        self.assertEqual(message, "build.sh exited 1")

    def test_active_pod_is_running(self):
        state, _, _ = derive_state(make_job(state="running"), [make_pod()])
        self.assertEqual(state, "running")

    def test_started_but_not_yet_active_is_still_treated_as_running(self):
        job = make_job(state="running")
        job["status"] = {"startTime": STARTED}
        state, reason, _ = derive_state(job, [])
        self.assertEqual(state, "running")
        self.assertEqual(reason, "Starting")

    def test_no_status_at_all_is_pending(self):
        state, reason, message = derive_state(make_job(state="pending"), [])
        self.assertEqual((state, reason, message), ("pending", "Queued", ""))

    def test_unschedulable_pod_is_blocked_not_pending(self):
        job = make_job(state="pending")
        job["status"] = {"startTime": STARTED}
        pod = make_pod(
            phase="Pending",
            unschedulable="0/3 nodes are available: 3 Insufficient pods.",
        )
        state, reason, message = derive_state(job, [pod])
        self.assertEqual(state, "blocked")
        self.assertEqual(reason, "Unschedulable")
        self.assertIn("Insufficient pods", message)

    def test_a_finished_job_wins_over_an_unschedulable_pod(self):
        # A retry can leave an old unschedulable pod behind; the Job's own
        # terminal condition is the truth.
        job = make_job(state="succeeded")
        pod = make_pod(phase="Pending", unschedulable="Insufficient pods")
        state, _, _ = derive_state(job, [pod])
        self.assertEqual(state, "succeeded")

    def test_is_terminal(self):
        self.assertTrue(is_terminal({"state": "succeeded"}))
        self.assertTrue(is_terminal({"state": "failed"}))
        self.assertFalse(is_terminal({"state": "running"}))
        self.assertFalse(is_terminal({"state": "blocked"}))


class IdentityTests(unittest.TestCase):
    def test_scheduled_run_resolves_its_cronjob_by_owner_reference(self):
        job = make_job(owner="aria-build-photon-5")
        self.assertEqual(owning_cronjob(job), "aria-build-photon-5")

    def test_manual_run_resolves_its_cronjob_by_the_name_label(self):
        job = make_job(
            name="aria-build-photon-5-manual-20261026-150000",
            owner=None,
            manual=True,
            labels={
                **labels_for("photon-5"),
                "app.kubernetes.io/name": "aria-build-photon-5",
            },
        )
        self.assertEqual(owning_cronjob(job), "aria-build-photon-5")

    def test_name_pattern_is_the_last_resort(self):
        job = make_job(
            name="aria-build-photon-5-manual-20261026-150000",
            owner=None,
            labels=labels_for("photon-5"),
        )
        self.assertEqual(owning_cronjob(job), "aria-build-photon-5")

    def test_a_pipeline_run_has_no_cronjob_but_still_knows_its_project(self):
        # This is what `kubectl create job --from=cronjob/...` leaves behind:
        # a project label and nothing that names the parent.
        job = make_job(
            name="aria-build-photon-5-manual-1234",
            owner=None,
            labels=labels_for("photon-5"),
        )
        self.assertEqual(owning_cronjob(job), "")
        self.assertEqual(build_project(job), "photon-5")

    def test_project_falls_back_to_the_cronjob_name(self):
        job = make_job(owner="aria-build-rhel-96", labels={})
        self.assertEqual(build_project(job), "rhel-96")

    def test_a_project_label_wins_over_the_name(self):
        job = make_job(owner="aria-build-rhel-96", labels=labels_for("rhel-9.6"))
        self.assertEqual(build_project(job), "rhel-9.6")


class ContainerTests(unittest.TestCase):
    def test_default_container_is_the_build_not_the_checkout(self):
        job = make_job()
        self.assertEqual(container_names(job, "initContainers"), ["checkout"])
        self.assertEqual(container_names(job, "containers"), ["packer"])
        self.assertEqual(default_container(job), "packer")

    def test_no_containers_gives_an_empty_default(self):
        job = make_job()
        job["spec"]["template"]["spec"]["containers"] = []
        self.assertEqual(default_container(job), "")


class ParameterTests(unittest.TestCase):
    def test_only_whitelisted_literal_values_are_exposed(self):
        parameters = build_parameters(make_job())
        self.assertEqual(parameters["PACKER_BUILD_ARGS"], "-force")
        self.assertEqual(parameters["PACKER_PROJECT"], "builds/linux/photon/5")

    def test_a_value_from_a_secret_is_not_read(self):
        job = make_job()
        job["spec"]["template"]["spec"]["containers"][0]["env"].append(
            {
                "name": "PACKER_PROJECT",
                "valueFrom": {"secretKeyRef": {"name": "pkrvars-photon-5", "key": "x"}},
            }
        )
        # The literal earlier in the list still wins; nothing from the Secret
        # is present, and in particular no value is invented for it.
        parameters = build_parameters(job)
        self.assertEqual(parameters["PACKER_PROJECT"], "builds/linux/photon/5")

    def test_variables_outside_the_whitelist_are_dropped(self):
        self.assertNotIn("CHECKPOINT_DISABLE", build_parameters(make_job()))


class SummaryTests(unittest.TestCase):
    def test_a_finished_run_reports_its_exact_duration(self):
        run = summarise_run(make_job(state="succeeded"), [], NOW)
        self.assertEqual(run["state"], "succeeded")
        self.assertEqual(run["durationSeconds"], 2520)
        self.assertEqual(run["createdAt"], CREATED)
        self.assertEqual(run["startTime"], STARTED)
        self.assertEqual(run["completionTime"], FINISHED)

    def test_a_running_run_reports_elapsed_time(self):
        run = summarise_run(make_job(state="running"), [make_pod()], NOW)
        # STARTED is 03:00:05Z and NOW is 05:00:00Z.
        self.assertEqual(run["durationSeconds"], 7195)

    def test_a_pending_run_has_no_duration(self):
        run = summarise_run(make_job(state="pending"), [], NOW)
        self.assertIsNone(run["durationSeconds"])

    def test_manual_marker_is_reported(self):
        run = summarise_run(make_job(manual=True), [], NOW)
        self.assertTrue(run["manual"])
        self.assertFalse(summarise_run(make_job(manual=False), [], NOW)["manual"])

    def test_job_settings_are_carried_through(self):
        run = summarise_run(make_job(), [], NOW)
        self.assertEqual(run["backoffLimit"], 0)
        self.assertEqual(run["activeDeadlineSeconds"], 7200)
        self.assertEqual(run["ttlSecondsAfterFinished"], 21600)

    def test_pod_summary_picks_the_newest_pod(self):
        older = make_pod(name="old-pod")
        older["metadata"]["creationTimestamp"] = "2026-10-25T02:00:00Z"
        newer = make_pod(name="new-pod")
        run = summarise_run(make_job(state="running"), [older, newer], NOW)
        assert run["pod"] is not None
        self.assertEqual(run["pod"]["name"], "new-pod")

    def test_no_pods_means_no_pod_summary(self):
        run = summarise_run(make_job(state="pending"), [], NOW)
        self.assertIsNone(run["pod"])

    def test_sort_key_is_the_creation_timestamp(self):
        self.assertEqual(sort_key(summarise_run(make_job(), [], NOW)), CREATED)


if __name__ == "__main__":
    unittest.main()
