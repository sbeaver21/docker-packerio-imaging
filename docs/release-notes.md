# Release notes

## Unreleased

### Vendor reference material

`references/` joins the repository: the material that covers what happens to an
image after it is published, and the one alternative builder. It is vendor
material, separate from this repository's own reference pages under
`docs/reference/`.

- **`supervisor-images/`** — fifteen Packer templates using the
  `vsphere-supervisor` builder instead of `vsphere-iso`: `examples/` is the
  upstream sample set as published, `site/` adds RHEL 9.4/9.6/10.0 and Windows
  Server 2022/2025 with full provisioning sequences, cloud-init and Sysprep
  bootstrap data, an Ansible sealing playbook, and the `serve-iso` helpers for
  importing an ISO by URL. Each template now carries a
  `packer { required_plugins }` block, so `packer init <template>` resolves the
  builder; the templates are otherwise unchanged.
- **`windows-vcf-image/`** — the Cloudbase-Init configuration a Windows image
  needs before VCF Automation 9.0 will initialise it: the two `.conf` files,
  their plugin order, the `Unattend.xml` passes, and the Sysprep caveat.
- **`vcfa-ad-join/`** — the Orchestrator workflow, event subscription and
  `project_associations` mapping that replace the Active Directory join removed
  from VCF Automation 9.0, with the attachment.

Documented under [Reference material](references/index.md), with a folder-level
[`references/README.md`][references-readme].

### Fixed

- **`scripts/serve-iso.*` looked one directory too high.** Both scripts walked
  five levels up from `scripts/` to find the repository root, but it is four, so
  they resolved `iso/` beside the repository instead of inside it and exited on
  "ISO directory not found". `serve-iso.ps1` also passed
  `-AdditionalChildPaths`, which is not a `Join-Path` parameter; it now uses
  plain path arithmetic. Verified: the PowerShell form resolves to the
  repository root and parses with no errors.

### Changed

- `packer fmt -check -recursive .` now covers `references/`, so the templates
  there are canonically formatted and stay that way.
- The Windows ADK *Deployment and Imaging Tools* carried under
  `references/windows-vcf-image/` are gitignored — around 21 MB of Microsoft
  binaries between the folder and its zip. The `.conf` fragments that matter are
  tracked.
- `README.md`, the project structure page and the validation report describe the
  new directory, and state what has and has not been checked there.
- `scripts/windows/README-WINDOWS-ISO.md` no longer names a specific drive and
  folder for the Windows build host; it says "a Windows host", which is what the
  point needed.
- Markdownlint exempts the three Broadcom READMEs as vendored pages. Everything
  written here, including `references/README.md`, is still linted. It also
  ignores `.pytest_cache/`, which pytest writes with its own `.gitignore` and
  which markdownlint would otherwise count as a page.

[references-readme]: https://github.com/sbeaver21/docker-packerio-imaging/blob/main/references/README.md

## 1.0.0

First public release.

A Packer project that turns a guest operating system ISO into a ready-to-deploy
VMware vSphere template. One Packer project per guest OS under
`builds/<family>/<version>/`, all using the `vsphere-iso` builder and the same
four stages: boot, unattended install, provisioning, publish.

### In this release

**Linux images** — AlmaLinux 8 and 9, CentOS Stream 9, Debian 11 and 12, Fedora
Server 40, Oracle Linux 8 and 9, Red Hat Enterprise Linux 9.6 and 10.0, Rocky
Linux 8 and 9, SUSE Linux Enterprise 15, Ubuntu Server 20.04, 22.04, 24.04 and
26.04, VMware Photon OS 4 and 5.

**Windows images** — Windows Server 2022 and 2025 in Standard and Datacenter,
each Core or Desktop Experience; Windows 10 and 11 Professional and Enterprise.

**Unattended install** from Kickstart, Preseed, Autoinstall, AutoYaST or
`Autounattend.xml`, rendered at build time from the same variables that configure
the builder.

**Provisioning** through Ansible roles (`base`, `users`, `configure`, `clean`) or
per-distribution shell scripts, then a full patch run that fails the build rather
than seal a template it cannot prove is current.

**Publishing** to a vSphere Content Library as an OVF template, with a JSON
manifest per run recording exactly what was built.

**Privileges** — `terraform/vsphere-role` creates the least-privilege role the
builds run under, so the Packer service account does not need administrator
rights.

**Tests** — `tests/` renders every network and storage template combination and
compares the result against golden files; 20 cases, no vSphere required.

### Requirements

Packer 1.15.0 or later, Packer plugins fetched by `packer init`, VMware vSphere
7.0 Update 3D or later, and a service account holding the role described in
[Privileges](getting-started/privileges.md). Terraform 1.9.5 or later is needed
once, to create that role. Ansible core 2.16 or later is needed only for the
Ansible-based Linux builds.

### Known limitations

One image per build: there is no in-place upgrade of an existing template, so a
patched image means a rebuild. Thirteen build projects ship only
`*.pkrvars.hcl.example`, so `packer validate` on a bare checkout stops on unset
variables until the configuration is supplied. See
[Validation](operations/validation.md) for the current state and
[Troubleshooting](operations/troubleshooting.md) for the failures worth knowing
before a first build.
