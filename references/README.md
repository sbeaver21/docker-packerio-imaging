# Reference material

This directory is **not part of the build pipeline**. Nothing here runs when a
`builds/` project runs, and `packer build builds/...` never reads it.

It holds the material needed for the second half of an image's life: getting a
vSphere template into **VCF Automation 9.0**, and building images directly on a
**vSphere Supervisor** cluster instead of on a plain vCenter. It was gathered
from Broadcom documentation and validated for syntax only; no image was built
from it in this repository.

For this repository's own reference - build projects, variables, scripts - see
[`docs/reference/`](../docs/reference/builds.md). This directory is the external
half: vendor procedures and sample templates.

The three sets answer different questions:

| Directory | Answers |
| :--- | :--- |
| [`supervisor-images/`](#vsphere-supervisor-images) | How do I build an image when the target is a Supervisor cluster rather than a vCenter, and publish it as a VM image? |
| [`windows-vcf-image/`](#windows-vcf-automation-image) | How must a Windows image be prepared so VCF Automation can initialise it? |
| [`vcfa-ad-join/`](#active-directory-join) | How do I join provisioned machines to Active Directory now that VCF Automation 9.0 removed ABX? |

The rendered documentation for all three is under
[`docs/references/`](../docs/references/index.md).

---

## vSphere Supervisor images

Packer templates that use the **`vsphere-supervisor`** builder instead of
`vsphere-iso`. The builder creates the source virtual machine on a Supervisor
cluster through the VM-Operator API, configures it over SSH or WinRM, and
publishes the result as a VM image in a content library.

Two directories, deliberately kept side by side:

| Directory | Contents |
| :--- | :--- |
| `examples/` | The upstream example set as published: `general-template`, `general-template-with-image-import`, `nginx-template`, `jenkins-template`, `windows-template`, `sysprep-unattend-data.yml`, `cleanup-playbook.yml` |
| `site/` | The same five templates, plus `rhel-9-4`, `rhel-9-6`, `rhel-10-0`, `windows-2022` and `windows-2025` with full provisioning sequences, `cloud-init-rhel-9.yml` and `cloud-init-rhel-10.yml`, per-version sysprep data, and `scripts/serve-iso.{ps1,sh}` |

Build from `site/`. `examples/` is kept unchanged so a re-sync from the upstream
project is a diff of named files rather than a merge.

The RHEL and Windows templates do real work: register and patch, install
open-vm-tools, configure SSH and firewalld, seal the guest (machine identity,
host keys, cloud-init state), then publish. The five general templates are
skeletons that write one file and stop.

Every template carries a `packer { required_plugins }` block pinning
`github.com/vmware/vsphere`, so `packer init <template>` resolves the builder.
Initialise and validate **per template file**, not per directory: the directory
holds several independent templates that each declare the same variable names,
and Packer loads all of them if given the directory.

```shell
cd references/supervisor-images/site
packer init     rhel-9-6.pkr.hcl
packer validate rhel-9-6.pkr.hcl      # needs a kubeconfig; see below
```

Full validation evaluates the builder's defaults, which include reading the
current context's namespace from a kubeconfig. Without one, `validate` stops
with `failed to get current context's namespace in kubeconfig file`. That is a
missing cluster, not a broken template: `packer validate -syntax-only` passes
for all fifteen.

`scripts/serve-iso.*` serve the `iso/` directory over HTTP so a Supervisor
cluster can import an ISO by URL. They are helpers for local testing and expect
that directory to exist beside the repository root.

---

## Windows VCF Automation image

Material for the Cloudbase-Init layer that VCF Automation uses to initialise a
Windows virtual machine on first boot.

| Path | Contents |
| :--- | :--- |
| `README.md` | The ten preparation steps, including the Sysprep caveat |
| `cd_files/` | The six scripts and two `.conf` files that go onto the image's CD-ROM: `cloudbase-init.conf`, `cloudbase-init-unattend.conf`, `cloudbased-init.ps1`, `cloudbased-init-local.ps1`, `windows-init.ps1`, `windows-prepare.ps1`, `windows-vmtools.ps1`, `dhcp-network.ps1` |
| `packages/Cloudbase Solutions/Cloudbase-Init/conf/` | The post-install `conf/` directory as it should end up in the image: both `.conf` files and `Unattend.xml` |
| `amd64/`, `amd64.zip` | The Windows ADK *Deployment and Imaging Tools* subset (`oscdimg.exe`, `DISM/`, `BCDBoot/`). **Not tracked** - see below |

The important difference from a plain Windows build is the metadata service
order. `VMwareGuestInfoService` must come before `OvfService`, and in the
first-boot configuration `NetworkConfigPlugin` must run before `UserDataPlugin`:

```ini
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfo.VMwareGuestInfoService,cloudbaseinit.metadata.services.ovfservice.OvfService
plugins=cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin
```

### The ADK binaries are not in git

`amd64/` is a copy of `%ProgramFiles(x86)%\Windows Kits\10\Assessment and
Deployment Kit\Deployment Tools\amd64` - about 15 MB of Microsoft binaries, and
`amd64.zip` is the same payload again at 5.7 MB. Committing either adds weight
with no source value, so `.gitignore` excludes both.

The repository's own ISO staging runs on Linux and uses `xorriso`
(`scripts/windows/build-scripts-isos.sh`). On a Windows build host `oscdimg` is
the equivalent, which is what this folder carries. To restore it, install the
Windows ADK and copy the folder back, or unzip a local `amd64.zip`:

```shell
# Windows, with the ADK installed
Copy-Item -Recurse "$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64" `
  "references\windows-vcf-image\amd64"
```

---

## Active Directory join

The replacement for the AD join that VCF Automation 9.0 removed along with ABX.
It is a set of VCF Automation objects - a configuration element, an imported
Orchestrator package, a workflow and an event subscription - not code that runs
on the build host.

| Path | Contents |
| :--- | :--- |
| `README.md` | The full procedure, from adding the AD server to the Orchestrator inventory through the blueprint's `metadata.name` |
| `packages/active.directory.create.delete.package` | The Orchestrator package to import under **Orchestrate → Assets → Packages**. 13 KB |

The one constraint that reaches back into this repository: the blueprint's
`metadata.name` becomes the AD computer account name and is limited to **15
characters**. A machine name longer than that will not be created in AD.

---

## Licence

None of this directory is covered by the repository's BSD 2-Clause licence.
Each set carries its own terms:

| Set | Licence |
| :--- | :--- |
| `supervisor-images/` | Mozilla Public License 2.0 — full text in `supervisor-images/LICENSE` |
| `windows-vcf-image/` | Documentation from Broadcom TechDocs; the Cloudbase-Init configuration fragments are from Cloudbase Solutions, Apache 2.0 |
| `vcfa-ad-join/` | Documentation from Broadcom TechDocs, and the Orchestrator package that article attaches |
