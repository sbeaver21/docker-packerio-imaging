# docker-packerio-imaging

Automated build pipeline for VMware vSphere virtual machine images.

A guest operating system ISO goes in, a ready-to-deploy vSphere template comes
out. Every build runs the same four stages.

1. **Boot.** Packer starts a virtual machine from the ISO with the
   `vsphere-iso` builder.
2. **Install.** The guest installs itself unattended from a kickstart, preseed,
   autoinstall or `Autounattend.xml` answer file.
3. **Provision.** Shell scripts, PowerShell and Ansible roles configure and
   harden the result.
4. **Publish.** The finished image is exported as an OVF template to a vSphere
   Content Library, and a manifest recording exactly what was built is written
   to `manifests/`.

Build definitions cover the Linux distributions and Windows products in
[What it builds](#what-it-builds), one Packer project per guest OS.

Distributed under BSD 2-Clause. Portions are derived from the Broadcom
`packer-examples-for-vsphere` sample project; see [LICENSE](LICENSE) for the
attribution notice that travels with them.

---

## Contents

- [docker-packerio-imaging](#docker-packerio-imaging)
  - [Contents](#contents)
  - [What it builds](#what-it-builds)
    - [Linux](#linux)
    - [Windows](#windows)
  - [How a build works](#how-a-build-works)
    - [Provisioning by distribution](#provisioning-by-distribution)
  - [Requirements](#requirements)
    - [Build host](#build-host)
    - [Target platform](#target-platform)
  - [Repository layout](#repository-layout)
  - [Quick start](#quick-start)
  - [Configuration and secrets](#configuration-and-secrets)
  - [Validation](#validation)
  - [Documentation](#documentation)
  - [Contributing](#contributing)
  - [License](#license)

---

## What it builds

Build definitions are organized under `builds/<family>/<version>/`. Each directory
is one Packer project and may declare several sources, producing several images
from one template.

### Linux

| Distribution | Versions | Unattended install | Post-install |
| :--- | :--- | :--- | :--- |
| AlmaLinux OS | 8, 9 | Kickstart | Ansible |
| CentOS Stream | 9 | Kickstart | Ansible |
| Debian | 11, 12 | Preseed | Ansible |
| Fedora Server | 40 | Kickstart | Ansible |
| Oracle Linux | 8, 9 | Kickstart | Ansible |
| Red Hat Enterprise | 9.6, 10.0 | Kickstart | Shell |
| Rocky Linux | 8, 9 | Kickstart | Ansible |
| SUSE Linux Enterprise | 15 | AutoYaST | Ansible |
| Ubuntu Server | 20.04, 22.04, 24.04, 26.04 | Autoinstall | Shell |
| VMware Photon OS | 4, 5 | Kickstart | Shell |

### Windows

| Product | Versions | Editions and experiences |
| :--- | :--- | :--- |
| Windows Server | 2022, 2025 | Standard, Datacenter × Core, Desktop Experience |
| Windows | 10, 11 | Professional, Enterprise |

---

## How a build works

```text
ISO in datastore
or content library
       |
       v
+------------------+   answer file served over
|  vsphere-iso     |   Packer's HTTP server, or a
|  builder         |---->secondary CD-ROM / floppy
+------------------+
       |
       |  guest installs unattended, then reboots
       v
+------------------+   communicator: SSH (Linux),
|  provisioners    |   SSH/WinRM (Windows)
|                  |---->shell scripts, PowerShell,
+------------------+   Ansible playbooks, Windows Update
       |
       v
+------------------+   OVF template in the content
|  post-processor  |---->library, plus a JSON manifest
+------------------+   under manifests/
```

The unattended install answers file is generated at build time from a template
in the project's `data/` directory, so guest hostname, account credentials,
network configuration and partition layout are rendered from the same variables
that configure the builder.

### Provisioning by distribution

- **Ansible-based builds** run `ansible/linux-playbook.yml`, which applies four
  roles in order: `base` (patch and install packages), `users`, `configure`,
  and `clean` (clear logs, machine identity and shell history before the image
  is sealed).
- **Shell-based builds** (RHEL, Ubuntu, Photon) run scripts from `scripts/`
  instead: baseline provisioning and subscription registration, patching, prep,
  cleanup and a final return to DHCP.
- **Windows builds** run Windows Update through the `windows-update`
  provisioner, remove Edge and AppX provisioned packages, then execute the
  site hardening payload from `builds/windows/files/Temp/` and return the
  network adapter to DHCP.

---

## Requirements

### Build host

| Component | Version | Notes |
| :--- | :--- | :--- |
| Packer | >= 1.15.0 | The highest floor any template declares; some declare 1.11.0. |
| Terraform | >= 1.9.5 | Only for `terraform/vsphere-role`, once. Fetched on demand into `tools/terraform/` by `scripts/bootstrap/fetch-terraform.*`. |
| Git | >= 2.45.0 | |
| ansible-core | >= 2.16 | Only needed for the Ansible-based Linux builds, and only on a POSIX host. |
| jq | >= 1.8 | |

The build host may be Linux, macOS or Windows, with one qualification: **the
eleven Ansible-provisioned projects cannot be built from a Windows host.**
ansible-core does not support Windows as a control node, and the Ansible
provisioner runs on the build host rather than in the guest — it fails during CLI
start-up, before it parses a playbook:

```text
ERROR: Ansible requires the locale encoding to be UTF-8; Detected 1252.
```

| Build host | Shell-provisioned (RHEL, Ubuntu, Photon, Windows) | Ansible-provisioned (AlmaLinux, CentOS, Debian, Fedora, Oracle, Rocky, SLES) |
| :--- | :--- | :--- |
| Linux, macOS | Yes | Yes |
| Windows | Yes | No — use WSL or a POSIX host |

Packer plugins are platform-specific and are downloaded by `packer init`; a host
with no outbound internet access needs the plugin binaries placed in
`PACKER_PLUGIN_PATH` first.

### Target platform

| Component | Version |
| :--- | :--- |
| VMware vSphere | 7.0 Update 3D or later, 8.0 or later |

The service account used by Packer needs a specific set of vSphere privileges.
They are listed in [docs/getting-started/privileges.md](docs/getting-started/privileges.md),
and are created by the Terraform module in `terraform/vsphere-role`. Creating the
role and assigning it to the service account is the one administrative step:
follow [docs/operations/terraform-role-deploy.md](docs/operations/terraform-role-deploy.md)
before the first build.

---

## Repository layout

| Path | Contents |
| :--- | :--- |
| `ansible/` | Playbooks and roles used to configure Linux guests after installation. |
| `artifacts/` | OVF export destination. Contents are generated, not source. |
| `builds/` | One Packer project per guest operating system, version and edition. |
| `data/` | Shared templates at the repository root; each build project carries its own `data/` and reads from `${path.root}/data/` (the project directory). |
| `docs/` | Documentation site source (MkDocs Material). |
| `kubernetes/` | The Helm chart that schedules the builds, and the generated manifest that deploys the web front end. See [kubernetes/README.md](kubernetes/README.md). |
| `manifests/` | Build manifests written by the manifest post-processor. Generated output. |
| `scripts/` | Provisioning scripts executed inside the guest, grouped by distribution. |
| `terraform/` | The least-privilege vSphere role the builds run under. Created once. |
| `tests/` | Bats tests for the network and storage template rendering. |
| `tools/` | Binaries fetched by `scripts/bootstrap/`, such as `terraform/`. Generated. |
| `web/` | Flask front end for starting, pausing and inspecting builds. |

Each of these directories has its own README describing its contents in detail.

---

## Quick start

1. Clone the repository.

   ```shell
   git clone https://github.com/example-org/docker-packerio-imaging.git
   cd docker-packerio-imaging
   ```

2. Verify the toolchain. See [Requirements](#requirements) for versions and
   offline installation.

   ```shell
   packer version        # >= 1.15.0
   ansible --version     # >= 2.16, only for Ansible-based Linux builds
   ./scripts/bootstrap/fetch-terraform.sh   # only for terraform/ changes
   git --version         # >= 2.45.0
   jq --version          # >= 1.8
   ```

3. Create the local configuration for the build you want to run. Packer loads
   every `*.auto.pkrvars.hcl` file in the project directory automatically, so
   the configuration lives beside the template and is never committed:

   ```text
   builds/linux/ubuntu/24-04-lts/
   ├── build.auto.pkrvars.hcl      build accounts and password hashes
   ├── common.auto.pkrvars.hcl     content library, ISO datastore, boot data source
   ├── storage.auto.pkrvars.hcl    partition layout
   ├── ubuntu.auto.pkrvars.hcl     OS version, ISO, hardware
   └── vsphere.auto.pkrvars.hcl    vCenter endpoint, credentials, inventory
   ```

   See [docs/reference/configuration.md](docs/reference/configuration.md) for
   the full variable reference.

4. Download the plugins the project requires.

   ```shell
   packer init builds/linux/ubuntu/24-04-lts
   ```

5. Check the template, then build it.

   ```shell
   packer validate builds/linux/ubuntu/24-04-lts
   packer build builds/linux/ubuntu/24-04-lts
   ```

   > **First build on a vCenter?** The service account needs the Packer role
   > before this works. [Deploy the role][d20] creates and assigns it.

6. To build a single source out of several, for example only the Windows
   Server 2025 Standard Core image:

   ```shell
   # Linux / macOS:
   packer build --only=vsphere-iso.windows-server-2025-standard-core \
       builds/windows/server/2025
   # Windows (Command Prompt):
   packer build --only=vsphere-iso.windows-server-2025-standard-core ^
       builds/windows/server/2025
   ```

7. After the build. The finished image appears in the content library named in
   `common_content_library`, an OVF is exported to `artifacts/`, and the manifest
   for the run is written to `manifests/`.

---

## Configuration and secrets

Build configuration carries live credentials: the vCenter service account, the
build accounts baked into every image, the encrypted password hashes, and the
public keys installed for SSH access.

**These files are not committed.** `.gitignore` excludes:

- `*.auto.pkrvars.hcl` — the per-build configuration listed above
- `*.pkrvars.hcl` — any explicit override file, except `*.pkrvars.hcl.example`
- `*.tfvars` — Terraform variable values, except `*.tfvars.example`
- key material (`*.pem`, `*.key`, `id_rsa*`, `id_ecdsa*`)

What *is* committed is the contract: the `variables.pkr.hcl` files declare every
input variable and its type, and the `*.pkrvars.hcl.example` files that ship with
individual builds show the expected shape.

Never commit a filled-in configuration file. If one is committed by accident,
rotate the credential — removing the file from a later commit does not remove it
from history or from existing clones. See
[docs/operations/secrets.md](docs/operations/secrets.md) and
[SECURITY.md](SECURITY.md).

> **If a secret is committed:** rotate the affected credential immediately. A
> later commit that deletes the file does not erase it from git history, so treat
> any credential that has reached a commit as compromised.

---

## Validation

The full report is in
[docs/operations/validation.md](docs/operations/validation.md).

**Templates resolve.** Every `templatefile()` reference in the build definitions
points at a file that exists: the per-project `data/` directories for Photon,
RHEL and Ubuntu, and `scripts/windows/data/` for the Windows Server projects,
which reach it as `../../../../scripts/windows/data/`.

**Configuration is local, by design.** Sixteen projects ship only
`*.pkrvars.hcl.example`, so `packer validate` on a bare checkout stops on unset
variables; fifteen ship no example at all, and for those the input contract is
the only guide:

| Ships `*.pkrvars.hcl.example` | Ships none |
| :--- | :--- |
| AlmaLinux, CentOS, Debian, Fedora, Oracle, Rocky, SLES, Photon, Windows Desktop, Ubuntu 22.04 | RHEL 9.6 and 10.0, Ubuntu 20.04/24.04/26.04, and the ten Windows Server projects |

Supply the configuration first, as described in
[Configuration and secrets](#configuration-and-secrets).

**Windows Server is verified end to end.** The eight Windows Server editions in
this repository have been built and published to a vSphere Content Library -
2022 and 2025, for Standard and Datacenter, Core and Desktop Experience.
See [docs/operations/windows-builds.md](docs/operations/windows-builds.md) for
the drive-letter contract the images depend on.

**The front end is tested.** `web/` is a Flask application over the same
CronJobs. Its 224 unit tests run against a fake gateway, with no cluster, and
`web/tools/gen-manifest.py --check` proves the deployed manifest still matches
the source. See [docs/operations/web-front-end.md](docs/operations/web-front-end.md).

**The build chart renders.** `helm lint` is clean, and `helm template` produces
one CronJob for each project directory under `builds/`, every one of them
pointing at a directory that exists. Rendering is what is checked, not an
install: there is no cluster to install into here.

**Terraform validates.** With Terraform 1.17.1 - the release pinned in
`scripts/bootstrap/terraform.lock` and fetched into `tools/terraform/` by
`scripts/bootstrap/fetch-terraform.*` - `terraform fmt -check -recursive
terraform` is clean, and `terraform init -backend=false` followed by
`terraform validate` succeeds for `terraform/vsphere-role`.

**Formatting.** `packer fmt -check -recursive .` is clean across the repository.
Run `packer fmt -recursive .` after editing a build definition so it stays that
way.

**Known issues** are tracked in
[docs/operations/validation.md](docs/operations/validation.md) and
[SECURITY.md](SECURITY.md). Check them before assuming a build failure is yours.

---

## Documentation

The documentation site source lives in `docs/` and is built with MkDocs
Material (`mkdocs.yml`).

| Page | Covers |
| :--- | :--- |
| [Overview][d1] | Overview and platform support matrix |
| [Get the project][d2] | Getting the source and the project structure |
| [Requirements][d3] | Toolchain and package requirements |
| [Configure][d4] | Configuring a build |
| [Build][d5] | Running builds |
| [Privileges][d6] | Least-privilege vSphere role |
| [Deploy the role][d20] | Creating and assigning that role, step by step |
| [FAQ][d7] | Common questions and failures |
| [Architecture][d8] | How the pipeline fits together |
| [Build projects][d9] | Every build project and its sources |
| [Configuration][d10] | Every input variable |
| [Scripts][d11] | Provisioning scripts |
| [Terraform][d12] | Terraform examples |
| [Tests][d13] | Template rendering tests |
| [Validation][d14] | Validation report |
| [Troubleshooting][d15] | Diagnosing failed builds |
| [Secrets][d16] | Credential handling |
| [Web front end][d19] | The build dashboard, deployment and config |
| [Kubernetes][d21] | The build chart, and how the two layers deploy |
| [Support][d17] | Community support channels |
| [Release notes][d18] | Per-release change notes |

To preview the site locally:

```shell
pip install mkdocs-material
mkdocs serve
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, the commit conventions,
and the checks a change must pass before it is merged. All participants are
expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Markdown changes must pass the linter configured in
`.markdownlint-cli2.jsonc`:

```shell
npx markdownlint-cli2 "**/*.md"
```

Changes to `builds/` are validated before merge:

```shell
packer fmt -check -recursive .
packer init    builds/<path>
packer validate builds/<path>
tools/terraform/terraform fmt -check -recursive terraform
```

---

## License

BSD 2-Clause. See [LICENSE](LICENSE). Third-party components redistributed or
downloaded during a build remain under their own licenses, listed there.

[d1]: docs/index.md
[d2]: docs/getting-started/get-project.md
[d3]: docs/getting-started/requirements.md
[d4]: docs/getting-started/configure.md
[d5]: docs/getting-started/build.md
[d6]: docs/getting-started/privileges.md
[d7]: docs/getting-started/faq.md
[d8]: docs/architecture/overview.md
[d9]: docs/reference/builds.md
[d10]: docs/reference/configuration.md
[d11]: docs/reference/scripts.md
[d12]: docs/reference/terraform.md
[d13]: docs/reference/tests.md
[d14]: docs/operations/validation.md
[d15]: docs/operations/troubleshooting.md
[d16]: docs/operations/secrets.md
[d17]: docs/community/support.md
[d18]: docs/release-notes.md
[d19]: docs/operations/web-front-end.md
[d20]: docs/operations/terraform-role-deploy.md
[d21]: kubernetes/README.md
