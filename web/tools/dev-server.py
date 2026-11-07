"""Run the dashboard against fixture data, with no cluster.

The page is a view over a Kubernetes namespace, which makes it awkward to work
on: a laptop with no cluster sees an empty screen, and a cluster with no builds
in flight sees almost the same. This serves the real application - the same
routes, the same templates, the same client script - over a fake gateway filled
with the states that are hard to reproduce on demand: a build in progress, a
failed build, a paused schedule, a run whose pod the scheduler will not place,
and a run whose CronJob has been deleted.

    python web/tools/dev-server.py
    python web/tools/dev-server.py --port 9000 --read-only

Nothing here is imported by the application or by the tests; it exists so a
change to the UI can be looked at.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

WEB_ROOT = Path(__file__).resolve().parent.parent
# The fixtures live with the tests and the application one level up, which is
# not on sys.path when a script is run by path. The same two directories are
# declared in pyrightconfig.json, because a type checker cannot follow this
# loop and would otherwise report every import below as unresolved.
for path in (WEB_ROOT, WEB_ROOT / "tests"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from support import FakeGateway, make_cronjob, make_job, make_pod, make_quota  # noqa: E402

from app import create_app  # noqa: E402
from config import load_settings  # noqa: E402

PHOTON = "aria-build-photon-5"
RHEL = "aria-build-rhel-96"
UBUNTU = "aria-build-ubuntu-24-04"
WINDOWS = "aria-build-windows-2022"
ORPHAN = "aria-build-retired-project"

#: The two containers every build pod has, in the order the job template
#: declares them: the checkout init container, then the build.
LOG_SAMPLE = """\
2026/10/25 03:00:05 packer-builder: waiting for machine to boot
2026/10/25 03:01:12 packer-builder: machine booted, 1m07s
2026/10/25 03:01:13 packer-builder: running provisioning script 01-common.sh
2026/10/25 03:04:48 packer-builder: running provisioning script 02-vmware-tools.sh
2026/10/25 03:09:02 packer-builder: running provisioning script 03-node-prep.sh
2026/10/25 03:18:31 packer-builder: provisioning complete
2026/10/25 03:18:32 packer-builder: converting to template 'photon-5-2026.10.25'
2026/10/25 03:41:07 packer-builder: template written
2026/10/25 03:42:05 packer-builder: build finished
"""


def demo_gateway() -> FakeGateway:
    cronjobs = [
        make_cronjob(name=PHOTON, project="photon-5", family="linux"),
        make_cronjob(
            name=RHEL,
            project="rhel-96",
            family="linux",
            schedule="0 4 * * 0",
            purpose="Weekly rebuild of the RHEL 9.6 node template",
            secret="pkrvars-rhel-96",
            packer_project="builds/linux/rhel/96",
        ),
        make_cronjob(
            name=UBUNTU,
            project="ubuntu-24-04",
            family="linux",
            schedule="0 5 1 * *",
            purpose="Monthly rebuild of the Ubuntu 24.04 node template",
            secret="pkrvars-ubuntu-24-04",
            packer_project="builds/linux/ubuntu/24-04-lts",
        ),
        make_cronjob(
            name=WINDOWS,
            project="windows-2022",
            family="windows",
            schedule="30 1 * * 6",
            suspend=True,
            purpose="Weekly rebuild of the Windows Server 2022 node template",
            secret="pkrvars-windows-2022",
            packer_project="builds/windows/server/2022",
        ),
    ]

    jobs = [
        # A finished, successful run.
        make_job(name=f"{PHOTON}-29000004", state="succeeded"),
        # A failed run, with the controller's own message.
        make_job(
            name=f"{RHEL}-29000003",
            project="rhel-96",
            owner=RHEL,
            state="failed",
            state_message="build 'rhel-96' errored: vSphere task timed out after 30m",
        ),
        # A run in progress.
        make_job(name=f"{UBUNTU}-29000002", project="ubuntu-24-04", owner=UBUNTU, state="running"),
        # A run the scheduler refuses to place.
        make_job(name=f"{WINDOWS}-29000001", project="windows-2022", owner=WINDOWS, state="pending"),
        # A run from a pipeline, carrying no owner reference at all - it has to
        # be attached to its project by the project label.
        make_job(
            name=f"{PHOTON}-manual-4821",
            owner=None,
            state="succeeded",
            labels={"packer.io/project": "photon-5"},
        ),
        # A run whose CronJob has been deleted: shown, with no Build button.
        make_job(
            name=f"{ORPHAN}-29000009",
            project="retired-project",
            owner=ORPHAN,
            state="succeeded",
        ),
    ]

    pods = {
        f"{UBUNTU}-29000002": [make_pod(name=f"{UBUNTU}-29000002-x7k2p")],
        f"{WINDOWS}-29000001": [
            make_pod(
                name=f"{WINDOWS}-29000001-4m9qz",
                phase="Pending",
                unschedulable=(
                    "0/1 nodes are available: 1 Insufficient pods. "
                    "preemption: 0/1 nodes are available: 1 No preemption victims found."
                ),
            )
        ],
        f"{PHOTON}-29000004": [make_pod(name=f"{PHOTON}-29000004-abcde", phase="Succeeded")],
    }

    quota = [
        make_quota(
            pods_hard="16",
            pods_used="6",
            jobs_hard="80",
            jobs_used="23",
        )
    ]

    gateway = FakeGateway(cronjobs=cronjobs, jobs=jobs, pods=pods, quota=quota)
    gateway.logs[f"{PHOTON}-29000004"] = LOG_SAMPLE
    return gateway


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Serve the dashboard over fixture data")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="serve with READ_ONLY=1, as a published deployment would",
    )
    args = parser.parse_args(argv)

    overrides = {
        # The build namespace, matching the Kubernetes manifest. The app is
        # deployed in packer-frontend but reads packer-imaging.
        "KUBE_NAMESPACE": "packer-imaging",
        "FLASK_HOST": args.host,
        "FLASK_PORT": str(args.port),
        "REFRESH_SECONDS": "5",
    }
    if args.read_only:
        overrides["READ_ONLY"] = "1"

    app = create_app(load_settings(overrides), demo_gateway())
    app.config.update(DEBUG=False, TESTING=False)

    print(f"dashboard on http://{args.host}:{args.port}/  (fixture data, no cluster)")
    print(f"  {len(demo_gateway().cronjobs)} projects, {len(demo_gateway().jobs)} runs")
    # The reloader is off deliberately: it re-imports this module in a child
    # process, which would build a second copy of the fixtures and double the
    # console output on every change.
    app.run(host=args.host, port=args.port, debug=False, use_reloader=False, threaded=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
