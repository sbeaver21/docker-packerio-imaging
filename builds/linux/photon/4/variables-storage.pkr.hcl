# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

/*
    DESCRIPTION:
    VMware Photon OS 4 storage variables.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.

    NOTE: nothing consumes the variables declared here.
    linux-photon.pkr.hcl never reads vm_disk_device, vm_disk_partitions or
    vm_disk_lvm, and data/storage.pkrtpl.hcl - the only template that renders
    them - is not referenced by any template or provisioner. The guest
    partition layout for this build is defined in data/ks.pkrtpl.hcl. The one
    capacity lever is vm_disk_size, which is set in photon.auto.pkrvars.hcl.
*/

// VM Storage Settings

variable "vm_disk_device" {
  type        = string
  description = "The device for the virtual disk. (e.g. 'sda')"
}

variable "vm_disk_use_swap" {
  type        = bool
  description = "Whether to use a swap partition."
}

variable "vm_disk_partitions" {
  type = list(object({
    name = string
    size = number
    format = object({
      label  = string
      fstype = string
    })
    mount = object({
      path    = string
      options = string
    })
    volume_group = string
  }))
  description = "The disk partitions for the virtual disk."
}

variable "vm_disk_lvm" {
  type = list(object({
    name = string
    partitions = list(object({
      name = string
      size = number
      format = object({
        label  = string
        fstype = string
      })
      mount = object({
        path    = string
        options = string
      })
    }))
  }))
  description = "The LVM configuration for the virtual disk."
  default     = []
}
