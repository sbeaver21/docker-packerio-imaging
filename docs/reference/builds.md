# Build Projects

Thirty-one Packer projects, sixty-three build sources. Each project is one
directory under `builds/`; the source name is what `--only` expects.

The **Answer file** column says where the unattended-install template is expected.
Where it reads *missing*, the project cannot validate or build as checked in —
see [Validation](../operations/validation.md).

---

## Linux

### AlmaLinux OS

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/almalinux/8` | `vsphere-iso.linux-almalinux` | `data/ks.pkrtpl.hcl` — present | Ansible |
| `builds/linux/almalinux/9` | `vsphere-iso.linux-almalinux` | `data/ks.pkrtpl.hcl` — present | Ansible |

### CentOS Stream

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/centos/9` | `vsphere-iso.linux-centos-stream` | `data/ks.pkrtpl.hcl` — present | Ansible |

### Debian

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/debian/11` | `vsphere-iso.linux-debian` | `data/ks.pkrtpl.hcl` (preseed) — present | Ansible |
| `builds/linux/debian/12` | `vsphere-iso.linux-debian` | `data/ks.pkrtpl.hcl` (preseed) — present | Ansible |

### Fedora Server

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/fedora/40` | `vsphere-iso.linux-fedora` | `data/ks.pkrtpl.hcl` — present | Ansible |

### Oracle Linux

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/oracle/8` | `vsphere-iso.linux-oracle` | `data/ks.pkrtpl.hcl` — present | Ansible |
| `builds/linux/oracle/9` | `vsphere-iso.linux-oracle` | `data/ks.pkrtpl.hcl` — present | Ansible |

### Red Hat Enterprise Linux

One source each, but the source name does not follow the directory name.

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/rhel/96` | `vsphere-iso.linux-rhel-96` | `data/ks.pkrtpl.hcl` — present | Shell |
| `builds/linux/rhel/100` | `vsphere-iso.linux-rhel-100` | `data/ks.pkrtpl.hcl` — present | Shell |

The RHEL projects take their whole configuration from a single
`rhel.auto.pkrvars.hcl`, unlike the other families which split it across
`build`, `common`, `vsphere` and OS-specific files.

### Rocky Linux

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/rocky/8` | `vsphere-iso.linux-rocky` | `data/ks.pkrtpl.hcl` — present | Ansible |
| `builds/linux/rocky/9` | `vsphere-iso.linux-rocky` | `data/ks.pkrtpl.hcl` — present | Ansible |

### SUSE Linux Enterprise

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/sles/15` | `vsphere-iso.linux-sles` | `data/autoinst.pkrtpl.hcl` (AutoYaST) — present | Ansible |

SLES registers with SUSE Customer Connect during the build when
`scc_username`/`scc_password` are set, and unregisters before sealing.

### Ubuntu Server

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/ubuntu/20-04-lts` | `vsphere-iso.linux-ubuntu-20-4` | `data/` — present | Shell |
| `builds/linux/ubuntu/22-04-lts` | `vsphere-iso.linux-ubuntu-22-04` | `data/` — present | Shell |
| `builds/linux/ubuntu/24-04-lts` | `vsphere-iso.linux-ubuntu-24-04` | `data/` — present | Shell |
| `builds/linux/ubuntu/26-04-lts` | `vsphere-iso.linux-ubuntu-26-04` | `data/` — present | Shell |

The Ubuntu source name for 20.04 is `linux-ubuntu-20-4`, not `linux-ubuntu-20-04`.
This is inconsistent with the other three and with the directory name; use the
exact string above with `--only`.

### VMware Photon OS

| Path | Source | Answer file | Provisioning |
| :--- | :----- | :---------- | :----------- |
| `builds/linux/photon/4` | `vsphere-iso.linux-photon` | `data/ks.pkrtpl.hcl` — present | Shell |
| `builds/linux/photon/5` | `vsphere-iso.linux-photon` | `data/ks.pkrtpl.hcl` — present | Shell |

The Photon OS 5 project pins the vSphere plugin exactly (`version = "= 2.1.1"`)
rather than accepting a range, as do the RHEL and Windows Server projects. The
Ubuntu projects require `>= 2.1.2`, and the Ansible-based projects still accept
`>= 1.4.0` — and they are the ones that declare the plugin from
`github.com/hashicorp/vsphere` rather than `github.com/vmware/vsphere`. Both
sources resolve today; unifying them is worth doing.

---

## Windows

### Windows Server

Each project declares four sources: Standard and Datacenter, each in Core and
Desktop experience.

| Path | Edition | Experience | Source |
| :--- | :------ | :--------- | :----- |
| `builds/windows/server/2022` | Standard | Core | `vsphere-iso.windows-server-2022-standard-core` |
| `builds/windows/server/2022` | Standard | Desktop | `vsphere-iso.windows-server-2022-standard-dexp` |
| `builds/windows/server/2022` | Datacenter | Core | `vsphere-iso.windows-server-2022-datacenter-core` |
| `builds/windows/server/2022` | Datacenter | Desktop | `vsphere-iso.windows-server-2022-datacenter-dexp` |
| `builds/windows/server/2025` | Standard | Core | `vsphere-iso.windows-server-2025-standard-core` |
| `builds/windows/server/2025` | Standard | Desktop | `vsphere-iso.windows-server-2025-standard-dexp` |
| `builds/windows/server/2025` | Datacenter | Core | `vsphere-iso.windows-server-2025-datacenter-core` |
| `builds/windows/server/2025` | Datacenter | Desktop | `vsphere-iso.windows-server-2025-datacenter-dexp` |

| Path | Answer file | Third CD | Provisioning |
| :--- | :---------- | :------- | :----------- |
| `builds/windows/server/2022` | `../../../../scripts/windows/data/autounattend.pkrtpl.hcl` — present | `packer-iso/win2022-<edition>-scripts.iso` | Windows Update, PowerShell |
| `builds/windows/server/2025` | `../../../../scripts/windows/data/autounattend.pkrtpl.hcl` — present | `packer-iso/win2025-<edition>-scripts.iso` | Windows Update, PowerShell |

The template is shared rather than copied into each project, and the builder
file names it with an explicit relative path from `path.root`. It lives in
`scripts/windows/data/` because it is a provisioning script, and it is shared
because the two versions differ only in the values passed to it.

The answer file is delivered as a **floppy image** (`floppy_content`), because
Windows Setup reads `Autounattend.xml` from `A:`. The first-logon payload is a
**prebuilt ISO on the datastore**, not a Packer-generated CD — see
[Windows Server builds](../operations/windows-builds.md) for why:

```hcl
iso_paths = [
  "[${var.common_iso_datastore}] ${var.iso_datastore_path}/${var.iso_file}",  # D:
  "[] /vmimages/tools-isoimages/windows.iso",                                 # E:
  "[example-datastore] packer-iso/win2025-standard-core-scripts.iso"          # F:
]
floppy_content = {
  "Autounattend.xml" = templatefile("${abspath(path.root)}/../../../../scripts/windows/data/autounattend.pkrtpl.hcl", { … })
}
```

There is no `cd_files` in any of these builders. Packer writes `cd_files` with
xorriso in Rock Ridge mode on Linux, Windows cannot read that volume, every
first-logon command fails in silence, VMware Tools never installs, and the build
hangs at `Waiting for IP...`.

The ISO is built per edition by `scripts/bootstrap/prepare-windows-iso.sh` and
verified by `scripts/bootstrap/check-joliet.sh`:

```shell
./scripts/bootstrap/prepare-windows-iso.sh builds/windows/server/2025-standard-core
./scripts/bootstrap/prepare-windows-iso.sh builds/windows/server/2025-standard-core --upload
```

It stages two things into one volume: the edition's own directory —
`<project>/<edition>/`, holding that edition's `temp-network.ps1`, which gives
each edition a different static address so parallel builds cannot collide — and
the shared payload in `builds/windows/files/`, which carries
`windows-vmtools.ps1` among others. That script installs VMware Tools, and is
therefore the reason vSphere reports a guest IP address at all.

```text
builds/windows/server/2025/
├── standard-core/           F: payload for the Standard Core source
├── standard-dexp/           F: payload for the Standard Desktop source
├── datacenter-core/         F: payload for the Datacenter Core source
├── datacenter-dexp/         F: payload for the Datacenter Desktop source
├── win2025.pkr.hcl
├── win2025.auto.pkrvars.hcl         local configuration
└── vsphere.auto.pkrvars.hcl         local configuration
```

The `templatefile()` path is written in full relative to `path.root`, four
levels up to the repository root. Do not reintroduce symlinks for it: those were
the mechanism by which a project could lose part of its configuration without
any diff showing it — the links existed only on the build host, so a fresh clone
could not build, and a hand-made copy of a project silently lost them.

Confirm every project in the family still attaches the third CD. Each of these
files declares four `source` blocks, so each must report `4`:

```shell
grep -c 'iso_paths *=.*-scripts\.iso' builds/windows/server/*/*.pkr.hcl
```

Match on `iso_paths` rather than on the bare string: every one of these files
also carries a `# cd_files replaced by datastore ISO: …` comment, so a search
for `scripts.iso` alone passes even when the `iso_paths` entry is gone — which
is precisely the failure this check exists to catch. A missing third entry is
what produced `timeout waiting for IP address` on two editions; see
[Windows Server builds](../operations/windows-builds.md).

#### Per-source projects

The two projects above build all four editions in one run. When only one
edition needs rebuilding, use the matching per-source project, which builds a
single source:

| Path | Source |
| :--- | :----- |
| `builds/windows/server/2022-datacenter-core` | `vsphere-iso.windows-server-2022-datacenter-core` |
| `builds/windows/server/2022-datacenter-dexp` | `vsphere-iso.windows-server-2022-datacenter-dexp` |
| `builds/windows/server/2022-standard-core` | `vsphere-iso.windows-server-2022-standard-core` |
| `builds/windows/server/2022-standard-dexp` | `vsphere-iso.windows-server-2022-standard-dexp` |
| `builds/windows/server/2025-datacenter-core` | `vsphere-iso.windows-server-2025-datacenter-core` |
| `builds/windows/server/2025-datacenter-dexp` | `vsphere-iso.windows-server-2025-datacenter-dexp` |
| `builds/windows/server/2025-standard-core` | `vsphere-iso.windows-server-2025-standard-core` |
| `builds/windows/server/2025-standard-dexp` | `vsphere-iso.windows-server-2025-standard-dexp` |

Each of these carries the same four `source` blocks as its parent project —
they differ only in the `sources` list of the `build` block, which names one
entry — so the file is still diffable against the parent. The builder file is
named `win<version>-<dc|std>-<core|dexp>.pkr.hcl`.

These directories previously existed only on the build host, hand-copied out of
the parent project, which is how `2022-standard-core` and `2022-standard-dexp`
came to be missing their third `iso_paths` entry: the scripts ISO was never
attached, VMware Tools was never installed, the guest never reported an IP
address, and both builds failed after thirty minutes with
`timeout waiting for IP address`. Keeping them in the repository, carrying the
same four `source` blocks as their parent, is what prevents a repeat.

Each per-source project also keeps the four edition payload directories of its
parent, even though `prepare-windows-iso.sh` reads only the one matching the
project name — `<project>/<edition>/`. That is deliberate: it keeps the project
byte-identical to its parent apart from the `sources` list, so a diff between
the two shows the source selection and nothing else.

### Windows Desktop

| Path | Edition | Source | Answer file |
| :--- | :------ | :----- | :---------- |
| `builds/windows/desktop/10` | Professional | `vsphere-iso.windows-desktop-pro` | `data/autounattend.pkrtpl.hcl` — present |
| `builds/windows/desktop/10` | Enterprise | `vsphere-iso.windows-desktop-ent` | `data/autounattend.pkrtpl.hcl` — present |
| `builds/windows/desktop/11` | Professional | `vsphere-iso.windows-desktop-pro` | `data/autounattend.pkrtpl.hcl` — present |
| `builds/windows/desktop/11` | Enterprise | `vsphere-iso.windows-desktop-ent` | `data/autounattend.pkrtpl.hcl` — present |

Both projects declare a source of the same name, so `--only` is unambiguous only
because they are separate projects.

Windows Desktop Professional cannot be built from the evaluation media: the
evaluation ISO provides Enterprise only, and Professional has no evaluation
mode. See [FAQ](../getting-started/faq.md).

---

## Summary

| | Count |
| :--- | :---- |
| Projects | 31 |
| Build sources | 63 |
| Projects whose install templates are present | 31 |
| Projects that ship a `*.pkrvars.hcl.example` | 16 |
| Projects that ship no example configuration at all | 15 |

---

## Adding a project

Copy the nearest existing project, then work through the checklist in
[Contributing](../community/contributing.md#changing-a-build-definition). The
two mistakes that account for most of the defects in this tree:

1. Referencing `data/` from the repository root instead of from `path.root`
   (the project directory).
2. Copying a project and leaving its `locals` block pointing at the previous
   version's name, address or ISO.
