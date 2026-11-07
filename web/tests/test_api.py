"""The HTTP surface, driven through Flask's test client.

Every route the browser calls is exercised here against the fake gateway, so
the suite proves the wiring and the status codes as well as the logic. The
read-only cases matter as much as the happy ones: `READ_ONLY=1` is how this
page can be published more widely without handing out the ability to boot
virtual machines.
"""

from __future__ import annotations

import re
import unittest

from support import (
    FakeGateway,
    assert_no_secret_values,
    make_failing_gateway,
    make_job,
    make_pod,
)

from app import create_app
from config import load_settings

CRONJOB = "aria-build-photon-5"


def build_app(gateway: FakeGateway | None = None, read_only: bool = False):
    # The namespace the page reads, which is where the builds are - not the
    # namespace this application is deployed into.
    overrides = {"KUBE_NAMESPACE": "packer-imaging"}
    if read_only:
        overrides["READ_ONLY"] = "1"
    settings = load_settings(overrides)
    app = create_app(settings, gateway or FakeGateway())
    app.config.update(TESTING=True)
    return app


#: Each page, and the marker that proves its own body was rendered rather than
#: another page's. If a template is swapped by mistake the marker disappears.
PAGES = {
    "/": "stat-grid",
    "/build": "project-grid",
    "/runs": "run-rows",
}


class PageTests(unittest.TestCase):
    def setUp(self):
        self.client = build_app().test_client()

    def body(self, path: str) -> str:
        response = self.client.get(path)
        self.assertEqual(response.status_code, 200, path)
        return response.get_data(as_text=True)

    def test_every_page_renders(self):
        for path, marker in PAGES.items():
            with self.subTest(path=path):
                body = self.body(path)
                self.assertIn("Image Builder", body)
                self.assertIn("packer-imaging", body)
                self.assertIn(f'id="{marker}"', body)

    def test_every_page_references_the_shared_assets(self):
        for path in PAGES:
            with self.subTest(path=path):
                body = self.body(path)
                self.assertIn("static/style.css", body)
                # core.js is shared; the page script is added on top of it.
                self.assertIn("static/core.js", body)

    def test_each_page_loads_exactly_one_page_script(self):
        for path in PAGES:
            with self.subTest(path=path):
                body = self.body(path)
                scripts = re.findall(r'static/(\w[\w-]*)\.js', body)
                page_script = path.strip("/") or "landing"
                # core.js first, then the page's own script: the page script
                # uses window.App, so the order in the markup matters.
                self.assertEqual(scripts, ["core", page_script])

    def test_the_navigation_is_on_every_page_and_marks_one_entry(self):
        for path in PAGES:
            with self.subTest(path=path):
                body = self.body(path)
                self.assertIn('aria-label="Sections"', body)
                # Exactly one link claims to be the current page; a page that
                # marks none, or two, is a navigation bug the eye will miss.
                self.assertEqual(body.count('aria-current="page"'), 1)

    def test_read_only_is_announced_on_every_page(self):
        client = build_app(read_only=True).test_client()
        for path in PAGES:
            with self.subTest(path=path):
                self.assertIn("read-only", client.get(path).get_data(as_text=True))

    def test_the_build_page_explains_what_the_buttons_do(self):
        body = self.body("/build")
        self.assertIn("Build now", body)
        self.assertIn("Pause", body)

    def test_the_runs_page_owns_the_log_dialog(self):
        body = self.body("/runs")
        self.assertIn('id="logs-dialog"', body)
        self.assertIn('id="run-filter"', body)
        self.assertIn('id="project-filter"', body)

    def test_the_log_dialog_is_not_shipped_on_the_other_pages(self):
        for path in ("/", "/build"):
            with self.subTest(path=path):
                self.assertNotIn('id="logs-dialog"', self.body(path))

    def test_plain_probe_does_not_touch_the_cluster(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_data(as_text=True).strip(), "ok")


class HealthTests(unittest.TestCase):
    def test_connected(self):
        payload = build_app().test_client().get("/api/health").get_json()
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["kubernetes"], "connected")
        self.assertEqual(payload["namespace"], "packer-imaging")
        self.assertEqual(payload["serverVersion"], "v1.31.4")

    def test_disconnected_still_answers_200(self):
        # The probe must not fail the container for an outage elsewhere.
        client = build_app(make_failing_gateway()).test_client()
        response = client.get("/api/health")
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertEqual(payload["status"], "degraded")
        self.assertEqual(payload["kubernetes"], "unavailable")
        self.assertIn("connection refused", payload["error"])


class OverviewTests(unittest.TestCase):
    def test_overview_reports_projects_runs_and_capacity(self):
        gateway = FakeGateway(
            jobs=[make_job(state="succeeded")],
            pods={},
        )
        payload = build_app(gateway).test_client().get("/api/overview").get_json()

        self.assertEqual(payload["namespace"], "packer-imaging")
        self.assertEqual(payload["counts"]["projects"], 1)
        self.assertEqual(payload["counts"]["runs"], 1)
        self.assertEqual(len(payload["projects"]), 1)

        project = payload["projects"][0]
        self.assertEqual(project["name"], CRONJOB)
        self.assertEqual(project["project"], "photon-5")
        self.assertEqual(project["health"], "ok")
        self.assertEqual(project["latestRun"]["state"], "succeeded")

        resources = {item["key"]: item for item in payload["capacity"]["resources"]}
        self.assertEqual(resources["pods"]["used"], "3")
        self.assertEqual(resources["pods"]["hard"], "16")
        self.assertFalse(resources["pods"]["saturated"])

    def test_a_full_quota_is_reported_as_saturated(self):
        from support import make_quota

        gateway = FakeGateway(quota=[make_quota(pods_used="16")])
        payload = build_app(gateway).test_client().get("/api/overview").get_json()
        pods = {item["key"]: item for item in payload["capacity"]["resources"]}["pods"]
        self.assertEqual(pods["percent"], 100)
        self.assertTrue(pods["saturated"])

    def test_blocked_run_is_visible_in_the_overview(self):
        job = make_job(state="pending", name="aria-build-photon-5-blocked")
        job["status"] = {"startTime": "2026-10-25T03:00:05Z"}
        pod = make_pod(
            job="aria-build-photon-5-blocked",
            phase="Pending",
            unschedulable="0/3 nodes are available: 3 Insufficient pods.",
        )
        gateway = FakeGateway(
            jobs=[job],
            pods={"aria-build-photon-5-blocked": [pod]},
        )
        payload = build_app(gateway).test_client().get("/api/overview").get_json()
        project = payload["projects"][0]
        self.assertEqual(project["health"], "running")
        self.assertEqual(project["latestRun"]["state"], "blocked")
        self.assertIn("Insufficient pods", project["latestRun"]["stateMessage"])

    def test_disconnected_overview_is_503_with_a_reason(self):
        client = build_app(make_failing_gateway()).test_client()
        response = client.get("/api/overview")
        self.assertEqual(response.status_code, 503)
        self.assertIn("connection refused", response.get_json()["error"])

    def test_overview_carries_no_credential_values(self):
        gateway = FakeGateway(jobs=[make_job()])
        payload = build_app(gateway).test_client().get("/api/overview").get_json()
        assert_no_secret_values(payload)


class ProjectRouteTests(unittest.TestCase):
    def setUp(self):
        self.gateway = FakeGateway()
        self.client = build_app(self.gateway).test_client()

    def test_single_project_includes_its_runs(self):
        payload = self.client.get(f"/api/projects/{CRONJOB}").get_json()
        self.assertEqual(payload["project"]["name"], CRONJOB)
        self.assertEqual(payload["runs"], [])

    def test_unknown_project_is_404(self):
        response = self.client.get("/api/projects/does-not-exist")
        self.assertEqual(response.status_code, 404)
        self.assertIn("not found", response.get_json()["error"])


class StartBuildTests(unittest.TestCase):
    def setUp(self):
        self.gateway = FakeGateway()
        self.client = build_app(self.gateway).test_client()

    def test_starting_a_build_returns_202_and_creates_a_job(self):
        response = self.client.post(f"/api/projects/{CRONJOB}/runs")
        self.assertEqual(response.status_code, 202)
        payload = response.get_json()
        self.assertIn("Build started", payload["message"])
        self.assertEqual(len(self.gateway.created), 1)
        created = self.gateway.created[0]
        self.assertTrue(created["metadata"]["name"].startswith(CRONJOB))
        self.assertEqual(
            created["metadata"]["labels"]["cronjob.kubernetes.io/instantiate"],
            "manual",
        )

    def test_the_new_run_then_appears_in_the_overview(self):
        self.client.post(f"/api/projects/{CRONJOB}/runs")
        payload = self.client.get("/api/overview").get_json()
        self.assertEqual(payload["counts"]["runs"], 1)
        run = payload["projects"][0]["latestRun"]
        self.assertEqual(run["cronjob"], CRONJOB)
        self.assertTrue(run["manual"])

    def test_starting_a_build_for_an_unknown_project_is_404(self):
        response = self.client.post("/api/projects/does-not-exist/runs")
        self.assertEqual(response.status_code, 404)
        self.assertIn("not found", response.get_json()["error"])

    def test_read_only_refuses_to_start_builds(self):
        gateway = FakeGateway()
        client = build_app(gateway, read_only=True).test_client()
        response = client.post(f"/api/projects/{CRONJOB}/runs")
        self.assertEqual(response.status_code, 403)
        self.assertIn("read-only", response.get_json()["error"])
        self.assertEqual(gateway.created, [])


class SuspendTests(unittest.TestCase):
    def setUp(self):
        self.gateway = FakeGateway()
        self.client = build_app(self.gateway).test_client()

    def test_pausing_sets_suspend(self):
        response = self.client.patch(f"/api/projects/{CRONJOB}", json={"suspend": True})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["project"]["suspend"])
        self.assertTrue(self.gateway.suspended[CRONJOB])

    def test_resuming_clears_it(self):
        self.client.patch(f"/api/projects/{CRONJOB}", json={"suspend": True})
        response = self.client.patch(f"/api/projects/{CRONJOB}", json={"suspend": False})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.get_json()["project"]["suspend"])

    def test_a_missing_field_is_rejected(self):
        response = self.client.patch(f"/api/projects/{CRONJOB}", json={})
        self.assertEqual(response.status_code, 400)
        self.assertIn("suspend", response.get_json()["error"])

    def test_a_non_boolean_is_rejected(self):
        response = self.client.patch(f"/api/projects/{CRONJOB}", json={"suspend": "yes"})
        self.assertEqual(response.status_code, 400)

    def test_a_body_that_is_not_json_is_rejected(self):
        response = self.client.patch(
            f"/api/projects/{CRONJOB}", data="not json", content_type="text/plain"
        )
        self.assertEqual(response.status_code, 400)

    def test_read_only_refuses_to_change_the_schedule(self):
        client = build_app(FakeGateway(), read_only=True).test_client()
        response = client.patch(f"/api/projects/{CRONJOB}", json={"suspend": True})
        self.assertEqual(response.status_code, 403)


class RunRouteTests(unittest.TestCase):
    def setUp(self):
        self.job = make_job(state="succeeded")
        self.pod = make_pod()
        self.gateway = FakeGateway(
            jobs=[self.job],
            pods={self.job["metadata"]["name"]: [self.pod]},
        )
        self.gateway.logs[self.job["metadata"]["name"]] = "Building photon-5...\ndone\n"
        self.client = build_app(self.gateway).test_client()

    def test_runs_are_listed(self):
        payload = self.client.get("/api/runs").get_json()
        self.assertEqual(len(payload["runs"]), 1)
        self.assertEqual(payload["runs"][0]["name"], self.job["metadata"]["name"])

    def test_one_run_can_be_read_back(self):
        payload = self.client.get(f"/api/runs/{self.job['metadata']['name']}").get_json()
        self.assertEqual(payload["run"]["state"], "succeeded")
        self.assertEqual(len(payload["pods"]), 1)

    def test_unknown_run_is_404(self):
        response = self.client.get("/api/runs/nope")
        self.assertEqual(response.status_code, 404)

    def test_logs_are_returned(self):
        payload = self.client.get(f"/api/runs/{self.job['metadata']['name']}/logs").get_json()
        self.assertIn("Building photon-5", payload["logs"])
        self.assertEqual(payload["job"], self.job["metadata"]["name"])

    def test_a_container_may_be_named(self):
        payload = (
            self.client.get(
                f"/api/runs/{self.job['metadata']['name']}/logs?container=checkout"
            ).get_json()
        )
        self.assertEqual(payload["container"], "checkout")

    def test_an_absurd_tail_is_clamped_rather_than_refused(self):
        response = self.client.get(
            f"/api/runs/{self.job['metadata']['name']}/logs?tail=99999999"
        )
        self.assertEqual(response.status_code, 200)

    def test_logs_for_a_run_with_no_pod_explain_themselves(self):
        gateway = FakeGateway(jobs=[make_job(state="pending")])
        client = build_app(gateway).test_client()
        payload = client.get("/api/runs/aria-build-photon-5-29000000/logs").get_json()
        self.assertEqual(payload["logs"], "")
        self.assertIn("No pod yet", payload["note"])


class DeleteTests(unittest.TestCase):
    def test_a_run_can_be_deleted(self):
        job = make_job()
        gateway = FakeGateway(jobs=[job])
        client = build_app(gateway).test_client()

        response = client.delete(f"/api/runs/{job['metadata']['name']}")
        self.assertEqual(response.status_code, 202)
        self.assertEqual(gateway.deleted, [job["metadata"]["name"]])

        overview = client.get("/api/overview").get_json()
        self.assertEqual(overview["counts"]["runs"], 0)

    def test_deleting_an_unknown_run_is_404(self):
        client = build_app().test_client()
        self.assertEqual(client.delete("/api/runs/nope").status_code, 404)

    def test_read_only_refuses_to_delete(self):
        job = make_job()
        gateway = FakeGateway(jobs=[job])
        client = build_app(gateway, read_only=True).test_client()
        response = client.delete(f"/api/runs/{job['metadata']['name']}")
        self.assertEqual(response.status_code, 403)
        self.assertEqual(gateway.deleted, [])


class CapacityRouteTests(unittest.TestCase):
    def test_capacity_route_matches_the_overview_section(self):
        payload = build_app().test_client().get("/api/capacity").get_json()
        keys = [item["key"] for item in payload["resources"]]
        self.assertEqual(
            keys,
            ["pods", "requests.cpu", "requests.memory", "limits.cpu", "limits.memory", "count/jobs.batch"],
        )


class AttachmentTests(unittest.TestCase):
    """A run with no owning CronJob is still shown under its project."""

    def test_a_pipeline_run_falls_under_its_project_card(self):
        # What `kubectl create job --from=cronjob/aria-build-photon-5` leaves
        # behind: owner=None and no app.kubernetes.io/name label.
        pipeline_run = make_job(
            name="aria-build-photon-5-manual-1234",
            owner=None,
            labels={"packer.io/project": "photon-5"},
        )
        gateway = FakeGateway(jobs=[pipeline_run])
        payload = build_app(gateway).test_client().get("/api/overview").get_json()

        self.assertEqual(payload["orphanProjects"], [])
        self.assertIsNotNone(payload["projects"][0]["latestRun"])
        self.assertEqual(len([r for r in payload["runs"] if r["cronjob"] == CRONJOB]), 1)

    def test_a_run_for_an_unknown_project_stays_an_orphan(self):
        stray = make_job(
            name="somebody-elses-job",
            owner=None,
            labels={"packer.io/project": "not-in-this-repo"},
        )
        gateway = FakeGateway(jobs=[stray])
        payload = build_app(gateway).test_client().get("/api/overview").get_json()

        self.assertEqual(len(payload["orphanProjects"]), 1)
        self.assertEqual(payload["orphanProjects"][0]["project"], "not-in-this-repo")

    def test_two_cronjobs_claiming_one_project_is_not_guessed_at(self):
        from support import make_cronjob

        gateway = FakeGateway(
            cronjobs=[
                make_cronjob(name="aria-build-photon-5", project="photon-5"),
                make_cronjob(name="aria-build-photon-5-nightly", project="photon-5"),
            ],
            jobs=[
                make_job(
                    name="aria-build-photon-5-manual-9999",
                    owner=None,
                    labels={"packer.io/project": "photon-5"},
                )
            ],
        )
        payload = build_app(gateway).test_client().get("/api/overview").get_json()
        self.assertEqual(len(payload["orphanProjects"]), 1)


if __name__ == "__main__":
    unittest.main()
