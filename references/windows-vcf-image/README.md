# Windows VCF Automation Image for vSphere

This guide documents the steps required to prepare a Windows virtual machine image for use with **VCF Automation** on **vSphere**. The image must be based on a vSphere template with **Cloudbase-Init** installed and configured.

> **Source**: [Broadcom TechDocs - Windows VCF Automation image for vSphere](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/organization-management/vcfa-overview/working-with-the-vcf-automation-catalog/maphead-designing-your-deployments/initialize-general/initialize-windows-general/initialize-windows-image-vsphere.html)

---

## Prerequisites

- Access to a vSphere environment
- Windows installation media (ISO)
- Cloudbase-Init MSI installer

---

## Creating the Image

### Step 1: Create and Power On a Windows VM

Use **vSphere** to create and power on a Windows virtual machine.

### Step 2: Log In to Windows

On the virtual machine, log in to Windows.

### Step 3: Download Cloudbase-Init

Download the Cloudbase-Init installer from the official site:

[https://cloudbase.it/cloudbase-init/#download](https://cloudbase.it/cloudbase-init/#download)

### Step 4: Install Cloudbase-Init

Start the Cloudbase-Init setup `.msi` file. During installation:

- Enter **`Administrator`** as the username
- Select the option to **Run as LocalSystem**
- Other setup selections can remain as default values

### Step 5: Do NOT Close the Setup Wizard

Allow the installation to run, but **do not close the final "Completed" page** of the setup wizard.

> **⚠ IMPORTANT**: Do not close the final page of the setup wizard.

### Step 6: Edit `cloudbase-init-unattend.conf`

With the Completed page still open, navigate to the Cloudbase-Init installation path and open the following file in a text editor:

```text
conf\cloudbase-init-unattend.conf
```

Set `metadata_services` to use `VMwareGuestInfoService` with `OvfService` as a fallback:

```ini
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfo.VMwareGuestInfoService,cloudbaseinit.metadata.services.ovfservice.OvfService
```

> **Note**: `VMwareGuestInfoService` reads `guestinfo.metadata` (hostname, network) injected by the vSphere VM Operator during `bootstrap.cloudInit`. `OvfService` is retained as a legacy fallback.

Configure the plugins for the unattended setup phase:

```ini
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin
```

> During the unattend phase, Cloudbase-Init applies the MTU configuration, sets the hostname, and extends the OS volume. `NetworkConfigPlugin` is intentionally excluded here — full NIC configuration happens in `cloudbase-init.conf`.

Save and close the file.

### Step 7: Edit `cloudbase-init.conf`

In the same folder, open the following file:

```text
conf\cloudbase-init.conf
```

Set the following configuration values:

```ini
first_logon_behaviour=always
```

Configure `metadata_services` to use `VMwareGuestInfoService` with `OvfService` as a fallback:

```ini
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfo.VMwareGuestInfoService,cloudbaseinit.metadata.services.ovfservice.OvfService
```

Configure the plugins in the following order:

```ini
plugins=cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin
```

> **NetworkConfigPlugin** must appear first so that the static IP (pushed via `guestinfo.metadata` from NSX allocation) is applied before `UserDataPlugin` executes `runcmd`. This ensures the network is available when user-data scripts run.
> **IPAM Integration**: If you are using an IPAM provider to assign static IPs on Windows, `NetworkConfigPlugin` (already listed above) handles the IPAM integration.

Save and close the file.

### Step 8: (Optional) Review `Unattend.xml`

The Cloudbase-Init installation includes an `Unattend.xml` file located alongside the `.conf` files:

```text
conf\Unattend.xml
```

This file defines the Windows unattended setup behavior during the `generalize`, `oobeSystem`, and `specialize` passes:

- **generalize pass**: Preserves all installed device drivers (`PersistAllDeviceInstalls=true`)
- **oobeSystem pass**: Skips the EULA page, sets network location to Work, enables recommended protection, and skips both machine and user OOBE
- **specialize pass**: Runs Cloudbase-Init with `cloudbase-init-unattend.conf` to set the hostname synchronously before the first boot completes

This file is typically used as-is and does not require modification.

### Step 9: Run Sysprep and Shut Down

On the **Completed page** of the setup wizard:

1. Select the option to **Run Sysprep**
2. Select the option to **Shut down after Sysprep**
3. Click **Finish**

> **⚠ NOTE**: VMware has seen cases where running Sysprep prevents deployments of the image from working. When deploying, VCF Automation applies a dynamically generated customization specification, which disconnects the network interface. The pending Sysprep state in the image might cause the customization specification to fail and leave the deployment disconnected. If you suspect this is happening in your environment, try leaving the Sysprep options deactivated when creating the image.

### Step 10: Convert to Template

After the virtual machine shuts down, use **vSphere** to convert it into a template.

---

## Configuration Reference

| Configuration Setting | Purpose |
| ---------------------- | --------- |
| **Username, CreateUserPlugin, and SetUserPasswordPlugin** | After Sysprep, first boot uses `CreateUserPlugin` to create the `Administrator` account with a blank password. `SetUserPasswordPlugin` allows Cloudbase-Init to change the blank password to the remote access password included in the cloud template. |
| **First Logon Behavior** | This setting (`first_logon_behaviour=always`) prompts the user to change the password upon first login. |
| **VMwareGuestInfoService** | Reads `guestinfo.metadata` (hostname, network configuration) injected by the vSphere VM Operator during `bootstrap.cloudInit`. Must be listed first for VCF Automation on Supervisor Clusters. |
| **OvfService** | Fallback metadata service for legacy OVF/vApp property deployments when `VMwareGuestInfoService` is unavailable. |
| **NetworkConfigPlugin** | Applies static IP configuration pushed via `guestinfo.metadata` from NSX IP allocation. Must run before `UserDataPlugin` to ensure the network is up before user-data scripts execute. |
| **MTUPlugin** | Applies MTU configuration during the unattend phase. |
| **SetHostNamePlugin** | Sets the hostname during the unattend phase. |
| **ExtendVolumesPlugin** | Extends the OS volume to fill available disk space during the unattend phase. |
| **Run as LocalSystem** | Supports advanced initialization commands that might require Cloudbase-Init to run under a dedicated administrator account. |

### Cloudbase-Init File Summary

| File | Phase | Purpose |
| ------ | ------- | --------- |
| `cloudbase-init-unattend.conf` | Unattend (Sysprep specialize pass) | Sets hostname, MTU, and extends the OS volume before first boot completes |
| `cloudbase-init.conf` | First boot | Applies network configuration, creates user, sets password, configures SSH keys, runs user data scripts |
| `Unattend.xml` | Windows sysprep | Controls generalize, OOBE, and specialize passes; runs `cloudbase-init-unattend.conf` synchronously |

### Full Configuration Details

The deployed `.conf` files include the following settings in addition to those above:

```ini
username=Administrator
groups=Administrators
inject_user_password=true
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
verbose=true
debug=true
log_dir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
mtu_use_dhcp_config=true
ntp_use_dhcp_config=true
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
check_latest_version=false
```

> **Note**: `bsdtar_path`, `mtools_path`, `verbose`, `debug`, and `check_latest_version` are derived from the Cloudbase-Init installer defaults.

---

## Related Documentation

- [Windows guest customization in VCF Automation for VM Apps](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/organization-management/vcfa-overview/working-with-the-vcf-automation-catalog/maphead-designing-your-deployments/initialize-general/initialize-windows-general.html)
- [Cloudbase-Init commands for Windows in VCF Automation for VM Apps](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/organization-management/vcfa-overview/working-with-the-vcf-automation-catalog/maphead-designing-your-deployments/initialize-general/initialize-windows-general/initialize-cloudbase-init.html)
