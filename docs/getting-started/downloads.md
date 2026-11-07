---
icon: octicons/download-16
---

# Guest Operating Systems

There is no download script. Each build takes an ISO you have already placed in
a vSphere datastore or a content library, and names it with three variables.

## Where the ISOs come from

| Distribution | Publisher |
| :--- | :--- |
| :simple-almalinux: AlmaLinux OS | [almalinux.org](https://almalinux.org/get-almalinux/) |
| :simple-centos: CentOS Stream | [centos.org](https://www.centos.org/download/) |
| :simple-debian: Debian | [debian.org](https://www.debian.org/download) |
| :simple-fedora: Fedora Server | [fedoraproject.org](https://fedoraproject.org/server/download/) |
| :material-linux: Oracle Linux | [oracle.com](https://yum.oracle.com/oracle-linux-isos.html) |
| :fontawesome-brands-redhat: Red Hat Enterprise Linux | Red Hat customer portal |
| :simple-rockylinux: Rocky Linux | [rockylinux.org](https://rockylinux.org/download) |
| :simple-suse: SUSE Linux Enterprise | SUSE customer centre |
| :simple-ubuntu: Ubuntu Server | [ubuntu.com](https://ubuntu.com/download/server) |
| :simple-vmware: VMware Photon OS | [vmware.com](https://github.com/vmware/photon/wiki/Downloading-Photon-OS) |
| :fontawesome-brands-windows: Windows Server, Windows | Microsoft Evaluation Center, or a volume licence portal |

Verify the checksum the publisher publishes before you upload it. An ISO that
is truncated by a partial download produces a build that fails in the guest,
not in Packer, and the failure is hard to read.

## Point the build at the ISO

Every build project declares the variables below in its `variables.pkr.hcl`;
set them in the project's `*.auto.pkrvars.hcl`.

### From a datastore

```hcl
common_iso_datastore               = "example-datastore"
common_iso_content_library_enabled = false
iso_datastore_path                 = "iso/linux/ubuntu"
iso_file                           = "ubuntu-24.04-live-server-amd64.iso"
```

`iso_datastore_path` is the directory on the datastore, without a leading or
trailing slash, and `iso_file` is the file name inside it.

### From a content library

```hcl
common_iso_datastore               = ""
common_iso_content_library_enabled = true
common_iso_content_library         = "example-iso-library"
iso_content_library_item           = "ubuntu-24.04-live-server-amd64"
```

`iso_content_library_item` is the **item** name in the library, not a path and
not a file name.

## Where the build reads it

With `common_data_source = "http"` Packer serves the answer file over its own
HTTP server and attaches the ISO from the location above. With
`common_data_source = "disk"` the answer file is delivered on a secondary
CD-ROM or floppy image instead. Both are set per project, and a build that takes
the wrong one for its distribution fails after the ISO has already booted.

## Windows: the scripts CD

The Windows Server builds deliver their helper scripts on a second CD-ROM built
at build time by `scripts/bootstrap/prepare-windows-iso.sh`. If the guest cannot
read that volume, VMware Tools never installs and the build waits for an IP
address forever. The diagnosis and the drive-letter contract are in
[Windows Builds](../operations/windows-builds.md).
