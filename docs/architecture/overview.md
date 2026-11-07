# Architecture Overview

This repository has four layers. A change belongs to exactly one of them, and
knowing which one tells you where to make it and what it can break.

```text
┌─────────────────────────────────────────────────────────────────────┐
│  1. Build definition        builds/<family>/<version>/*.pkr.hcl     │
│     Declares the builder source, the variables, the build block     │
│     and the provisioner sequence.                                   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ renders
┌───────────────────────────────▼─────────────────────────────────────┐
│  2. Unattended install      builds/<project>/data/*.pkrtpl.hcl      │
│     Kickstart, preseed, autoinstall, AutoYaST or Autounattend.      │
│     Answers the installer: accounts, disk, network, packages.       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ first boot of the guest
┌───────────────────────────────▼─────────────────────────────────────┐
│  3. Provisioning            scripts/, ansible/, builds/windows/files │
│     Patches, installs, hardens, configures, then seals the guest.   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ export
┌───────────────────────────────▼─────────────────────────────────────┐
│  4. Delivery                vSphere Content Library + manifests/    │
│     OVF template, and the record of what produced it.               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1 — the build definition

One directory per project. The `.pkr.hcl` files declare:

- **`packer {}`** — the minimum Packer version and the plugins with their
  pinned versions. This is why `packer init` is per project.
- **`locals {}`** — values computed at validation time: the VM name, the build
  timestamp, the notes written onto the VM, the rendered answer-file content,
  the manifest path. Several projects also pin the guest IP address here, which
  is why the network variables have no effect (see
  [Configure](../getting-started/configure.md#guest-network-configuration)).
- **`source "vsphere-iso"`** — one per image variant. Holds the vCenter
  connection, the hardware, the ISO, the boot command, the communicator and the
  publish settings.
- **`build {}`** — which sources to run, the provisioners to apply after the
  install, and the post-processors.

A build block's provisioner order is behaviour, not style. The Photon OS 5
project ends with the patch provisioner precisely so that nothing installed
afterwards can be left unpatched; its own comments say so, and moving that block
silently changes what the image contains.

### Why the answer file is rendered, not stored

The installer needs values the template already knows: hostname, the account and
its hashed password, the IP address, the partition layout. Duplicating those into
a static answer file guarantees drift. Instead, the build block renders the
template into `http_content` or `cd_content` at validation time:

```hcl
data_source_content = {
  "/ks.cfg" = templatefile("${abspath(path.root)}/data/ks.pkrtpl.hcl", {
    build_username           = var.build_username
    build_password_encrypted = var.build_password_encrypted
    network = templatefile("${abspath(path.root)}/data/network.pkrtpl.hcl", { … })
    storage = templatefile("${abspath(path.root)}/data/storage.pkrtpl.hcl", { … })
  })
}
```

`path.root` is the **project** directory. That is the constraint behind the
known defect: a project whose `data/` directory is missing cannot render its own
answer file, so it fails at validation rather than at install time.

---

## Layer 2 — the unattended install

Four installer families are in use, chosen by distribution:

| Family | Installer | Used by |
| :----- | :-------- | :------ |
| Kickstart | Anaconda | RHEL, Rocky, AlmaLinux, Oracle, CentOS Stream, Fedora, Photon |
| Preseed | Debian installer | Debian |
| Autoinstall | Subiquity | Ubuntu Server |
| AutoYaST | YaST | SUSE Linux Enterprise |
| Autounattend | Windows Setup | Windows Server, Windows |

Each family gets its answer file to the guest differently, and the templates
carry matching boot commands:

- **Kickstart** — `inst.ks=http://…/ks.cfg` for RHEL-family, `ks=…` for Photon.
  The RHEL template additionally passes `ip=` so the installer brings up the
  static address before it fetches the file.
- **Preseed** and **Autoinstall** — fetched over HTTP, or read from a second
  CD-ROM when `common_data_source = "disk"`.
- **AutoYaST** — an `autoinst.xml` on a second CD-ROM.
- **Autounattend** — written into a **floppy image** (`floppy_content`), not a
  CD-ROM, because Windows Setup reads it from `A:`.

The boot commands are timing-sensitive. They send keystrokes to a bootloader
menu: `<up>`, `e`, `<down><down><end>`, then the extra kernel arguments, then
Ctrl-X to boot. A host that is faster or slower than the one the sequence was
written on can miss the menu. `vm_boot_wait` is the knob.

---

## Layer 3 — provisioning

After the install and reboot, Packer connects over SSH (Linux) or WinRM
(Windows) and runs the provisioning sequence.

### Two styles, deliberately

| Style | Used by | Why |
| :---- | :------ | :-- |
| Ansible roles | AlmaLinux, CentOS, Debian, Fedora, Oracle, Rocky, SLES | The upstream structure; declarative, per-OS task files selected by `ansible_os_family` |
| Shell scripts | RHEL, Ubuntu, Photon | These builds needed OS-specific sequences that did not fit the generic roles, and were moved to explicit script lists |

`ansible/linux-playbook.yml` applies four roles in a fixed order:

```text
base      → update the OS, install the package set for the OS family
users     → create the build and automation accounts
configure → hostname, network, time, SNMP, chrony
clean     → clear logs, shell history, machine identity; return to DHCP
```

The order matters in one direction only: `clean` must be last, or the artefacts
it removes are recreated by whatever runs after it.

### Sealing

Every sequence ends by making the guest safe to clone:

- network returned to DHCP, so clones do not fight over the build address
- `/etc/machine-id` truncated, SSH host keys and `cloud-init` state removed
- logs and shell history cleared
- the machine shut down cleanly

A clone that keeps the build hostname, address or machine identity is a clone
whose sealing step did not run.

### Windows is different

The Windows projects do not use Ansible on the guest. The build block:

1. runs the `windows-update` provisioner against Microsoft Update,
2. removes Edge and AppX provisioned packages in a guarded PowerShell block
   that tolerates Server Core having no AppX subsystem,
3. executes the site hardening script set from `builds/windows/files/Temp/`
   elevated,
4. returns the adapter to DHCP and resets the network stack.

The hardening scripts are third-party and are committed as-is. See
[Secrets](../operations/secrets.md) for the supply-chain caveat.

---

## Layer 4 — delivery

### Content library

The default output is an OVF template in a vSphere Content Library:

```hcl
dynamic "content_library_destination" {
  for_each = var.common_content_library != null ? [1] : []
  content {
    library     = var.common_content_library
    name        = local.vm_name_standard_core
    description = local.vm_description
    ovf         = var.common_content_library_ovf
    destroy     = var.common_content_library_destroy
    skip_import = var.common_content_library_skip_export
  }
}
```

The condition is `common_content_library != null`, not a separate `_enabled`
flag: leaving the library name unset is what turns publishing off.

An existing item of the same name is updated in place, so a rebuild produces a
new version of the same library item rather than a duplicate.

!!! note "Encrypted VMs cannot be exported"
    Cloning an encrypted virtual machine to a content library as an OVF template
    is not supported by vSphere. Windows 11 builds in particular are excluded
    from content library transfer by default; use VM template output instead.

### Manifest

Every build writes a JSON manifest under `manifests/`. It is the only durable
record of what produced an image:

```json
{
  "builds": [
    {
      "name": "windows-server-2025-standard-core",
      "builder_type": "vsphere-iso",
      "artifact_id": "windows-server-2025-standard-core-packer",
      "packer_run_uuid": "…",
      "custom_data": { "build_date": "…", "vsphere_cluster": "…", "vm_disk_size": "…" }
    }
  ]
}
```

Manifests are gitignored: they are output, not source. If an image's provenance
matters, copy its manifest somewhere durable before rebuilding.

---

## What is shared and what is not

| Shared | Not shared |
| :----- | :--------- |
| `ansible/` roles and playbooks, for the Ansible-style builds | The `data/` answer-file templates: each project has its own |
| `scripts/linux/{photon,rhel,ubuntu}/`, one copy of each script, reached from `path.root` | Plugin versions: pinned per project |
| `builds/windows/files/`, for every Windows build | The `locals` block: one per project, including the guest IP |
| `terraform/vsphere-role`, for the service account | Hardware defaults: each project sets its own |

The practical consequence: changing a shared script changes every project that
lists it, and there is no central list. `grep` is the tool:

```shell
grep -rl "scripts/linux/" builds/
```

`prep.sh` is also the reason the shared scripts must stay POSIX `sh`: RHEL
invokes them with `sh -eux`, and `/bin/sh` is ash on Photon OS. Ubuntu and
Photon pass `bash -eux`, but only the Photon patch script relies on it by
re-executing itself under `bash` — the rest of the tree stays POSIX so a script
can be listed by more than one family.
