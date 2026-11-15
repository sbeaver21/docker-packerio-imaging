# Windows build manifests

The Windows Server Packer templates write their manifest here. All ten projects
under `builds/windows/server/` — the two per-version parents (`2022`, `2025`)
and the eight per-edition projects — declare:

```hcl
manifest_path   = "${abspath(path.root)}/../../../../manifests/windows/"
manifest_output = "${local.manifest_path}${local.manifest_date}.json"
```

`path.root` is the project directory, so four levels up from
`builds/windows/server/2025` is the repository root, and the manifest lands beside
this file.

The two **desktop** projects (`builds/windows/desktop/10`, `11`) are not in this
list. They write to `${path.cwd}/manifests/` like the Linux projects, so their
manifests land in the repository root `manifests/` when the build is started from
there.

## Why this file exists

**This directory has to exist in the checkout, not just on a build host.** The
`manifest` post-processor opens its output file directly — it does not create the
parent directory. A checkout with no `manifests/windows/` fails the
post-processor with

```text
Post-processor failed: Unable to write .../manifests/windows/<timestamp>.json:
no such file or directory
```

(`no such file or directory` is the POSIX wording; on a Windows build host the
same failure ends `The system cannot find the path specified.`)

and Packer then reports

```text
Builds finished but no artifacts were created.
```

That message is misleading. The image **was** built: the OVF had already been
converted and imported into the content library and the build VM destroyed by the
time the post-processor ran. Only the manifest is missing — but the run still
exits non-zero, so a good image reads as a failed build.

Git does not track empty directories, and `.gitignore` ignores the manifests
themselves:

```gitignore
manifests/**/*.json
!manifests/**/.gitkeep
manifests/**/*.json.lock
```

so without a tracked file in here a fresh clone has no `manifests/windows/` at
all, and the first Windows build after a clone fails this way. This file is that
tracked file. **Do not delete it.** If you replace it with a `.gitkeep`, confirm
`git check-ignore -v manifests/windows/.gitkeep` reports nothing.

## The Linux and desktop projects are not affected

They write to `${path.cwd}/manifests/`, which is the repository root when the
build is started from the root as
[Build](../../docs/getting-started/build.md) describes. `manifests/.gitkeep`
keeps that directory in the clone.
