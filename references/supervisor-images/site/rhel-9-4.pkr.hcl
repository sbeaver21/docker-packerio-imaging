# A Packer template to deploy a Red Hat Enterprise Linux 9.4 VM using the vsphere-supervisor builder.
# Supports ISO import (from a URL-accessible image) pattern for the RHEL 9.4 boot ISO.
#
# ISO file (from project iso/ directory):
#   rhel-9.4-x86_64-dvd.iso
#
# Prerequisites:
#   - The RHEL 9.4 ISO must be accessible via HTTPS/HTTP URL from the
#     vSphere Supervisor cluster.
#   - For local testing, use the included helper scripts to serve the project ISO:
#
#     Windows (PowerShell):
#       powershell -ExecutionPolicy Bypass -File scripts/serve-iso.ps1
#
#     Linux/macOS (Bash):
#       ./scripts/serve-iso.sh
#
#     These scripts start a temporary HTTP server serving the ISOs from
#     the project's iso/ directory and display example import_source_url values.
#   - A cloud-init bootstrap data file (default: ./cloud-init-rhel-9.yml) should
#     be provided to automate initial setup.
#
# Quick start (using project's local ISO server):
#   # Terminal 1: Start the ISO file server
#   powershell -ExecutionPolicy Bypass -File scripts/serve-iso.ps1
#
#   # Terminal 2: Run Packer (automatically uses the local server)
#   packer build \
#     -var="use_local_iso_server=true" \
#     -var="local_iso_server_host=<SERVER_IP>" \
#     -var="class_name=best-effort-xsmall" \
#     -var="storage_class=m01-cl01-optimal-datastore-default-policy-raid5" \
#     -var="image_name=rhel-9-4-template" \
#     -var="supervisor_namespace=my-namespace" \
#     rhel-9-4.pkr.hcl
#
# Usage (ISO hosted on a remote server):
#   packer build \
#     -var="import_source_url=https://your-storage.example.com/rhel-9.4-x86_64-dvd.iso" \
#     -var="class_name=best-effort-xsmall" \
#     -var="storage_class=m01-cl01-optimal-datastore-default-policy-raid5" \
#     -var="image_name=rhel-9-4-template" \
#     -var="supervisor_namespace=my-namespace" \
#     rhel-9-4.pkr.hcli 

# ---------------------------------------------------------------------------
# Project ISO filename (defaults to the RHEL 9.4 ISO in iso/)
# ---------------------------------------------------------------------------
packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vsphere = {
      version = ">= 2.1.1"
      source  = "github.com/vmware/vsphere"
    }
  }
}

variable "iso_filename" {
  type        = string
  default     = "rhel-9.4-x86_64-dvd.iso"
  description = "ISO filename in the project's iso/ directory (used when use_local_iso_server=true)"
}

# ---------------------------------------------------------------------------
# Local ISO server configs (for use with scripts/serve-iso.*)
# ---------------------------------------------------------------------------
variable "use_local_iso_server" {
  type        = bool
  default     = false
  description = "Set to true to use the local ISO server from scripts/serve-iso.* (auto-constructs import_source_url)"
}

variable "local_iso_server_host" {
  type        = string
  default     = "localhost"
  description = "Hostname or IP of the local ISO server (e.g., the Supervisor cluster-accessible IP of your machine)"
}

variable "local_iso_server_port" {
  type        = number
  default     = 8080
  description = "Port of the local ISO server (must match the port used in scripts/serve-iso.*)"
}

# ---------------------------------------------------------------------------
# Image import configs.
# ---------------------------------------------------------------------------
variable "import_source_url" {
  type        = string
  default     = null
  description = "URL to the RHEL 9.4 ISO image. Leave null when using use_local_iso_server=true."
}

variable "import_source_ssl_certificate" {
  type        = string
  default     = null
  description = "SSL certificate for the import source URL (PEM format, if using self-signed)"
}

variable "import_target_location_name" {
  type        = string
  default     = null
  description = "Target content library or location name for the imported image"
}

variable "import_target_image_type" {
  type        = string
  default     = null
  description = "Type of the imported image (e.g., ISO, OVA)"
}

variable "import_target_image_name" {
  type        = string
  default     = null
  description = "Name of the imported image in the content library"
}

variable "clean_imported_image" {
  type        = bool
  default     = false
  description = "Whether to clean up the imported image from the content library after build"
}

variable "keep_import_request" {
  type        = bool
  default     = false
  description = "Whether to keep the import request after build"
}

# VM-Service source VM configs.
variable "image_name" {
  type        = string
  description = "Name of the source VM or image to create"
}

variable "class_name" {
  type        = string
  description = "VM class name (e.g., best-effort-xsmall, guaranteed-large)"
}

variable "storage_class" {
  type        = string
  description = "Storage class (e.g., m01-cl01-optimal-datastore-default-policy-raid5)"
}

variable "source_name" {
  type        = string
  default     = null
  description = "Name of an existing source VM to clone (alternative to ISO import)"
}

variable "bootstrap_provider" {
  type        = string
  default     = "CloudInit"
  description = "Bootstrap provider (CloudInit for Linux, Sysprep for Windows)"
}

variable "bootstrap_data_file" {
  type        = string
  default     = "./cloud-init-rhel-9.yml"
  description = "Path to the CloudInit bootstrap data YAML file"
}

# Supervisor cluster configs.
variable "kubeconfig_path" {
  type        = string
  default     = null
  description = "Path to the kubeconfig file for the Supervisor cluster"
}

variable "supervisor_namespace" {
  type        = string
  default     = null
  description = "Supervisor namespace to deploy into"
}

# SSH connection configs.
variable "communicator" {
  type        = string
  default     = "ssh"
  description = "Communicator type (ssh for Linux, winrm for Windows)"
}

variable "ssh_username" {
  type        = string
  default     = "packer"
  description = "SSH username"
}

variable "ssh_password" {
  type        = string
  default     = "packer"
  sensitive   = true
  description = "SSH password"
}

variable "ssh_timeout" {
  type        = string
  default     = "1h"
  description = "SSH connection timeout"
}

variable "ssh_bastion_host" {
  type        = string
  default     = null
  description = "Bastion/jump host for SSH connectivity"
}

variable "ssh_bastion_username" {
  type        = string
  default     = null
  description = "Username for bastion host SSH authentication"
}

variable "ssh_bastion_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for bastion host SSH authentication"
}

# Whether to keep the created source VM after the build.
variable "keep_input_artifact" {
  type        = bool
  default     = false
  description = "Whether to keep the source VM after the build completes"
}

# VM publishing configs.
variable "publish_location_name" {
  type        = string
  default     = null
  description = "Content library name to publish the template to"
}

variable "publish_image_name" {
  type        = string
  default     = null
  description = "Name of the published template image"
}

# Watch timeout related configs.
variable "watch_import_timeout_sec" {
  type        = number
  default     = 1800
  description = "Timeout in seconds for the image import operation"
}

variable "watch_source_timeout_sec" {
  type        = number
  default     = 3600
  description = "Timeout in seconds for the source VM creation"
}

variable "watch_publish_timeout_sec" {
  type        = number
  default     = 1800
  description = "Timeout in seconds for the publish operation"
}

# RHEL provisioning configs.
variable "rhel_subscription_username" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Red Hat Subscription Management username (leave empty if registered via other means)"
}

variable "rhel_subscription_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Red Hat Subscription Management password (leave empty if registered via other means)"
}

variable "rhel_auto_register" {
  type        = bool
  default     = false
  description = "Whether to auto-register with Red Hat Subscription Management"
}

variable "cleanup_before_shutdown" {
  type        = bool
  default     = true
  description = "Run cleanup tasks before final VM shutdown"
}

# ---------------------------------------------------------------------------
# Locals: compute the import source URL when using the project's local ISO
# server (scripts/serve-iso.*). This allows the template to automatically
# construct the correct URL from variables rather than requiring the user
# to manually craft it.
# ---------------------------------------------------------------------------
locals {
  local_iso_url = "http://${var.local_iso_server_host}:${var.local_iso_server_port}/${var.iso_filename}"
}

source "vsphere-supervisor" "rhel-9" {
  # Supervisor cluster connection
  kubeconfig_path      = var.kubeconfig_path
  supervisor_namespace = var.supervisor_namespace

  # Image import (ISO to content library)
  # When use_local_iso_server is true, auto-construct the URL from the
  # local server host/port and the project ISO filename. Otherwise,
  # fall back to the explicitly provided import_source_url.
  import_source_url             = var.use_local_iso_server ? local.local_iso_url : var.import_source_url
  import_source_ssl_certificate = var.import_source_ssl_certificate
  import_target_location_name   = var.import_target_location_name
  import_target_image_type      = var.import_target_image_type
  import_target_image_name      = var.import_target_image_name
  clean_imported_image          = var.clean_imported_image
  keep_import_request           = var.keep_import_request

  # VM deployment
  image_name          = var.image_name
  class_name          = var.class_name
  storage_class       = var.storage_class
  source_name         = var.source_name
  bootstrap_provider  = var.bootstrap_provider
  bootstrap_data_file = var.bootstrap_data_file
  keep_input_artifact = var.keep_input_artifact

  # Publish to content library
  publish_location_name = var.publish_location_name
  publish_image_name    = var.publish_image_name

  # Watch timeouts
  watch_import_timeout_sec  = var.watch_import_timeout_sec
  watch_source_timeout_sec  = var.watch_source_timeout_sec
  watch_publish_timeout_sec = var.watch_publish_timeout_sec

  # SSH communicator settings
  communicator         = var.communicator
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = var.ssh_timeout
  ssh_bastion_host     = var.ssh_bastion_host
  ssh_bastion_username = var.ssh_bastion_username
  ssh_bastion_password = var.ssh_bastion_password
}

build {
  sources = ["source.vsphere-supervisor.rhel-9"]

  # Initial connectivity check
  provisioner "shell" {
    inline = [
      "echo 'SSH connection established. Starting RHEL 9.4 provisioning.'",
      "hostnamectl",
      "cat /etc/redhat-release",
      "uname -a"
    ]
  }

  # Register with Red Hat Subscription Management (if credentials provided)
  provisioner "shell" {
    only = ["vsphere-supervisor.rhel-9"]
    inline = [
      "if [ -n \"${var.rhel_subscription_username}\" ] && [ -n \"${var.rhel_subscription_password}\" ]; then",
      "  echo 'Registering with Red Hat Subscription Management...'",
      "  subscription-manager register --username='${var.rhel_subscription_username}' --password='${var.rhel_subscription_password}' --auto-attach",
      "  echo 'Registration complete.'",
      "fi",
      "",
      "# Check subscription status",
      "subscription-manager status"
    ]
  }

  # Configure DNF for RHEL 9
  provisioner "shell" {
    inline = [
      "echo 'Configuring DNF package manager...'",
      "# Enable CRB (CodeReady Linux Builder) repository if available",
      "dnf config-manager --set-enabled crb 2>/dev/null || true",
      "",
      "# Set DNF configuration for faster operations",
      "cat > /etc/dnf/dnf.conf << 'DNFEOF'",
      "[main]",
      "gpgcheck=1",
      "installonly_limit=3",
      "clean_requirements_on_remove=True",
      "best=False",
      "skip_if_unavailable=True",
      "max_parallel_downloads=10",
      "DNFEOF",
      "echo 'DNF configuration complete.'"
    ]
  }

  # Update all system packages
  provisioner "shell" {
    inline = [
      "echo 'Updating all system packages...'",
      "dnf update -y",
      "echo 'System update complete.'"
    ]
  }

  # Install common tools and utilities
  provisioner "shell" {
    inline = [
      "echo 'Installing common tools and utilities...'",
      "dnf install -y \\",
      "  wget curl telnet net-tools bind-utils \\",
      "  vim-enhanced nano \\",
      "  tar gzip bzip2 xz \\",
      "  git jq \\",
      "  lsof strace sysstat \\",
      "  lvm2 device-mapper-persistent-data \\",
      "  bash-completion \\",
      "  nfs-utils \\",
      "  cloud-init cloud-utils-growpart \\",
      "  python3 python3-pip \\",
      "  openssh-server openssh-clients \\",
      "  sudo \\",
      "  tmux screen",
      "echo 'Common tools installation complete.'"
    ]
  }

  # Install open-vm-tools (VMware Tools for Linux)
  provisioner "shell" {
    inline = [
      "echo 'Installing open-vm-tools (VMware Tools)...'",
      "dnf install -y open-vm-tools",
      "",
      "# Enable and start the vmtoolsd service",
      "systemctl enable vmtoolsd",
      "systemctl start vmtoolsd",
      "",
      "# Verify installation",
      "vmtoolsd --version 2>/dev/null || vmware-toolbox-cmd -v 2>/dev/null || true",
      "echo 'open-vm-tools installation complete.'"
    ]
  }

  # Install development tools (optional - can be customized)
  provisioner "shell" {
    inline = [
      "echo 'Installing development tools...'",
      "dnf groupinstall -y 'Development Tools' || true",
      "echo 'Development tools installation complete.'"
    ]
  }

  # Configure SSH for better security and performance
  provisioner "shell" {
    inline = [
      "echo 'Configuring SSH...'",
      "# Enable SSH key-based authentication",
      "sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config",
      "sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config || true",
      "",
      "# Disable DNS resolution for faster SSH connections",
      "echo 'UseDNS no' >> /etc/ssh/sshd_config",
      "",
      "# Set SSH keepalive",
      "echo 'ClientAliveInterval 300' >> /etc/ssh/sshd_config",
      "echo 'ClientAliveCountMax 3' >> /etc/ssh/sshd_config",
      "",
      "# Restart SSH service",
      "systemctl restart sshd",
      "echo 'SSH configuration complete.'"
    ]
  }

  # Configure system settings
  provisioner "shell" {
    inline = [
      "echo 'Configuring system settings...'",
      "",
      "# Set timezone to Eastern Time",
      "timedatectl set-timezone America/New_York || true",
      "",
      "# Enable NTP",
      "timedatectl set-ntp true || true",
      "",
      "# Configure kernel parameters for better performance",
      "cat > /etc/sysctl.d/99-packer.conf << 'SYSEOF'",
      "# Packer-configured sysctl settings",
      "net.ipv4.tcp_tw_reuse = 1",
      "net.ipv4.ip_local_port_range = 1024 65535",
      "net.core.somaxconn = 1024",
      "vm.swappiness = 10",
      "SYSEOF",
      "sysctl -p /etc/sysctl.d/99-packer.conf || true",
      "",
      "echo 'System settings configuration complete.'"
    ]
  }

  # Configure firewall (firewalld)
  provisioner "shell" {
    inline = [
      "echo 'Configuring firewalld...'",
      "systemctl enable firewalld",
      "systemctl start firewalld || true",
      "",
      "# Allow SSH through firewall",
      "firewall-cmd --permanent --add-service=ssh || true",
      "firewall-cmd --reload || true",
      "echo 'Firewall configuration complete.'"
    ]
  }

  # Create the packer user for future provisioning if it doesn't exist
  provisioner "shell" {
    inline = [
      "echo 'Ensuring packer user exists...'",
      "id packer 2>/dev/null || useradd -m -s /bin/bash -G wheel packer",
      "echo 'packer' | passwd --stdin packer 2>/dev/null || echo 'packer:packer' | chpasswd",
      "",
      "# Grant sudo access to packer user without password",
      "echo 'packer ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/packer",
      "chmod 440 /etc/sudoers.d/packer",
      "echo 'Packer user configuration complete.'"
    ]
  }

  # Disable RH subscription auto-attach for templated systems
  provisioner "shell" {
    only = ["vsphere-supervisor.rhel-9"]
    inline = [
      "# If registered, disable auto-attach for templated image",
      "if command -v subscription-manager &>/dev/null; then",
      "  subscription-manager config --rhsm.auto_attach_eligible=false 2>/dev/null || true",
      "fi"
    ]
  }

  # Cleanup tasks (prepare for templating)
  provisioner "shell" {
    only = ["vsphere-supervisor.rhel-9"]
    inline = [
      "echo 'Starting cleanup for template preparation...'",
      "",
      "# Clear package cache",
      "dnf clean all",
      "",
      "# Clear temporary files",
      "rm -rf /tmp/* /var/tmp/*",
      "",
      "# Clear audit logs",
      "truncate -s 0 /var/log/wtmp",
      "truncate -s 0 /var/log/lastlog",
      "truncate -s 0 /var/log/audit/audit.log 2>/dev/null || true",
      "",
      "# Clear machine ID (will be regenerated on first boot)",
      "rm -f /etc/machine-id",
      "touch /etc/machine-id",
      "",
      "# Remove SSH host keys (will be regenerated on first boot)",
      "rm -f /etc/ssh/ssh_host_*",
      "",
      "# Clear bash history",
      "rm -f ~packer/.bash_history",
      "rm -f /root/.bash_history",
      "history -c 2>/dev/null || true",
      "",
      "# Clear cloud-init state for re-initialization on first boot",
      "cloud-init clean --logs 2>/dev/null || rm -rf /var/lib/cloud /var/log/cloud-init*",
      "",
      "echo 'Cleanup complete.'"
    ]
  }

  # Final status and system info
  provisioner "shell" {
    inline = [
      "echo '========================================'",
      "echo 'RHEL 9.4 template build complete!'",
      "echo 'Hostname: ' $(hostname)",
      "echo 'OS: ' $(cat /etc/redhat-release)",
      "echo 'Kernel: ' $(uname -r)",
      "echo 'Architecture: ' $(uname -m)",
      "echo 'CPU Cores: ' $(nproc)",
      "echo 'Memory: ' $(free -h | awk '/^Mem:/ {print $2}')",
      "echo 'Disk: ' $(df -h / | awk 'NR==2 {print $2}')",
      "echo '========================================'"
    ]
  }
}