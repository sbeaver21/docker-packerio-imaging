# Deploy the vSphere role

The Packer builds need a set of vSphere privileges. This page takes you from
nothing to a service account that can build images without administrator rights,
using the one Terraform module in this repository.

Run it **once per vCenter Server**, before the first build. It takes about ten
minutes, of which most is reading the plan.

```text
fetch Terraform ──► write terraform.tfvars ──► init ──► validate ──► plan ──► apply
        │                                                    │
        └── pinned, digest-verified                          └── no vCenter contact
                                                                  until here
```

---

## Before you start

| Requirement | Detail |
| :---------- | :----- |
| vCenter | 7.0 Update 3D or later, or 8.0 or later |
| An administrative account | Creating a role is an SSO-level operation. `administrator@vsphere.local` or an equivalent |
| A build host | Windows, Linux or macOS. This is where Terraform runs; it needs HTTPS to vCenter, port 443 |
| Network | `releases.hashicorp.com` (to fetch Terraform) and `registry.terraform.io` (to fetch the provider) |

You do **not** need Packer installed to do this, and you do not need to have
configured a build yet.

!!! warning "This is the only step that needs administrator rights"
    Everything else in this repository runs as the least-privilege role this page
    creates. Keep the administrative credentials out of the build host's
    `*.auto.pkrvars.hcl` files — those hold the *service account*, not this one.

---

## Step 1 — Install Terraform

Do not install Terraform from a package manager for this. The version is pinned
so that the plan you review is the plan that was tested:

```shell
# Linux, macOS, Git Bash
./scripts/bootstrap/fetch-terraform.sh

# Windows PowerShell
./scripts/bootstrap/fetch-terraform.ps1
```

Expected output:

```text
downloading terraform_1.17.1_linux_amd64.zip
installed /path/to/docker-packer/tools/terraform
  Terraform v1.17.1
  sha256 4638628058e71a55212b1c563712eac03b902128f40740f3dc8174df12135061
```

The script verifies the download against the SHA-256 in
`scripts/bootstrap/terraform.lock` and refuses to install on a mismatch. It
installs to `tools/terraform/`, which is gitignored; `scripts/bootstrap/README.md`
covers the fetcher in full.

Confirm:

=== "Linux, macOS, Git Bash"

    ```shell
    tools/terraform/terraform version
    ```

=== "Windows PowerShell"

    ```powershell
    .\tools\terraform\terraform.exe version
    ```

```text
Terraform v1.17.1
on linux_amd64
```

!!! tip "Every command below uses the vendored binary"
    `terraform` alone is whatever happens to be on your `PATH`. Use
    `tools/terraform/terraform` (or `.\tools\terraform\terraform.exe`) so the
    version matches the lock. The rest of this page writes `terraform` for
    brevity — substitute the path.

---

## Step 2 — Create the variable file

```shell
cd terraform/vsphere-role
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` is gitignored, because it holds the administrative password.
Open it and set each value.

### What each value must be

| Variable | What to put | How to find it |
| :------- | :---------- | :------------- |
| `vsphere_server` | vCenter **FQDN** | vSphere Client → the address bar. Use the name, not an IP: the provider passes it to the appliance certificate and SSO login |
| `vsphere_username` | An account that can create roles | `administrator@vsphere.local` for a default SSO domain, or `<user>@<domain>` for an integrated one |
| `vsphere_password` | That account's password | — |
| `vsphere_insecure` | `true` for the default self-signed appliance certificate; `false` only if vCenter presents a certificate the host trusts | vSphere Client → Administration → Certificates |
| `packer_vsphere_role` | The role name to create. Leave the default unless it collides with an existing role | vSphere Client → Administration → Access Control → Roles |
| `packer_vsphere_privileges` | **Leave exactly as it is** | Matches [Privileges](../getting-started/privileges.md) |

A completed file, with the password as the only value you must invent:

```hcl
vsphere_server   = "sfo-m01-vc01.sfo.example.com"
vsphere_username = "administrator@vsphere.local"
vsphere_password = "<the administrative password>"
vsphere_insecure = true

packer_vsphere_role = "Packer to vSphere Integration"

packer_vsphere_privileges = [
  # ... leave the 35 entries from the example file unchanged ...
]
```

!!! danger "Quotes and special characters in the password"
    `terraform.tfvars` is HCL, not a shell script. The password goes inside
    double quotes; a literal `\` or `"` in the password must be escaped as `\\`
    or `\"`. A password containing `$` is safe — HCL does not expand it.

### Why not trim the privilege list

Two of the 35 are easy to remove and produce a build that fails an hour in:

| Privilege | Needed for | Symptom when missing |
| :-------- | :--------- | :------------------- |
| `Cryptographer.Encrypt` | vTPM, used by the Windows 11 builds | VM creation fails immediately |
| `Cryptographer.Access` | Uploading `packer_cache` to the datastore | Build fails during ISO upload |

`VApp.Export`, `ContentLibrary.AddLibraryItem` and
`ContentLibrary.UpdateLibraryItem` are the same: they are only used at the end
of a build, so they are only missed after the install has already run.

---

## Step 3 — Check the configuration without touching vCenter

Both commands work offline, apart from downloading the provider once.

```shell
terraform init -backend=false
terraform validate
```

Expected:

```text
Initializing provider plugins...
- Reusing version 2.12.0 of hashicorp/vsphere from the dependency lock file
- Installing hashicorp/vsphere v2.12.0...
- Installed hashicorp/vsphere v2.12.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

*Reusing* is the line to look for. `.terraform.lock.hcl` is committed, so this
resolves 2.12.0 on your host exactly as it did on the host this was checked on,
rather than taking the newest provider that satisfies `>= 2.8.3`. If you see
`Finding hashicorp/vsphere versions matching` instead, the lock file is missing
from your checkout.

```text
Success! The configuration is valid.
```

!!! note "A provider deprecation warning is expected"
    The registry reports that `hashicorp/vsphere` has moved to `vmware/vsphere`.
    Initialisation and validation still succeed; the warning is a naming
    migration. Changing it is a separate, deliberate change.

If `validate` fails instead, it names the file and line. The common causes are a
missing `=` or a typo in a variable name — note that an *unknown* variable name
in `terraform.tfvars` is a plan-time warning, not a validate-time error, so read
the plan output in the next step too.

---

## Step 4 — Review the plan

This is the first command that contacts vCenter. It creates nothing.

```shell
terraform plan -out=tfplan
```

Expected, at the end:

```text
Plan: 1 to add, 0 to change, 0 to destroy.

────────────────────────────────────────────────────────────

Saved the plan to: tfplan
```

The single resource is the role. Read the block above that summary and check:

- `+ resource "vsphere_role" "packer-vsphere"` — one resource, nothing else.
- `name = "Packer to vSphere Integration"` — the name you set.
- `role_privileges` lists 35 privileges. **Count them.** A list silently
  truncated by a missing comma is a plan that succeeds and a build that fails.

If the plan shows `0 to add` and `1 to change`, a role with that name already
exists and Terraform will update its privileges in place, which is what you want
when the repository's privilege list changes.

!!! warning "A warning in the plan output matters"
    ```text
    Warning: Value for undeclared variable
    ```
    means `terraform.tfvars` sets a variable `variables.tf` does not declare. It
    is ignored. If you see it, delete that line from your copy — it is not
    coming from the example in this repository.

---

## Step 5 — Apply

```shell
terraform apply tfplan
```

Expected:

```text
vsphere_role.packer-vsphere: Creating...
vsphere_role.packer-vsphere: Creation complete after 3s [id=role-42]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

The role now exists on the vCenter Server. It is global: not scoped to a data
center, cluster or folder. Assignment is what scopes it.

!!! note "Apply from the saved plan"
    `terraform apply tfplan` applies exactly what you reviewed. `terraform apply`
    with no argument re-plans and asks again — fine, but it defeats the point of
    having read the plan.

---

## Step 6 — Confirm the role exists

=== "vSphere Client"

    **Administration → Access Control → Roles →** `Packer to vSphere Integration`

    Open it and confirm the privilege count in the panel on the right. It should
    read 35. `System.Anonymous`, `System.Read` and `System.View` show under a
    collapsed *System* group, so the visible list is shorter than 35 — expand
    every group before concluding one is missing.

=== "govc"

    ```shell
    govc role.ls 'Packer to vSphere Integration'
    ```

=== "Terraform"

    ```shell
    terraform state show vsphere_role.packer-vsphere
    terraform output 2>/dev/null || true
    ```

    If you later delete the role by hand, this command fails — which is the
    fastest way to find out that someone did.

---

## Step 7 — Assign the role to the service account

Creating the role grants nothing. It has to be assigned, and the content library
is the part that catches people out: `ContentLibrary.AddLibraryItem` and
`ContentLibrary.UpdateLibraryItem` are checked against the library, which lives
outside the cluster and data center tree.

The documented route is **Global Permissions**, which covers the content library
by construction. This is also what
[Least Privilege](../getting-started/privileges.md) describes.

1. **Create the service account**, if it does not exist: **Administration** →
   **Single Sign On** → **Users and Groups** → **Users**, pick the domain, **Add**.
   A dedicated `svc-packer-vsphere@<domain>` is the intent; do not reuse the
   administrator.
2. **Administration** → **Access Control** → **Global Permissions** → **Add
   permission**.
3. **User/Group**: the service account. **Role**: `Packer to vSphere Integration`.
   Tick **Propagate to children**. **OK**.

Then narrow it, if the vCenter hosts more than one domain. Global permissions
grant the role everywhere on that vCenter; to keep Packer out of, say, a
management domain, override the role there:

1. **Hosts and Clusters** → select the vCenter → **Permissions** tab.
2. Select the service account → **Edit**.
3. **Role**: **No Access**, tick **Propagate to children**, **OK**.

!!! warning "Datastores outside the assigned scope"
    The builds read ISOs from a datastore and write the OVF export somewhere.
    If those live in a domain you just set to **No Access**, the build fails on
    the upload. `Datastore.AllocateSpace`, `Datastore.Browse` and
    `Datastore.FileManagement` are checked against the datastore object, so the
    role has to reach it.

### Verify the assignment

=== "vSphere Client"

    **Administration** → **Access Control** → **Global Permissions**. The service
    account should be listed with the new role and *Propagate* set. If you narrowed
    the scope, check the **Permissions** tab of the object you narrowed it on as
    well.

=== "PowerCLI"

    ```powershell
    Connect-VIServer -Server sfo-m01-vc01.sfo.example.com
    Get-VIPermission | Where-Object { $_.Principal -eq 'svc-packer@vsphere.local' } |
        Format-Table Principal, Role, Entity, Propagate
    ```

---

## Step 8 — Prove it with a build

The role is correct when a build runs under it and completes. A validation pass
proves nothing about privileges: `packer validate` never contacts vCenter.

1. Put the **service account** credentials in the build's
   `vsphere.auto.pkrvars.hcl` — not the administrator's.
2. Validate, then build the smallest project you have:

   ```shell
   tools/terraform/terraform --version   # still the pinned binary, for reference
   packer init     builds/linux/photon/5
   packer validate builds/linux/photon/5
   packer build    builds/linux/photon/5
   ```

3. Watch the end of the build. The privilege failures that survive to this stage
   are all in the publish step:

   | Failure | Missing privilege |
   | :------ | :---------------- |
   | `Permission to perform this operation was denied` during ISO upload | `Datastore.FileManagement` or `Cryptographer.Access` |
   | `Cannot create a role` / export failure at the end | `VApp.Export` |
   | Content library update denied | `ContentLibrary.UpdateLibraryItem`, usually because the global permission was replaced by a narrower one that does not reach the library |

4. Once it builds, the administrator account is no longer needed for this
   vCenter.

---

## Changing the privilege list later

The privilege list is the contract between this repository and the role. When a
build starts using a new operation, the list changes and the role is updated —
never repaired by hand, because a hand-edited role is not recorded anywhere.

```shell
cd terraform/vsphere-role
git pull
terraform plan -out=tfplan     # expect: 0 to add, 1 to change, 0 to destroy
terraform apply tfplan
```

The plan shows the added and removed privileges by name. Read them: an
unintended `-` removes a privilege an existing build depends on, and the failure
appears at the end of the next build, not here.

Renaming the role — changing `packer_vsphere_role` — is destructive: Terraform
creates the new role and deletes the old one, and every assignment of the old
role is left pointing at nothing. Reassign the service account afterwards.

---

## Removing it

Only if the vCenter is being retired or the account is being decommissioned. The
role cannot be destroyed while something is assigned to it.

```shell
cd terraform/vsphere-role
terraform destroy
```

```text
Plan: 0 to add, 0 to change, 1 to destroy.
...
Destroy complete! Resources: 1 destroyed.
```

If the destroy fails with a permission or in-use error, the assignment is still
there: remove the global permission (and any narrower override) from the service
account first — Step 7 in reverse — then retry.

---

## Troubleshooting

| Symptom | Cause | Fix |
| :------ | :---- | :-- |
| `Error: Missing required provider` | `terraform validate` or `plan` run before `init`, or `.terraform/` was deleted | Run `terraform init` again |
| `Error: Failed to instantiate provider … to obtain schema` | A stale provider binary in `.terraform/providers` | `rm -rf .terraform .terraform.lock.hcl` then `terraform init` |
| `Warning: Value for undeclared variable` | `terraform.tfvars` sets a variable `variables.tf` does not declare | Delete the line |
| `Error: Invalid provider configuration` / cannot log in | `vsphere_server` is an IP, a short name, or an ESXi host instead of the vCenter FQDN | Use the vCenter FQDN |
| `x509: certificate signed by unknown authority` | Self-signed appliance certificate with `vsphere_insecure = false` | Set `vsphere_insecure = true` |
| `ServerFaultCode: Permission to perform this operation was denied` on apply | The account can log in but cannot create roles | Use an account with the administrator role on the root folder |
| `Error: Role already exists` | A role with that name exists and was not created by this state | Import it (`terraform import vsphere_role.packer-vsphere <role-id>`) or change `packer_vsphere_role` |
| Build gets through install, then fails at publish | The role does not reach the content library | Use the global permission, or add the role on the library object explicitly |

---

## What was created

| Object | Scope | Recorded in |
| :----- | :---- | :---------- |
| vSphere role `Packer to vSphere Integration` | vCenter, global | `terraform.tfstate`, alongside this module |
| Global permission for the service account | The whole vCenter, unless narrowed | vCenter only |

State and `.terraform/` are gitignored — the state can contain the administrative
password. Back up `terraform.tfstate` somewhere safe before an apply that changes
the role, or re-import the role if it is lost.
