---
icon: octicons/gift-24
---

# Get the Project

```shell
git clone https://github.com/sbeaver21/docker-packerio-imaging.git
cd docker-packerio-imaging
```

Work on a branch. The branch name is not decorative: it is recorded in the build
version and in the resulting virtual machine name.

```shell
git switch -c feature/my-change
```

???+ warning "Never commit a filled-in configuration"

    The files Packer loads automatically - `*.auto.pkrvars.hcl` - carry the
    vCenter service account and the build passwords. They are gitignored and
    must stay that way. See [Secrets](../operations/secrets.md).

## Project structure

| Directory | Contents |
| :--- | :--- |
| `ansible/` | Playbooks and roles used to configure Linux guests after installation. |
| `artifacts/` | OVF export destination. Generated output, not source. |
| `builds/` | One Packer project per guest operating system, version and edition. |
| `data/` | Shared answer-file templates; each build project also carries its own `data/`. |
| `docs/` | This documentation site (MkDocs Material). |
| `manifests/` | Build manifests written by the manifest post-processor. Generated output. |
| `scripts/` | Provisioning scripts executed inside the guest, grouped by distribution. |
| `terraform/` | The least-privilege vSphere role the builds run under. |
| `tests/` | Bats tests for the network and storage template rendering. |

Each directory has its own README describing its contents.

## What is not in the repository

Two things are deliberately absent:

- **The local configuration.** Every build needs a `*.auto.pkrvars.hcl` that
  points at a real vCenter. Those files are written on the build host, not here.
- **Any built image.** ISOs, OVFs and the Packer plugin cache are all excluded
  by `.gitignore`.
