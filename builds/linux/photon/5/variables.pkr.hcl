# Copyright 2023-2024 Broadcom. All rights reserved.
# SPDX-License-Identifier: BSD-2

/*
    DESCRIPTION:
    VMware Photon OS 5 input variables.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.
*/

//  BLOCK: variable
//  Defines the input variables.

// vSphere Credentials

variable "vsphere_endpoint" {
  type        = string
  description = "The fully qualified domain name or IP address of the vCenter Server instance."
}

variable "vsphere_username" {
  type        = string
  description = "The username to login to the vCenter Server instance."
  sensitive   = true
}

variable "vsphere_password" {
  type        = string
  description = "The password for the login to the vCenter Server instance."
  sensitive   = true
}

variable "vsphere_insecure_connection" {
  type        = bool
  description = "Do not validate vCenter Server TLS certificate."
}

// vSphere Settings

variable "vsphere_datacenter" {
  type        = string
  description = "The name of the target vSphere datacenter."
  default     = ""
}

variable "vsphere_cluster" {
  type        = string
  description = "The name of the target vSphere cluster."
  default     = ""
}

variable "vsphere_host" {
  type        = string
  description = "The name of the target ESXi host."
  default     = ""
}

variable "vsphere_datastore" {
  type        = string
  description = "The name of the target vSphere datastore."
}

variable "vsphere_network" {
  type        = string
  description = "The name of the target vSphere network segment."
}

variable "vsphere_folder" {
  type        = string
  description = "The name of the target vSphere folder."
  default     = ""
}

variable "vsphere_resource_pool" {
  type        = string
  description = "The name of the target vSphere resource pool."
  default     = ""
}

variable "vsphere_set_host_for_datastore_uploads" {
  type        = bool
  description = "Set this to true if packer should use the host for uploading files to the datastore."
  default     = false
}

// Virtual Machine Settings

variable "vm_guest_os_language" {
  type        = string
  description = "The guest operating system lanugage."
  default     = "en_US"
}

variable "vm_guest_os_keyboard" {
  type        = string
  description = "The guest operating system keyboard input."
  default     = "us"
}

variable "vm_guest_os_timezone" {
  type        = string
  description = "The guest operating system timezone."
  default     = "America/New_York"
}

variable "vm_guest_os_family" {
  type        = string
  description = "The guest operating system family. Used for naming and VMware Tools."
  default     = "linux"
}

variable "vm_guest_os_name" {
  type        = string
  description = "The guest operating system name. Used for naming."
}

variable "vm_guest_os_version" {
  type        = string
  description = "The guest operating system version. Used for naming."
}

variable "vm_guest_os_type" {
  type        = string
  description = "The guest operating system type, also know as guestid."
}

variable "vm_guest_os_cloudinit" {
  type        = bool
  description = "Enable cloud-init for the guest operating system."
  default     = false
}

variable "vm_firmware" {
  type        = string
  description = "The virtual machine firmware."
  default     = "efi-secure"
}

variable "vm_cdrom_type" {
  type        = string
  description = "The virtual machine CD-ROM type."
  default     = "sata"
}

variable "vm_cdrom_count" {
  type        = string
  description = "The number of virtual CD-ROMs remaining after the build."
  default     = 1
}

variable "vm_cpu_count" {
  type        = number
  description = "The number of virtual CPUs."
  default     = 2
}

variable "vm_cpu_cores" {
  type        = number
  description = "The number of virtual CPUs cores per socket."
  default     = 1
}

variable "vm_cpu_hot_add" {
  type        = bool
  description = "Enable hot add CPU."
  default     = false
}

variable "vm_mem_size" {
  type        = number
  description = "The size for the virtual memory in MB."
  default     = 2048
}

variable "vm_mem_hot_add" {
  type        = bool
  description = "Enable hot add memory."
  default     = false
}

variable "vm_disk_size" {
  type        = number
  description = "The size for the virtual disk in MB."
  default     = 40960
}

variable "vm_disk_controller_type" {
  type        = list(string)
  description = "The virtual disk controller types in sequence."
  default     = ["pvscsi"]
}

variable "vm_disk_thin_provisioned" {
  type        = bool
  description = "Thin provision the virtual disk."
  default     = true
}

variable "vm_network_card" {
  type        = string
  description = "The virtual network card type."
  default     = "vmxnet3"
}

variable "common_vm_version" {
  type        = number
  description = "The vSphere virtual hardware version."
}

variable "common_tools_upgrade_policy" {
  type        = bool
  description = "Upgrade VMware Tools on reboot."
  default     = true
}

variable "common_remove_cdrom" {
  type        = bool
  description = "Remove the virtual CD-ROM(s)."
  default     = true
}

// Template and Content Library Settings

variable "common_template_conversion" {
  type        = bool
  description = "Convert the virtual machine to template. Must be 'false' for content library."
  default     = false
}

variable "common_content_library_enabled" {
  type        = bool
  description = "Import the virtual machine into the vSphere content library."
  default     = true
}

variable "common_content_library" {
  type        = string
  description = "The name of the target vSphere content library, if enabled."
  default     = null
}

variable "common_content_library_ovf" {
  type        = bool
  description = "Export to content library as an OVF template."
  default     = true
}

variable "common_content_library_destroy" {
  type        = bool
  description = "Delete the virtual machine after exporting to the content library."
  default     = true
}

variable "common_content_library_skip_export" {
  type        = bool
  description = "Skip exporting the virtual machine to the content library. Option allows for testing/debugging without saving the machine image."
  default     = false
}

// OVF Export Settings

variable "common_ovf_export_enabled" {
  type        = bool
  description = "Enable OVF artifact export."
  default     = false
}

variable "common_ovf_export_overwrite" {
  type        = bool
  description = "Overwrite existing OVF artifact."
  default     = true
}

// Removable Media Settings

variable "common_iso_content_library_enabled" {
  type        = bool
  description = "Import the guest operating system ISO into the vSphere content library."
  default     = false
}

variable "common_iso_content_library" {
  type        = string
  description = "The name of the target vSphere content library for the guest operating system ISO."
}

variable "common_iso_datastore" {
  type        = string
  description = "The name of the target vSphere datastore for the guest operating system ISO."
}

variable "iso_datastore_path" {
  type        = string
  description = "The path on the source vSphere datastore for the guest operating system ISO."
}

variable "iso_file" {
  type        = string
  description = "The file name of the guest operating system ISO."
}

variable "iso_content_library_item" {
  type        = string
  description = "The vSphere content library item name for the guest operating system ISO."
}

// Boot Settings

variable "common_data_source" {
  type        = string
  description = "The provisioning data source. One of `http` or `disk`."
  default     = "disk"
}

variable "common_http_ip" {
  type        = string
  description = "Define an IP address on the host to use for the HTTP server."
  default     = null
}

variable "common_http_port_min" {
  type        = number
  description = "The start of the HTTP port range."
}

variable "common_http_port_max" {
  type        = number
  description = "The end of the HTTP port range."
}

variable "vm_boot_order" {
  type        = string
  description = "The boot order for virtual machines devices."
  default     = "disk,cdrom"
}

variable "vm_boot_wait" {
  type        = string
  description = "The time to wait before boot."
  default     = "5s"
}

variable "common_ip_wait_timeout" {
  type        = string
  description = "Time to wait for guest operating system IP address response."
}

variable "common_ip_settle_timeout" {
  type        = string
  description = "Time to wait for guest operating system IP to settle down."
  default     = "5s"
}

variable "common_shutdown_timeout" {
  type        = string
  description = "Time to wait for guest operating system shutdown."
}

// Communicator Settings and Credentials

variable "root_password_encrypted" {
  type        = string
  description = "The SHA-512 encrypted password to login to the guest operating system."
  sensitive   = true
}

variable "build_username" {
  type        = string
  description = "The username to login to the guest operating system."
  sensitive   = true
}

variable "build_password" {
  type        = string
  description = "The password to login to the guest operating system."
  sensitive   = true
}

variable "build_password_encrypted" {
  type        = string
  description = "The SHA-512 encrypted password to login to the guest operating system."
  sensitive   = true
}

variable "build_key" {
  type        = string
  description = "The public key to login to the guest operating system."
  sensitive   = true
}





variable "auto_username" {
  type        = string
  description = "The username to login to the guest operating system."
  sensitive   = true
}

variable "auto_password" {
  type        = string
  description = "The password to login to the guest operating system."
  sensitive   = true
}

variable "auto_password_encrypted" {
  type        = string
  description = "The encrypted password to login the guest operating system."
  sensitive   = true
}

variable "auto_key" {
  type        = string
  description = "The public key to login to the guest operating system."
  sensitive   = true
}

variable "communicator_proxy_host" {
  type        = string
  description = "The proxy server to use for SSH connection. (Optional)"
  default     = null
}

variable "communicator_proxy_port" {
  type        = number
  description = "The port to connect to the proxy server. (Optional)"
  default     = null
}

variable "communicator_proxy_username" {
  type        = string
  description = "The username to authenticate with the proxy server. (Optional)"
  default     = null
}

variable "communicator_proxy_password" {
  type        = string
  description = "The password to authenticate with the proxy server. (Optional)"
  sensitive   = true
  default     = null
}

variable "communicator_port" {
  type        = number
  description = "The port for the communicator protocol."
  default     = 22
}

variable "communicator_timeout" {
  type        = string
  description = "The timeout for the communicator protocol."
  default     = "30m"
}

// Ansible Credentials

variable "ansible_username" {
  type        = string
  description = "The username for Ansible to login to the guest operating system."
  sensitive   = true
  default     = "buildops"
}

variable "ansible_key" {
  type        = string
  description = "The public key for Ansible to login to the guest operating system."
  sensitive   = true
  default     = "password"
}

// HCP Packer Settings

variable "common_hcp_packer_registry_enabled" {
  type        = bool
  description = "Enable the HCP Packer registry."
  default     = false
}

// Additional Settings

variable "additional_packages" {
  type        = list(string)
  description = "Additional packages to install."
  default     = []
}

// Photon Settings

/*
    DESCRIPTION:
    VMware Photon OS template.
*/

variable "os_vendor" {
  type    = string
  default = "VMware"
}

variable "os_distro" {
  type    = string
  default = "Photon"
}

variable "os_version" {
  type = string
}

variable "os_release" {
  type = string
}

variable "os_display_name" {
  type    = string
  default = null
}

variable "os_packagelist" {
  type        = string
  description = "The VMware Photon OS installation package."
  default     = "minimal"
  validation {
    condition     = contains(["minimal", "developer"], var.os_packagelist)
    error_message = "Must be one of 'minimal' or 'developer'."
  }
}

variable "vm_name" {
  type    = string
  default = "photon"
}

variable "iso_url" {
  type = string
}

variable "iso_checksum_type" {
  type    = string
  default = "sha1"
  validation {
    condition     = contains(["sha1", "md5"], var.iso_checksum_type)
    error_message = "Must be one of 'sha1' or 'md5'."
  }
}

variable "iso_checksum_value" {
  type = string
}

variable "guest_additions_path" {
  type    = string
  default = "/root/VBoxGuestAdditions.iso"
}

variable "guest_additions_url" {
  type = string
}

variable "guest_additions_checksum" {
  type = string
}

variable "boot_wait" {
  type    = string
  default = "3s"
}

variable "boot_key_interval" {
  type    = string
  default = "10ms"
}

variable "boot_command" {
  type = list(string)
  default = [
    "<esc><wait>",
    "vmlinuz initrd=initrd.img root=/dev/ram0 loglevel=3 ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.json insecure_installation=1 photon.media=cdrom",
    "<enter>"
  ]
}

variable "ssh_timeout" {
  type    = string
  default = "15m"
}

variable "ssh_username" {
  type    = string
  default = "root"
}

variable "ssh_password" {
  type      = string
  default   = "VMw@re123!"
  sensitive = true
}

variable "vagrant_username" {
  type    = string
  default = "vagrant"
}

variable "vagrant_password" {
  type      = string
  default   = "VMw@re123!"
  sensitive = true
}

variable "vagrant_key" {
  type      = string
  default   = "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key"
  sensitive = true
}

variable "headless" {
  type    = bool
  default = false
}

variable "hardware_version_vmw" {
  type    = number
  default = 18
  validation {
    condition = (
      var.hardware_version_vmw >= 11 &&
      var.hardware_version_vmw <= 18
    )
    error_message = "Must be between 11 and 18."
  }
}

variable "guest_os_vmw" {
  type    = string
  default = "vmware-photon-64"
}

variable "guest_os_vbx" {
  type    = string
  default = "Linux_64"
}

variable "cpu_count" {
  type    = number
  default = 2
}

variable "memory_size" {
  type    = number
  default = 1024
}

variable "disk_adapter_vmw" {
  type    = string
  default = "pvscsi"
}

variable "disk_adapter_vbx" {
  type    = string
  default = "scsi"
}

variable "disk_type_vmw" {
  type    = number
  default = 0
  validation {
    condition = (
      var.disk_type_vmw >= 0 &&
      var.disk_type_vmw <= 5
    )
    error_message = "Must be between 0 and 5."
  }
}

variable "disk_size" {
  type    = number
  default = 20480
}

variable "gfx_controller_vbx" {
  type    = string
  default = "vboxsvga"
}

variable "gfx_memory_vbx" {
  type    = string
  default = "128"
}

variable "network_adapter_vmw" {
  type    = string
  default = "vmxnet3"
}

variable "network_vmw" {
  type    = string
  default = "nat"
  validation {
    condition     = contains(["nat", "bridged", "hostonly"], var.network_vmw)
    error_message = "Must be one of 'nat', 'bridged', or 'hostonly'."
  }
}

variable "vsphere_guest_os_type" {
  type    = string
  default = null
}
