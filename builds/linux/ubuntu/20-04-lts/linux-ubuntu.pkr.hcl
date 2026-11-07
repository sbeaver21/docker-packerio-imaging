# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

# ----------------------------------------------------------------------------
# Name:         linux-ubuntu.pkr.hcl
# Description:  Build definition for Ubuntu Server 20.04 LTS
# Author:       Stephen Beaver
# ----------------------------------------------------------------------------

/*
    DESCRIPTION:
    Ubuntu Server 20.04 LTS build definition.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.
*/

//  BLOCK: packer
//  The Packer configuration.

# -------------------------------------------------------------------------- #
#                           Packer Configuration                             #
# -------------------------------------------------------------------------- #

packer {
  required_version = ">= 1.15.0"
  required_plugins {
    vsphere = {
      version = ">= 2.1.2"
      source  = "github.com/vmware/vsphere"
    }
    git = {
      version = ">= 0.6.5"
      source  = "github.com/ethanmdavidson/git"
    }
  }
}


//  BLOCK: data
//  Defines the data sources.

// data "git-repository" "cwd" {}

//  BLOCK: locals
//  Defines the local variables.

# -------------------------------------------------------------------------- #
#                              Local Variables                               #
# -------------------------------------------------------------------------- #

locals {
  build_by            = "Built by: HashiCorp Packer ${packer.version}"
  build_create        = "Created by: Image Automation"
  build_datetime      = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  build_date          = formatdate("YYYY-MM-DD", timestamp())
  build_time          = formatdate("hh:mm ZZZ", timestamp())
  build_version       = "packer"
  build_description   = "${local.build_create}\nImaged on: ${local.build_date}\nImage Time: ${local.build_time}\nImage Version: ${local.build_datetime}\n${local.build_by}"
  vm_ip_address       = "192.0.2.75"
  vm_ip_netmask       = "24"
  vm_ip_gateway       = "192.0.2.1"
  vm_dns_list         = ["192.0.2.53", "192.0.2.54"]
  vm_guest_os_version = "20.04"
  iso_paths = {
    content_library = "${var.common_iso_content_library}/${var.iso_content_library_item}/${var.iso_file}",
    datastore       = "[${var.common_iso_datastore}] ${var.iso_datastore_path}/${var.iso_file}"
  }
  manifest_date   = formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())
  manifest_path   = "${path.cwd}/manifests/"
  manifest_output = "${local.manifest_path}${local.manifest_date}-${local.vm_name}.json"
  ovf_export_path = "${path.cwd}/artifacts/${local.vm_name}"
  data_source_content = {
    "/meta-data" = file("${abspath(path.root)}/data/meta-data")
    "/user-data" = templatefile("${abspath(path.root)}/data/user-data.pkrtpl.hcl", {
      build_username           = var.build_username
      build_password           = var.build_password
      build_password_encrypted = var.build_password_encrypted
      auto_username            = var.auto_username
      auto_password            = var.auto_password
      auto_password_encrypted  = var.auto_password_encrypted
      vm_guest_os_language     = var.vm_guest_os_language
      vm_guest_os_keyboard     = var.vm_guest_os_keyboard
      vm_guest_os_timezone     = var.vm_guest_os_timezone
      network = templatefile("${abspath(path.root)}/data/network.pkrtpl.hcl", {
        name    = local.vm_name
        ip      = local.vm_ip_address
        netmask = local.vm_ip_netmask
        gateway = local.vm_ip_gateway
        dns     = local.vm_dns_list
      })
      storage = templatefile("${abspath(path.root)}/data/storage.pkrtpl.hcl", {
        device     = var.vm_disk_device
        swap       = var.vm_disk_use_swap
        partitions = var.vm_disk_partitions
        lvm        = var.vm_disk_lvm
      })
      additional_packages = var.additional_packages
    })
  }
  data_source_command = var.common_data_source == "http" ? "ds=\"nocloud-net;seedfrom=http://{{.HTTPIP}}:{{.HTTPPort}}/\"" : "ds=\"nocloud\""
  vm_name             = "${var.vm_guest_os_family}-${var.vm_guest_os_name}-${local.vm_guest_os_version}-${local.build_version}"
  bucket_name         = replace("${var.vm_guest_os_family}-${var.vm_guest_os_name}-${var.vm_guest_os_version}", ".", "")
  bucket_description  = "${var.vm_guest_os_family} ${var.vm_guest_os_name} ${var.vm_guest_os_version}"
}

//  BLOCK: source
//  Defines the builder configuration blocks.

# -------------------------------------------------------------------------- #
#                       Template Source Definitions                          #
# -------------------------------------------------------------------------- #

source "vsphere-iso" "linux-ubuntu-20-4" {

  // vCenter Server Endpoint Settings and Credentials
  vcenter_server      = var.vsphere_endpoint
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  // vSphere Settings
  datacenter                     = var.vsphere_datacenter
  cluster                        = var.vsphere_cluster
  host                           = var.vsphere_host
  datastore                      = var.vsphere_datastore
  folder                         = var.vsphere_folder
  resource_pool                  = var.vsphere_resource_pool
  set_host_for_datastore_uploads = var.vsphere_set_host_for_datastore_uploads
  remote_cache_path              = "packer_cache_v2"

  // Virtual Machine Settings
  vm_name              = local.vm_name
  guest_os_type        = var.vm_guest_os_type
  firmware             = var.vm_firmware
  CPUs                 = var.vm_cpu_count
  cpu_cores            = var.vm_cpu_cores
  CPU_hot_plug         = var.vm_cpu_hot_add
  RAM                  = var.vm_mem_size
  RAM_hot_plug         = var.vm_mem_hot_add
  cdrom_type           = var.vm_cdrom_type
  disk_controller_type = var.vm_disk_controller_type
  storage {
    disk_size             = var.vm_disk_size
    disk_thin_provisioned = var.vm_disk_thin_provisioned
  }
  network_adapters {
    network      = var.vsphere_network
    network_card = var.vm_network_card
  }
  vm_version           = var.common_vm_version
  remove_cdrom         = var.common_remove_cdrom
  reattach_cdroms      = var.vm_cdrom_count
  tools_upgrade_policy = var.common_tools_upgrade_policy
  notes                = local.build_description

  // Removable Media Settings
  iso_paths    = var.common_iso_content_library_enabled ? [local.iso_paths.content_library] : [local.iso_paths.datastore]
  http_content = var.common_data_source == "http" ? local.data_source_content : null
  cd_content   = var.common_data_source == "disk" ? local.data_source_content : null
  cd_label     = var.common_data_source == "disk" ? "cidata" : null

  // Boot and Provisioning Settings
  http_ip       = var.common_data_source == "http" ? var.common_http_ip : null
  http_port_min = var.common_data_source == "http" ? var.common_http_port_min : null
  http_port_max = var.common_data_source == "http" ? var.common_http_port_max : null
  boot_order    = var.vm_boot_order
  boot_wait     = var.vm_boot_wait
  boot_command = [
    // This waits for 3 seconds, sends the "c" key, and then waits for another 3 seconds. In the GRUB boot loader, this is used to enter command line mode.
    "<esc><wait>",
    // This types a command to load the Linux kernel from the specified path with the 'autoinstall' option and the value of the 'data_source_command' local variable.
    // The 'autoinstall' option is used to automate the installation process.
    // The 'data_source_command' local variable is used to specify the kickstart data source configured in the common variables.
    "linux /casper/vmlinuz --- autoinstall ${local.data_source_command}",
    // This sends the "enter" key and then waits. This is typically used to execute the command and give the system time to process it.
    "<enter><wait>",
    // This types a command to load the initial RAM disk from the specified path.
    "initrd /casper/initrd",
    // This sends the "enter" key and then waits. This is typically used to execute the command and give the system time to process it.
    "<enter><wait>",
    // This types the "boot" command. This starts the boot process using the loaded kernel and initial RAM disk.
    "boot",
    // This sends the "enter" key. This is typically used to execute the command.
    "<enter>"
  ]
  ip_wait_timeout   = var.common_ip_wait_timeout
  ip_settle_timeout = var.common_ip_settle_timeout
  shutdown_command  = "echo '${var.build_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout  = var.common_shutdown_timeout

  // Communicator Settings and Credentials
  communicator       = "ssh"
  ssh_proxy_host     = var.communicator_proxy_host
  ssh_proxy_port     = var.communicator_proxy_port
  ssh_proxy_username = var.communicator_proxy_username
  ssh_proxy_password = var.communicator_proxy_password
  ssh_username       = var.build_username
  ssh_password       = var.build_password
  ssh_port           = var.communicator_port
  ssh_timeout        = var.communicator_timeout

  // Template and Content Library Settings
  convert_to_template = var.common_template_conversion
  dynamic "content_library_destination" {
    for_each = var.common_content_library_enabled ? [1] : []
    content {
      library     = var.common_content_library
      description = local.build_description
      ovf         = var.common_content_library_ovf
      destroy     = var.common_content_library_destroy
      skip_import = var.common_content_library_skip_export
    }
  }

  // OVF Export Settings
  # directory_permission is set explicitly even though 0750 is the plugin's own
  # default. On a Windows build host the plugin never defaults the value and
  # then dereferences it while preparing the exporter, so `packer validate`
  # dies with "unexpected EOF" and a nil-pointer panic in the plugin instead of
  # reporting a real diagnostic. Setting it keeps the definition validatable
  # from any host, and changes nothing on a Linux host.
  dynamic "export" {
    for_each = var.common_ovf_export_enabled ? [1] : []
    content {
      name                 = local.vm_name
      force                = var.common_ovf_export_overwrite
      directory_permission = "0750"
      options = [
        "extraconfig"
      ]
      output_directory = local.ovf_export_path
    }
  }
}

//  BLOCK: build
//  Defines the builders to run, provisioners, and post-processors.

# -------------------------------------------------------------------------- #
#                             Build Management                               #
# -------------------------------------------------------------------------- #

build {
  sources = ["source.vsphere-iso.linux-ubuntu-20-4"]

  provisioner "shell" {
    # bash, not sh: apt.sh and finalupdate.sh use arrays, [[ ]], set -o pipefail
    # and an ERR trap, none of which exist in dash - and /bin/sh on Ubuntu is
    # dash. The RHEL templates have always had bash here because /bin/sh is
    # bash there; cleanup.sh is POSIX and runs either way.
    execute_command = "{{.Vars}} sudo -S -E bash -eux '{{.Path}}'"
    # One copy of each script, shared by every project that runs it, in
    # scripts/linux/ubuntu/ at the repository root. Four levels up from this
    # project directory is that root: ubuntu/<version> -> ubuntu -> linux ->
    # builds -> root. abspath keeps the resolved path absolute, so the
    # definition finds the same files whether packer is run from the repository
    # root or from the project directory - which a path.cwd-relative reference
    # did not.
    scripts = [
      "${abspath(path.root)}/../../../../scripts/linux/ubuntu/apt.sh",
      "${abspath(path.root)}/../../../../scripts/linux/ubuntu/finalupdate.sh",
      "${abspath(path.root)}/../../../../scripts/linux/ubuntu/netreset.sh"
    ]
  }

  post-processor "manifest" {
    output     = local.manifest_output
    strip_path = true
    strip_time = true
    custom_data = {
      build_username           = var.build_username
      build_date               = local.build_date
      build_version            = local.build_version
      common_data_source       = var.common_data_source
      common_vm_version        = var.common_vm_version
      vm_cpu_cores             = var.vm_cpu_cores
      vm_cpu_count             = var.vm_cpu_count
      vm_disk_size             = var.vm_disk_size
      vm_disk_thin_provisioned = var.vm_disk_thin_provisioned
      vm_firmware              = var.vm_firmware
      vm_guest_os_type         = var.vm_guest_os_type
      vm_mem_size              = var.vm_mem_size
      vm_network_card          = var.vm_network_card
      vsphere_cluster          = var.vsphere_cluster
      vsphere_datacenter       = var.vsphere_datacenter
      vsphere_datastore        = var.vsphere_datastore
      vsphere_endpoint         = var.vsphere_endpoint
    }
  }

  dynamic "hcp_packer_registry" {
    for_each = var.common_hcp_packer_registry_enabled ? [1] : []
    content {
      bucket_name = local.bucket_name
      description = local.bucket_description
      bucket_labels = {
        "os_family" : var.vm_guest_os_family,
        "os_name" : var.vm_guest_os_name,
        "os_version" : var.vm_guest_os_version,
      }
      build_labels = {
        "build_version" : local.build_version,
        "packer_version" : packer.version,
      }
    }
  }
}
