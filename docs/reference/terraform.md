# Terraform role

Terraform is **not** used by the build pipeline. One module supports it: it
creates the least-privilege vSphere role the builds run under, so the Packer
service account does not need administrator rights.

Terraform `>= 1.9.5`, vSphere provider `>= 2.8.3`.

The version used to check this module is **1.17.1**, pinned with its SHA-256 in
`scripts/bootstrap/terraform.lock` and installed by
`scripts/bootstrap/fetch-terraform.ps1` (Windows) or `fetch-terraform.sh`
(everything else) into `tools/terraform/`. Using the pinned binary rather than
whatever is on `PATH` is what makes a check reproducible; `tools/terraform/` is
gitignored, the lock is not.

---

## `terraform/vsphere-role`

Creates (or updates) a vSphere role holding exactly the privileges Packer needs.

```text
terraform/vsphere-role/
├── main.tf
├── variables.tf
├── versions.tf
├── terraform.tfvars.example
└── .terraform.lock.hcl           committed: provider version and package hashes
```

`main.tf` is a single resource:

```hcl
resource "vsphere_role" "packer-vsphere" {
  name            = var.packer_vsphere_role
  role_privileges = var.packer_vsphere_privileges
}
```

### Usage

```shell
cd terraform/vsphere-role
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Variables

| Variable | Type | Notes |
| :------- | :--- | :---- |
| `vsphere_server` | string | vCenter FQDN |
| `vsphere_username` | string, sensitive | Needs permission to create roles — this is an administrative operation |
| `vsphere_password` | string, sensitive | |
| `vsphere_insecure` | bool | Default `false` |
| `packer_vsphere_role` | string | Role name, e.g. `Packer to vSphere Integration` |
| `packer_vsphere_privileges` | list(string) | The privilege set |

The privilege list in the example file is the authoritative one and matches
[Privileges](../getting-started/privileges.md). It includes
`ContentLibrary.AddLibraryItem`, `ContentLibrary.UpdateLibraryItem`,
`Cryptographer.Access` (required to upload `packer_cache`),
`Cryptographer.Encrypt` (required for vTPM), `VApp.Export` and the
`VirtualMachine.*` set.

!!! tip "Deploying it for the first time"
    [Deploy the vSphere role](../operations/terraform-role-deploy.md) walks
    through it end to end: fetching the pinned Terraform, filling in
    `terraform.tfvars` value by value, reading the plan, assigning the role to
    the service account, and a troubleshooting table for the failures that
    actually happen.

!!! note "Creating a role is not least-privilege"
    This is the one part of the repository that needs an administrator. Run it
    once, from an account with role-management rights, then remove those rights
    and use the created role for the service account.

---

## Conventions

- **One directory, one root module.** No shared modules and no remote state —
  this is a one-off administrative helper, not a deployment framework.
- **`terraform.tfvars` is gitignored.** The module ships
  `terraform.tfvars.example`; `.gitignore` excludes `*.tfvars` and keeps
  `*.tfvars.example`.
- **`.terraform/` and `*.tfstate` are gitignored.** State can contain the
  vCenter password in clear text.
- **`.terraform.lock.hcl` is committed.** It records `hashicorp/vsphere` 2.12.0
  and the SHA-256 of the package for `windows_amd64`, `linux_amd64`,
  `linux_arm64`, `darwin_amd64` and `darwin_arm64`. `init` then reuses that
  version instead of resolving `>= 2.8.3` again, which is what makes the check
  here reproducible on a different host.
- **`versions.tf` pins the provider floor**, not a range, so a plan does not
  silently pick up a new provider major version.

---

## Checking a change

```shell
./scripts/bootstrap/fetch-terraform.sh          # once; Windows: the .ps1

tools/terraform/terraform fmt -check -recursive terraform

cd terraform/vsphere-role
../../tools/terraform/terraform init -backend=false
../../tools/terraform/terraform validate
```

Both were run against Terraform 1.17.1 with this repository as it stands:
`fmt -check` is clean and `validate` reports *Success! The configuration is
valid.*

`validate` needs no vCenter connection. It catches undeclared variables, missing
required arguments and type errors — which is most of what goes wrong in these
files.

!!! note "`init` prints a provider deprecation warning"
    The registry warns that `hashicorp/vsphere` has moved to `vmware/vsphere`
    and asks for `required_providers` to be updated. The module still
    initialises and validates; the warning is a naming migration, not an error.
    Changing the provider source is a separate, deliberate change: it downloads
    the provider again and regenerates the dependency lock file.
