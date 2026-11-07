"""The generated Kubernetes manifest.

Three failures this guards against, all silent in production:

* the committed ``web-frontend.yaml`` drifting from ``web/`` - the pod keeps
  running the previous version of a file, and nothing says so;
* the ConfigMap mangling a file's contents on the way through YAML, so the
  container starts and dies on an IndentationError;
* the two namespaces collapsing into one, which leaves the page authorised in
  the namespace it runs in rather than the one it reads. That fails at the
  first API call, not at apply time.
"""

from __future__ import annotations

import importlib.util
import unittest

import yaml

from support import WEB_ROOT

REPO_ROOT = WEB_ROOT.parent
GENERATOR = WEB_ROOT / "tools" / "gen-manifest.py"
MANIFEST = REPO_ROOT / "kubernetes" / "workloads" / "web-frontend.yaml"

#: The namespace this application's own objects belong in.
APP_NAMESPACE = "packer-frontend"
#: The namespace holding the build CronJobs it manages.
BUILD_NAMESPACE = "packer-imaging"


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_manifest", GENERATOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def documents() -> list[dict]:
    return [doc for doc in yaml.safe_load_all(MANIFEST.read_text(encoding="utf-8")) if doc]


def find(kind: str) -> dict:
    return next(doc for doc in documents() if doc["kind"] == kind)


class GeneratorTests(unittest.TestCase):
    def test_the_generator_agrees_with_the_committed_namespaces(self):
        generator = load_generator()
        self.assertEqual(generator.APP_NAMESPACE, APP_NAMESPACE)
        self.assertEqual(generator.BUILD_NAMESPACE, BUILD_NAMESPACE)

    def test_the_committed_manifest_matches_the_source_tree(self):
        rendered = load_generator().render_manifest()
        self.assertEqual(
            MANIFEST.read_text(encoding="utf-8"),
            rendered,
            "web-frontend.yaml is stale; run: python web/tools/gen-manifest.py",
        )

    def test_a_missing_file_is_refused_rather_than_skipped(self):
        # A ConfigMap with a hole in it produces a pod that fails on an import,
        # which tells the reader far less than a generator error would.
        generator = load_generator()
        generator.APP_FILES = generator.APP_FILES + ("does-not-exist.py",)
        with self.assertRaises(SystemExit):
            generator.render_manifest()


class ManifestShapeTests(unittest.TestCase):
    def test_every_object_is_expected(self):
        self.assertEqual(
            sorted(doc["kind"] for doc in documents()),
            sorted(
                [
                    "ConfigMap",
                    "Deployment",
                    "Role",
                    "RoleBinding",
                    "Service",
                    "ServiceAccount",
                ]
            ),
        )

    def test_the_application_objects_are_in_the_application_namespace(self):
        for kind in ("ConfigMap", "Deployment", "Service", "ServiceAccount"):
            with self.subTest(kind=kind):
                self.assertEqual(find(kind)["metadata"]["namespace"], APP_NAMESPACE)

    def test_the_authorisation_objects_are_in_the_build_namespace(self):
        # The whole point of the split: the Role has to sit where the CronJobs
        # are, not where the pod is.
        for kind in ("Role", "RoleBinding"):
            with self.subTest(kind=kind):
                self.assertEqual(find(kind)["metadata"]["namespace"], BUILD_NAMESPACE)

    def test_the_role_binding_names_the_account_across_namespaces(self):
        subject = find("RoleBinding")["subjects"][0]
        self.assertEqual(subject["kind"], "ServiceAccount")
        self.assertEqual(subject["namespace"], APP_NAMESPACE)
        self.assertEqual(subject["name"], find("ServiceAccount")["metadata"]["name"])

    def test_the_role_binding_refers_to_the_role_that_exists(self):
        binding = find("RoleBinding")
        role = find("Role")
        self.assertEqual(binding["roleRef"]["kind"], "Role")
        self.assertEqual(binding["roleRef"]["name"], role["metadata"]["name"])


class ConfigMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load_generator()
        cls.data = find("ConfigMap")["data"]

    def test_each_file_round_trips_exactly(self):
        for relative in self.generator.APP_FILES:
            with self.subTest(file=relative):
                expected = (WEB_ROOT / relative).read_text(encoding="utf-8")
                self.assertEqual(self.data[self.generator.config_key(relative)], expected)

    def test_the_entry_point_and_assets_are_present(self):
        for relative in (
            "app.py",
            "requirements.txt",
            "static/style.css",
        ):
            with self.subTest(key=relative):
                self.assertIn(self.generator.config_key(relative), self.data)

    def test_every_template_is_mounted(self):
        # The shell plus one per page. A missing template is a 500 at request
        # time, not an import error, so it would survive a container start.
        for name in ("base", "landing", "build", "runs"):
            with self.subTest(template=name):
                key = self.generator.config_key(f"templates/{name}.html")
                self.assertIn(key, self.data)

    def test_the_shared_script_and_one_per_page_are_mounted(self):
        for name in ("core", "landing", "build", "runs"):
            with self.subTest(script=name):
                key = self.generator.config_key(f"static/{name}.js")
                self.assertIn(key, self.data)

    def test_the_single_page_files_are_gone(self):
        # Both were replaced by the split; leaving them mounted would ship two
        # versions of the same UI and only one of them reachable.
        for stale in ("templates.index.html", "static.app.js"):
            with self.subTest(key=stale):
                self.assertNotIn(stale, self.data)

    def test_every_key_is_a_legal_config_map_key(self):
        # A slash in a key is rejected by the API server at apply time, and the
        # ConfigMap is what the whole deployment depends on.
        for key in self.data:
            with self.subTest(key=key):
                self.assertNotIn("/", key)
                self.assertRegex(key, r"^[-._a-zA-Z0-9]+$")

    def test_every_key_is_mapped_back_to_its_real_path(self):
        volume = next(
            item for item in find("Deployment")["spec"]["template"]["spec"]["volumes"]
            if item["name"] == "app"
        )
        items = volume["configMap"]["items"]
        self.assertIsNotNone(items, "without items the subdirectories are lost")
        mapped = {item["key"]: item["path"] for item in items}
        for relative in self.generator.APP_FILES:
            with self.subTest(file=relative):
                self.assertEqual(mapped[self.generator.config_key(relative)], relative)

    def test_every_key_in_the_config_map_is_mounted(self):
        volume = next(
            item for item in find("Deployment")["spec"]["template"]["spec"]["volumes"]
            if item["name"] == "app"
        )
        mounted = {item["key"] for item in volume["configMap"]["items"]}
        self.assertEqual(mounted, set(self.data))

    def test_each_module_the_application_imports_is_mounted(self):
        # app.py imports these by bare name, so a missing key is an ImportError
        # at container start rather than anything the build would catch.
        for key in ("api", "config", "kube", "pages", "projects", "runs", "services"):
            with self.subTest(module=key):
                self.assertIn(f"{key}.py", self.data)

    def test_no_test_or_development_file_is_mounted(self):
        for key in self.data:
            with self.subTest(key=key):
                self.assertFalse(key.startswith("tests"))
                self.assertNotIn("tools", key)
                self.assertNotEqual(key, "Dockerfile")

    def test_the_config_map_stays_under_the_size_limit(self):
        total = sum(len(value.encode("utf-8")) for value in self.data.values())
        self.assertLess(total, 1024 * 1024)

    def test_no_line_ends_with_trailing_whitespace(self):
        for key, value in self.data.items():
            for number, line in enumerate(value.split("\n"), 1):
                with self.subTest(file=key, line=number):
                    self.assertEqual(line, line.rstrip())


class DeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.deployment = find("Deployment")
        cls.pod = cls.deployment["spec"]["template"]["spec"]
        cls.container = cls.pod["containers"][0]
        cls.env = {item["name"]: item.get("value") for item in cls.container["env"]}

    def test_runs_the_application_from_the_mounted_config(self):
        self.assertIn("/app/app.py", " ".join(self.container["args"]))

    def test_reads_the_build_namespace_not_its_own(self):
        # The single most consequential value in this file: point it at the
        # wrong namespace and the page loads happily showing nothing.
        self.assertEqual(self.env["KUBE_NAMESPACE"], BUILD_NAMESPACE)

    def test_listens_on_the_port_the_service_and_probes_expect(self):
        port = self.container["ports"][0]
        self.assertEqual(port["name"], "http")
        self.assertEqual(port["containerPort"], 8080)
        self.assertEqual(self.env["FLASK_PORT"], "8080")

    def test_the_page_is_reachable_on_the_node_port_eighty(self):
        self.assertEqual(self.container["ports"][0]["hostPort"], 80)

    def test_recreate_strategy_because_the_host_port_is_exclusive(self):
        self.assertEqual(self.deployment["spec"]["strategy"]["type"], "Recreate")

    def test_dependencies_go_to_a_writable_volume(self):
        mounts = {item["mountPath"]: item for item in self.container["volumeMounts"]}
        self.assertIn("/deps", mounts)
        self.assertIn("/tmp", mounts)
        self.assertEqual(self.env["PYTHONPATH"], "/deps")

    def test_the_application_mount_is_read_only(self):
        mounts = {item["mountPath"]: item for item in self.container["volumeMounts"]}
        self.assertTrue(mounts["/app"]["readOnly"])

    def test_every_mount_has_a_volume(self):
        declared = {volume["name"] for volume in self.pod["volumes"]}
        for mount in self.container["volumeMounts"]:
            with self.subTest(mount=mount["name"]):
                self.assertIn(mount["name"], declared)

    def test_probes_use_the_probe_that_does_not_touch_the_cluster(self):
        for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
            with self.subTest(probe=probe):
                self.assertEqual(self.container[probe]["httpGet"]["path"], "/healthz")
                self.assertEqual(self.container[probe]["httpGet"]["port"], "http")

    def test_the_startup_probe_allows_for_a_cold_pip_install(self):
        probe = self.container["startupProbe"]
        budget = probe["periodSeconds"] * probe["failureThreshold"]
        self.assertGreaterEqual(budget, 120)

    def test_runs_unprivileged_with_an_immutable_root(self):
        self.assertTrue(self.pod["securityContext"]["runAsNonRoot"])
        self.assertTrue(self.container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(self.container["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(
            self.container["securityContext"]["capabilities"]["drop"], ["ALL"]
        )

    def test_uses_its_own_service_account(self):
        self.assertEqual(
            self.pod["serviceAccountName"], find("ServiceAccount")["metadata"]["name"]
        )

    def test_the_config_map_volume_names_the_config_map_that_exists(self):
        volume = next(item for item in self.pod["volumes"] if item["name"] == "app")
        self.assertEqual(volume["configMap"]["name"], find("ConfigMap")["metadata"]["name"])


class RbacTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.role = find("Role")
        cls.rules = {
            (tuple(rule["apiGroups"]), tuple(rule["resources"])): set(rule["verbs"])
            for rule in cls.role["rules"]
        }

    def verbs(self, group: str, resource: str) -> set[str]:
        return self.rules[((group,), (resource,))]

    def test_cronjobs_can_be_read_and_patched_but_not_created_or_deleted(self):
        verbs = self.verbs("batch", "cronjobs")
        self.assertTrue({"get", "list", "patch"} <= verbs)
        for forbidden in ("create", "delete", "deletecollection"):
            self.assertNotIn(forbidden, verbs)

    def test_jobs_can_be_created_and_deleted(self):
        verbs = self.verbs("batch", "jobs")
        self.assertTrue({"get", "list", "create", "delete"} <= verbs)
        self.assertNotIn("deletecollection", verbs)

    def test_pod_logs_can_be_read(self):
        self.assertEqual(self.verbs("", "pods/log"), {"get"})

    def test_resource_quotas_can_be_read_for_the_capacity_bars(self):
        self.assertTrue({"get", "list"} <= self.verbs("", "resourcequotas"))

    def test_secrets_are_never_readable(self):
        for (_group, resources), _verbs in self.rules.items():
            with self.subTest(resources=resources):
                self.assertNotIn("secrets", resources)


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = find("Service")

    def test_is_reachable_on_a_node_port_as_well_as_the_host_port(self):
        self.assertEqual(self.service["spec"]["type"], "NodePort")
        port = self.service["spec"]["ports"][0]
        self.assertEqual(port["port"], 80)
        self.assertEqual(port["targetPort"], "http")

    def test_no_node_port_is_pinned(self):
        # A pinned number fails at apply whenever something else already holds
        # it - including the previous deployment of this same page.
        self.assertNotIn("nodePort", self.service["spec"]["ports"][0])

    def test_selects_the_deployment(self):
        # A Service selector is a *subset* of the pod labels: it is a matcher,
        # not a copy, and adding a label to the pod must not orphan the Service.
        deployment = find("Deployment")
        pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
        selector = self.service["spec"]["selector"]
        self.assertTrue(selector, "an empty selector would select every pod")
        for key, value in selector.items():
            with self.subTest(label=key):
                self.assertEqual(pod_labels.get(key), value)

    def test_does_not_select_anything_else(self):
        # `app.kubernetes.io/part-of` is on every object in the project, so
        # selecting on it would route traffic to unrelated pods.
        selector = self.service["spec"]["selector"]
        self.assertNotIn("app.kubernetes.io/part-of", selector)
        self.assertEqual(selector["app.kubernetes.io/name"], "aria-image-builder-web")
