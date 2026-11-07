# Ansible

Playbooks and roles that configure a Linux or Windows guest **after** the
unattended install, as a Packer provisioner.

Used by the AlmaLinux, CentOS Stream, Debian, Fedora, Oracle Linux, Rocky Linux
and SLES projects. The RHEL, Ubuntu and Photon projects use the scripts in
[`../scripts/`](../scripts/) instead.

---

## Contents

```text
ansible/
├── ansible.cfg                 connection defaults and interpreter
├── linux-playbook.yml          entry point for Linux guests
├── linux-requirements.yml      Galaxy collections for the Linux play
├── windows-playbook.yml        entry point for Windows guests
├── windows-requirements.yml    Galaxy collections for the Windows play
└── roles/
    ├── base/                   patch and install the package set
    ├── users/                  create the site accounts
    ├── configure/              hostname, network, time, SNMP
    └── clean/                  seal the guest before capture
```

Each role has `tasks/main.yml` that dispatches on the guest's OS family:

| Role | `debian` | `redhat` | `photon` | `suse` | `windows` |
| :--- | :------: | :------: | :------: | :----: | :-------: |
| `base` | yes | yes | yes | yes | yes |
| `users` | via `linux.yml` | via `linux.yml` | via `linux.yml` | via `linux.yml` | — |
| `configure` | yes | yes | yes | yes | yes |
| `clean` | yes | yes | yes | yes | — |

`users` has a single `linux.yml`, because the account model is the same across
the Linux families. `clean` has no Windows task file: the Windows projects do
their sealing in PowerShell.

---

## Entry points

### `linux-playbook.yml`

```yaml
- name: Playbook for Linux
  become: true
  become_method: ansible.builtin.sudo
  gather_facts: true
  hosts: all
  vars:
    enable_cloudinit: false
  roles:
    - base
    - users
    - configure
    - clean
```

The order is behaviour, not style. `clean` **must** be last: it truncates the
machine-id, removes SSH host keys and clears logs, and anything running after it
recreates what it removed.

`become: true` is required — every role writes to `/etc` or installs packages.

### `windows-playbook.yml`

```yaml
- name: Playbook for Microsoft Windows
  gather_facts: true
  hosts: all
  roles:
    - base
    - configure
```

No `become`: the WinRM connection already runs elevated. No `clean`: sealing is
done by the PowerShell provisioners, not by a role.

---

## How Packer invokes them

The provisioner supplies an inventory of one host and passes the variables the
playbook needs:

```hcl
provisioner "ansible" {
  playbook_file = "${path.cwd}/ansible/linux-playbook.yml"
  galaxy_file   = "${path.cwd}/ansible/linux-requirements.yml"
  roles_path    = "${path.cwd}/ansible/roles"
  user          = var.build_username
  use_proxy     = false
  extra_arguments = [
    "--extra-vars", "ansible_user=${var.build_username}",
    "--extra-vars", "ansible_password=${var.build_password}",
    "--extra-vars", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'",
  ]
}
```

`${path.cwd}` is the directory Packer was started from, so these builds expect
`packer build` to be run from the repository root.

The Ansible provisioner runs **on the build host**, not in the guest. That means
`ansible-core` must be installed where Packer runs — see
[Requirements](../docs/getting-started/requirements.md).

---

## `ansible.cfg`

```ini
[defaults]
stdout_callback = default
display_skipped_hosts = false
ansible_python_interpreter = /usr/bin/python3

[ssh_connection]
ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
scp_extra_args = "-O"
```

Two settings matter:

- **`ansible_python_interpreter = /usr/bin/python3`** — pinned, because a fresh
  guest may not have `python3` on `PATH` yet, and Ansible's auto-discovery then
  fails before the first task runs.
- **`HostKeyAlgorithms=+ssh-rsa` and `PubkeyAcceptedKeyTypes=+ssh-rsa`** —
  re-enable the RSA SHA-1 algorithms that older guests (and some OpenSSH
  versions shipped in RHEL 8) still negotiate. Without them the connection is
  refused with `no matching host key type found`.
- **`scp_extra_args = "-O"`** — forces the legacy SCP protocol, which older
  guests require.

These are compatibility settings for the oldest guests in the matrix. Removing
them breaks RHEL 8 and SLES 15 before any role runs.

---

## Requirements

`linux-requirements.yml` and `windows-requirements.yml` declare the Galaxy
collections. `ansible-galaxy collection install -r <file>` installs them; the
Packer provisioner does it through `galaxy_file`.

---

## Working on a role

```shell
# Syntax only — no guest needed
ansible-playbook -i localhost, ansible/linux-playbook.yml --syntax-check

# Lint
ansible-lint ansible/

# Against a real guest
ansible-playbook -i <host>, -u <build user> -k ansible/linux-playbook.yml
```

A role change reaches production the next time **any** Ansible-based image is
built. Test it against at least one guest of a different OS family before
merging — the per-family task files diverge, and a change to `main.yml` affects
all five.

See [Provisioning Scripts](../docs/reference/scripts.md) for the analogous
conventions on the shell-script side.
