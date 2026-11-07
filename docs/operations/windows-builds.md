# Windows Server builds

The eight Windows Server images — 2022, 2025 × Standard/Datacenter ×
Core/Desktop Experience — depend on a contract between the template and the
guest that is easy to break and hard to diagnose. This page records the contract,
the failure that results when it is broken, and how it is verified.

## The drive letters are part of the interface

The answer file's first-logon commands address the build media by drive letter,
so the order the template attaches devices in *is* the interface:

| Drive | Contents | Attached by |
| :---- | :------- | :---------- |
| `D:` | Windows Server install ISO | `iso_paths[0]` |
| `E:` | VMware Tools ISO (`setup.exe`) | `iso_paths[1]` |
| `F:` | first-logon scripts, `CD\`, `Temp\` | `iso_paths[2]` |

```hcl
iso_paths = [
  "[${ var.common_iso_datastore }] ${ var.iso_datastore_path }/${ var.iso_file }",
  "[] /vmimages/tools-isoimages/windows.iso",
  "[example-datastore] packer-iso/win2025-standard-core-scripts.iso"
]
```

`windows-vmtools.ps1` expects `E:`. `win-init.ps1` reads its first-logon scripts and
timezone wheel from `$SourceRoot`, default `F:\`, and stages the `CD` and `Temp`
directories from there.

## The failure: an unreadable F

If the third ISO is produced by Packer's `cd_files`, the images work on a
Windows build host and hang on a Linux one. On Linux, Packer writes `cd_files`
with xorriso in Rock Ridge mode; Windows cannot read that volume:

```text
C:\> dir f:
The volume does not contain a recognized file system.
```

Every first-logon command then fails in silence, VMware Tools is never
installed, the guest never reports an IP, and Packer waits until it gives up:

```text
==> vsphere-iso.windows-server-2025-standard-core: Waiting for IP...
```

The scripts themselves are fine — run them by hand and they work. Only the
volume they arrive on is wrong.

## The contract

The third ISO is built by `scripts/bootstrap/prepare-windows-iso.sh`, which
uses `-J` (Joliet) and additionally `-R`. Joliet is what Windows reads; Rock
Ridge alone is ignored by it.

The builder refuses to make an image it knows Windows cannot read:

```shell
$ ./scripts/bootstrap/prepare-windows-iso.sh builds/windows/server/2025-standard-core
built builds/windows/packer-iso/win2025-standard-core-scripts.iso (46211072 bytes, 11 entries)
joliet: present (sector 17, escape %/E)
```

`scripts/bootstrap/check-joliet.sh` is the check on its own, for an ISO built
elsewhere:

```shell
$ ./scripts/bootstrap/check-joliet.sh builds/windows/packer-iso/win2025-standard-core-scripts.iso
joliet: present (sector 17, escape %/E)

$ ./scripts/bootstrap/check-joliet.sh /tmp/rock-ridge-only.iso
joliet: ABSENT - Windows cannot read this volume
```

It walks the ISO 9660 volume descriptor set from sector 16 looking for a
supplementary descriptor (type 2) carrying the Joliet escape sequence `%/@`,
`%/C` or `%/E`. Do not try to answer this with `xorriso -pvd_info | grep -i
joliet` — that prints only the primary descriptor and fails on a good image.

## What has to be on F

`builds/windows/files/` is the payload. One file in it is a wheel rather than a
script, and it is fetched rather than committed:

| File | Read by | Source |
| :--- | :------ | :----- |
| `tzdata-2026.5-py2.py3-none-any.whl` | `win-init.ps1` | PyPI (pinned by filename only) |

!!! warning "No fetcher is committed yet"
    Place the wheel in `builds/windows/files/` before building. There is no
    `scripts/bootstrap/fetch-windows-payload.sh` and no
    `scripts/bootstrap/payload.lock` in this repository, so the download is
    manual and its digest is not verified: fetch
    `tzdata-2026.5-py2.py3-none-any.whl` from PyPI yourself, and check the
    SHA-256 against the published value before putting it there. A committed
    fetcher with a pinned digest is the obvious next step.

## Verification

A build is proven by reaching the guest, not by the template validating:

1. `packer validate` passes for the project.
2. The build log passes `Waiting for IP...` — `Connected to SSH!` follows.
3. `Get-VM <name> | Select Guest` reports `guestToolsRunning` and an IP.
4. The build completes through `Converting virtual machine to template` and the
   OVF appears in the content library.
5. The Windows Update provisioner runs — it is the longest stage at roughly
   26 GB, and it dominates the runtime.

All eight editions were taken through those five steps against this repository.

## Answer file settings that matter

- `<RequiresUserInput>false</RequiresUserInput>` on the `Set-ExecutionPolicy`
  commands. With `true`, Windows stops and waits for a user before running the
  rest of the chain, so nothing after it runs and the build hangs exactly as it
  does when `F:` is unreadable.
- First-logon commands address `F:\` literally. If the ISO build changes the
  device order the letters shift, and every one of them breaks.

## Related

- `scripts/windows/README-WINDOWS-ISO.md` — the ISO layout and the payload list.
- `scripts/bootstrap/` — fetching the payload on a new instance.
- [Validation](validation.md) — the wider validation report.
