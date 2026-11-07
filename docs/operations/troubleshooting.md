# Troubleshooting

Diagnosis by symptom. For the failure taxonomy found during validation, see
[Validation](validation.md); for the questions asked most often, see
[FAQ](../getting-started/faq.md).

---

## Before the VM is created

### `Error: Unset variable "…"`

The project has no configuration. Create the `*.auto.pkrvars.hcl` files listed in
[Configure](../getting-started/configure.md#where-configuration-lives).

### `Error: Missing plugins`

```shell
packer init builds/<project>
```

`packer init` is per project — each pins its own plugin versions. If it still
fails:

```shell
# Is the plugin actually installed, and executable?
ls -l "$PACKER_PLUGIN_PATH/packer-plugin-vsphere"
find "$PACKER_PLUGIN_PATH" -type f -name 'packer-plugin-*' -exec chmod +x {} +
```

The second command is the fix for the most misleading error in Packer: a plugin
copied from another host or from Windows arrives without its execute bit, and
Packer reports it as *not installed* and tells you to run `packer init`, which
will not help.

### `Call to function "templatefile" failed: no file exists at …/data/…`

The project's `data/` directory is missing. This was a repository-wide defect
that is now fixed — every committed project carries its templates, and all 129
`templatefile()` references resolve. If you see it, either the project was
created by copying without its `data/` directory, or a file was not added to the
commit:

```shell
ls builds/<project>/data/
git status --short builds/<project>/
```

Windows Server projects resolve theirs from the repository root as
`../../../../scripts/windows/data/`, so the directory to check there is
`scripts/windows/data/`.

### `Incorrect attribute value type`

A string where a number is expected, or the reverse. The two that catch people:

```hcl
vm_ip_netmask = 24       # number
iso_file      = "…"      # string
```

### `Error: Unsupported argument`

The variable does not exist in this project. Variable sets differ between
families; check `variables.pkr.hcl` in the project directory rather than
assuming a neighbouring project will accept the same key.

---

## During the install

### The build sits at `Waiting for IP...`

The guest booted but never completed an unattended install, so it never brought
up networking.

**Open the VM console in vCenter.** That is the fastest answer to every variant
of this problem: the screen shows whether the installer started, whether it is
asking a question, and whether it errored.

| What the console shows | Cause | Fix |
| :--------------------- | :---- | :-- |
| The bootloader menu, unchanged | `boot_command` did not take | Increase `vm_boot_wait` |
| An installer prompt | The answer file was not found | Check `common_data_source`, and that the ISO supports a second CD-ROM |
| `dracut-initqueue timeout` | The installer could not fetch its answer file over HTTP | The guest cannot reach `common_http_ip` on the port range |
| A package error | The answer file names a package the installer cannot reach | Remove it from `additional_packages` and install it afterwards |
| A completely blank screen | The ISO is not bootable, or it is a different product | Verify `iso_file` |
| A login prompt | The install finished but Packer is waiting for a **different** address | Check that the guest address matches the one the builder expects |

The address the builder waits for comes from the template's `locals` for Photon,
RHEL and Ubuntu — not from your configuration. If you changed `vm_ip_address` in
a var file and the build still waits on the old address, that is why.

### The install fails on the wrong Windows edition

```text
Windows cannot find the Microsoft Software License Terms
```

Or the install stops asking for an edition. The image index in `iso_file` does
not match `vm_inst_os_image`. List the indices:

```powershell
dism /Get-WimInfo /WimFile:D:\sources\install.wim
```

Evaluation media and volume-licensing media expose different names.

---

## After the install, before provisioning

### `Waiting for SSH` forever

The guest is up but the communicator cannot log in.

- **The two passwords disagree.** The installer received
  `build_password_encrypted`; SSH receives `build_password`. If the hash was not
  generated from the same password, the login is wrong while the console login
  works.
- **No SSH server.** Some minimal installs omit `openssh-server`. The kickstart
  must install it.
- **The wrong address.** See above.
- **A firewall.** Check from the build host:

  ```shell
  nc -vz <guest-address> 22
  ```

### `Waiting for WinRM`

- `communicator_port` must be `5985` for WinRM over HTTP.
- VMware Tools must be installed: the builder needs it to discover the address.
- WinRM must be enabled by the answer file, and it is not on by default in
  Windows Server.

---

## During provisioning

### A script fails at its first command

The provisioners run with `sh -eux`. `-e` means the first non-zero exit fails
the build, and `-u` means an unset variable does. Common causes:

| Symptom | Cause |
| :------ | :---- |
| `ifconfig: command not found` | `net-tools` is not installed. Use `ip`. |
| `unbound variable` | `-u` plus an unset variable, often an environment override the template does not set |
| `command not found` for something the script installs | The install step failed earlier and `-e` did not stop it because it was piped to `tee` or `grep` |
| Works interactively, fails in the build | `/bin/sh` is not bash — on Photon it is ash |

### A package install fails

The guest cannot reach its repositories. On RHEL, that usually means
subscription-manager registration failed; on Ubuntu, that the mirror in
`scripts/linux/ubuntu/apt.sh` is unreachable from the build network.

The guest's console and `/var/log/` inside it are the only place the real error
appears — Packer shows the script's stdout, not the package manager's full
output, once it is piped.

### Windows Update takes forever

It does. The provisioner allows `restart_timeout = "120m"`. A build that runs
longer than that has a broken WSUS or proxy path, not a slow disk.

### The Photon build fails with `FileNotFoundError: 'docker'`

A package was added to `additional_packages`. The Photon installer falls back to
installing through a container when it cannot find a package on the ISO, and the
installer environment has no Docker. Keep `additional_packages = []` and install
after the OS is up.

---

## Publishing

### `… is not a valid OVF` / export fails

- vSphere cannot export an **encrypted** VM to a content library as an OVF.
  Windows 11 builds are excluded by default.
- The content library must allow OVF items: `common_content_library_ovf = true`
  needs a library that is not backed by a datastore-only type.

### The library item is not updated

An existing item of the same name is replaced, not duplicated. If the build
succeeded but the item looks unchanged:

```shell
# Confirm the build actually published
jq '.builds[].artifact_id' manifests/<timestamp>.json
```

and check `common_content_library_skip_export` is `false`.

### The build VM is left behind

`common_content_library_destroy = false`, or the build failed. Delete it, but
check first that it is not the only copy of a half-built image you want to
inspect.

---

## Working on the repository

### `packer fmt -check` fails on files I did not touch

Expected. 54 files are non-canonical. Format your own files:

```shell
packer fmt builds/<project>/<file>.pkr.hcl
```

### A new project fails with missing files even though I copied one that works

Two causes, both common:

1. `templatefile()` resolves `${path.root}/data/…`, and `path.root` is **the new
   project directory**. Copying `data/` from the old project is a separate step.
2. The copied template's `locals` block still names the previous version — the
   VM name, the ISO, the address. Search the new directory for the old version
   string:

   ```shell
   grep -rn "9-4" builds/linux/rhel/96/
   ```

### `packer validate` passes but the build fails immediately

`validate` never contacts vCenter. A wrong datastore name, a port group path, an
ISO name or a missing content library item all pass validation and fail at
build. Check them against the real inventory:

```shell
govc ls /dc01/vm
govc datastore.ls -ds <datastore>
govc ls /dc01/network
```

---

## Getting more information

| Want | Do this |
| :--- | :------ |
| Keep the VM after a failure | `packer build -on-error=abort <project>` |
| Step through provisioners | `packer build -debug <project>` |
| Override one value | `packer build -var 'name=value' <project>` |
| Supply a password without a file | `export PKR_VAR_vsphere_password=…` |
| See the rendered answer file | Build with `-debug`, or render it with `packer console` |
| List the sources a project declares | `packer inspect <project>` |
| Timestamp the log | `packer build -timestamp-ui <project>` |
