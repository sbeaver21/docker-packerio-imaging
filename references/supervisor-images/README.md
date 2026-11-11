# Packer: vSphere Supervisor Builder

> **Type:** `vsphere-supervisor`  
> **Artifact BuilderId:** `vsphere.supervisor`  
> **Source Executable:** [Download Packer](https://developer.hashicorp.com/packer/install)  
> **Plugin Source:** [HashiCorp Developer Docs - vSphere Supervisor Builder](https://developer.hashicorp.com/packer/integrations/vmware/vsphere/latest/components/builder/vsphere-supervisor)

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Plugin Installation](#plugin-installation)
- [Examples](#examples)
- [Configuration Reference](#configuration-reference)
- [Deprovisioning Tasks](#deprovisioning-tasks)
- [Troubleshooting](#troubleshooting)
- [Additional Resources](#additional-resources)

---

## Overview

This Packer builder creates a virtual machine on a **vSphere Supervisor cluster** using the **VM-Operator API**. It is part of the [VMware vSphere Packer Plugin](https://github.com/vmware/packer-plugin-vsphere) maintained by VMware.

### Key Features

- Uses a `kubeconfig` file to connect to the vSphere Supervisor cluster
- Leverages the [VM-Operator API](https://vm-operator.readthedocs.io/en/latest/concepts/) to deploy and configure the source virtual machine
- Supports Packer provisioners for customizing the virtual machine after connection
- Publishes the customized VM as a new VM image to a designated content library in vSphere

> **Note:** This builder maintains compatibility with VMware vSphere versions until their respective End of General Support dates. See the [Broadcom Product Lifecycle](https://support.broadcom.com/group/ecx/productlifecycle) for details.

---

## Prerequisites

Before using this builder, ensure the following are in place:

- **vSphere Supervisor cluster** configured with [VM Service](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/deploying-and-managing-virtual-machines-in-vsphere-iaas-control-plane.html)
- A valid **`kubeconfig` file** for accessing the Supervisor cluster (defaults to `$KUBECONFIG` env var or `$HOME/.kube/config`)
- The **Packer Plugin for VMware vSphere** installed (see [Plugin Installation](#plugin-installation))
- **Packer v1.7.0+** recommended for full HCL2 support

---

## Plugin Installation

### Method 1: Using `packer init` (Recommended)

Add this block to your Packer configuration:

```hcl
packer {
  required_plugins {
    vsphere = {
      version = "~> 1"
      source  = "github.com/vmware/vsphere"
    }
  }
}
```

Then run:

```shell
packer init .
```

### Method 2: Manual Installation

```shell
packer plugins install github.com/vmware/vsphere
```

---

## Examples

### Basic HCL Example

The simplest configuration uses an existing VM image from a content library:

```hcl
source "vsphere-supervisor" "example-vm" {
  image_name             = "ubuntu-impish-21.10-cloudimg"
  class_name             = "best-effort-large"
  storage_class          = "wcplocal-storage-profile"
  bootstrap_provider     = "CloudInit"
  bootstrap_data_file    = "./user-data"
  publish_location_name  = "cl-6066c61f7931c5ef9"
}

build {
  sources = ["source.vsphere-supervisor.example-vm"]
}
```

### HCL Example with Image Import

Import a remote image (OVF/ISO) before building:

```hcl
source "vsphere-supervisor" "example-vm" {
  import_source_url             = "https://example.com/ubuntu-22.04.ovf"
  import_source_ssl_certificate = "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"
  import_target_location_name   = "cl-6066c61f7931c5ef9"
  import_target_image_type      = "ovf"
  import_target_image_name      = "ubuntu-22.04-cloudimg"
  class_name                    = "best-effort-large"
  storage_class                 = "wcplocal-storage-profile"
  bootstrap_provider            = "CloudInit"
  bootstrap_data_file           = "./user-data"
  publish_location_name         = "cl-6066c61f7931c5ef9"
}

build {
  sources = ["source.vsphere-supervisor.example-vm"]
}
```

### JSON Example

Equivalent configuration using legacy JSON format:

```json
{
  "builders": [
    {
      "type": "vsphere-supervisor",
      "image_name": "ubuntu-impish-21.10-cloudimg",
      "class_name": "best-effort-large",
      "storage_class": "wcplocal-storage-profile",
      "bootstrap_provider": "CloudInit",
      "bootstrap_data_file": "./user-data",
      "publish_location_name": "cl-6066c61f7931c5ef9"
    }
  ]
}
```

### JSON Example with Image Import

```json
{
  "builders": [
    {
      "type": "vsphere-supervisor",
      "import_source_url": "https://example.com/ubuntu-22.04.ovf",
      "import_source_ssl_certificate": "-----BEGIN CERTIFICATE-----xxxxx-----END CERTIFICATE-----",
      "import_target_location_name": "cl-6066c61f7931c5ef9",
      "import_target_image_type": "ovf",
      "import_target_image_name": "ubuntu-22.04-cloudimg",
      "class_name": "best-effort-large",
      "storage_class": "wcplocal-storage-profile",
      "bootstrap_provider": "CloudInit",
      "bootstrap_data_file": "./user-data",
      "publish_location_name": "cl-6066c61f7931c5ef9"
    }
  ]
}
```

---

## Configuration Reference

### Required Parameters

| Parameter      | Type   | Description                                                  |
|----------------|--------|--------------------------------------------------------------|
| `class_name`   | string | Name of the VM class that describes virtual hardware settings (e.g., `best-effort-large`, `guaranteed-medium`) |
| `storage_class`| string | Name of the storage class that configures storage-related attributes (e.g., `wcplocal-storage-profile`) |

---

### Supervisor Connection (Optional)

| Parameter            | Type   | Default                                    | Description                                                  |
|----------------------|--------|--------------------------------------------|--------------------------------------------------------------|
| `kubeconfig_path`    | string | `$KUBECONFIG` env var or `$HOME/.kube/config` | Path to the kubeconfig file for accessing the vSphere Supervisor cluster |
| `supervisor_namespace` | string | Current context's namespace in kubeconfig    | The Supervisor namespace to deploy the source VM             |

---

### Source VM Image Importing (Optional)

| Parameter                    | Type   | Default                                        | Description                                                  |
|------------------------------|--------|------------------------------------------------|--------------------------------------------------------------|
| `import_source_url`          | string | -                                              | Remote URL where the to-be-imported image is hosted          |
| `import_source_ssl_certificate` | string | -                                            | SSL certificate of the remote HTTPS server hosting the image |
| `import_target_location_name`  | string | -                                            | Name of a writable, import-allowed ContentLibrary resource in the namespace |
| `import_target_image_type`     | string | Suffix of the source URL                      | Type of imported image. Options: `ovf`, `iso`                |
| `import_target_image_name`     | string | File name from source URL                     | Name of the imported image                                   |
| `import_request_name`          | string | `packer-vsphere-supervisor-import-req-<random-suffix>` | Name of the image import request                             |
| `watch_import_timeout_sec`    | int    | `600`                                         | Timeout in seconds to wait for image import                  |
| `keep_import_request`         | bool   | `false`                                       | Preserve the import request after build finishes             |
| `clean_imported_image`        | bool   | `false`                                       | Delete the imported image after build finishes               |

---

### Source Virtual Machine Creation

| Parameter            | Type   | Default                                        | Description                                                  |
|-----------------------|--------|------------------------------------------------|--------------------------------------------------------------|
| `image_name`          | string | -                                              | Name of the source VM image. If specified, uses this image; otherwise uses the imported image name |
| `source_name`         | string | `source-<random-5-digit-suffix>`               | Name of the source VM (limited to **15 characters**)         |
| `keep_input_artifact` | bool   | `false`                                        | Preserve all created objects in Supervisor cluster after build |
| `bootstrap_provider`  | string | `CloudInit`                                    | Bootstrap provider. Options: `CloudInit`, `Sysprep`, `vAppConfig` |
| `bootstrap_data_file` | string | Basic cloud config with SSH user               | Path to bootstrap config file. **Required** if `bootstrap_provider` is not `CloudInit` |
| `guest_os_type`       | string | `otherGuest`                                   | Guest operating system identifier for the VM                 |
| `iso_boot_disk_size`  | string | `20Gi`                                         | Size of the PVC boot disk for ISO VM deployments. Supported units: `Gi`, `Mi`, `Ki`, `G`, `M`, `K` |

---

### Source Virtual Machine Watching (Optional)

| Parameter                | Type | Default | Description                                        |
|--------------------------|------|---------|----------------------------------------------------|
| `watch_source_timeout_sec` | int  | `3600`  | Timeout in seconds to wait for the source VM to be ready |

---

### Source Virtual Machine Publishing (Optional)

| Parameter                  | Type   | Default                       | Description                                                  |
|----------------------------|--------|-------------------------------|--------------------------------------------------------------|
| `publish_image_name`       | string | Set by vm-operator API        | Name of the published VM image                               |
| `publish_location_name`    | string | -                             | Target content library for the published image               |
| `watch_publish_timeout_sec`| int    | `600`                         | Timeout in seconds to wait for VM publishing                 |

---

### SSH Communicator Configuration (Optional)

| Parameter                    | Type     | Default        | Description                                                  |
|------------------------------|----------|----------------|--------------------------------------------------------------|
| `ssh_host`                   | string   | Auto-configured | Address to SSH to                                            |
| `ssh_port`                   | int      | `22`           | SSH port                                                     |
| `ssh_username`               | string   | -              | SSH username (**required** if using SSH)                     |
| `ssh_password`               | string   | -              | SSH password                                                 |
| `ssh_timeout`                | duration | `5m`           | Time to wait for SSH to become available                     |
| `ssh_handshake_attempts`     | int      | `10`           | Number of handshake attempts                                 |
| `ssh_private_key_file`       | string   | -              | Path to PEM-encoded private key file                         |
| `ssh_certificate_file`       | string   | -              | Path to user certificate for SSH authentication              |
| `ssh_pty`                    | bool     | `false`        | Request a PTY for the SSH connection                         |
| `ssh_disable_agent_forwarding` | bool   | `false`        | Disable SSH agent forwarding                                 |
| `ssh_bastion_host`           | string   | -              | Bastion host for SSH connection                              |
| `ssh_bastion_port`           | int      | `22`           | Bastion host port                                            |
| `ssh_bastion_username`       | string   | -              | Bastion host username                                        |
| `ssh_bastion_password`       | string   | -              | Bastion host password                                        |
| `ssh_bastion_private_key_file` | string | -              | Bastion host private key file                                |
| `ssh_bastion_certificate_file` | string | -              | Bastion host certificate file                                |
| `ssh_bastion_agent_auth`     | bool     | `false`        | Use local SSH agent for bastion authentication               |
| `ssh_bastion_interactive`    | bool     | -              | Use keyboard-interactive for bastion auth                    |
| `ssh_file_transfer_method`   | string   | `scp`          | File transfer method: `scp` or `sftp`                        |
| `ssh_proxy_host`             | string   | -              | SOCKS proxy host for SSH                                     |
| `ssh_proxy_port`             | int      | `1080`         | SOCKS proxy port                                             |
| `ssh_proxy_username`         | string   | -              | SOCKS proxy username                                         |
| `ssh_proxy_password`         | string   | -              | SOCKS proxy password                                         |
| `ssh_keep_alive_interval`    | duration | `5s`           | Keep-alive interval (negative value disables)                |
| `ssh_read_write_timeout`     | duration | Disabled       | Timeout for remote commands                                  |
| `ssh_remote_tunnels`         | []string | -              | Remote port forwarding: `["REMOTE_PORT:LOCAL_HOST:LOCAL_PORT"]` |
| `ssh_local_tunnels`          | []string | -              | Local port forwarding: `["LOCAL_PORT:REMOTE_HOST:REMOTE_PORT"]` |
| `ssh_clear_authorized_keys`  | bool     | `false`        | Remove temporary key from authorized_keys after build        |
| `ssh_key_exchange_algorithms`| []string | -              | Override key exchange algorithms                             |
| `ssh_ciphers`                | []string | (see below)    | Override SSH ciphers                                         |

**Default SSH ciphers:**

```json
[
  "aes128-gcm@openssh.com",
  "chacha20-poly1305@openssh.com",
  "aes128-ctr",
  "aes192-ctr",
  "aes256-ctr"
]
```

**Temporary Key Pair Options:**

| Parameter                   | Type   | Default | Description                                              |
|-----------------------------|--------|---------|----------------------------------------------------------|
| `temporary_key_pair_type`   | string | `rsa`   | Key type: `dsa`, `ecdsa`, `ed25519`, or `rsa`           |
| `temporary_key_pair_bits`   | int    | `4096`  | Number of bits in the key                                |

---

### WinRM Communicator Configuration (Optional)

| Parameter          | Type   | Default                    | Description                                                  |
|--------------------|--------|----------------------------|--------------------------------------------------------------|
| `winrm_username`   | string | -                          | WinRM username                                               |
| `winrm_password`   | string | -                          | WinRM password                                               |
| `winrm_host`       | string | -                          | WinRM host address                                           |
| `winrm_port`       | int    | `5985` (plain) / `5986` (SSL) | WinRM port                                                |
| `winrm_timeout`    | duration | `30m`                     | Time to wait for WinRM                                       |
| `winrm_use_ssl`    | bool   | `false`                    | Use HTTPS for WinRM                                          |
| `winrm_insecure`   | bool   | `false`                    | Skip server certificate validation                           |
| `winrm_use_ntlm`   | bool   | `false`                    | Use NTLMv2 authentication                                    |
| `winrm_no_proxy`   | bool   | `false`                    | Bypass proxies for WinRM connection                          |

---

## Deprovisioning Tasks

After provisioning, it is recommended (but optional) to clean up the virtual machine before publishing the final image. Use the [Ansible provisioner](https://developer.hashicorp.com/packer/integrations/hashicorp/ansible/latest/components/provisioner/ansible) with a cleanup playbook to:

- Remove machine-specific identifiers and configurations
- Truncate logs and audit files
- Clean temporary files and shell history

### HCL Example with Ansible Cleanup

```hcl
build {
  sources = ["source.vsphere-supervisor.vm"]

  provisioner "ansible" {
    playbook_file = "cleanup-playbook.yml"
  }
}
```

### JSON Example with Ansible Cleanup

```json
{
  "builders": [
    {
      "type": "vsphere-supervisor"
    }
  ],
  "provisioners": [
    {
      "type": "ansible",
      "playbook_file": "./cleanup-playbook.yml"
    }
  ]
}
```

### Cleanup Playbook (`cleanup-playbook.yml`)

```yaml
---
- name: Clean up source virtual machine prior to publishing
  hosts: default
  become: true
  tasks:
    - name: Truncate machine-id
      file:
        state: "{{ item.state }}"
        path: "{{ item.path }}"
        owner: root
        group: root
        mode: "{{ item.mode }}"
      loop:
        - { path: /etc/machine-id, state: absent, mode: "0644" }
        - { path: /etc/machine-id, state: touch, mode: "0644" }

    - name: Truncate audit logs (wtmp, lastlog)
      file:
        state: "{{ item.state }}"
        path: "{{ item.path }}"
        owner: root
        group: utmp
        mode: "{{ item.mode }}"
      loop:
        - { path: /var/log/wtmp, state: absent, mode: "0664" }
        - { path: /var/log/lastlog, state: absent, mode: "0644" }
        - { path: /var/log/wtmp, state: touch, mode: "0664" }
        - { path: /var/log/lastlog, state: touch, mode: "0644" }

    - name: Remove cloud-init data and logs
      file:
        state: absent
        path: "{{ item }}"
      loop:
        - /var/lib/cloud
        - /var/log/cloud-init.log
        - /var/log/cloud-init-output.log
        - /var/run/cloud-init

    - name: Truncate remaining log files in /var/log
      shell:
        cmd: find /var/log -type f -iname '*.log' -exec truncate -s 0 {} +

    - name: Remove rotated log archives
      shell:
        cmd: find /var/log -type f -name '*.gz' -delete

    - name: Find temporary files
      find:
        depth: 1
        file_type: any
        paths:
          - /tmp
          - /var/tmp
        pattern: "*"
      register: temp_files

    - name: Remove temporary files
      file:
        state: absent
        path: "{{ item.path }}"
      loop: "{{ temp_files.files }}"

    - name: Remove shell history files
      file:
        state: absent
        path: "{{ item.path }}"
      loop:
        - { path: /root/.bash_history }
        - { path: "/home/{{ ansible_env.SUDO_USER | default(ansible_user_id) }}/.bash_history" }
```

---

## Troubleshooting

### Common Issues

| Issue                                               | Possible Cause                                     | Solution                                                |
|-----------------------------------------------------|----------------------------------------------------|----------------------------------------------------------|
| `Error: failed to connect to supervisor cluster`    | Invalid or missing `kubeconfig`                    | Verify `KUBECONFIG` env var or set `kubeconfig_path`     |
| `Error: VM class not found`                         | Incorrect `class_name`                             | List available classes: `kubectl get vmclasses`          |
| `Error: storage class not found`                    | Incorrect `storage_class`                          | List available classes: `kubectl get storageclasses`     |
| `Timeout waiting for source VM`                     | VM creation taking too long                        | Increase `watch_source_timeout_sec`                      |
| `SSH connection refused`                            | Bootstrap data missing SSH configuration            | Provide valid `bootstrap_data_file` with SSH public key  |
| `Publishing failed`                                 | Content library not writable                        | Verify content library permissions and name              |

### Debug Mode

Run Packer with increased verbosity to diagnose issues:

```shell
PACKER_LOG=1 packer build config.pkr.hcl
```

For even more detail:

```shell
PACKER_LOG=1 PACKER_LOG_PATH=packer.log packer build config.pkr.hcl
```

---

## Additional Resources

- [Packer Plugin for VMware vSphere (GitHub)](https://github.com/vmware/packer-plugin-vsphere)
- [Examples Directory](https://github.com/vmware/packer-plugin-vsphere/tree/main/examples/)
- [VM-Operator API Documentation](https://vm-operator.readthedocs.io/en/latest/concepts/)
- [Deploying and Managing VMs in vSphere Supervisor](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/deploying-and-managing-virtual-machines-in-vsphere-iaas-control-plane.html)
- [Broadcom Product Lifecycle](https://support.broadcom.com/group/ecx/productlifecycle)
- [Packer HCL2 Documentation](https://developer.hashicorp.com/packer/docs/templates/hcl_templates)