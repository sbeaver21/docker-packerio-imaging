# Contributing

This repository builds the machine images that everything else is deployed from.
A change here reaches production through a template, so the review bar is higher
than for ordinary application code: a wrong partition layout or a missing package
is only discovered when a guest will not boot.

---

## Before you start

- Read `docs/architecture/overview.md` so you know which layer you are changing:
  build definition, unattended install template, provisioning script, or Ansible
  role.
- Check `docs/operations/validation.md`. All 31 projects validate. Thirteen stop
  on unset variables because they ship no local configuration, which is by
  design — not a defect, and not yours.
- Never commit a filled-in `*.auto.pkrvars.hcl`. See `docs/operations/secrets.md`.

---

## Getting set up

```shell
git clone https://github.com/sbeaver21/docker-packerio-imaging
cd docker-packerio-imaging
git switch -c feature/<short-description>
```

You need Packer, and for the Ansible-based Linux distributions, ansible-core:

```shell
packer version        # >= 1.15.0
ansible --version     # >= 2.16, only for ansible/ changes
```

ansible-core runs only on a POSIX control node. It cannot be started on Windows
at all: `ansible/utils/display.py` imports `fcntl` unconditionally, so the CLI
dies before it reads a playbook. If you are on Windows, make `ansible/` changes
under WSL, or at minimum expect to be unable to run the checks below. The same
applies to the eleven Ansible-provisioned builds — see *Build host* in
`README.md`.

Terraform is only needed for `terraform/` changes, and it is not on `PATH` by
default: the pinned release is fetched into `tools/terraform/` on demand.

```shell
./scripts/bootstrap/fetch-terraform.sh          # Windows: fetch-terraform.ps1
tools/terraform/terraform version               # 1.17.1
```

Create the local configuration for whichever build you are working on. It is
gitignored, so it stays on your machine:

```shell
cp builds/linux/almalinux/9/linux-almalinux.pkrvars.hcl.example \
   builds/linux/almalinux/9/linux-almalinux.auto.pkrvars.hcl
```

and fill in the vCenter, account and ISO values described in
`docs/reference/configuration.md`.

---

## Branch and commit conventions

Branches are named for the work:

```text
feature/<description>      new build, new distribution, new capability
fix/<description>          a defect in an existing build
docs/<description>         documentation only
chore/<description>        tooling, formatting, housekeeping
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <subject>
```

`type` is one of `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`.
`scope` is the area you touched, for example `photon`, `rhel`, `windows`,
`ansible`, `terraform`, `docs`.

```text
feat(builds/rhel96): add RHEL 9.6 build definition
fix(builds/photon5): restore the kickstart template the build reads
docs(reference): document every build variable
chore(fmt): apply packer fmt to all templates
```

Rules:

- Subject in the imperative mood, lower case, no trailing full stop, under 72
  characters.
- One logical change per commit. Do not combine a template rename with a
  formatting sweep.
- Reference the issue in the body if there is one:

  ```text
  fix(builds/ubuntu24): restore the autoinstall templates

  The build referenced data/ but the templates had been moved to data-local/,
  so packer validate failed with "no file exists at .../data/meta-data".

  Refs #1234
  ```

Do not commit:

- `*.auto.pkrvars.hcl`, `*.pkrvars.hcl`, `*.tfvars`, keys, certificates
- plugin caches (`.packer.d/`, `packer.d/`), `packer_cache/`
- build output (`manifests/*.json`, `artifacts/`, `*.iso`)
- editor or scratch files (`*.bak`, `*.save`, `*.old`, `*.last`, `*.sample`)
- the Windows ADK binaries under `references/**/amd64/` and
  `references/**/amd64.zip`; they are Microsoft's, they are 21 MB together, and
  the copy command in `references/README.md` restores them

`.gitignore` covers all of these. One deliberate exception: `.gitignore`
re-includes `tests/**/*.pkrvars.hcl`, because those fixture files carry disk
layouts and test addresses and never credentials. Do not "fix" that by deleting
the negation.

Run `git status` before you commit and read what is staged:

```shell
git add -A
git status
git diff --cached --stat
```

---

## What a change must pass

Run these before you open a pull request. The first two need no configuration at
all; the third needs a filled-in `*.auto.pkrvars.hcl` for the project, which is
why it is per-project rather than repository-wide.

```shell
# 1. Templates must be canonically formatted.
packer fmt -check -recursive .

# 2. Terraform examples must be formatted.
tools/terraform/terraform fmt -check -recursive terraform

# 3. The project you changed must initialise and validate.
packer init     builds/<the project you changed>
packer validate builds/<the project you changed>
```

On a project that ships no `*.pkrvars.hcl.example` — RHEL, most of Ubuntu, and
all ten Windows Server projects — step 3 fails on unset variables until you
write the configuration from the `variables*.pkr.hcl` declarations. That is
expected. A failure for any *other* reason is not.

If you are validating on Windows, note that `packer-plugin-vsphere` 2.5.1
panics on an `export` block that omits `directory_permission`, and reports it as
`unexpected EOF` rather than as a diagnostic. The Ubuntu projects set
`directory_permission = "0750"` explicitly for that reason; keep it when you
copy one. See `docs/operations/validation.md`.

`packer fmt -check -recursive .` walks the repository root, so it covers
`references/` as well as `builds/`. A template there that is not canonically
formatted fails the same gate.

### Vendor reference material under `references/`

Those templates are not built by this repository, so they are held to syntax
only — but the formatting gate still applies, and they are initialised and
validated **per file**, because each directory holds several independent
templates that declare the same variable names:

```shell
cd references/supervisor-images/site
packer init                  rhel-9-6.pkr.hcl
packer validate -syntax-only rhel-9-6.pkr.hcl
```

`packer init .` fails with `Duplicate variable` for that reason, and a plain
`packer validate` needs a kubeconfig for the Supervisor cluster. Neither is a
defect in the template. See `docs/operations/validation.md` for what has been
checked there and what has not.

Do not "fix" a failure in that material by editing this repository's build
projects: they share no code. If the material needs a change, change it there
and say in the pull request which template you validated.

If `packer fmt -check` reports files you did not touch, format **only** the
files in your change:

```shell
packer fmt builds/<path>/<file>.pkr.hcl
```

and leave the rest for a dedicated formatting commit.

### Template rendering tests

The network and storage answer-file templates have golden-file tests. If you
changed anything in `tests/*/templates/`, or the network or storage variables,
run them:

```shell
cd tests/network && bats test
cd tests/storage && bats test
```

Each suite writes `<suite>/output/<config>/<source>` and compares it against
`<suite>/golden/<base>-<source><-swap>`. The two paths differ in shape, so
compare the case you changed rather than globbing:

```shell
# tests/storage/output/lvm/autoinstall  ->  tests/storage/golden/lvm-autoinstall
# tests/storage/output/lvm-swap/autoinstall -> tests/storage/golden/lvm-autoinstall-swap
diff -u tests/storage/golden/lvm-autoinstall tests/storage/output/lvm/autoinstall
```

Update a golden file deliberately, and only after confirming the diff is what
you intended. The goldens end with a trailing newline and the builders supply
it, so a diff that shows only `\ No newline at end of file` means the template
lost its final newline.

### Ansible changes

```shell
ansible-playbook -i localhost, ansible/linux-playbook.yml  --syntax-check
ansible-playbook -i localhost, ansible/windows-playbook.yml --syntax-check
ansible-lint ansible/
```

There is no inventory file in the repository: the Packer provisioner builds a
one-host inventory at build time and passes the variables it collected. The
`-i localhost,` above exists only to satisfy `ansible-playbook` for a parse and
matches no real target — `--syntax-check` runs no task.

`ansible-lint` is not in the dependency list in
`docs/getting-started/requirements.md`; install it separately. It also wants a
POSIX control node, for the reason given under *Getting set up*.

### Terraform changes

```shell
./scripts/bootstrap/fetch-terraform.sh           # Windows: the .ps1

cd terraform/vsphere-role
../../tools/terraform/terraform init -backend=false
../../tools/terraform/terraform validate
```

Use the pinned binary rather than whatever `terraform` resolves to on your
machine: the version in `scripts/bootstrap/terraform.lock` is the one the module
was checked with, and the fetch verifies its SHA-256 before installing it.

`terraform validate` needs no vCenter connection; `terraform plan` does. Do not
run `plan` or `apply` against a production vCenter to test a change.

### A real build

Formatting and validation prove the template parses. They do not prove an image
boots. Before merging a change to a build definition, an unattended install
template or a provisioning script, build the image and boot a clone:

```shell
packer build builds/<path>
```

and confirm, on the clone:

- the guest boots and the account from `build_username` can log in,
- the network is DHCP unless the build is meant to be static,
- `cloud-init` or the installer did not leave a stale machine identity,
- for Linux, the expected packages are present and the services the scripts
  configure are running,
- for Windows, Windows Update completed and the hardening payload ran.

State in the pull request which build you ran and what the clone showed.

---

## Changing a build definition

A project is self-contained. Adding a version means copying the nearest one and
editing, not editing a shared file:

```text
builds/<family>/<version>/
├── <name>.pkr.hcl               builder source and build block
├── variables.pkr.hcl            input variable declarations
├── variables-network.pkr.hcl    network inputs, where the build takes them
├── variables-storage.pkr.hcl    storage inputs, where the build takes them
├── data/                        unattended install templates (must exist)
│   ├── ks.pkrtpl.hcl            or preseed.cfg / autoinstall / Autounattend.xml
│   ├── network.pkrtpl.hcl
│   └── storage.pkrtpl.hcl
└── <name>.pkrvars.hcl.example   the shape of the local configuration
```

Checklist for a new build:

- [ ] `data/` exists **in the project directory**. The template resolves
      `${path.root}/data/...`, which is the project directory, not the
      repository root.
- [ ] `packer init` and `packer validate` pass with a real configuration.
- [ ] The `packer {}` block pins plugin versions, and every plugin the build
      uses is listed there.
- [ ] The manifest post-processor writes to `manifests/`.
- [ ] A `*.pkrvars.hcl.example` documents every variable the project needs,
      with placeholder values only.
- [ ] `docs/reference/builds.md` lists the new project.
- [ ] The image was built and a clone was booted.

One exception to the tree above: the Windows Server projects carry no `data/` of
their own. They name the shared template in full, four levels up from
`path.root`, as `scripts/windows/data/autounattend.pkrtpl.hcl`. Copying a Linux
project to make a Windows one will leave `templatefile()` pointing at a `data/`
that does not exist, and `packer validate` will say so.

---

## Changing documentation

Documentation lives in two places and both must stay true:

- **`docs/`** — the MkDocs Material site. `mkdocs.yml` defines the navigation;
  a page that is not in the navigation will not appear.
- **README files** — one per top-level directory, describing what that directory
  holds.

`mkdocs.yml` is plain YAML and must stay that way, so it can be read by any YAML
tool. Where a Markdown extension needs a Python callable — `pymdownx.emoji`
needs Material's icon index and SVG generator — the callable is attached by a
script under `hooks/` rather than with PyYAML's `!!python/name:` tag, which
generic YAML parsers report as an unresolved tag. Add new hooks to the `hooks`
key in `mkdocs.yml`.

Rules:

- Describe what the code does now, not what it is meant to do later. If a file
  the documentation refers to does not exist, fix the reference or create the
  file — the previous revision of these docs pointed at build scripts and
  example variable files that were not in the repository.
- Do not copy upstream VMware documentation without adapting it. This repository
  is not the sample project: it has fixed addresses, site inventory names, and
  no `build.sh`, `config.sh` or `download.sh` menu scripts.
- Preview before you commit:

  ```shell
  pip install mkdocs-material
  mkdocs serve
  ```

- Then run the two gates that `serve` does not enforce:

  ```shell
  npx markdownlint-cli2 "**/*.md"
  python -m mkdocs build --strict
  ```

  `--strict` turns a warning into a failure, so it aborts on a navigation entry
  pointing at a page that is not there and on a relative link that does not
  resolve. That is the check that catches a dead cross-reference; `serve`
  prints the warning and carries on.

---

## Review and merge

1. Open a pull request against `main` with the checks above recorded.
2. One reviewer is enough for documentation, formatting and new build
   definitions.
3. A change to a shared provisioning script, an Ansible role, or anything under
   `builds/windows/files/` needs a second reviewer, because it changes every
   image built after it merges.
4. Merge with a merge commit so the branch's commits and the merge point are
   both visible in history.

---

## Reporting problems

Defects in a build definition, a missing template, or a failed validation belong
in an issue against this repository. Include the exact command you ran and the
exact output — `packer validate` output names the file and line, and that is
usually the whole diagnosis.

Security issues do not go in an issue. See `SECURITY.md`.

All participants are expected to follow the Code of Conduct, `CODE_OF_CONDUCT.md`.
