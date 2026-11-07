# © Broadcom. All Rights Reserved.
# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

/*
    DESCRIPTION:
    VMware Photon OS 4 build definition.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.
*/

//  BLOCK: packer
//  The Packer configuration.

packer {
  required_version = ">= 1.15.0"
  required_plugins {
    vsphere = {
      source  = "github.com/vmware/vsphere"
      version = ">= 2.1.1"
    }
    git = {
      source  = "github.com/ethanmdavidson/git"
      version = ">= 0.6.5"
    }
  }
}

//  BLOCK: data
//  Defines the data sources.

// data "git-repository" "cwd" {}

//  BLOCK: locals
//  Defines the local variables.

locals {
  build_by            = "Built by: HashiCorp Packer ${packer.version}"
  build_create        = "Created by: Image Automation"
  build_datetime      = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  build_date          = formatdate("YYYY-MM-DD", timestamp())
  build_time          = formatdate("hh:mm ZZZ", timestamp())
  build_version       = "packer"
  build_description   = "${local.build_create}\nImaged on: ${local.build_date}\nImage Time: ${local.build_time}\nImage Version: ${local.build_datetime}\n${local.build_by}"
  vm_name             = "${var.vm_guest_os_family}-${var.vm_guest_os_name}-${var.vm_guest_os_version}-${local.build_version}"
  vm_ip_address       = "192.0.2.74"
  vm_ip_netmask       = "24"
  vm_ip_gateway       = "192.0.2.1"
  vm_dns_list         = ["192.0.2.53", "192.0.2.54"]
  vm_network_device   = "eth0"
  vm_guest_os_version = "4"
  iso_paths = {
    //content_library = "${var.common_iso_content_library}/${var.iso_content_library_item}/${var.iso_file}",
    content_library = "${var.common_iso_content_library}/${var.iso_content_library_item}",
    datastore       = "[${var.common_iso_datastore}] ${var.iso_datastore_path}/${var.iso_file}"
  }
  manifest_date   = formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())
  manifest_path   = "${path.cwd}/manifests/"
  manifest_output = "${local.manifest_path}${local.manifest_date}.json"
  ovf_export_path = "${path.cwd}/artifacts/"
  //ovf_export_path = "${path.cwd}/artifacts/${local.vm_name}"
  data_source_content = {
    "/ks.json" = templatefile("${abspath(path.root)}/data/ks.pkrtpl.hcl", {
      vm_hostname              = local.vm_name
      build_username           = var.build_username
      build_password           = var.build_password
      build_password_encrypted = var.build_password_encrypted
      root_password_encrypted  = var.build_password_encrypted
      vm_guest_os_cloudinit    = var.vm_guest_os_cloudinit
      device                   = local.vm_network_device
      ip                       = local.vm_ip_address
      netmask                  = local.vm_ip_netmask
      gateway                  = local.vm_ip_gateway
      dns                      = local.vm_dns_list
      // Renders the installer's "network" object.
      //
      // The DNS key is "nameserver" - not "dns". Photon OS 4.0's installer
      // reads that name, and when it is absent the installer aborts after the
      // packages are installed with "Failed to setup network!": it never writes
      // the static address, the guest never comes up on the network and Packer
      // sits at "Waiting for IP" until ip_wait_timeout expires. (Photon OS 5.0's
      // installer is the one that expects "dns"; the key is not interchangeable
      // between the two builds.)
      network = templatefile("${abspath(path.root)}/data/network.pkrtpl.hcl", {
        device  = local.vm_network_device
        ip      = local.vm_ip_address
        netmask = local.vm_ip_netmask
        gateway = local.vm_ip_gateway
        dns     = local.vm_dns_list
      })
      additional_packages = var.additional_packages
    })
  }
  data_source_command = var.common_data_source == "http" ? "ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.json" : "ks=/dev/fd0:/ks.json"
  bucket_name         = replace("${var.vm_guest_os_family}-${var.vm_guest_os_name}-${var.vm_guest_os_version}", ".", "")
  bucket_description  = "${var.vm_guest_os_family} ${var.vm_guest_os_name} ${var.vm_guest_os_version}"
}

//  BLOCK: source
//  Defines the builder configuration blocks.

source "vsphere-iso" "linux-photon" {

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
  iso_paths      = var.common_iso_content_library_enabled ? [local.iso_paths.content_library] : [local.iso_paths.datastore]
  http_content   = var.common_data_source == "http" ? local.data_source_content : null
  cd_content     = var.common_data_source == "disk" ? local.data_source_content : null
  floppy_content = var.common_data_source == "disk" ? { "/ks.json" = local.data_source_content["/ks.json"] } : null

  // Boot and Provisioning Settings
  http_ip       = var.common_http_ip
  http_port_min = var.common_http_port_min
  http_port_max = var.common_http_port_max
  boot_order    = var.vm_boot_order
  boot_wait     = var.vm_boot_wait
  boot_command = [
    "<wait><wait><leftCtrlOn><leftAltOn><delOn><delOff><leftAltOff><leftCtrlOff>",
    // This sends the "escape" key, waits, and then sends the "c" key. In the GRUB boot loader, this is used to enter command line mode.
    "<esc><wait>c",
    // This types a command to load the Linux kernel from the specified path, with the specified boot parameters.
    // The 'data_source_command' local variable is used to specify the kickstart data source configured in the common variables.
    "linux /isolinux/vmlinuz root=/dev/ram0 loglevel=3 insecure_installation=1 ${local.data_source_command} photon.media=cdrom",
    // This sends the "enter" key, which executes the command.
    "<enter>",
    // This types a command to load the initial RAM disk from the specified path.
    "initrd /isolinux/initrd.img",
    // This sends the "enter" key, which executes the command.
    "<enter>",
    // This types the "boot" command, which starts the boot process using the loaded kernel and initial RAM disk.
    "boot",
    // This sends the "enter" key, which executes the command.
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
  dynamic "export" {
    for_each = var.common_ovf_export_enabled ? [1] : []
    content {
      name  = local.vm_name
      force = var.common_ovf_export_overwrite
      options = [
        "extraconfig"
      ]
      output_directory = local.ovf_export_path
    }
  }
}

//  BLOCK: build
//  Defines the builders to run, provisioners, and post-processors.

build {
  sources = ["source.vsphere-iso.linux-photon"]

  // Provisioners
  // ---------------------------------------------------------------------------
  // Update and patch the guest, and keep it last.
  //
  // This is the only provisioner in this build, and the position is the point:
  // a provisioner that installed a package after this one would leave that
  // package unpatched, and the script refuses to finish unless
  // `tdnf check-update` reports nothing pending in its strictness mode, so a
  // build that cannot reach the Photon repositories fails instead of sealing an
  // unpatched template.
  //
  // The script is bash, not sh: Photon's /bin/sh is a busybox-derived ash,
  // which has no arrays, no [[ ]] and no ERR trap, all of which
  // update-packages.sh uses.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -S -E bash -eux '{{.Path}}'"
    # One shared copy of the script, at the repository root, used by every
    # project that runs it. Four levels up from this project directory is that
    # root: photon/4 -> photon -> linux -> builds -> root. abspath keeps the
    # resolved path absolute, so the definition finds the same file whether
    # packer is run from the repository root or from the project directory.
    scripts = ["${abspath(path.root)}/../../../../scripts/linux/photon/system/update-packages.sh"]
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
      vsphere_host             = var.vsphere_host
      vsphere_datacenter       = var.vsphere_datacenter
      vsphere_datastore        = var.vsphere_datastore
      vsphere_endpoint         = var.vsphere_endpoint
      vsphere_folder           = var.vsphere_folder
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
