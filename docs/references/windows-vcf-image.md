---
icon: octicons/device-desktop-24
---

# Windows VCF Automation image

VCF Automation does not run `Autounattend.xml` for you. A Windows image deployed
from a VCF Automation catalog is **initialised on first boot by Cloudbase-Init**,
which reads the hostname, network configuration and user data that the platform
injects. If the image does not have Cloudbase-Init installed and configured for
`VMwareGuestInfoService`, the deployment powers on with no hostname, no network
and no way in.

This page documents that preparation layer. It is not about the `builds/windows`
projects, which produce the sealed image; it is about what has to be true of that
image before VCF Automation will accept it.

| Property | Value |
| :--- | :--- |
| Material | `references/windows-vcf-image/` |
| Source | Broadcom TechDocs, *Windows VCF Automation image for vSphere* |
| Platform | vSphere, deployed through VCF Automation 9.0 |

## The procedure

| Step | Action |
| :--- | :--- |
| 1 | Create a Windows VM in vSphere and power it on |
| 2 | Log in |
| 3 | Download the Cloudbase-Init installer from `cloudbase.it` |
| 4 | Install it: username `Administrator`, **Run as LocalSystem**, defaults elsewhere |
| 5 | **Do not close the final page of the setup wizard** |
| 6 | Edit `conf\cloudbase-init-unattend.conf` |
| 7 | Edit `conf\cloudbase-init.conf` |
| 8 | Optionally review `conf\Unattend.xml` |
| 9 | On the wizard's last page: **Run Sysprep**, **Shut down after Sysprep**, **Finish** |
| 10 | Convert the powered-off VM to a template |

Step 5 is not a formality. The wizard's final page is what performs Sysprep
against the configuration files you are about to edit; closing it early seals the
image with the installer's defaults, and the metadata service will be wrong.

## The two configuration files

Both files live in `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\`.
The copies in `references/windows-vcf-image/packages/Cloudbase
Solutions/Cloudbase-Init/conf/` are the state they should end in, and
`cd_files/` holds the same pair for attaching through a CD-ROM.

### `cloudbase-init-unattend.conf` - the Sysprep specialize pass

```ini
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfo.VMwareGuestInfoService,cloudbaseinit.metadata.services.ovfservice.OvfService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin
```

Hostname, MTU and OS-volume growth, synchronously, while the first boot completes.
`NetworkConfigPlugin` is deliberately **absent** here: the network is configured
by the first-boot pass, once, not twice.

### `cloudbase-init.conf` - the first boot

```ini
first_logon_behaviour=always
metadata_services=cloudbaseinit.metadata.services.vmwareguestinfo.VMwareGuestInfoService,cloudbaseinit.metadata.services.ovfservice.OvfService
plugins=cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.common.sshpublickeys.SetUserSSHPublicKeysPlugin,cloudbaseinit.plugins.common.userdata.UserDataPlugin
```

Two orders in those two lines are load-bearing:

1. **`VMwareGuestInfoService` before `OvfService`.** The vSphere VM Operator
   injects the hostname and network through `guestinfo.metadata`. `OvfService`
   reads OVF environment properties and is a legacy fallback; if it is consulted
   first the guest comes up with nothing.
2. **`NetworkConfigPlugin` before `UserDataPlugin`.** The static address comes
   from the NSX IP allocation through `guestinfo.metadata`. If user data runs
   first, its `runcmd` scripts execute on a guest with no usable network.

The remaining plugin order is the account sequence: create the `Administrator`
account, set its password from the deployment, install SSH keys, then run user
data.

### The rest of the file

The installer writes these defaults, which the documentation keeps:

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

`verbose=true` and `debug=true` are worth keeping while an image is being brought
up: the log in `log_dir` is the only place the plugin order shows its work.

## `Unattend.xml`

The installer's own `Unattend.xml` sits beside the `.conf` files and is normally
left alone. It controls three passes:

| Pass | What it sets |
| :--- | :--- |
| `generalize` | `PersistAllDeviceInstalls=true`, so drivers installed for the source VM survive |
| `oobeSystem` | EULA skipped, network location Work, recommended protection, machine and user OOBE skipped |
| `specialize` | Runs Cloudbase-Init with `cloudbase-init-unattend.conf`, so the hostname is set before first boot returns |

## The Sysprep caveat

VCF Automation applies a generated customization specification at deploy time,
and that specification momentarily disconnects the network adapter. An image left
in a pending Sysprep state can make that step fail, which leaves the deployment
disconnected - the guest boots, and nothing else happens.

If deployments from an otherwise correct image come up with no network, the
documented workaround is to leave the Sysprep options in step 9 deactivated:

- **Run Sysprep** cleared
- **Shut down** selected on its own

Then seal the image another way, or accept that the same image will be
generalized by the platform.

## Relation to the Windows builds in this repository

| Concern | Where it is handled |
| :--- | :--- |
| Install Windows unattended | `scripts/windows/data/autounattend.pkrtpl.hcl` |
| Patch, harden, strip AppX, return to DHCP | `builds/windows/files/`, driven by the build block |
| Seal before publishing | The build block's final provisioners |
| **Initialise a deployed clone (hostname, IP, user data)** | **This page** |

A `builds/windows/server/*` image is a valid input to this procedure - but it is
not yet a VCF Automation image. The Cloudbase-Init layer is added on top, once,
and then converted to a template.

## Related

- [vSphere Supervisor images](vsphere-supervisor.md) - the builder side, where
  `bootstrap_provider = "Sysprep"` is what makes the platform inject the
  unattend data this page configures.
- [Active Directory join](vcfa-ad-join.md) - the name VCF Automation gives the
  guest is the AD computer account name, and it is limited to 15 characters.
- [Windows Server builds](../operations/windows-builds.md) - the drive-letter
  contract the images depend on.
