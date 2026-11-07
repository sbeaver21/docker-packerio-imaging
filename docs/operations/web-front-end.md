# Web front end

`web/` is a Flask application that answers the question the cluster cannot: what
state are the builds in, and can I rebuild one. It reads the build CronJobs and
their Jobs from the Kubernetes API and can start a run, pause a schedule, delete
a finished run and show a run's log.

It is a view over the cluster, not a second source of truth. There is no list of
projects in the code: a project appears because its CronJob exists, and its name
comes from that CronJob's `packer.io/project` label. Adding or removing a build
project changes this page with no code change and no redeploy, provided the
CronJob that runs it carries the label.

## The three pages

| Page | Question it answers |
| :--- | :------------------ |
| `/` | What state is the namespace in, and is anything wrong right now |
| `/build` | Start a run, or pause a schedule |
| `/runs` | What happened: the run list, logs, and deleting a run |

Every page is a shell. Everything inside it is drawn from `GET /api/overview`
by that page's own script, so one refresh is one consistent snapshot rather than
a project list that is one poll ahead of the run list. The browser builds the DOM
with `textContent` and `document.createElement`, never `innerHTML` with a value
that came from the cluster.

`/healthz` answers without touching the cluster. That is deliberate: a liveness
probe that fails when Kubernetes is unreachable would restart a web server that
is working and simply has nothing to show.

## Two namespaces

| Namespace | Holds |
| :-------- | :---- |
| `packer-frontend` | this Deployment, its ServiceAccount, its ConfigMap |
| `packer-imaging` | the build CronJobs and Jobs the page reads and starts |

The pod runs in `packer-frontend` and is authorised in `packer-imaging`, so the
Role and RoleBinding live in the second namespace and name the ServiceAccount in
the first as their subject. `KUBE_NAMESPACE` must name the namespace being
**read**; getting it wrong is not an error, it is an empty project list.

The Role grants `get`/`list`/`watch`/`patch` on CronJobs, `get`/`list`/`watch`/
`create`/`delete` on Jobs, read on Pods and `pods/log`, and read on
ResourceQuotas. No Secret is readable — the page only ever prints their names.

## Deployment

There is no registry on the target cluster, so the application is deployed by
mounting its files from a ConfigMap rather than by pulling an image. The
manifest is therefore a copy of this directory, and a copy made by hand goes
stale in silence — the UI keeps working while running last month's code.

`web/tools/gen-manifest.py` is the only way that copy is made. It inlines an
explicit list of files (not a glob: the tests and the Dockerfile must not end up
at `/app`) and writes the whole manifest:

```shell
python web/tools/gen-manifest.py
python web/tools/gen-manifest.py --check   # exit 1 if the copy has drifted
```

Run it after any change under `web/`. `web/tests/test_manifest.py` compares the
committed file against a fresh render, so a change that forgets this fails the
test suite rather than the deployment.

Apply order matters once — the chart creates both namespaces, and
`packer-frontend` has to exist before the manifest can be applied into it:

```shell
helm upgrade --install packer-imaging kubernetes/charts/packer-imaging \
  --namespace packer-imaging --create-namespace
kubectl apply -f kubernetes/workloads/web-frontend.yaml
kubectl -n packer-frontend get service aria-image-builder-web   # the NodePort
```

The page is served on the node's port 80 (`http://10.3.48.245/`) and also on a
NodePort the cluster allocates. The NodePort is not pinned: a fixed number
collides with whatever held it last time, and that failure only appears at apply
time.

Where a registry does exist, `web/Dockerfile` builds the same application:

```shell
docker build -t aria-image-builder-web web
docker run --rm -p 8080:8080 -v "$HOME/.kube:/home/app/.kube:ro" aria-image-builder-web
```

## Configuration

Everything comes from the environment, so the same code runs in the cluster,
on a workstation, and in tests.

| Variable | Default | Meaning |
| :------- | :------ | :------ |
| `KUBE_NAMESPACE` | `packer-imaging` | Namespace the page reads |
| `KUBE_HOST` | `10.3.48.245` | API server host |
| `KUBE_PORT` | `6443` | API server port |
| `KUBE_TOKEN` | — | Bearer token; the mounted service account is used when unset |
| `KUBE_CA_FILE` | — | CA bundle for the API server |
| `KUBE_VERIFY_SSL` | `0` | Verify the API server certificate |
| `KUBE_TIMEOUT_SECONDS` | `20` | Per-request timeout, clamped to 1–120 |
| `FLASK_HOST` | `0.0.0.0` | Listen address |
| `FLASK_PORT` | `8080` | Listen port |
| `REFRESH_SECONDS` | `15` | Browser poll interval, clamped to 5–300 |
| `LOG_TAIL_DEFAULT` | `2000` | Log lines fetched by default, clamped to 50–20000 |
| `READ_ONLY` | `0` | Refuse every write |

Out-of-range and unparseable values are clamped or ignored rather than raised: a
mistyped environment variable should not stop a container from starting.

## Read-only mode

`READ_ONLY=1` publishes the page without the controls that change anything: no
Build button, no delete, no pause. The mutating endpoints answer 403 rather than
being hidden, so a stale tab reports why instead of failing obscurely. That is
the safe way to show this to a wider audience — everyone can see builds and logs,
nobody can start one by accident.

## Working on it

```shell
python web/tools/dev-server.py            # the real UI over fixture data
python web/tools/dev-server.py --read-only
```

The fixture gateway holds the states that are hard to reproduce on demand: a run
in progress, a failed run with the controller's message, a paused schedule, a run
whose pod the scheduler will not place, and a run whose CronJob has been deleted.
Because the fixtures name real projects, a project removed from `builds/` should
be removed from them too — `rhel-94` was renamed to `rhel-96` when those builds
were trimmed.

Tests, from `web/` (the suite is 224 cases and needs no cluster):

```shell
set PYTHONPATH=.;tests
python -m unittest test_api test_job_body test_k8stime test_manifest test_naming ^
    test_projects test_quantities test_runs test_theme
```

## Related

- `web/README.md` — the module map and how to run it.
- `kubernetes/README.md` — the chart that creates the CronJobs this page reads.
- `kubernetes/workloads/web-frontend.yaml` — the generated manifest.
- [Secrets](secrets.md) — what the page deliberately cannot read.
