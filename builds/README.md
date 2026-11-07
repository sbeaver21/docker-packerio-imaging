# Builds

One directory per Packer project. Each project builds one or more images from a
guest operating system ISO, and publishes them to a vSphere Content Library.

```text
builds/
├── linux/
│   ├── almalinux/8/ 9/
│   ├── centos/9/
│   ├── debian/11/ 12/
│   ├── fedora/40/
│   ├── oracle/8/ 9/
│   ├── photon/4/ 5/
│   ├── rhel/96/ 100/
│   ├── rocky/8/ 9/
│   ├── sles/15/
│   └── ubuntu/20-04-lts/ 22-04-lts/ 24-04-lts/ 26-04-lts/
└── windows/
    ├── desktop/10/ 11/
    ├── files/          shared payload, not a project
    └── server/2022/ 2025/
```

31 projects, 63 build sources. The full inventory — source names, answer file,
provisioning style — is in
[docs/reference/builds.md](../docs/reference/builds.md).

`builds/windows/files/` is not a project. It holds the payload copied into every
Windows build: the initialization and VMware Tools scripts, the CD-ROM contents
and the hardening scripts.

---

## What is in a project

```text
builds/linux/almalinux/9/
├── linux-almalinux.pkr.hcl              builder source + build block
├── variables.pkr.hcl                    input variable declarations
├── variables-network.pkr.hcl            network inputs
├── variables-storage.pkr.hcl            storage inputs
├── linux-almalinux.pkrvars.hcl.example  shape of the local configuration
└── data/                                unattended install templates
    ├── ks.pkrtpl.hcl
    ├── network.pkrtpl.hcl
    └── storage.pkrtpl.hcl
```

| File | Role |
| :--- | :--- |
| `<name>.pkr.hcl` | `packer {}` block with pinned plugins, `locals`, `source "vsphere-iso"`, `build {}` |
| `variables*.pkr.hcl` | The input contract. Committed. |
| `data/` | The answer-file templates `templatefile()` renders. Committed. |
| `*.pkrvars.hcl.example` | Placeholder values, showing the shape of the configuration. Committed. |
| `*.auto.pkrvars.hcl` | **Real** values, including credentials. **Gitignored.** |

!!! danger "`*.auto.pkrvars.hcl` must never be committed"
    It holds the vCenter service-account password and the build-account
    password. See [Secrets](../docs/operations/secrets.md).

---

## The four families behave differently

Do not assume a pattern from one project applies to the next.

| Family | Configuration files | Provisioning | Notes |
| :----- | :------------------ | :----------- | :---- |
| Photon, Ubuntu | `build`, `common`, `storage`, `<os>`, `vsphere` | Shell scripts | Five separate var files |
| RHEL | `rhel.auto.pkrvars.hcl` | Shell scripts | Everything in one file |
| Windows Server | `vsphere`, `win20xx` | Windows Update + PowerShell | Four sources per project |
| AlmaLinux, CentOS, Debian, Fedora, Oracle, Rocky, SLES, Windows Desktop | none committed | Ansible (Windows Desktop: PowerShell) | Ships only `*.pkrvars.hcl.example` |

---

## Answer-file templates

Every project that installs unattended renders its answer file with
`templatefile()`, and the template has to be beside the project. Two layouts are
in use:

- **Per-project `data/`** — Photon, RHEL and Ubuntu each keep their own
  `ks.pkrtpl.hcl`, `network.pkrtpl.hcl`, `storage.pkrtpl.hcl` (Ubuntu also
  `user-data.pkrtpl.hcl` and `meta-data`). Rendered from `${path.root}`.
- **Shared `scripts/windows/data/`** — the Windows Server projects reach it as
  `../../../../scripts/windows/data/autounattend.pkrtpl.hcl`, four levels up to
  the repository root.

Both are committed. Every `templatefile()` reference in the build definitions
resolves to a file that exists — check with:

```shell
grep -rn 'templatefile(' builds/ --include='*.pkr.hcl'
```

A missing template is not a configuration problem: `packer validate` reports
`no file exists at ...` and the build cannot start. If a new project shows that
error, the `data/` directory was not created in the project directory.

## Windows Server

The ten Windows Server projects are the exception among the families: they
need a third CD attached at build time, carrying the first-logon scripts. That
CD is built by `scripts/bootstrap/prepare-windows-iso.sh` and must be Joliet,
not Rock Ridge. See
[README-WINDOWS-ISO.md](../scripts/windows/README-WINDOWS-ISO.md) and
[windows-builds.md](../docs/operations/windows-builds.md).

---

## Building one

```shell
packer init     builds/linux/almalinux/9
packer validate builds/linux/almalinux/9
packer build    builds/linux/almalinux/9
```

Either working directory works: every path inside a definition is anchored on
`path.root`, the project directory. Manifest and OVF output are written under
`${path.cwd}/`, so run from the repository root if you want them in
`manifests/` and `artifacts/` at the top level.

To build a single source:

```shell
packer inspect builds/windows/server/2025
packer build --only=vsphere-iso.windows-server-2025-standard-core \
    builds/windows/server/2025
```

---

## Adding a project

Copy the nearest existing project and change, rather than editing a shared file:

```shell
cp -r builds/linux/rhel/96 builds/linux/rhel/97
```

Then:

- [ ] Rename the `.pkr.hcl` and `.pkrvars.hcl.example` files.
- [ ] Update the `locals` block — VM name, ISO file, notes. A copied project
      that still names the previous version is the most common defect here.
- [ ] Create `data/` **in the new directory**. `templatefile()` resolves against
      `${path.root}`, the project directory.
- [ ] Rename the `source` block, and keep the naming scheme consistent with the
      other projects in the family.
- [ ] Add the entry to [docs/reference/builds.md](../docs/reference/builds.md).
- [ ] Build it, boot a clone, and check the clone — validation proves the
      template parses, not that the image works.

The full checklist is in
[Contributing](../CONTRIBUTING.md#changing-a-build-definition).

---

## Conventions

- **Directory names** use the marketing version: `24-04-lts` and `100` for 10.0.
- **Source names** are `vsphere-iso.<distinctive-name>`. They are mostly
  consistent, with one exception: Ubuntu 20.04 is `linux-ubuntu-20-4`, not
  `linux-ubuntu-20-04`.
- **One plugin version set per project.** There is no shared `required_plugins`.
- **Anchor input paths on `path.root`, not `path.cwd`.** `path.root` is the
  project directory, so a definition resolves the same input files whether
  Packer was started from the repository root or from inside the project.
  Anything outside the project - the shared provisioning scripts,
  `scripts/windows/data/`, the Windows payload in `scripts/windows/` - is
  written as an explicit relative path from it, keeping the result absolute:

  ```hcl
  scripts = ["${abspath(path.root)}/../../../../scripts/linux/rhel/prep.sh"]
  cd_files = ["${abspath(path.root)}/../../../../scripts/${var.vm_guest_os_family}/"]
  ```

  Four levels up from a project directory is the repository root. `path.cwd`
  depends on where `packer build` was typed, so an input path written against it
  breaks the moment the command is run from somewhere else.

- **`path.cwd` is right for output and for the Ansible provisioner.** The
  manifest and OVF export paths intentionally land in the directory Packer was
  started from, and the Windows Desktop projects pass `ansible/` the same way.
  Those are deliberate: build output follows the invocation, and `ansible/` is
  only reachable from the repository root.
