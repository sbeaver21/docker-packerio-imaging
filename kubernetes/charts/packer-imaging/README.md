# packer-imaging

Build CronJobs for the Packer image pipeline, and the namespaces, quota and
limits they run under.

One CronJob per project in `.values.projects`. The chart does not build anything
itself: each CronJob checks the repository out, runs `packer init` then
`packer build` on one project directory, and exits. What that produces is decided
by the Packer template, not by this chart.

## What it creates

| Kind | How many | Purpose |
| :--- | :------- | :------ |
| `Namespace` | 2 | one for the builds, one for the web page |
| `CronJob` | one per project | the schedule and the build pod |
| `ResourceQuota` | 1 | the capacity a build competes for |
| `LimitRange` | 1 | per-pod ceiling, and the default when none is set |

It does not create any Secret. Both Secrets a build needs carry credentials, so
they are provisioned separately — see [Secrets](../../../docs/operations/secrets.md).

## Installing

```shell
helm upgrade --install packer-imaging kubernetes/charts/packer-imaging \
  --namespace packer-imaging --create-namespace
```

`NOTES.txt` prints the two Secrets to create and the names it expects, resolved
from the values you installed with.

## Values

### Namespaces

| Value | Default | Meaning |
| :---- | :------ | :------ |
| `namespaces.create` | `true` | create both namespaces |
| `namespaces.builds` | `packer-imaging` | where the CronJobs and Jobs live |
| `namespaces.frontend` | `packer-frontend` | where the web page lives |

### Naming

| Value | Default | Meaning |
| :---- | :------ | :------ |
| `jobPrefix` | `aria-build-` | prefix on every CronJob name |
| `labels.partOf` | `aria-automation` | `app.kubernetes.io/part-of` |

`jobPrefix` must equal `PROJECT_PREFIX` in `web/runs.py`. This is the one value
that silently degrades the dashboard rather than failing: change it alone and the
page still works, and every run loses its project.

### Build pod

| Value | Default | Meaning |
| :---- | :------ | :------ |
| `runner.image` | `ghcr.io/sbeaver21/packer-imaging-runner:1.0.0` | the build image |
| `runner.workDir` | `/workspace` | where the repository is checked out |
| `runner.pluginCacheDir` | `/var/cache/packer` | where `packer init` installs |
| `repo.url` | this repository | what the init container clones |
| `repo.ref` | `refs/heads/main` | branch, tag or commit |
| `repo.credentialsSecret` | `aria-repo-credentials` | `username` and `password` |
| `scripts.configMap` | `aria-image-build-scripts` | scripts mounted at `/scripts` |

The runner image is built from `kubernetes/runner/`. It carries Packer plus
ansible-core and the usual CLI tools, and no Packer plugins: each project pins its
own, and `packer init` installs them per run.

### Defaults and per-project overrides

Every key under `defaults` can be overridden on an individual project, by adding
the same key to that project's entry.

| Value | Default | Meaning |
| :---- | :------ | :------ |
| `defaults.schedule` | `0 3 * * 0` | cron expression, in `timeZone` |
| `defaults.timeZone` | `America/New_York` | the zone the schedule is read in |
| `defaults.concurrencyPolicy` | `Forbid` | a second run waits instead of competing |
| `defaults.backoffLimit` | `0` | never retry a failed build |
| `defaults.activeDeadlineSeconds` | `7200` | two hours, then the Job is killed |
| `defaults.ttlSecondsAfterFinished` | `604800` | finished Jobs kept for a week |
| `defaults.args` | `["-force"]` | passed to `packer build` |
| `defaults.resources` | 2 CPU, 4Gi request | per build pod |

`backoffLimit: 0` is not an oversight. A failed Packer build has usually left a
half-built VM on the datastore; retrying it silently makes that worse, so the run
fails once, visibly, and the log says why.

### Capacity

| Value | Default | Meaning |
| :---- | :------ | :------ |
| `quota.enabled` | `true` | create the ResourceQuota |
| `quota.hard` | 16 pods, 8 CPU, 16Gi | what the namespace may consume |
| `limitRange.enabled` | `true` | create the LimitRange |
| `limitRange.max` | 8 CPU, 16Gi | ceiling for one build pod |

A build holds a virtual machine for the length of an install, so `pods` is the
constraint that actually stops a build starting. When the quota is full the pod
stays unschedulable, and the web page shows the run as blocked rather than
pending — that is the difference the capacity panel exists to make visible.

### Projects

`projects` is a list; each entry takes:

| Key | Required | Meaning |
| :-- | :------- | :------ |
| `name` | yes | becomes the CronJob name after `jobPrefix` |
| `path` | yes | project directory, relative to the repository root |
| `family` | yes | `linux` or `windows`, shown on the project card |
| `purpose` | no | one line describing the build |
| `schedule` | no | overrides `defaults.schedule` |
| `suspend` | no | install the CronJob paused |
| `args`, `resources`, `timeZone`, `concurrencyPolicy` | no | as above |

`path` must be a real directory containing that project's `*.pkr.hcl` files. It
is not validated at install time: a typo installs cleanly and fails on the first
run, in the build log, as a `cd` into a directory that is not there.

The Windows per-edition projects install with `suspend: true` on purpose. The
`windows-server-2022` and `windows-server-2025` parents already build all four
editions in one run, so scheduling the per-edition entries as well would build
each edition twice. They exist to rebuild one edition on demand.

## What the build pod does

1. `checkout` — an init container clones `repo.url` at `repo.ref` into `workDir`.
   It runs as the same uid as the build so the build can write its manifest into
   the checkout.
2. `packer` — changes into `PACKER_PROJECT`, runs `packer init .`, then
   `packer build` with every `*.hcl` file from the project's pkrvars Secret
   passed as `-var-file`.

The Secret is mounted at `/pkrvars`, not onto the project directory. Mounting it
onto the project directory would hide the checked-out templates the build needs to
read, which is a mistake that looks like a missing variable rather than a missing
file.

## Environment the web page reads

Three variables on the build container are shown in the UI:

| Variable | Value |
| :------- | :---- |
| `PACKER_PROJECT` | the project `path` |
| `PACKER_BUILD_ARGS` | `args` joined by spaces |
| `GIT_REF` | `repo.ref` |

None is a secret, which is why they are safe to display. Do not add anything to
that list that is.
