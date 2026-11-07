# web

The web front end: a Flask application that reads the build CronJobs and their
Jobs from the Kubernetes API, and can start a run, pause a schedule, delete a
finished run and show a run's log.

Two namespaces, deliberately:
`packer-frontend` holds this Deployment, its ServiceAccount and its ConfigMap;
`packer-imaging` holds the builds it reads. The page is served from a node's
port 80, so it is reachable at `http://10.3.48.245/`.

```text
web/
├── app.py              application factory and entrypoint
├── config.py           settings, read from the environment
├── kube.py             the only module that talks to the Kubernetes API
├── services.py         per-application collaborators, registered on the app
├── projects.py         a CronJob described as the project a user sees
├── runs.py             a Job described as a run: state, identity, duration
├── naming.py           names and labels for an on-demand run
├── quantities.py       CPU/memory quantities, parsed and humanised
├── k8stime.py          Kubernetes timestamps
├── api.py              the JSON API the browser calls
├── pages.py            the three HTML shells and /healthz
├── templates/          base.html plus one shell per page
├── static/             one script per page, plus core.js and style.css
├── tests/              the unit tests, and the fake gateway they use
├── tools/dev-server.py serve the real UI over fixture data, no cluster
├── tools/gen-manifest.py  generate the Kubernetes manifest from this directory
├── requirements.txt    Flask, kubernetes, waitress
└── Dockerfile          for a host that has a registry
```

## Running it

Against fixture data, which is how a UI change is looked at:

```shell
python web/tools/dev-server.py
# dashboard on http://127.0.0.1:8080/
```

Against a real cluster, using whatever `kubectl` already uses:

```shell
cd web
pip install -r requirements.txt
KUBE_NAMESPACE=packer-imaging python app.py
```

## Tests

From this directory:

```shell
set PYTHONPATH=.;tests
python -m unittest test_api test_job_body test_k8stime test_manifest test_naming ^
    test_projects test_quantities test_runs test_theme
```

`test_manifest.py` compares `kubernetes/workloads/web-frontend.yaml` with what
`tools/gen-manifest.py` renders now, so it fails if the committed manifest has
drifted from this directory. Regenerate with:

```shell
python web/tools/gen-manifest.py
python web/tools/gen-manifest.py --check   # what the pipeline runs
```

There is no registry on the target cluster: the front end is deployed by
mounting its files from a ConfigMap, which is why that copy has to be generated
rather than hand-maintained.

See [docs/operations/web-front-end.md](../docs/operations/web-front-end.md) for
the deployment, the configuration variables and the read-only mode.
