<img src="assets/images/icon-color.svg" alt="VMware vSphere" width="150">

# Packer image builds for VMware vSphere

This repository turns a guest operating system ISO into a ready-to-deploy
vSphere template. Packer boots a virtual machine with the `vsphere-iso` builder,
the guest installs itself unattended, provisioning scripts and Ansible roles
configure and harden the result, and the finished image is published to a
vSphere Content Library as an OVF template.

Every build runs the same four stages:

1. **Boot.** A virtual machine starts from the ISO with the `vsphere-iso`
   builder.
2. **Install.** The guest installs itself from a kickstart, preseed, autoinstall
   or `Autounattend.xml` answer file.
3. **Provision.** Shell scripts, PowerShell and Ansible roles configure and
   harden the result.
4. **Publish.** The image is exported to the content library, and a manifest
   recording exactly what was built is written to `manifests/`.

All build definitions are written in the HashiCorp Configuration Language
("HCL"), and every input variable is declared with its type.

## :material-linux: Linux Distributions

| Distribution | Versions | Unattended install | Post-install |
| :--- | :--- | :--- | :--- |
| :simple-almalinux: AlmaLinux OS | 8, 9 | Kickstart | Ansible |
| :simple-centos: CentOS Stream | 9 | Kickstart | Ansible |
| :simple-debian: Debian | 11, 12 | Preseed | Ansible |
| :simple-fedora: Fedora Server | 40 | Kickstart | Ansible |
| :material-linux: Oracle Linux | 8, 9 | Kickstart | Ansible |
| :fontawesome-brands-redhat: Red Hat Enterprise | 9.6, 10.0 | Kickstart | Shell |
| :simple-rockylinux: Rocky Linux | 8, 9 | Kickstart | Ansible |
| :simple-suse: SUSE Linux Enterprise | 15 | AutoYaST | Ansible |
| :simple-ubuntu: Ubuntu Server | 20.04, 22.04, 24.04, 26.04 | Autoinstall | Shell |
| :simple-vmware: VMware Photon OS | 4, 5 | Kickstart | Shell |

## :fontawesome-brands-windows: Microsoft Windows

| Product | Versions | Editions and experiences |
| :--- | :--- | :--- |
| :fontawesome-brands-windows: Windows Server | 2022, 2025 | Standard, Datacenter, each Core or Desktop Experience |
| :fontawesome-brands-windows: Windows | 10, 11 | Professional, Enterprise |

## Where to go next

| Page | Covers |
| :--- | :--- |
| [Get the project](getting-started/get-project.md) | Getting the source and the project structure |
| [Requirements](getting-started/requirements.md) | Toolchain and target platform |
| [Privileges](getting-started/privileges.md) | The least-privilege vSphere role |
| [Deploy the vSphere role](operations/terraform-role-deploy.md) | Creating that role with Terraform and assigning it, step by step |
| [Validation](operations/validation.md) | What has been checked, and what has not |
| [Configure](getting-started/configure.md) | Every input variable a build takes |
| [Build](getting-started/build.md) | Running a build |
| [Architecture](architecture/overview.md) | How the pipeline fits together |

## Provenance

Distributed under BSD 2-Clause. Portions are derived from the Broadcom
[packer-examples-for-vsphere][upstream] sample project. See the
[License](license.md) page for the full attribution.

[upstream]: https://github.com/vmware-samples/packer-examples-for-vsphere
