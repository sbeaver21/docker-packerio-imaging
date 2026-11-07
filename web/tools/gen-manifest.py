"""Generate ``kubernetes/workloads/web-frontend.yaml`` from the source tree.

The cluster has no registry, so the front end is deployed by mounting its files
from a ConfigMap rather than by pulling an image. That means the manifest has to
contain a copy of the application, and a copy made by hand goes stale silently:
the UI keeps working while running last month's code.

This script is the only way that copy is made. It inlines an explicit list of
files - not a glob, because the tests and the Dockerfile must not end up
mounted at ``/app`` - and writes the whole manifest.

    python web/tools/gen-manifest.py

Run it after any change under ``web/``. ``--check`` exits non-zero if the
committed manifest is out of date, which is what the pipeline runs.

Two namespaces
--------------
The front end and the builds do not live in the same place:

``APP_NAMESPACE``     packer-frontend  where this Deployment, its ServiceAccount
                                       and the ConfigMap are created.
``BUILD_NAMESPACE``   packer-imaging   where the build CronJobs and their Jobs
                                       already are, and what the page reads.

That split is why the Role and RoleBinding below are in ``packer-imaging`` while
the ServiceAccount is in ``packer-frontend``: a subject may be bound across
namespaces, so the pod authenticates against its own namespace and is authorised
in the namespace it reads.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

WEB_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = WEB_ROOT.parent
MANIFEST = REPO_ROOT / "kubernetes" / "workloads" / "web-frontend.yaml"

#: Files that make up the application, relative to ``web/``. Their ConfigMap
#: keys are derived by :func:`config_key`, and the volume puts the directory
#: structure back so Flask finds ``/app/app.py`` next to ``/app/static/core.js``.
APP_FILES: tuple[str, ...] = (
    "app.py",
    "api.py",
    "config.py",
    "k8stime.py",
    "kube.py",
    "naming.py",
    "pages.py",
    "projects.py",
    "quantities.py",
    "runs.py",
    "services.py",
    "requirements.txt",
    # The pages. base.html is the shell the other three extend; each page has
    # its own script, and core.js is shared by all of them.
    "templates/base.html",
    "templates/landing.html",
    "templates/build.html",
    "templates/runs.html",
    # Assets.
    "static/style.css",
    "static/core.js",
    "static/landing.js",
    "static/build.js",
    "static/runs.js",
)

#: Where this application's own objects are created.
APP_NAMESPACE = "packer-frontend"
#: Where the build CronJobs are, and therefore what the page reads.
BUILD_NAMESPACE = "packer-imaging"

APP_NAME = "aria-image-builder-web"
CONFIG_MAP = "aria-image-builder-web-app"
SERVICE_ACCOUNT = "aria-image-builder-web"
IMAGE = "python:3.14-slim"
CONTAINER_PORT = 8080
HOST_PORT = 80

HEADER = """\
# =============================================================================
#  aria-image-builder-web - web front end for starting and rebuilding images
# =============================================================================
#
#  GENERATED FILE - do not edit by hand.
#  Source of truth: web/ (the application) and web/tools/gen-manifest.py (this
#  layout). Regenerate with:
#
#      python web/tools/gen-manifest.py
#
#  What it is: a Flask application that reads the build CronJobs and their Jobs
#  from the Kubernetes API, and can start a run, pause a schedule, delete a
#  finished run and show a run's log.
#
#  Two namespaces, deliberately:
#
#      packer-frontend   this Deployment, its ServiceAccount and the ConfigMap
#      packer-imaging    the build CronJobs and Jobs it reads and starts
#
#  The Role and RoleBinding therefore live in packer-imaging and name the
#  ServiceAccount in packer-frontend as their subject. Nothing in packer-imaging
#  is writable except CronJob spec.suspend and the Jobs this front end creates.
#
#  Where it is reachable:
#
#      http://10.3.48.245/          hostPort 80 on the node running the pod
#
#  The Service also gets a NodePort, allocated by the cluster rather than
#  pinned: a fixed number collides with whatever held it last time the front
#  end was deployed, and the failure only shows up at apply. Read the number
#  it was given with:
#
#      kubectl -n packer-frontend get service aria-image-builder-web
#
#  Apply order matters once: packer-frontend has to exist before this can be
#  applied into it, and the chart creates it along with the ResourceQuota and
#  LimitRange.
#
#      helm upgrade --install packer-imaging kubernetes/charts/packer-imaging \
#          --namespace packer-imaging --create-namespace
#      kubectl apply -f kubernetes/workloads/web-frontend.yaml
# =============================================================================
"""


def read_app_files() -> dict[str, str]:
    """Read every application file, refusing a missing one.

    Generating a manifest with a hole in it would produce a pod that starts and
    then fails on an import, which is much harder to diagnose than this error.
    """
    contents: dict[str, str] = {}
    missing: list[str] = []
    for relative in APP_FILES:
        path = WEB_ROOT / relative
        if not path.is_file():
            missing.append(relative)
            continue
        contents[relative] = path.read_text(encoding="utf-8")
    if missing:
        raise SystemExit(
            "missing application files, refusing to generate an incomplete "
            "manifest: " + ", ".join(missing)
        )
    return contents


def config_key(relative: str) -> str:
    """The ConfigMap key for an application file.

    Kubernetes validates a ConfigMap key against ``[-._a-zA-Z0-9]+``, so the
    obvious key - the file's path - is rejected outright for anything in a
    subdirectory. A slash becomes a dot instead, and the volume below maps the
    key back to the real path with an ``items`` entry.
    """
    return relative.replace("/", ".")


def config_items() -> list[tuple[str, str]]:
    """(key, path) pairs for the ConfigMap volume's ``items``.

    Two files whose paths differ only by directory separator would collide on
    the same key, so that is refused here rather than becoming a pod that
    silently loses a file.
    """
    pairs = [(config_key(relative), relative) for relative in APP_FILES]
    keys = [key for key, _path in pairs]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        raise SystemExit(
            "two application files map to the same ConfigMap key: "
            + ", ".join(duplicates)
        )
    return pairs


def literal_block(text: str, indent: int) -> str:
    """Render ``text`` as the body of a YAML literal block scalar.

    Empty lines are emitted empty rather than as indentation only: trailing
    whitespace is rejected by the repository's linting, and a genuinely blank
    line does not end a literal block.
    """
    pad = " " * indent
    body = text if text.endswith("\n") else text + "\n"
    lines = body.split("\n")[:-1]
    return "\n".join(pad + line if line else "" for line in lines)


def render_config_map(files: dict[str, str]) -> str:
    lines = [
        "---",
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        f"  name: {CONFIG_MAP}",
        f"  namespace: {APP_NAMESPACE}",
        "  labels:",
        f"    app.kubernetes.io/name: {APP_NAME}",
        "    app.kubernetes.io/part-of: aria-automation",
        "  annotations:",
        "    aria-automation/generated-by: web/tools/gen-manifest.py",
        "data:",
    ]
    for relative in sorted(files):
        lines.append(f"  {config_key(relative)}: |")
        lines.append(literal_block(files[relative], 4))
    return "\n".join(lines) + "\n"


def render_rbac() -> str:
    """The ServiceAccount, and the role that lets it read the build namespace.

    Two objects in two namespaces, because that is the shape of the problem:

    * the ServiceAccount is in ``packer-frontend``, alongside the pod that uses
      it - that is the only namespace a service account can live in;
    * the Role and RoleBinding are in ``packer-imaging``, because that is where
      the CronJobs and Jobs are. A RoleBinding may name a subject in another
      namespace, which is exactly what this does.

    The verbs are the narrowest set that makes the page work. ``patch`` on
    CronJobs is the only write to something this front end did not create;
    Jobs are created and deleted, which is what Build and Delete do. No Secret
    is readable - the page only ever prints their names.
    """
    return """\
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {account}
  namespace: {app_ns}
  labels:
    app.kubernetes.io/name: {app}
    app.kubernetes.io/part-of: aria-automation
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {account}
  namespace: {build_ns}
  labels:
    app.kubernetes.io/name: {app}
    app.kubernetes.io/part-of: aria-automation
  annotations:
    aria-automation/purpose: >-
      Lets the image builder front end in packer-frontend read and control the
      build CronJobs in this namespace.
rules:
  # The build definitions: read them, and pause or resume their schedules.
  - apiGroups: ["batch"]
    resources: ["cronjobs"]
    verbs: ["get", "list", "watch", "patch"]
  # Runs: read them, start one, delete a finished one.
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete"]
  # Pods are read to explain a run: why it is not starting, and which
  # container to read the log from.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  # The capacity bars.
  - apiGroups: [""]
    resources: ["resourcequotas"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {account}
  namespace: {build_ns}
  labels:
    app.kubernetes.io/name: {app}
    app.kubernetes.io/part-of: aria-automation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {account}
subjects:
# The subject lives in the other namespace: the pod runs in packer-frontend
  # and is authorised here.
  - kind: ServiceAccount
    name: {account}
    namespace: {app_ns}
""".format(
        account=SERVICE_ACCOUNT,
        app=APP_NAME,
        app_ns=APP_NAMESPACE,
        build_ns=BUILD_NAMESPACE,
    )


def render_deployment() -> str:
    """The Deployment, in ``packer-frontend``, reading ``packer-imaging``.

    The dependencies are installed into an emptyDir at start-up rather than
    baked into an image, because there is no registry on this cluster. That
    write is why ``/deps`` and ``/tmp`` are separate volumes: with
    ``readOnlyRootFilesystem`` the rest of the container is immutable and only
    those two paths can be written to.

    ``startupProbe`` gets three minutes. A cold pip install from PyPI takes tens
    of seconds and must not be mistaken for a crash loop; once it has passed,
    ``livenessProbe`` takes over with a five-second budget.
    """
    return """\
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {app}
  namespace: {app_ns}
  labels:
    app.kubernetes.io/name: {app}
    app.kubernetes.io/part-of: aria-automation
    app.kubernetes.io/component: web
  annotations:
    aria-automation/purpose: Web front end for starting and rebuilding images
spec:
  replicas: 1
  # The node's port 80 can only be held by one pod: rolling a second one up
  # before the first goes down would leave it Pending for ever.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: {app}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {app}
        app.kubernetes.io/part-of: aria-automation
        app.kubernetes.io/component: web
    spec:
      serviceAccountName: {account}
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: {image}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              if [ ! -f /deps/.installed ]; then
                echo "installing dependencies into /deps"
                pip install --quiet --no-cache-dir --target /deps \\
                  -r /app/requirements.txt
                touch /deps/.installed
              fi
              exec python /app/app.py
          ports:
            - name: http
              containerPort: {port}
              # The node's own port 80, so the page is reachable at
              # http://10.3.48.245/ without a proxy or an ingress.
              hostPort: {host_port}
              protocol: TCP
          env:
            # The namespace the page READS. This is not the namespace the pod
            # runs in: the builds are in packer-imaging, the app is here.
            - name: KUBE_NAMESPACE
              value: {build_ns}
            - name: FLASK_HOST
              value: "0.0.0.0"
            - name: FLASK_PORT
              value: "{port}"
            - name: REFRESH_SECONDS
              value: "8"
            - name: LOG_TAIL_DEFAULT
              value: "2000"
            # Set to "1" to publish the page read-only: builds cannot be
            # started, runs cannot be deleted, schedules cannot be changed.
            - name: READ_ONLY
              value: "0"
            - name: PYTHONPATH
              value: /deps
            - name: PYTHONUNBUFFERED
              value: "1"
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            - name: PIP_NO_CACHE_DIR
              value: "1"
            - name: HOME
              value: /tmp
            - name: TMPDIR
              value: /tmp
          volumeMounts:
            - name: app
              mountPath: /app
              readOnly: true
            - name: deps
              mountPath: /deps
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 3
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: app
          configMap:
            name: {config_map}
            # The keys are flat because a ConfigMap key cannot contain a
            # slash; these entries put the subdirectories back, so Flask finds
            # templates/ and static/ where it expects them.
            items:
{config_items}
        - name: deps
          emptyDir: {{}}
        - name: tmp
          emptyDir: {{}}
""".format(
        config_items="\n".join(
            f"              - key: {key}\n                path: {path}"
            for key, path in config_items()
        ),
        app=APP_NAME,
        app_ns=APP_NAMESPACE,
        build_ns=BUILD_NAMESPACE,
        account=SERVICE_ACCOUNT,
        image=IMAGE,
        port=CONTAINER_PORT,
        host_port=HOST_PORT,
        config_map=CONFIG_MAP,
    )


def render_service() -> str:
    """A NodePort as well as the host port.

    The host port only works on the node the pod happens to be on; the NodePort
    works on any node, so the page survives the pod being rescheduled.

    ``nodePort`` is deliberately left out. Pinning it looked tidier until the
    API server rejected the manifest because the previous deployment of this
    same page still held 30080 - a failure that depends on what is already
    installed, not on anything in the file. The cluster allocates one instead.
    """
    return """\
---
apiVersion: v1
kind: Service
metadata:
  name: {app}
  namespace: {app_ns}
  labels:
    app.kubernetes.io/name: {app}
    app.kubernetes.io/part-of: aria-automation
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: {app}
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
""".format(app=APP_NAME, app_ns=APP_NAMESPACE)


def render_manifest() -> str:
    files = read_app_files()
    return (
        HEADER
        + render_config_map(files)
        + render_rbac()
        + render_deployment()
        + render_service()
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the committed manifest does not match the source tree",
    )
    args = parser.parse_args(argv)

    rendered = render_manifest()

    if args.check:
        if not MANIFEST.is_file():
            print(f"{MANIFEST} does not exist", file=sys.stderr)
            return 1
        if MANIFEST.read_text(encoding="utf-8") != rendered:
            print(
                f"{MANIFEST} is out of date with web/.\n"
                "Regenerate it with: python web/tools/gen-manifest.py",
                file=sys.stderr,
            )
            return 1
        print(f"{MANIFEST} is up to date")
        return 0

    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(rendered, encoding="utf-8")
    files = read_app_files()
    print(f"wrote {MANIFEST.relative_to(REPO_ROOT)}")
    print(
        f"  {len(files)} application files, {rendered.count(chr(10))} lines, "
        f"app in {APP_NAMESPACE}, reads {BUILD_NAMESPACE}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
