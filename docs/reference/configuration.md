# Configuration Reference

Every input variable declared by the build projects, grouped by purpose. The
declarations live in the `variables*.pkr.hcl` files in each project directory;
values live in that project's `*.auto.pkrvars.hcl`, which is not committed.

The **Scope** column says where a variable appears:

| Scope | Meaning |
| :---- | :------ |
| all | Declared by every project |
| linux | Only the Linux projects |
| photon/ubuntu | Only those projects |
| windows | Only the Windows projects |
| rhel | Only the RHEL projects, in their single `rhel.auto.pkrvars.hcl` |

---

## vSphere connection

| Variable | Type | Scope | Notes |
| :------- | :--- | :---- | :---- |
| `vsphere_endpoint` | string | all | vCenter FQDN or IP |
| `vsphere_username` | string, sensitive | all | Service account, `user@domain` form |
| `vsphere_password` | string, sensitive | all | Prefer `PKR_VAR_vsphere_password` |
| `vsphere_insecure_connection` | bool | all | `true` disables TLS validation |

---

## vSphere inventory

| Variable | Type | Scope | Default | Notes |
| :------- | :--- | :---- | :------ | :---- |
| `vsphere_datacenter` | string | all | `""` | Datacenter name |
| `vsphere_cluster` | string | all | `""` | Cluster name; leave empty for a standalone host |
| `vsphere_host` | string | all | `""` | Required when DRS is disabled or the host is standalone |
| `vsphere_datastore` | string | all | — | Datastore for the build VM |
| `vsphere_network` | string | all | — | Full inventory path to the port group |
| `vsphere_folder` | string | all | `""` | VM folder |
| `vsphere_resource_pool` | string | all | `""` | Resource pool, if not the cluster root |
| `vsphere_set_host_for_datastore_uploads` | bool | all | `false` | Route ISO/files uploads through the host |

`vsphere_network` must be a path such as
`/dc01/network/vds01/VM Network`, not a bare port group name.

---

## Virtual machine hardware

| Variable | Type | Scope | Default | Notes |
| :------- | :--- | :---- | :------ | :---- |
| `vm_guest_os_family` | string | all | `linux` | Used in the VM name |
| `vm_guest_os_name` | string | all | — | Used in the VM name |
| `vm_guest_os_version` | string | all | — | Used in the VM name |
| `vm_guest_os_type` | string | all | — | vSphere guest ID, e.g. `vmwarePhoton64Guest` |
| `vm_guest_os_language` | string | all | `en_US` | |
| `vm_guest_os_keyboard` | string | all | `us` | |
| `vm_guest_os_timezone` | string | all | `America/New_York` | IANA name on Linux, Windows name on Windows |
| `vm_guest_os_cloudinit` | bool | linux | `false` | Enable cloud-init in the guest |
| `vm_firmware` | string | all | `efi-secure` | `bios`, `efi`, `efi-secure` |
| `vm_cpu_count` | number | all | `2` | vCPUs |
| `vm_cpu_cores` | number | all | `1` | Cores per socket |
| `vm_cpu_hot_add` | bool | all | `false` | |
| `vm_mem_size` | number | all | `2048` | MB |
| `vm_mem_hot_add` | bool | all | `false` | |
| `vm_disk_size` | number | all | `102400` | MB. On several builds this is the only capacity control |
| `vm_disk_controller_type` | list(string) | all | `["pvscsi"]` | |
| `vm_disk_thin_provisioned` | bool | all | `true` | |
| `vm_network_card` / `vm_nic_type` | string | all | `vmxnet3` | The name differs by project |
| `vm_cdrom_type` | string | all | `sata` | |
| `vm_cdrom_count` | number | linux | `1` | CD-ROMs left after the build |
| `common_vm_version` | number | all | — | vSphere hardware version, e.g. `21` |
| `common_tools_upgrade_policy` | bool | all | `true` | Upgrade VMware Tools on reboot |
| `common_remove_cdrom` | bool | all | varies | Remove the CD-ROM before sealing |

The Windows Server projects additionally use `common_reattach_cdroms` (number).

---

## Template and content library

| Variable | Type | Default | Notes |
| :------- | :--- | :------ | :---- |
| `common_template_conversion` | bool | `false` | Convert the VM to a template. Must be `false` when publishing to a library |
| `common_content_library_enabled` | bool | `true` | Publish to a content library |
| `common_content_library` | string | `null` | Library name |
| `common_content_library_ovf` | bool | `true` | Publish as an OVF template |
| `common_content_library_destroy` | bool | `true` | Delete the build VM after publishing |
| `common_content_library_skip_export` | bool | `false` | Publish nothing — use for a test build |

---

## OVF export

| Variable | Type | Default | Notes |
| :------- | :--- | :------ | :---- |
| `common_ovf_export_enabled` | bool | `false` | Write an OVF under `artifacts/` |
| `common_ovf_export_overwrite` | bool | `true` | Overwrite an existing export |
| `common_ovf_export_image_files` | bool | — | Include disk files in the export |

---

## ISO and removable media

| Variable | Type | Notes |
| :------- | :--- | :---- |
| `common_iso_content_library_enabled` | bool | Choose library over datastore for the ISO |
| `common_iso_content_library` | string | Library holding the ISO |
| `common_iso_datastore` | string | Datastore holding the ISO |
| `iso_datastore_path` | string | Path within the datastore |
| `iso_file` | string | ISO file name |
| `iso_content_library_item` | string | Content library item name for the ISO |

Linux projects also declare `iso_checksum_type`, `iso_checksum_value` and
`iso_url`, which describe the upstream download. They are **not** used to verify
the ISO the builder mounts from vSphere.

---

## Boot and provisioning data source

| Variable | Type | Default | Notes |
| :------- | :--- | :------ | :---- |
| `common_data_source` | string | — | `http` or `disk` |
| `common_http_ip` | string | `null` | Bind Packer's HTTP server to this address |
| `common_http_port_min` | number | — | Start of the HTTP port range |
| `common_http_port_max` | number | — | End of the HTTP port range |
| `vm_boot_order` | string | `disk,cdrom` | |
| `vm_boot_wait` | string | `5s` | Delay before the boot command starts |
| `common_ip_wait_timeout` | string | — | How long to wait for the guest address |
| `common_ip_settle_timeout` | string | `5s` | How long the address must be stable |
| `common_shutdown_timeout` | string | — | How long to wait for the guest to power off |

Windows projects add `vm_boot_command` and `vm_shutdown_command`.

---

## Accounts

| Variable | Type | Scope | Notes |
| :------- | :--- | :---- | :---- |
| `build_username` | string, sensitive | all | The account Packer connects as |
| `build_password` | string, sensitive | all | Literal password for the communicator |
| `build_password_encrypted` | string, sensitive | all | SHA-512 crypt of the same password |
| `build_key` | string, sensitive | all | Public key, or `""` |
| `ansible_username` | string, sensitive | linux | Ansible account |
| `ansible_key` | string, sensitive | linux | Ansible public key |
| `build_username` | string, sensitive | photon, ubuntu | Guest build account |
| `build_password` | string, sensitive | photon, ubuntu | |
| `build_password_encrypted` | string, sensitive | photon, ubuntu | |
| `auto_username` | string, sensitive | photon, ubuntu | Site automation account |
| `auto_password` | string, sensitive | photon, ubuntu | |
| `auto_password_encrypted` | string, sensitive | photon, ubuntu | |
| `auto_key` | string, sensitive | photon, ubuntu | |
| `root_password_encrypted` | string, sensitive | photon, ubuntu | Root account hash |

Windows projects use `vm_windows_image`, `vm_inst_os_image`, `vm_inst_os_key`,
`vm_inst_os_language`, `vm_inst_os_keyboard`, `vm_inst_os_eval` and
`vm_guest_os_name` to select the image index inside the media.

---

## Subscription registration

| Variable | Type | Scope | Notes |
| :------- | :--- | :---- | :---- |
| `rhsm_username` | string | rhel | Red Hat subscription account |
| `rhsm_password` | string, sensitive | rhel | |
| `scc_username` | string | sles | SUSE Customer Connect |
| `scc_password` | string, sensitive | sles | |

Both are registered before package installation and unregistered before the
image is sealed.

---

## Communicator

| Variable | Type | Default | Notes |
| :------- | :--- | :------ | :---- |
| `communicator_port` | number | `22` Linux, `5985` Windows | SSH or WinRM |
| `communicator_timeout` | string | `30m` | |
| `communicator_proxy_host` | string | `null` | SSH jump host |
| `communicator_proxy_port` | number | `null` | |
| `communicator_proxy_username` | string | `null` | |
| `communicator_proxy_password` | string, sensitive | `null` | |

---

## Network (guest)

| Variable | Type | Notes |
| :------- | :--- | :---- |
| `vm_ip_address` | string | Static address for the build |
| `vm_ip_netmask` | number or string | Prefix length |
| `vm_ip_gateway` | string | |
| `vm_dns_list` | list(string) | Resolvers |

!!! warning "Shadowed by `locals` in several projects"
    The Photon, RHEL and Ubuntu templates define these names in a `locals`
    block, which takes precedence over the variable. Setting them in an
    `*.auto.pkrvars.hcl` for those projects has no effect. See
    [Configure](../getting-started/configure.md#guest-network-configuration).

---

## Storage

| Variable | Type | Notes |
| :------- | :--- | :---- |
| `vm_disk_device` | string | e.g. `sda` |
| `vm_disk_use_swap` | bool | Create a swap partition or volume |
| `vm_disk_partitions` | list(object) | `name`, `size`, `format{label,fstype}`, `mount{path,options}`, `volume_group` |
| `vm_disk_lvm` | list(object) | `name`, `partitions[]` with the same shape |

`size = -1` takes the remaining space, and is valid only on the last partition
or logical volume.

---

## Packages and registry

| Variable | Type | Default | Notes |
| :------- | :--- | :------ | :---- |
| `additional_packages` | list(string) | `[]` | Installed by the answer file. Keep this empty on Photon — see below |
| `common_hcp_packer_registry_enabled` | bool | `false` | Publish to HCP Packer |

!!! warning "`additional_packages` on Photon OS"
    The Photon installer resolves package names only against the repository on
    the installation ISO. Given a name it cannot find there it does not report a
    missing package — it switches to installing through a Docker container and
    fails with `FileNotFoundError: 'docker'`, because the installer environment
    has no Docker.

!!! tip "What to do instead on Photon OS"
    Keep `additional_packages = []` and install everything after the OS is up,
    with a provisioner that runs on the installed system.

---

## Windows provisioner settings

| Variable | Type | Notes |
| :------- | :--- | :---- |
| `scripts` | list(string) | PowerShell commands run after the inline block |
| `inline` | list(string) | The hardening sequence, run elevated as SYSTEM |
| `vm_shutdown_command` | string | Shutdown command invoked by the communicator |

The `inline` list in each Windows project's `*.auto.pkrvars.hcl` is what disables
IPv6, resets TCP/IP and Winsock, and runs the hardening scripts from
`builds/windows/files/Temp/`.

---

## Environment overrides

Any variable can be supplied as `PKR_VAR_<name>` in the environment, and that
takes precedence over a value in a var file:

```shell
export PKR_VAR_vsphere_password='«password»'
packer build builds/linux/photon/5
```

Use this for `vsphere_password` on a shared build host. The variables are
`sensitive`-flagged where it matters, so Packer redacts them in logs — but a
value written into a committed file is not protected by that.
