# Each render is written by the `file` builder, not by a shell provisioner, so
# these tests do not depend on the host's shell. See tests/network/test.pkr.hcl.

# The trailing newline is part of the contract: the golden files end with one.
# See tests/network/test.pkr.hcl.
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

locals {
  autoinstall = templatefile("${abspath(path.root)}/templates/autoinstall.pkrtpl", {
    device     = var.vm_disk_device,
    swap       = var.vm_disk_use_swap,
    partitions = var.vm_disk_partitions,
    lvm        = var.vm_disk_lvm,
  })
  kickstart = templatefile("${abspath(path.root)}/templates/kickstart.pkrtpl", {
    device     = var.vm_disk_device,
    swap       = var.vm_disk_use_swap,
    partitions = var.vm_disk_partitions,
    lvm        = var.vm_disk_lvm,
  })
  preseed = templatefile("${abspath(path.root)}/templates/preseed.pkrtpl", {
    device     = var.vm_disk_device,
    swap       = var.vm_disk_use_swap,
    partitions = var.vm_disk_partitions,
    lvm        = var.vm_disk_lvm,
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
