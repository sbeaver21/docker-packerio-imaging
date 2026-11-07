---
icon: octicons/play-24
---

# Build the Images

Every build is a Packer project under `builds/`. There is no wrapper script and
no menu: Packer is invoked directly, against the project you want.

## Before the first build

Two things have to exist before `packer build` will do anything useful:

1. **The project's local configuration.** Packer loads every
   `*.auto.pkrvars.hcl` file beside the template automatically, and those files
   are gitignored because they carry the vCenter credentials and the build
   passwords. Create them from the project's `*.pkrvars.hcl.example` files -
   see [Configure](configure.md).
2. **The plugins.** `packer init` downloads the builders the project declares.

```shell
packer init builds/linux/ubuntu/24-04-lts
```

## Build a project

```shell
packer validate builds/linux/ubuntu/24-04-lts
packer build    builds/linux/ubuntu/24-04-lts
```

`packer validate` parses the template, resolves every `${path.root}` and
`templatefile()` reference, and fails on a variable that has no value. It does
not contact vSphere. Run it first: it catches the errors that would otherwise
surface halfway through an unattended install.

## Build one source out of several

A project may declare several sources - one per edition, for example - and
produce several images from one template. `--only` builds one of them.

```shell
# Linux / macOS
packer build --only=vsphere-iso.windows-server-2025-standard-core \
    builds/windows/server/2025

# Windows Command Prompt
packer build --only=vsphere-iso.windows-server-2025-standard-core ^
    builds/windows/server/2025
```

The source names are the `source` blocks in the project's `*.pkr.hcl` file;
`packer inspect builds/<path>` lists them.

## What a build produces

| Output | Where |
| :--- | :--- |
| The image | The vSphere Content Library named by `common_content_library` |
| An OVF export | `artifacts/` |
| A build manifest | `manifests/`, written by the manifest post-processor |

The manifest records the variables the build ran with, the source, and the
timestamps, which is what makes a published template traceable back to a
commit.

![Packer building an Ubuntu Server image](../assets/images/build.gif)

## Build with environment variables

Packer reads `PKR_VAR_<name>` from the environment and an environment variable
always takes precedence over a value in a variable file. That is the supported
way to supply a credential without writing it to disk:

```shell
export PKR_VAR_build_password="$BUILD_PASSWORD"   # Linux / macOS
$env:PKR_VAR_build_password = $env:BUILD_PASSWORD # PowerShell
```

Anything supplied this way must still be declared in the project's
`variables.pkr.hcl`; an undeclared `PKR_VAR_` is ignored silently.

## Content Library behaviour

By default the finished image is transferred to a
[vSphere Content Library][vsphere-content-library] as an OVF template and the
temporary virtual machine is destroyed. If an item of the same name already
exists in the target library, Packer updates it with the new version.

A Windows 11 image is **not** published to the content library by default: an
encrypted virtual machine cannot be cloned to a content library as an OVF
template. Configure the library to use VM templates instead, and see the
[VMware vSphere product documentation][vsphere-tpm] for the trust and
encryption prerequisites.

[//]: Links
[vsphere-content-library]: https://docs.vmware.com/en/VMware-vSphere/7.0/com.vmware.vsphere.vm_admin.doc/GUID-2A56B36F-55DD-4E47-A83A-3B1B0F7A9C5D.html
[vsphere-tpm]: https://docs.vmware.com/en/VMware-vSphere/7.0/com.vmware.vsphere.vm_admin.doc/GUID-4DBF65A4-4BA0-4667-9725-AE9F047DE00A.html
