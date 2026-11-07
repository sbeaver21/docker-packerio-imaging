# terraform

Terraform is not part of the build pipeline. This one module supports it: it
creates the vSphere role the Packer builds run under.

```text
terraform/
└── vsphere-role/                  the least-privilege role for the service account
```

Terraform `>= 1.9.5`, vSphere provider `>= 2.8.3`.

---

## `vsphere-role`

Creates a vSphere role with exactly the privileges the builds need, so the
service account does not need administrator rights.

```shell
cd terraform/vsphere-role
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The privilege list is in `terraform.tfvars.example` and is the authoritative one;
it is also reproduced in
[docs/getting-started/privileges.md](../docs/getting-started/privileges.md).

!!! note "This is the one administrative operation"
    Creating a role requires role-management rights. Run it once, then remove
    those rights and assign the new role to the Packer service account.

Two privileges are easy to trim by mistake and hard to diagnose:

- `Cryptographer.Encrypt` — vTPM, used by the Windows 11 builds
- `Cryptographer.Access` — uploading `packer_cache` to the datastore

---

## Conventions

| Rule | Why |
| :--- | :-- |
| One directory, one root module | No shared modules, no remote state. These are examples. |
| `terraform.tfvars` is gitignored | It holds the vCenter password. Only `.example` files are committed. |
| State is gitignored | `.terraform/`, `*.tfstate`, `*.tfstate.*`. State can contain the password in clear text. |
| `.terraform.lock.hcl` **is** committed | It pins `hashicorp/vsphere` 2.12.0 and carries the package digest for five platforms, so a Linux or macOS build host resolves the same provider this was checked against. |
| `versions.tf` pins a floor | So a plan does not silently take a new provider major version. |
| `variables.tf` is the contract | Every input is declared with a type; passwords are `sensitive = true`. |

---

## Checking a change

```shell
terraform fmt -check -recursive terraform

cd terraform/vsphere-role
terraform init -backend=false
terraform validate
```

`validate` needs no vCenter connection, and catches undeclared variables, missing
required arguments and type errors — most of what goes wrong here.

`init` reuses the version recorded in `.terraform.lock.hcl` rather than resolving
the constraint again:

```text
- Reusing version 2.12.0 of hashicorp/vsphere from the dependency lock file
```

Regenerate that file only after deliberately moving the provider in
`versions.tf`:

```shell
cd terraform/vsphere-role
../../tools/terraform/terraform providers lock \
    -platform=windows_amd64 -platform=linux_amd64 -platform=linux_arm64 \
    -platform=darwin_amd64  -platform=darwin_arm64
```

The reference for every variable is in
[docs/reference/terraform.md](../docs/reference/terraform.md). The step-by-step
runbook — what each value must be, reading the plan, assigning the role in
vCenter, and what to do when an apply or a build fails — is
[docs/operations/terraform-role-deploy.md](../docs/operations/terraform-role-deploy.md).
