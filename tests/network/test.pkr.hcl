# Each render is written by the `file` builder, not by a shell provisioner.
# The shell-local provisioner that used to write these ran the platform's shell,
# so on Windows (cmd.exe) every line of a quoted multi-line echo failed with
# "'network:' is not recognized as an internal or external command" and all
# twenty tests failed. The file builder writes the rendered string itself, so
# these tests no longer depend on the host's shell at all.

# The trailing newline is part of the contract: the golden files end with one,
# because the render used to be written by `echo`. The file builder writes its
# content byte for byte, so it has to be supplied here.
source "file" "autoinstall" {
  content = "${local.autoinstall}\n"
  target  = "${var.output_folder}/autoinstall"
}

source "file" "kickstart" {
  content = "${local.kickstart}\n"
  target  = "${var.output_folder}/kickstart"
}

source "file" "preseed" {
  content = "${local.preseed}\n"
  target  = "${var.output_folder}/preseed"
}

source "file" "photon" {
  content = "${local.photon}\n"
  target  = "${var.output_folder}/photon"
}

locals {
  autoinstall = templatefile("${abspath(path.root)}/templates/autoinstall.pkrtpl", {
    device  = var.vm_network_device,
    ip      = var.vm_ip_address,
    netmask = var.vm_ip_netmask,
    gateway = var.vm_ip_gateway,
    dns     = var.vm_dns_list,
  })
  kickstart = templatefile("${abspath(path.root)}/templates/kickstart.pkrtpl", {
    device  = var.vm_network_device,
    ip      = var.vm_ip_address,
    netmask = var.vm_ip_netmask,
    gateway = var.vm_ip_gateway,
    dns     = var.vm_dns_list,
  })
  preseed = templatefile("${abspath(path.root)}/templates/preseed.pkrtpl", {
    device  = var.vm_network_device,
    ip      = var.vm_ip_address,
    netmask = var.vm_ip_netmask,
    gateway = var.vm_ip_gateway,
    dns     = var.vm_dns_list,
  })
  photon = templatefile("${abspath(path.root)}/templates/photon.pkrtpl", {
    device  = var.vm_network_device,
    ip      = var.vm_ip_address,
    netmask = var.vm_ip_netmask,
    gateway = var.vm_ip_gateway,
    dns     = var.vm_dns_list,
  })
}

build {
  name    = "autoinstall"
  sources = ["source.file.autoinstall"]
}

build {
  name    = "kickstart"
  sources = ["source.file.kickstart"]
}

build {
  name    = "preseed"
  sources = ["source.file.preseed"]
}

build {
  name    = "photon"
  sources = ["source.file.photon"]
}
