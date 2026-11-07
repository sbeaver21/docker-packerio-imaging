# Windows builds: the F: scripts ISO

## Symptom

Windows builds install fine and log in, but VMware Tools never installs and
Packer sits forever at:

```text
==> vsphere-iso.<build>: Waiting for IP...
```

Inside the guest the build CD fails to read:

```text
C:\> dir f:
The volume does not contain a recognized file system.
```

## Root cause

The Windows builds deliver their helper scripts with Packer's `cd_files`.
Packer's behaviour there is host dependent:

| Packer host | CD writer | Windows can read it? |
| --- | --- | --- |
| Windows | built-in ISO writer (Joliet) | yes - `F:` works |
| Linux container | `xorriso` in Rock Ridge mode | **no** |

On Linux, xorriso also warns:

```text
xorriso : WARNING : -volid text does not comply to ISO 9660 / ECMA 119 rules
```

So the same templates work from `D:\docker-packerio-imaging` on a Windows box and fail when
built in the `hashicorp/packer` container.

Because `F:` is unreadable, every first-logon command in the answer file
(`powershell -File F:\windows-vmtools.ps1`, `F:\temp-network.ps1`, ...) fails.
No Tools means no guest IP, so Packer waits forever.

## Fix

Stop using `cd_files` for the Windows builds. Build an equivalent ISO with
Joliet and attach it through `iso_paths` as the third ISO:

```hcl
iso_paths = [
  "[${ var.common_iso_datastore }] ${ var.iso_datastore_path }/${ var.iso_file }",
  "[] /vmimages/tools-isoimages/windows.iso",
  "[example-datastore] packer-iso/win2025-standard-core-scripts.iso"
]
```

Device order then gives the letters the scripts expect:

| Drive | Contents |
| --- | --- |
| `D:` | Windows Server install ISO |
| `E:` | VMware Tools ISO (`setup.exe`) |
| `F:` | this scripts ISO |

## What must be on the ISO

Mirror `builds/windows/files/*`:

* `dhcp-network.ps1`, `fix-permissions.ps1`, `win-init.ps1`,
  `windows-init.ps1`, `windows-prepare.ps1`, `windows-vmtools.ps1`
* `CD\` and `Temp\` - `win-init.ps1` has `$StageFolder = @('CD','Temp')` and
  stages them to `C:\CD` / `C:\Temp`
* the edition's own `temp-network.ps1` from `<edition>/`

Each edition has a **different** `temp-network.ps1` (they set different static
IPs so parallel builds do not collide), so there is one ISO per edition.

## Rebuild

```sh
# on a host/container that mounts the share at /workspace
scripts/windows/build-scripts-isos.sh /workspace
# -> builds/windows/packer-iso/win<ver>-<edition>-scripts.iso
```

Re-run whenever anything under `builds/windows/files/` or an edition's
`temp-network.ps1` changes.

## Upload

The ISOs must live on a datastore both build hosts can see. They are read from
`[example-datastore] packer-iso/`. Upload with PowerCLI:

```powershell
$ds = Get-Datastore -Name 'example-datastore'
New-PSDrive -Name dsw -PSProvider VimDatastore -Root '\' -Datastore $ds | Out-Null
Copy-DatastoreItem -Item 'C:\isos\win2025-standard-core-scripts.iso' `
                   -Destination 'dsw:\packer-iso\win2025-standard-core-scripts.iso' -Force
```

## Answer file requirements

`scripts/windows/data/autounattend.pkrtpl.hcl`:

* first-logon commands reference `F:\...`
* `<RequiresUserInput>false</RequiresUserInput>` on the
  `Set-ExecutionPolicy` commands - with `true`, Windows stops and waits for a
  user before running the rest of the chain, so nothing after it ever runs

## Note on `windows-vmtools.ps1`

Keep the original form:

```powershell
[string]$SetupPath = "E:"
```

Do **not** replace it with a drive-scan that waits for media to appear. If the
media cannot be found the wait blocks the rest of the first-logon chain for its
full timeout, which looks exactly like the original hang.
