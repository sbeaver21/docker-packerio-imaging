---
icon: octicons/server-24
---

# vSphere Supervisor images

An alternative builder, for clusters where the image does not start from an ISO
attached to a VM in a vCenter. The **`vsphere-supervisor`** builder creates the
source virtual machine on a vSphere Supervisor cluster through the VM-Operator
API, configures it over SSH or WinRM, and publishes the finished machine as a
VM image in a content library.

| Property | Value |
| :--- | :--- |
| Builder type | `vsphere-supervisor` |
| Artifact BuilderId | `vsphere.supervisor` |
| Plugin | `github.com/vmware/vsphere`, pinned `>= 2.1.1` |
| Material | `references/supervisor-images/` |
| Licence | Mozilla Public License 2.0 |

## What the two directories hold

**Upstream** is `examples/`, the sample set as published. **Site** is `site/`,
the set this site builds from.

| Template | `examples/` | `site/` | Does |
| :--- | :---: | :---: | :--- |
| `general-template.pkr.hcl` | • | • | Smallest working source: existing image, one shell provisioner |
| `general-template-with-image-import.pkr.hcl` | • | • | Same, but imports an OVF or ISO from a URL first |
| `nginx-template.pkr.hcl` | • | • | Installs nginx, publishes a web server image |
| `jenkins-template.pkr.hcl` | • | • | Installs Jenkins and completes the unlock flow |
| `windows-template.pkr.hcl` | • | • | Windows source with the Sysprep bootstrap provider |
| `rhel-9-4.pkr.hcl`, `rhel-9-6.pkr.hcl`, `rhel-10-0.pkr.hcl` | | • | RHEL from a URL-imported DVD ISO through a full provisioning and sealing sequence |
| `windows-2022.pkr.hcl`, `windows-2025.pkr.hcl` | | • | Windows Server from a URL-imported ISO, provisioned over WinRM, sealed with `sysprep /generalize` |
| `cloud-init-rhel-9.yml`, `cloud-init-rhel-10.yml` | | • | Cloud-init bootstrap data for the RHEL templates; identical in content, because the `bootstrap_data_file` default names a file per release |
| `sysprep-unattend-data.yml` | • | • | Generic Sysprep unattend, YAML-wrapped for the builder |
| `sysprep-unattend-windows-2022.yml`, `-2025.yml` | | • | Per-version unattend files |
| `cleanup-playbook.yml` | • | • | Ansible equivalent of the sealing steps, for the `ansible` provisioner |
| `scripts/serve-iso.ps1`, `scripts/serve-iso.sh` | | • | Serve a local `iso/` directory over HTTP for image import |

The two directories overlap deliberately: `examples/` is the upstream example
set as published, and `site/` is the same five templates plus the images this
site actually builds. Change `site/`; leave `examples/` alone unless you are
re-syncing from upstream.

## Prerequisites

- A vSphere Supervisor cluster with **VM Service** enabled.
- A kubeconfig for that cluster. The builder reads `kubeconfig_path`, then
  `$KUBECONFIG`, then `$HOME/.kube/config`.
- A **VM class** (`kubectl get virtualmachineclasses`) and a **storage class**
  (`kubectl get storageclass`). Both are required and both are site-specific:
  `best-effort-xsmall`, `guaranteed-large`, `thick` and `thin` appear in the
  template comments only as examples.
- A content library in the target namespace that is writable and permits
  imports, when you import an image by URL or publish the result.
- Packer 1.11.0 or later, and the vsphere plugin: `packer init <template>`.

## Running a template

Initialise and validate **per template file**. These directories hold several
independent templates that each declare `image_name`, `class_name` and
`storage_class`, and Packer loads every template in a directory it is given - so
`packer init .` fails with a wall of `Duplicate variable` errors that say
nothing about the templates.

```shell
cd references/supervisor-images/site

packer init     rhel-9-6.pkr.hcl
packer validate rhel-9-6.pkr.hcl
```

`packer validate` needs the kubeconfig: the builder evaluates
`supervisor_namespace` at validation time. Without one it stops on

```text
failed to get current context's namespace in kubeconfig file:
invalid configuration: no configuration has been provided
```

which is a missing cluster, not a broken template. `packer validate
-syntax-only` passes for all fifteen and needs nothing.

A build supplies the site values as variables:

```shell
packer build \
  -var="class_name=best-effort-xsmall" \
  -var="storage_class=thick" \
  -var="image_name=rhel-9-6-template" \
  -var="supervisor_namespace=my-namespace" \
  -var="publish_location_name=my-content-library" \
  -var="import_source_url=https://files.example.com/rhel-9.6-x86_64-dvd.iso" \
  rhel-9-6.pkr.hcl
```

## Importing an ISO from a local HTTP server

The builder imports an image by URL, which means the Supervisor cluster has to
be able to reach it. For a first test the ISO usually sits on the machine you
are working on, so `scripts/serve-iso.*` start a Python HTTP server over an
`iso/` directory at the repository root, list the addresses it is reachable on,
and print the `import_source_url` value to use for each:

```shell
# Linux or macOS
./scripts/serve-iso.sh 8080

# Windows
powershell -ExecutionPolicy Bypass -File scripts/serve-iso.ps1 -Port 8080
```

Then set `use_local_iso_server=true` and `local_iso_server_host=<your address>`.
The template builds the URL from the host, port and `iso_filename` rather than
making you type it:

```hcl
locals {
  local_iso_url = "http://${var.local_iso_server_host}:${var.local_iso_server_port}/${var.iso_filename}"
}
```

`local_iso_server_host` defaults to `localhost`, which the Supervisor cluster
cannot reach - set it to an address the cluster routes to.

## What the image templates do

### RHEL 9.4, 9.6, 10.0

Shell provisioners, in this order:

1. Connectivity check and OS identification.
2. `subscription-manager register --auto-attach`, when
   `rhel_subscription_username` and `rhel_subscription_password` are set.
3. DNF configuration, `dnf update -y`, common tooling, `open-vm-tools`,
   optional Development Tools.
4. SSH hardening (keepalive, `UseDNS no`), timezone, sysctl tuning, firewalld.
5. A `packer` account with passwordless sudo, so the image can be re-provisioned.
6. Sealing: package cache cleared, `/etc/machine-id` truncated, SSH host keys
   removed, shell history cleared, `cloud-init clean --logs`.
7. Summary output.

The three templates differ only in the ISO filename, the source block name and
the release they target. Copy the nearest one rather than editing in place.

### Windows Server 2022, 2025

Powershell provisioners over WinRM (`winrm_use_ssl = true`,
`winrm_insecure = true`, `winrm_timeout = "2h"`), in this order:

1. Execution policy and timezone (`Eastern Standard Time` on 2022, `Central
   Standard Time` on 2025 - the files disagree, and neither is derived).
2. WinRM limits, then .NET 3.5, .NET 4.8, SNMP and Telnet features.
3. IE Enhanced Security off, RDP on, firewall profiles off, high-performance
   power scheme.
4. Windows Update through `PSWindowsUpdate`, with `expect_disconnect` and a
   restart provisioner.
5. Cleanup: temp files, update cache, event logs.
6. `sysprep /generalize /oobe /shutdown /quiet`.

!!! warning "Firewall and RDP are deliberately open"

    The Windows templates disable every firewall profile and enable RDP so the
    build can complete. That is a build-time posture. If the published image is
    the basis of a template, treat the firewall state as something to correct
    afterwards, exactly as you would with an unattended install that leaves the
    guest open.

### Sealing with Ansible instead

`cleanup-playbook.yml` performs the Linux seal - machine-id truncation, log
truncation, cloud-init removal, temp files, shell history - and is attached with
the `ansible` provisioner when you prefer that to inline shell:

```hcl
build {
  sources = ["source.vsphere-supervisor.vm"]

  provisioner "ansible" {
    playbook_file = "cleanup-playbook.yml"
  }
}
```

The RHEL templates in `site/` do the same work inline, so they do not use it.

## Selected reference

| Parameter | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `class_name` | string | required | VM class: virtual hardware |
| `storage_class` | string | required | Storage policy for the VM and its disks |
| `image_name` | string | required | Source VM image in the namespace's content library |
| `source_name` | string | random | Source VM name, limited to 15 characters |
| `kubeconfig_path` | string | `$KUBECONFIG` | Cluster credentials |
| `supervisor_namespace` | string | kubeconfig context | Namespace to deploy into |
| `bootstrap_provider` | string | `CloudInit` | `CloudInit`, `Sysprep` or `vAppConfig` |
| `bootstrap_data_file` | string | basic cloud-config | Required when the provider is not `CloudInit` |
| `import_source_url` | string | - | Remote OVF or ISO to import first |
| `import_target_location_name` | string | - | Content library that receives the import |
| `import_target_image_type` | string | URL suffix | `ovf` or `iso` |
| `clean_imported_image` | bool | `false` | Delete the imported image after the build |
| `publish_location_name` | string | - | Content library that receives the published image |
| `publish_image_name` | string | builder default | Name of the published image |
| `watch_source_timeout_sec` | number | `3600` | Wait for the source VM to be ready |
| `keep_input_artifact` | bool | `false` | Leave the source VM behind |
| `iso_boot_disk_size` | string | `20Gi` | PVC size for ISO deployments |

The full parameter list, including every SSH and WinRM option, is in the plugin
documentation linked from `references/supervisor-images/README.md`.

## When it fails

| Symptom | Cause | Check |
| :--- | :--- | :--- |
| `failed to connect to supervisor cluster` | kubeconfig missing or stale | `kubectl config current-context` with the same `KUBECONFIG` |
| `VM class not found` | `class_name` wrong or not offered in the namespace | `kubectl get virtualmachineclasses` |
| `storage class not found` | `storage_class` wrong | `kubectl get storageclass` |
| `Timeout waiting for source VM` | Import or boot slow | Raise `watch_source_timeout_sec`, or `watch_import_timeout_sec` |
| `SSH connection refused` | Bootstrap data has no SSH key or user | Check `bootstrap_data_file` |
| `Publishing failed` | Content library not writable | `publish_location_name`, and the namespace's library permissions |
| `Duplicate variable` on `packer init` | The directory was passed instead of a file | `packer init <template>.pkr.hcl` |

## Related

- [Windows VCF Automation image](windows-vcf-image.md) - the Cloudbase-Init
  layer a Windows image needs before VCF Automation will initialise it.
- [Active Directory join](vcfa-ad-join.md) - what happens once it is deployed.
- [Build projects](../reference/builds.md) - the `vsphere-iso` projects these
  templates are an alternative to.
