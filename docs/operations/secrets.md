# Credential Handling

The build configuration in this repository carries live credentials. This page
is what to do about that: what is excluded from version control, where the real
values live, and how to handle an exposure.

---

## What is sensitive, and where it lives

| Credential | Variable | File |
| :--------- | :------- | :--- |
| vCenter service account | `vsphere_username`, `vsphere_password` | `vsphere.auto.pkrvars.hcl`, or `rhel.auto.pkrvars.hcl` |
| Build account | `build_username`, `build_password`, `build_password_encrypted` | `build.auto.pkrvars.hcl`, `win20xx.auto.pkrvars.hcl`, `rhel.auto.pkrvars.hcl` |
| Build account | `build_username`, `build_password`, `build_password_encrypted` | `build.auto.pkrvars.hcl` (Photon, Ubuntu) |
| Site automation account | `auto_username`, `auto_password`, `auto_password_encrypted` | `build.auto.pkrvars.hcl` (Photon, Ubuntu) |
| Root hash | `root_password_encrypted` | `*.auto.pkrvars.hcl` (Photon, Ubuntu) |
| SSH public keys | `build_key`, `ansible_key`, `auto_key` | `build.auto.pkrvars.hcl` |
| Red Hat subscription | `rhsm_username`, `rhsm_password` | `rhel.auto.pkrvars.hcl` |
| SUSE subscription | `scc_username`, `scc_password` | `*.auto.pkrvars.hcl` (SLES) |
| Terraform vCenter account | `vsphere_username`, `vsphere_password` | `terraform.tfvars` |
| Windows product key | `vm_inst_os_key`, `vm_inst_os_key_pro` | `win20xx.auto.pkrvars.hcl` |

A public key is not secret. Its presence in this table is because the variable is
`sensitive`-flagged alongside the password in the same file.

---

## What is excluded

`.gitignore` excludes the files, not the variables:

```gitignore
*.auto.pkrvars.hcl      # Packer loads these automatically; they hold the real values
*.pkrvars.hcl           # explicit override files
!*.pkrvars.hcl.example  # the committed examples
*.tfvars                # Terraform values
!*.tfvars.example
*.pem
*.key
*.pfx
id_rsa*
id_ecdsa*
```

This was added when the repository was prepared for its first commit. Before
that, the working tree contained the vCenter service-account password and the
build-account passwords in plaintext in
`builds/**/*.auto.pkrvars.hcl`.

!!! danger "The credentials must be rotated"
    Adding the files to `.gitignore` prevents a future leak. It does not undo
    the exposure. Those credentials existed unprotected on the build host, in
    any copy of the tree, and in any backup of either.

Rotate, in this order:

1. The vCenter service account password.
2. The build account password on every image already published — those images
   carry it in their answer files and password hashes.
3. The site automation accounts, likewise.
4. Any SSH key pair whose **private** half was ever stored next to the public
   half in this tree.

Rotating the vCenter account is the priority: it holds create, snapshot and
template rights across the cluster.

---

## Where the real values should live

### Option 1 — a file on the build host (default)

```text
builds/linux/photon/5/
├── build.auto.pkrvars.hcl       ← local, gitignored
├── common.auto.pkrvars.hcl      ← local, gitignored
├── photon.auto.pkrvars.hcl      ← local, gitignored
├── storage.auto.pkrvars.hcl     ← local, gitignored
└── vsphere.auto.pkrvars.hcl     ← local, gitignored
```

Simple, and how these builds have been run. The weakness is that the file is
readable by anyone with access to the build host, and it is easy to copy
somewhere it should not go.

### Option 2 — environment variables (recommended for the password)

Any variable can be supplied as `PKR_VAR_<name>`, and that takes precedence over
a var file:

```shell
export PKR_VAR_vsphere_password='…'
packer build builds/linux/photon/5
```

Keep the non-secret values in the var file and only the password in the
environment. On Windows:

```powershell
$env:PKR_VAR_vsphere_password = '…'
```

This keeps the password out of every file on disk. It does not keep it out of the
process environment, which is visible to the same user.

### Option 3 — a secret store

For a shared or automated build host, read the value at run time rather than
storing it:

```shell
export PKR_VAR_vsphere_password="$(vault kv get -field=password secret/packer)"
```

Nothing in this repository implements that today; there is no wrapper script. It
is the right direction if builds move into a pipeline.

---

## The secrets that are not in a var file

These are committed, and each is a deliberate decision worth knowing about:

| Item | Where | Risk |
| :--- | :---- | :--- |
| Satellite host, organisation and activation key | `scripts/linux/rhel/baseline-rhel9.sh` | The activation key is not a password, but it grants entitlement registration to anyone who can reach the Satellite |
| NTP servers, DNS resolvers | `baseline-rhel9.sh`, `*.auto.pkrvars.hcl` | Infrastructure disclosure only |
| Windows hardening scripts | `builds/windows/files/Temp/` | Executed as SYSTEM on every Windows image |

For the last two: verify the binaries against their publisher's checksums, and
review the PowerShell scripts before relying on any image built from this tree.
Neither has been verified as part of preparing this repository.

---

## If a secret is committed

**Rotate first.** History rewriting is secondary and does not help on its own,
because the value has already been read by everyone with a clone.

1. Rotate the credential.
2. Remove the file from the working tree:
   `git rm --cached <file>` (keeps your local copy, untracks it).
3. Confirm the ignore rule matches:
   `git check-ignore -v <file>`.
4. Only then decide whether history matters. If the repository has not been
   shared, rewriting is safe:

   ```shell
   git filter-repo --path <file> --invert-paths
   ```

   If it has been shared, rewriting breaks every clone and does not undo the
   exposure. Rotate and move on.

### The check before every push

```shell
git status --short                 # is anything unexpected staged?
git diff --cached --name-only      # full list of files in the commit
git check-ignore -v builds/linux/photon/5/vsphere.auto.pkrvars.hcl
```

A pre-commit hook is not configured in this repository. If credentials are
committed a second time, the ignore rules were not the problem.

---

## Answer-file passwords

The guest installer receives a hash; the communicator receives the literal
password. Both must describe the same password, and the hash must use SHA-512:

```shell
SALT=$(openssl rand -base64 6)
echo -n '«the password»' | openssl passwd -6 -stdin -salt "$SALT"
```

The `$6$` prefix is what makes the installer accept it. A hash generated with
`-1` (MD5) or `-5` (SHA-256) is silently ignored by some installers, and the
build then waits for an IP address that never appears.

A plaintext `*_password` variable is unavoidable for the SSH and WinRM
communicators. Its consequence is that the password is present on the build host
in memory and, if it is in a var file, on disk.

---

## Least privilege

The vCenter account is the highest-value credential here. See
[Privileges](../getting-started/privileges.md) for the exact role, which
`terraform/vsphere-role` creates. Do not use `administrator@vsphere.local`, and
do not share the account with other automation.

Two privileges in that role are worth understanding before you trim it:

- `Cryptographer.Encrypt` — required for vTPM, which the Windows 11 builds use.
- `Cryptographer.Access` — required to upload `packer_cache` to the datastore.

Removing either makes some builds fail in a way that does not mention
privileges.
