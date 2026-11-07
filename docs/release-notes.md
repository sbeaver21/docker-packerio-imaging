# Release notes

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
