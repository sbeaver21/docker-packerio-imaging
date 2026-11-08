# Security Policy

## Reporting a vulnerability

Report security issues privately to the Platform Automation Services team
through the GitHub repository (`sbeaver21/docker-packerio-imaging`) security issue
type, or directly to the repository maintainers.

Do not open a public issue, and do not include live credentials, hostnames or
guest images in a issue. Include:

- the affected file and the commit it was found in,
- what an attacker could do with it,
- the smallest reproduction you can manage.

You should receive an acknowledgement within two business days.

---

## What this repository contains

This is infrastructure automation, not a running service. The security-relevant
surface is:

| Area | Where | Risk |
| :--- | :---- | :--- |
| vCenter credentials | `*.auto.pkrvars.hcl` in each build project | Full inventory access if leaked |
| Build account passwords | `build.auto.pkrvars.hcl`, `*.auto.pkrvars.hcl` | Console and SSH access to every image built from the template |
| Encrypted password hashes | `*_password_encrypted` variables | Offline cracking if a weak password is used |
| SSH public keys | `build_key`, `ansible_key` | Access to every clone of a template |
| Guest hardening payloads | `builds/windows/files/Temp/` | Applied to every Windows image |
| Third-party binaries | Windows hardening payloads only | Executed inside the guest during a build |

Nothing in this repository is exposed at runtime. The threat model is
**credential leakage through version control** and **supply chain substitution**
of the binary payloads.

---

## Credential handling rules

1. **Never commit a filled-in configuration file.** `.gitignore` excludes
   `*.auto.pkrvars.hcl`, `*.pkrvars.hcl` (except `*.pkrvars.hcl.example`),
   `*.tfvars` (except `*.tfvars.example`) and key material. See
   [docs/operations/secrets.md](docs/operations/secrets.md).

2. **Assume anything committed is public.** A credential removed in a later
   commit is still in history and still in every clone. If a secret reaches a
   commit, **rotate it**; do not attempt to rewrite history as the only remedy.

3. **Do not reuse the service account.** The Packer account holds create,
   snapshot and template privileges on the target cluster. Do not use a
   domain administrator or an account shared with other automation. The
   least-privilege role is defined in
   [docs/getting-started/privileges.md](docs/getting-started/privileges.md) and
   can be created with `terraform/vsphere-role`.

4. **Use encrypted passwords in answer files.** Guest installers accept a
   SHA-512 `crypt` hash. A plaintext `*_password` variable exists because the
   SSH communicator needs the literal value during the build; it must match the
   hash and must not be reused for anything else.

5. **Prefer key authentication.** `build_key` and `ansible_key`
   install public keys into the image. Empty strings are accepted, so an image
   built without them relies on password authentication alone.

---

## Known issues in the current tree

These are recorded here because they are security-adjacent and must be resolved
before this repository is treated as a clean baseline.

| Issue | Impact | Action |
| :---- | :----- | :----- |
| Live vCenter service-account credentials and build-account passwords were present in plaintext in the working tree (`builds/**/*.auto.pkrvars.hcl`). | Full compromise of the vSphere inventory and of every image built from those templates. | `.gitignore` now excludes these files. **The credentials should still be rotated**, because they existed unprotected on a build host and in any copy of this tree. |
| The Windows hardening payloads in `builds/windows/files/Temp/` are unverified third-party scripts executed with `-Verb RunAs` during the build. | A tampered payload runs as SYSTEM in every Windows image. | Review the scripts and pin their checksums before relying on them. |
| Third-party payloads are committed to the repository. | A modified file is trusted by the build. | Review the hardening scripts under `builds/windows/files/Temp/` and pin their checksums. |
| `vsphere_insecure_connection = true` is set in the working configuration. | The vCenter TLS certificate is not validated, so a machine-in-the-middle can capture the service-account password. | Install the vCenter CA certificate on the build host and set this to `false`. |

---

## Supported versions

Only the current `main` branch is maintained. There are no released versions;
builds are made from the branch.
