# Bootstrap

Everything a fresh instance needs before it can build, that is deliberately not
in git.

The repository holds build definitions and the scripts the guests run. It does
not hold install media, plugin binaries, or built images — those are large,
third-party, or generated. A new instance therefore runs one preparation step
first, and the preparation step is the contract between the repository and the
build.

```text
checkout ──► build scripts ISO ──► upload ──► packer build
             (Joliet, per          (datastore)
              edition)
```

## What is not committed, and why

| Item | Why it is not committed | Where it comes from |
| :--- | :---------------------- | :------------------ |
| Packer plugins (~300 MB/project) | platform-specific binaries | `packer init`, from `required_plugins` |
| Terraform (~30 MB) | platform-specific binary | `fetch-terraform.ps1` / `.sh`, pinned in `terraform.lock` |
| Guest OS install ISOs | licence-restricted media | already on the datastore; the templates reference them |
| Exported OVF templates | build output | written to the Content Library |

## Running it

On a build host:

```shell
./scripts/bootstrap/prepare-windows-iso.sh \
    builds/windows/server/2025-standard-core --upload
```

`--upload` needs `govc` and `GOVC_URL`, `GOVC_DATASTORE`, `GOVC_USERNAME`,
`GOVC_PASSWORD`. Without it the ISO is built and left in
`builds/windows/packer-iso/` for you to move yourself.

The step is a plain shell script over the files in git, so a CI job can chain it
for any Windows project without manual preparation.

## Fetching Terraform

`terraform/vsphere-role` is the one module here, and it runs once, to create the
vSphere role the builds use. Terraform is therefore not on the `PATH` of a
normal build host and is not committed: `terraform.lock` pins the release and
its SHA-256, and one of these installs `terraform.exe` into `tools/terraform/`:

```shell
# Windows
./scripts/bootstrap/fetch-terraform.ps1

# Linux, macOS, or Git Bash
./scripts/bootstrap/fetch-terraform.sh
```

Both read the same lock, verify the digest before unpacking anything, and are
idempotent - a second run sees the pinned version installed and returns without
a network call. A digest mismatch stops the fetch rather than installing a
different binary under the same name.

```text
$ ./scripts/bootstrap/fetch-terraform.sh
downloading terraform_1.17.1_linux_amd64.zip
installed /path/to/docker-packer/tools/terraform
  Terraform v1.17.1
  sha256 4638628058e71a55212b1c563712eac03b902128f40740f3dc8174df12135061
```

`tools/terraform/` is gitignored; the lock and both scripts are not.

Bump `version` and every digest in `terraform.lock` together, from the release's
published `terraform_<version>_SHA256SUMS`. The lock must satisfy the
`required_version` floor in `terraform/vsphere-role/versions.tf`.

## Why the ISO is built rather than copied

The Windows templates attach a third CD carrying the first-logon scripts. That
CD has to be Joliet: Packer's `cd_files` on Linux writes Rock Ridge, which
Windows cannot read — the guest reports *"The volume does not contain a
recognized file system"* for `F:`, none of the first-logon commands run, VMware
Tools never installs, and Packer waits at `Waiting for IP...` until it times out.

See [README-WINDOWS-ISO.md](../../scripts/windows/README-WINDOWS-ISO.md) for the
full failure description and the drive-letter layout the guest depends on.
