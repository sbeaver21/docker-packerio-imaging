# A Packer template to deploy a Windows Server 2025 VM using the vsphere-supervisor builder.
# Supports both ISO import (from a URL-accessible image) and source VM clone patterns. 
#
# ISO file (from project iso/ directory):
#   SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO
#
# Prerequisites:
#   - The Windows Server 2025 ISO must be accessible via HTTPS/HTTP URL from the
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
#     -var="storage_class=thick" \
#     -var="image_name=windows-2025-template" \
#     -var="supervisor_namespace=my-namespace" \
#     windows-2025.pkr.hcl
#
# Usage (ISO hosted on a remote server):
#   packer build \
#     -var="import_source_url=https://your-storage.example.com/SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO" \
#     -var="class_name=best-effort-xsmall" \
#     -var="storage_class=thick" \
#     -var="image_name=windows-2025-template" \
#     -var="supervisor_namespace=my-namespace" \
#     windows-2025.pkr.hcl

# ---------------------------------------------------------------------------
# Project ISO filename (defaults to the Windows Server 2025 ISO in iso/)
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
  default     = "SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO"
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
  description = "URL to the Windows Server 2025 ISO or OVA image. Leave null when using use_local_iso_server=true."
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
  description = "Storage class (e.g., thick, thin)"
}

variable "source_name" {
  type        = string
  default     = null
  description = "Name of an existing source VM to clone (alternative to ISO import)"
}

variable "bootstrap_provider" {
  type        = string
  default     = "Sysprep"
  description = "Bootstrap provider (Sysprep for Windows, CloudInit for Linux)"
}

variable "bootstrap_data_file" {
  type        = string
  default     = "./sysprep-unattend-windows-2025.yml"
  description = "Path to the Sysprep unattend YAML file"
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

# WinRM connection configs.
variable "communicator" {
  type        = string
  default     = "winrm"
  description = "Communicator type (winrm for Windows, ssh for Linux)"
}

variable "winrm_username" {
  type        = string
  default     = "packer"
  description = "WinRM username"
}

variable "winrm_password" {
  type        = string
  default     = "packer"
  sensitive   = true
  description = "WinRM password"
}

variable "winrm_timeout" {
  type        = string
  default     = "2h"
  description = "WinRM connection timeout"
}

variable "winrm_use_ssl" {
  type        = bool
  default     = true
  description = "Use SSL for WinRM"
}

variable "winrm_insecure" {
  type        = bool
  default     = true
  description = "Allow insecure WinRM connections (skip SSL verification)"
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

# Windows provisioning configs.
variable "windows_update_timeout" {
  type        = string
  default     = "3h"
  description = "Timeout for Windows Update provisioning"
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

source "vsphere-supervisor" "windows-2025" {
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

  # WinRM communicator settings
  communicator   = var.communicator
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = var.winrm_use_ssl
  winrm_insecure = var.winrm_insecure
}

build {
  sources = ["source.vsphere-supervisor.windows-2025"]

  # Wait for WinRM to be ready
  provisioner "powershell" {
    inline = [
      "Write-Host 'WinRM connection established. Starting Windows Server 2025 provisioning.'",
      "Set-Location $env:TEMP"
    ]
  }

  # Set execution policy and basic configuration
  provisioner "powershell" {
    inline = [
      "Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force",
      "Write-Host 'Setting time zone to Central Standard Time'",
      "Set-TimeZone -Id 'Central Standard Time'"
    ]
  }

  # Configure WinRM for better reliability
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring WinRM settings'",
      "winrm set winrm/config/service '@{MaxTimeoutMs=\"1800000\"}'",
      "winrm set winrm/config/service/auth '@{Basic=\"true\"}'",
      "winrm set winrm/config/service '@{AllowUnencrypted=\"true\"}'",
      "winrm set winrm/config/winrs '@{MaxMemoryPerShellMB=\"2048\"}'"
    ]
  }

  # Install Windows Features (common server roles)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Installing .NET Framework 3.5'",
      "Install-WindowsFeature -Name Net-Framework-Core -IncludeAllSubFeature -ErrorAction SilentlyContinue",
      "Write-Host 'Installing .NET Framework 4.8 Features'",
      "Install-WindowsFeature -Name Net-Framework-45-Core -IncludeAllSubFeature -ErrorAction SilentlyContinue",
      "Write-Host 'Installing SNMP Service'",
      "Install-WindowsFeature -Name SNMP-Service -IncludeAllSubFeature -ErrorAction SilentlyContinue",
      "Write-Host 'Installing Telnet Client'",
      "Install-WindowsFeature -Name Telnet-Client -ErrorAction SilentlyContinue"
    ]
  }

  # System configuration
  provisioner "powershell" {
    inline = [
      # Disable IE Enhanced Security Configuration
      "Write-Host 'Disabling IE Enhanced Security Configuration for Administrators'",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Active Setup\\Installed Components\\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Active Setup\\Installed Components\\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name 'IsInstalled' -Value 0",

      # Enable Remote Desktop
      "Write-Host 'Enabling Remote Desktop'",
      "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0",
      "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'",

      # Disable Windows Firewall for initial setup (can be re-enabled after)
      "Write-Host 'Disabling Windows Firewall profiles'",
      "Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False",

      # Set power scheme to High Performance
      "Write-Host 'Setting power scheme to High Performance'",
      "powercfg /change standby-timeout-ac 0",
      "powercfg /change hibernate-timeout-ac 0",
      "powercfg /setactive SCHEME_MIN"
    ]
  }

  # Create temporary directory for Packer scripts
  provisioner "powershell" {
    inline = [
      "Write-Host 'Creating C:\\Packer directory'",
      "New-Item -ItemType Directory -Force -Path 'C:\\Packer' | Out-Null"
    ]
  }

  # Run Windows Update (optional - set windows_update_timeout to control)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Starting Windows Update. This may take a while...'",
      "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null",
      "Install-Module -Name PSWindowsUpdate -Force -ErrorAction SilentlyContinue | Out-Null",
      "Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -AutoReboot:$false | Out-File -FilePath 'C:\\Packer\\windows-update.log'",
      "Write-Host 'Windows Update completed. See C:\\Packer\\windows-update.log for details.'"
    ]
    skip_clean        = true
    expect_disconnect = true
    pause_before      = "30s"
    max_retries       = 3
  }

  # Reboot if needed after Windows updates
  provisioner "windows-restart" {
    restart_check_command = "powershell -Command \"& {Write-Host 'Machine restarted'}\""
  }

  # Cleanup tasks
  provisioner "powershell" {
    inline = [
      "Write-Host 'Cleaning up temporary files'",
      "CleanMgr /sagerun:1 | Out-Null",
      "Remove-Item -Path 'C:\\Windows\\Temp\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "Remove-Item -Path 'C:\\Users\\packer\\AppData\\Local\\Temp\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "Remove-Item -Path 'C:\\Packer\\Drivers' -Recurse -Force -ErrorAction SilentlyContinue",

      # Clean Windows Update cache
      "Write-Host 'Cleaning Windows Update cache'",
      "Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue",
      "Remove-Item -Path 'C:\\Windows\\SoftwareDistribution\\Download\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "Start-Service -Name wuauserv -ErrorAction SilentlyContinue",

      # Clear event logs
      "Write-Host 'Clearing Event Logs'",
      "wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }"
    ]
  }

  # Final status
  provisioner "powershell" {
    inline = [
      "Write-Host '========================================'",
      "Write-Host 'Windows Server 2025 template build complete!'",
      "Write-Host 'Hostname: ' (Get-CimInstance Win32_ComputerSystem).Name",
      "Write-Host 'OS Version: ' (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').ProductName",
      "Write-Host 'Build: ' (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').CurrentBuild",
      "Write-Host '========================================'"
    ]
  }

  # Prepare for Sysprep (generalize the image)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Running Sysprep to generalize the image'",
      "C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet",
      "Write-Host 'Sysprep executed. VM will shut down.'"
    ]
    expect_disconnect = true
    timeout           = "30m"
  }
}