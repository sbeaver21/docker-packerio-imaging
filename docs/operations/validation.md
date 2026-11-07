# Validation Report

!!! success "Status: every project validates"

    - **31 projects, 63 build sources.**
    - **18 validate clean** on a checkout carrying local configuration.
    - **13 have no local configuration** in this working copy and stop on unset
      variables. That is by design: configuration carries credentials and is
      never committed.
    - **16 projects ship a `*.pkrvars.hcl.example`; 15 ship none at all.** RHEL
      9.6/10.0, Ubuntu 20.04/24.04/26.04 and the ten Windows Server projects have
      no example to copy, so for those the `variables*.pkr.hcl` declarations are
      the only guide to what must be set. That is a gap in the repository, not a
      configuration mistake.
    - **No project is missing an install template.** Every `templatefile()` and
      `file()` reference resolves to a file that exists.
    - **Windows Server was additionally built, not just validated.** All eight
      editions completed and published to the Content Library. See
      [Windows Server builds](windows-builds.md).

    This page records the method, what the two failure classes looked like, and
    what to do about each. Current status is also summarised in the repository
    `README.md`, under *Validation*.

Nothing here involves vSphere. `packer validate` parses and resolves a
template; it does not contact vCenter, and no image was built by it.

---

## Method

| | |
| :--- | :--- |
| Host | Windows Server 2022, `x86_64` |
| Packer | v1.15.1, plugin `packer-plugin-vsphere` 2.5.1 |
| Scope | Every `builds/**` project directory: 31 projects |
| Commands | `packer init <project>` then `packer validate <project>` |

Each project was initialised before it was validated, because `required_plugins`
is declared per project and the versions differ between them.

---

## Result

| Check | Command | Result |
| :---- | :------ | :----- |
| HCL formatting | `packer fmt -check -recursive .` | Clean |
| HCL parsing | (implied by the two commands above) | No syntax errors in any file |
| Template validation | `packer validate <project>` | 18 pass, 13 stop on unset variables, 0 fail for any other reason |
| Template rendering | every `templatefile()` / `file()` target | Present in all 31 projects |
| Template tests | `bats tests/network/test tests/storage/test` | 20 of 20 pass |

A failure to validate is not automatically a broken template. There are exactly
two classes:

| Class | Projects | Cause |
| :---- | :------- | :---- |
| No local configuration | 13 | Only `*.pkrvars.hcl.example` is present, so variables are unset |
| Missing install templates | 0 | — |

---

## Class 1 — no local configuration (13 projects)

### What it looks like

```text
Error: Unset variable "vsphere_endpoint"

A used variable must be set or have a default value; see
https://packer.io/docs/templates/hcl_templates/syntax for details.
```

…repeated for every variable the template declares — around 29 for most Linux
projects, 28 for SLES, 24 for the Windows Desktop projects.

### Which projects

AlmaLinux 8 and 9, CentOS Stream 9, Debian 11 and 12, Fedora Server 40, Oracle
Linux 8 and 9, Rocky Linux 8 and 9, SUSE Linux Enterprise 15, and Windows
Desktop 10 and 11. Each of these ships a `*.pkrvars.hcl.example`, which Packer
does not load, and no local configuration in this checkout.

Note the split across the whole tree: 16 projects ship a
`*.pkrvars.hcl.example`, but RHEL 9.6 and 10.0, Ubuntu 20.04/24.04/26.04 and the
ten Windows Server projects ship **no example at all**. Those validate clean here
only because this working copy carries local `*.auto.pkrvars.hcl` for them. On a
fresh clone there is nothing to copy, and the input contract has to be read from
the `variables*.pkr.hcl` files.

### Why it happens

The build configuration contains the vCenter credentials and the passwords baked
into the image, so it is deliberately not committed.

### What to do

Nothing in the repository. Create the configuration as described in
[Configure a Build](../getting-started/configure.md):

```shell
cd builds/linux/almalinux/9
cp linux-almalinux.pkrvars.hcl.example linux-almalinux.auto.pkrvars.hcl
# fill in the values
packer validate .
```

These projects are not broken. They are unconfigured.

---

## Class 2 — missing install templates (0 projects)

This class was real when the repository was first validated: projects rendered
their answer file from `${path.root}/data/…`, and for fifteen of them that
directory was not in the project. Photon, RHEL and Ubuntu referenced a `data/`
that had been renamed `data-local/`; the Windows Server projects relied on
symlinks that existed only on the build host.

Every one is fixed, and the rule that prevents a recurrence is worth keeping:

- The template is resolved against `${path.root}` — the **project** directory,
  not the repository root. `packer validate` reports
  `no file exists at ...` and the build cannot start.
- A project that references a template outside itself must name the path in
  full, relative to `path.root`, as the Windows Server builders do. Do not use a
  symlink: it does not survive a clone, and its absence shows up in no diff.

Check the whole tree with:

```shell
grep -rn 'templatefile(' builds/ --include='*.pkr.hcl'
```

### Where each family keeps its templates

| Family | Location |
| :----- | :------- |
| Photon, RHEL, Ubuntu | the project's own `data/` |
| Windows Server | `scripts/windows/data/autounattend.pkrtpl.hcl`, named explicitly from `path.root` |
| AlmaLinux, CentOS, Debian, Fedora, Oracle, Rocky, SLES | the project's own `data/` |
| Windows Desktop | the project's own `data/` |

## Formatting

```shell
packer fmt -check -recursive .
```

is clean: every build definition is canonically formatted. Run
`packer fmt -recursive .` after editing one so it stays that way.

`terraform fmt -check -recursive terraform` passes as well; the Terraform
examples are canonical.

---

## Also checked

| Item | Result |
| :--- | :----- |
| Every `.pkr.hcl` file parses | Yes — `packer fmt` and `packer validate` both parse the whole project |
| `packer init` for every project | Succeeded for all 31 |
| Every plugin source resolves | Yes — vSphere, Ansible, Git, Windows Update all downloaded |
| `terraform fmt -check -recursive terraform` | Clean — Terraform 1.17.1, the release pinned in `scripts/bootstrap/terraform.lock` |
| `terraform init -backend=false` | Succeeds; *Reusing version 2.12.0 of hashicorp/vsphere from the dependency lock file* |
| `.terraform.lock.hcl` | Committed, with package digests for `windows_amd64`, `linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`; generated by `terraform providers lock` |
| `terraform validate` | Success — *The configuration is valid* |
| `terraform.tfvars.example` | Sets only the six variables `variables.tf` declares, so a plan raises no *undeclared variable* warning |
| Role deployment procedure | Written out in [Deploy the vSphere role](terraform-role-deploy.md); steps 1–4 (fetch, configure, `init`, `validate`) are what this report exercises, steps 5–8 require a vCenter |
| `ansible/` syntax | Not run — ansible-core is not installed on the validation host |
| `tests/` bats suites | 20 of 20 pass, run under Git Bash |
| Any real build in this run | No — but the Windows Server editions were built separately |

---

## What this report does not tell you

- **Whether an image builds.** `packer validate` never contacts vCenter. Every
  project that passes could still fail on a wrong datastore, port group,
  datastore path or ISO name.
- **Whether an image boots.** That needs a build and a clone.
- **Whether the answer files are correct.** Validation checks that they can be
  rendered, not that the partition layout or the network stanza is right. That is
  what `tests/` is for.
- **Whether the provisioning scripts work.** `baseline-rhel9.sh`, `prep.sh`,
  `cleanup.sh` and the others have never been exercised by this validation.
- **Whether the role deploys.** `terraform plan` and `terraform apply` need a
  vCenter with an account that can create roles, which this validation host did
  not have. `validate` proves the module is well-formed, not that the apply
  succeeds or that the privileges are sufficient — only a build under the role
  proves that, as [Deploy the vSphere role](terraform-role-deploy.md) step 8
  describes.

---

## Re-running it

```shell
# One project
packer init     builds/linux/photon/5
packer validate builds/linux/photon/5

# Every project, with a shared plugin cache
export PACKER_PLUGIN_PATH="$PWD/.packer.d/plugins"
for project in $(find builds -name '*.pkr.hcl' -exec dirname {} \; | sort -u); do
  echo "=== $project"
  packer init     "$project" >/dev/null 2>&1
  packer validate "$project" && echo "OK" || echo "FAILED"
done
```

On Windows, `find` and the shell loop are not available; run the same two
commands per project directory.

!!! warning "A Windows build host and the `export` block"
    `packer-plugin-vsphere` 2.5.1 only defaults the OVF exporter's
    `directory_permission` when it is not running on Windows, then dereferences
    it unconditionally. On a Windows host an `export` block without
    `directory_permission` therefore panics the plugin, and the failure surfaces
    as `unexpected EOF` on the build definition rather than as a diagnostic. The
    Ubuntu projects set `directory_permission = "0750"` explicitly for that
    reason; keep it when copying one.
