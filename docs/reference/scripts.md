# Provisioning Scripts

Scripts under `scripts/` run **inside the guest**, after the unattended install
and reboot. They are invoked by the build block, usually as:

```hcl
provisioner "shell" {
  execute_command = "{{.Vars}} sudo -S -E sh -eux '{{.Path}}'"
  scripts = [ "${abspath(path.root)}/../../../../scripts/linux/rhel/prep.sh", … ]
}
```

Which shell that is depends on the family, and it is worth knowing before
writing a script:

| Family | `execute_command` |
| :----- | :---------------- |
| RHEL | `sudo -S -E sh -eux` |
| Ubuntu | `sudo -S -E bash -eux` |
| Photon | `sudo -S -E bash -eux` |

Three consequences follow from `-eux`, whichever shell runs it:

- **`-e`** — any command that exits non-zero fails the image build. A script
  must make every expected failure explicit (`|| warn …`).
- **`-u`** — an unset variable is fatal.
- **`-x`** — every command is traced into the build log.

`/bin/sh` is bash on RHEL-family systems, but **ash** on Photon OS. Only the
Photon patch script re-executes itself under `bash`; everything else must stay
POSIX, because a script listed for more than one family may be run by `sh`.

!!! note "Every Linux project uses `${path.root}/scripts/…`"
    RHEL, Ubuntu and Photon all reference their scripts as
    `${abspath(path.root)}/../../../../scripts/linux/<distribution>/…` — anchored
    on `path.root`, the **project** directory, not on `path.cwd`. Nothing depends on
    the directory Packer was started from, so a project builds identically from
    the repository root or from inside its own directory.

    There is one copy of each script, in `scripts/linux/<distribution>/` at the
    repository root, shared by every project that runs it. Four levels up from a
    project directory is that root.

---

## RHEL: `scripts/linux/rhel/`

The RHEL projects run four scripts in this order:

| Order | Script | What it does |
| :---: | :----- | :----------- |
| 1 | `baseline-rhel9.sh` | RHEL 9 baseline: trust the Satellite CA, provision the `buildops` SSH account, register with subscription-manager, SELinux to permissive, AD crypto policy, patch, baseline packages, AD realm-join packages |
| 2 | `prep.sh` | Generalize the guest: unregister the entitlement, remove SSH host keys, reset machine-id and hostname, clear caches, history, `/tmp` and logs |
| 3 | `cleanup.sh` | Shrink the guest: reset machine identity again, disable IPv6, clear login records and logs, zero swap, zero free space, report disk usage |
| 4 | `dhcp.sh` | Return the adapter to DHCP with `nmcli device modify <dev> ipv4.method auto` |

RHEL 10 uses `baseline-rhel10.sh` instead of `baseline-rhel9.sh`. The two differ
in the AD crypto policy (`DEFAULT:AD-SUPPORT` in both, with a different baseline
package set) and in the package names the major version provides.

!!! warning "These scripts carry site defaults"
    `baseline-rhel9.sh` defaults to a Satellite host
    (`satellite.example.com`), organisation
    `image-automation` and activation key `AK_EXAMPLE_Rhel9`.
    None of it is read from a variable, so using these builds in another estate
    means editing the scripts.

!!! note "Environment overrides exist, but the provisioner does not set them"
    `baseline-rhel9.sh` accepts overrides for all of it (`SATELLITE_HOST`,
    `SUBSCRIPTION_ORG`, `SUBSCRIPTION_ACTIVATION_KEY`, `SERVICE_USER`), but the
    Packer provisioner sets none of them — the defaults are what runs.

!!! note "`prep.sh` and `cleanup.sh` are the well-behaved ones"
    Both are idempotent, accept `--dry-run`, honour `ALLOW_NON_ROOT`, and
    explain each decision in a header comment. They are the reference for how a
    new script in this tree should be written. Both also deliberately avoid
    deleting the script Packer is currently reading, which a naive
    `rm -rf /tmp/*` does.

### Known quirks

| Script | Issue |
| :----- | :---- |
| `dhcp.sh` | Starts with `sudo su buildops`, which cannot change the identity of the commands that follow it in a non-interactive script and fails when stdin is not a tty. It also leaves `$ens` unquoted. |

---

## Ubuntu: `scripts/linux/ubuntu/`

| Script | What it does |
| :----- | :----------- |
| `apt.sh` | Point the package sources at the site mirrors and update |
| `netreset.sh` | Remove netplan static configuration and restore DHCP |
| `cleanup.sh` | Clear logs, history, machine-id |
| `finalupdate.sh` | Final `apt` upgrade before the image is captured |

---

## Photon OS: `scripts/linux/photon/`

| Script | What it does |
| :----- | :----------- |
| `update.sh` | On-demand update and patch of a running Photon host |
| `dhcp.sh` | Return to DHCP |
| `prep.sh`, `clean.sh`, `cleanup.sh` | Generalize and shrink the guest |
| `apt.sh` | Present for parity; Photon uses `tdnf` |
| `system/update-packages.sh` | **The final provisioner.** Patch until `tdnf check-update` reports nothing pending, and fail the build if that cannot be proven |
| `system/complete-build.sh` | GRUB `net.ifnames=0`, truncate machine-id, zero free space, clean `tdnf` |
| `system/install-packages.sh` | Install `sudo` |
| `system/lockdown-security.sh` | Lock `root`, disable SSH password authentication |
| `vmware/install-vmw-guest-additions.sh` | open-vm-tools |
| `virtualbox/install-vbx-guest-additions.sh` | VirtualBox guest additions, for the non-vSphere variants |
| `vagrant/setup-vagrant-user.sh` | Vagrant user, for the Vagrant output variant |

### `system/update-packages.sh` deserves its own paragraph

It is the only script in the tree that refuses to let a build succeed on an
unprovable claim. `tdnf` reports success after silently dropping a repository it
could not reach, so "no updates pending" and "I could not ask" look identical.
The script captures every `tdnf` invocation, scans the output for
`Disabling Repo` and `Failed to synchronize cache`, checks that at least one
repository is enabled, and fails the build when the system cannot be shown to be
current:

| Variable | Default | Effect |
| :------- | :------ | :----- |
| `PHOTON_PATCH_MAX_ROUNDS` | `5` | Upgrade rounds before giving up |
| `PHOTON_PATCH_ATTEMPTS` | `3` | Metadata refresh attempts |
| `PHOTON_PATCH_STRICT` | `1` | `0` warns instead of failing |

It runs **last** on purpose: anything installed after it would be captured
unpatched.

### Photon's `/bin/sh` is ash

No arrays, no `[[ ]]`, no `ERR` trap. Anything using them must re-execute under
`bash`, as `system/update-packages.sh` does.

Photon and Ubuntu both invoke the shell provisioner with `bash -eux`; only RHEL
uses `sh -eux`. That does not make bash-isms safe: `/bin/sh` on a Photon guest
is still ash, so a script that reaches `sh` by another route — `sh script.sh` in
a `cd_files` payload, for instance — is running under ash regardless.

---

## Windows: `scripts/windows/` and `builds/windows/files/`

The Windows projects do not use shell scripts. The build block runs PowerShell,
and the payload it executes lives in `builds/windows/files/`:

| Path | Purpose |
| :--- | :------ |
| `files/win-init.ps1` | Guest initialization: staging, OpenSSH, power, RDP, adapter tuning, time zone, PowerShell 7 |
| `files/windows-init.ps1` | Earlier-generation guest initialization, kept for the projects that still call it |
| `files/windows-prepare.ps1` | Preparation before capture |
| `files/windows-vmtools.ps1` | Install VMware Tools from the supplied ISO |
| `files/dhcp-network.ps1` | Return the adapter to DHCP |
| `files/fix-permissions.ps1` | Repair ACLs on the copied payload |
| `files/CD/` | Files copied to the CD-ROM: `guest-init.ps1`, `dhcp-network.ps1`, `ipFixForVM.ps1`, `netConfig.ini`, `ip4net.json`, `Uninstall-EverythingZoom.ps1` |
| `files/Temp/` | Vulnerability-hardening scripts and `How-To.txt` |

The hardening scripts in `files/Temp/` are executed elevated as SYSTEM by the
`inline` list in each project's `*.auto.pkrvars.hcl`:

```hcl
"Start-Process Powershell.exe -Wait -Verb RunAs -ArgumentList
    'Set-ExecutionPolicy Bypass -Scope Process -Force; C:/Temp/Check-hardening-server-v2.ps1'"
```

`C:/Temp/` is where the payload lands inside the guest, not a path in this
repository. The same list disables IPv6, resets `netsh int ip` and
`netsh winsock`, and removes the Edge AppX packages.

!!! warning "These scripts are third-party and unverified"
    They are committed as-is and run with SYSTEM privileges on every Windows
    image. Review them and pin their checksums before relying on the images. See
    [Secrets](../operations/secrets.md).

---

## Writing a new script

Follow the pattern of `prep.sh`:

- Header comment stating what the script does, its steps, and its environment
  overrides.
- `set -euo pipefail`.
- `--dry-run` and `--help`.
- A `run()` wrapper that logs the command before executing it.
- Idempotent — a second run is a no-op.
- POSIX-mode safe: RHEL runs it with `sh -eux`, and Photon's `/bin/sh` is ash.
- Every expected failure handled explicitly, because `-e` fails the build on the
  first one.
