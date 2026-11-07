"""Building the Job to create from a CronJob.

This is the one place where a mistake is expensive: a body the API server
rejects means every Build button fails, and a body that copies a selector means
the run starts and never gets a pod. The assertions follow what
``kubectl create job --from=cronjob`` does, for the reason given in the module
docstring: the browser and the pipeline must produce the same object.
"""

from __future__ import annotations

import copy
import unittest

from support import build_job_body, make_cronjob

JOB_NAME = "aria-build-photon-5-manual-20261026-150000"


class BodyShapeTests(unittest.TestCase):
    def setUp(self):
        self.cronjob = make_cronjob()
        self.body = build_job_body(self.cronjob, JOB_NAME)

    def test_is_a_batch_job(self):
        self.assertEqual(self.body["apiVersion"], "batch/v1")
        self.assertEqual(self.body["kind"], "Job")

    def test_takes_its_name_and_namespace(self):
        self.assertEqual(self.body["metadata"]["name"], JOB_NAME)
        self.assertEqual(self.body["metadata"]["namespace"], "packer-imaging")

    def test_keeps_the_job_template_spec(self):
        spec = self.body["spec"]
        self.assertEqual(spec["backoffLimit"], 0)
        self.assertEqual(spec["activeDeadlineSeconds"], 7200)
        self.assertEqual(spec["ttlSecondsAfterFinished"], 21600)
        containers = spec["template"]["spec"]["containers"]
        self.assertEqual(containers[0]["name"], "packer")
        self.assertEqual(containers[0]["image"], "hashicorp/packer:1.15.0")

    def test_keeps_the_init_container_and_its_env_from(self):
        init = self.body["spec"]["template"]["spec"]["initContainers"][0]
        self.assertEqual(init["name"], "checkout")
        self.assertEqual(init["envFrom"][0]["secretRef"]["name"], "aria-repo-credentials")

    def test_drops_any_selector_so_the_controller_generates_one(self):
        self.cronjob["spec"]["jobTemplate"]["spec"]["selector"] = {
            "matchLabels": {"controller-uid": "stale"}
        }
        self.cronjob["spec"]["jobTemplate"]["spec"]["manualSelector"] = True
        body = build_job_body(self.cronjob, JOB_NAME)
        self.assertNotIn("selector", body["spec"])
        self.assertNotIn("manualSelector", body["spec"])

    def test_drops_server_populated_pod_metadata(self):
        pod_meta = self.body["spec"]["template"]["metadata"]
        for key in ("creationTimestamp", "resourceVersion", "uid", "managedFields"):
            self.assertNotIn(key, pod_meta)


class LabelTests(unittest.TestCase):
    def setUp(self):
        self.cronjob = make_cronjob()
        self.labels = build_job_body(self.cronjob, JOB_NAME)["metadata"]["labels"]

    def test_marks_the_run_as_manual(self):
        self.assertEqual(self.labels["cronjob.kubernetes.io/instantiate"], "manual")

    def test_records_what_started_it(self):
        self.assertEqual(self.labels["aria-automation/created-by"], "web-frontend")

    def test_names_the_owning_cronjob_so_the_run_can_be_attached(self):
        self.assertEqual(self.labels["app.kubernetes.io/name"], "aria-build-photon-5")

    def test_keeps_the_templates_project_label(self):
        self.assertEqual(self.labels["packer.io/project"], "photon-5")

    def test_copies_the_family_from_the_cronjob_because_the_template_lacks_it(self):
        # The family lives on the CronJob, not on its job template, so without
        # this the run could not say which family it belongs to.
        self.assertNotIn("packer.io/family", self._template_labels())
        self.assertEqual(self.labels["packer.io/family"], "linux")

    def _template_labels(self):
        return self.cronjob["spec"]["jobTemplate"]["metadata"]["labels"]

    def test_annotation_also_records_the_marker(self):
        annotations = build_job_body(self.cronjob, JOB_NAME)["metadata"]["annotations"]
        self.assertEqual(annotations["cronjob.kubernetes.io/instantiate"], "manual")

    def test_a_pipeline_style_cronjob_without_a_family_still_builds(self):
        cronjob = make_cronjob(family=None)
        labels = build_job_body(cronjob, JOB_NAME)["metadata"]["labels"]
        self.assertNotIn("packer.io/family", labels)


class SafetyTests(unittest.TestCase):
    def test_the_caller_object_is_not_mutated(self):
        cronjob = make_cronjob()
        before = copy.deepcopy(cronjob)
        build_job_body(cronjob, JOB_NAME)
        self.assertEqual(cronjob, before)

    def test_no_secret_value_reaches_the_body(self):
        # Only names of Secrets appear; the object never carries their content.
        body = build_job_body(make_cronjob(), JOB_NAME)
        self.assertNotIn("data", body["spec"]["template"]["spec"]["volumes"][-1]["secret"])

    def test_a_cronjob_with_no_template_still_produces_a_body_to_send(self):
        # The API server rejects it with a clear message, which is better than
        # a KeyError in the web process.
        cronjob = make_cronjob()
        cronjob["spec"]["jobTemplate"] = {}
        body = build_job_body(cronjob, JOB_NAME)
        self.assertEqual(body["spec"], {})


if __name__ == "__main__":
    unittest.main()
