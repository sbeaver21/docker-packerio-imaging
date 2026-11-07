# scripts

Provisioning scripts executed **inside the guest**, after the unattended install
and reboot. Grouped by distribution.

```text
scripts/
├── linux/
│   ├── photon/     Photon OS 4 and 5
│   ├── rhel/       Red Hat Enterprise Linux 8, 9, 10
│   └── ubuntu/     Ubuntu Server 20.04 to 26.04
├── windows/
│   ├── dhcp-network.ps1
│   ├── guest-init.ps1
│   ├── standard-dexp.ps1
│   ├── windows-init.ps1
│   ├── windows-prepare.ps1
│   ├── windows-vmtools.ps1
│   ├── winnetwork.pkrtpl.hcl
│   └── data/
└── bootstrap/      build-host preparation, not run in the guest
```

`bootstrap/` is the one directory whose scripts do **not** run inside the guest.
They run on the build host, before Packer starts, and build the per-edition
scripts ISO the Windows guests read from `F:`. See
[bootstrap/README.md](bootstrap/README.md).

Which script a build runs is listed in
[docs/reference/scripts.md](../docs/reference/scripts.md), and the full
description of each is there too. This file covers the conventions.

---

## How they are invoked

```hcl
provisioner "shell" {
  execute_command = "{{.Vars}} sudo -S -E sh -eux '{{.Path}}'"
  scripts = [ "${abspath(path.root)}/../../../../scripts/linux/rhel/prep.sh", … ]
}
```

`sh -eux` is the contract:

| Flag | Effect on your script |
| :--- | :-------------------- |
| `-e` | The first non-zero exit fails the image build. Handle every expected failure with `\|\| true` or `\|\| warn …`. |
| `-u` | Referencing an unset variable is fatal. |
| `-x` | Every command is echoed into the build log — do not `echo` secrets. |

`/bin/sh` is bash on RHEL-family guests, but **ash** on Photon OS. Only RHEL
invokes these scripts with `sh -eux`; Ubuntu and Photon pass `bash -eux`. Write
POSIX anyway, because a script listed by more than one family may be run by
`sh`, and anything bash-specific should re-execute itself under `bash` the way
`linux/photon/system/update-packages.sh` does.

!!! note "This tree is the only copy"
    Every Linux project references its scripts as
    `${abspath(path.root)}/../../../../scripts/linux/<distribution>/…`, which
    resolves to this directory whatever working directory `packer build` was
    started from. There are no per-project copies to keep in step: change a
    script here and every project that lists it gets the change.

    Four levels up from a project directory (`builds/linux/<distribution>/<version>`)
    is the repository root.

---

## Writing one

Model a new script on `linux/rhel/prep.sh` or `linux/rhel/cleanup.sh`. Both are
idempotent, accept `--dry-run`, and explain each step in a header comment.

Minimum shape:

```bash
#!/usr/bin/env bash
#
# name.sh -- one sentence on what this does.
#
# Steps:
#   1. …
#
# Usage:
#   sudo ./name.sh [--dry-run] [--help]

set -euo pipefail

DRY_RUN=0

log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$(basename "$0")" "$*"; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

run() {
  if (( DRY_RUN )); then log "DRY-RUN would execute: $*"; return 0; fi
  log "executing: $*"
  "$@"
}
```

Rules that are not negotiable, because the build fails if they are broken:

- **Idempotent.** A retried provisioner must not duplicate a user, a key, a
  firewall rule or a repository.
- **POSIX-mode safe.** `-o pipefail` is bash-only; check it does not break under
  `sh` on the target distribution.
- **No secrets in output.** `-x` traces every command into the build log, which
  is retained.
- **Explicit failure handling.** `set -e` plus a command that legitimately
  returns non-zero (`grep` with no match, `dnf check-update`, `id` for a user that
  does not exist yet) will fail the build.
- **Do not delete `/tmp` wholesale.** Packer uploads the script to `/tmp` and
  bash reads it incrementally; `rm -rf /tmp/*` can unlink the running script.
  `prep.sh` skips its own path for this reason.

---

## Sealing

Every project's final scripts must leave the guest safe to clone:

- network returned to DHCP (`dhcp.sh`, `netreset.sh`, `dhcp-network.ps1`)
- `/etc/machine-id` truncated
- SSH host keys removed
- logs, shell history and login records cleared
- package caches cleaned, free space zeroed

A clone that keeps the build hostname, address or machine identity is a clone
whose sealing step did not run.

---

## Site-specific values

Several scripts hardcode this environment's infrastructure:

| Script | Hardcoded |
| :----- | :-------- |
| `linux/rhel/baseline-rhel9.sh` | Satellite host, subscription org, activation key, `buildops` account |
| `linux/ubuntu/apt.sh` | Package mirror |

These are not parameters. Using these builds elsewhere means editing the scripts
— see [Secrets](../docs/operations/secrets.md) for what that implies.

---

## Windows payload

The PowerShell scripts the Windows builds execute are split between this
directory and `builds/windows/files/`:

| Location | Contents |
| :------- | :------- |
| `scripts/windows/` | Initialization, preparation, VMware Tools, DHCP reset, a network template |
| `builds/windows/files/` | Guest initialization, CD payload, hardening scripts |
| `builds/windows/files/Temp/` | Vulnerability-hardening scripts, run elevated as SYSTEM |

The hardening scripts are third-party and committed as-is. They have not been
reviewed or checksum-verified as part of preparing this repository.
