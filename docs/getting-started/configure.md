---
icon: octicons/gear-24
---

# Configure Your Environment

## Where configuration lives

There is no shared `config/` directory and no `config.sh`. Configuration lives
in the project it configures: Packer loads every `*.auto.pkrvars.hcl` file in the
project directory automatically, so each build carries its own — and only its
own — inputs.

Nothing in that set is committed. The committed contract is the
`*.pkrvars.hcl.example` beside each template, plus the `variables*.pkr.hcl`
declarations. See [Secrets](../operations/secrets.md).

## Copy the examples

```shell
cd builds/linux/almalinux/9
cp linux-almalinux.pkrvars.hcl.example linux-almalinux.auto.pkrvars.hcl
```

Projects with several input files need several copies. Ubuntu splits its inputs
across five — `build`, `common`, `storage`, `ubuntu` and `vsphere`:

```shell
cd builds/linux/ubuntu/24-04-lts
for f in *.pkrvars.hcl.example; do
    cp "$f" "${f%.hcl.example}.auto.pkrvars.hcl"
done
```

The Windows Server projects take two: `vsphere.auto.pkrvars.hcl` and
`win20xx.auto.pkrvars.hcl`.

## vSphere connection

Four values are needed before anything can build:

```hcl title="vsphere.auto.pkrvars.hcl"
vsphere_endpoint = "vcenter.example.com"
vsphere_username = "svc-packer@example.com"
vsphere_password = "«password»"
vsphere_datacenter = "es10-WLD1-DC"
```

`vsphere_network` must be a **path**, not a bare port group name:

```hcl
vsphere_network = "/es10-WLD1-DC/network/es10-WLD1-VDS01/VM Network"
```

Prefer passing the password through the environment on a shared build host — a
value in the environment beats one in a var file, and is not written to disk:

```shell
export PKR_VAR_vsphere_password='«password»'
packer build builds/linux/photon/5
```

## Accounts

Every project bakes in a build account that Packer connects as:

```hcl title="build.auto.pkrvars.hcl"
build_username           = "builduser"
build_password           = "«literal password»"
build_password_encrypted = "«sha-512 crypt»"
build_key                = "«public key»"
```

`build_password_encrypted` is the shadowed hash written into the guest;
`build_password` is the literal the communicator authenticates with. They must
be the same password.

Generate the hash:

```shell
SALT=$(openssl rand -base64 6); \
ENCRYPTED_PASSWORD=$(echo -n '<your_password>' | openssl passwd -6 -stdin -salt $SALT); \
echo "Generated Salt: $SALT"; \
echo "Encrypted Password: $ENCRYPTED_PASSWORD"
```

Generate the key pair:

```shell
ssh-keygen -t ecdsa -b 521 -C "<name@example.com>"
```

`build_key` takes the **public** half. On Linux guests it is appended to
`~/.ssh/authorized_keys` for `build_username`.

## Guest network configuration

The build runs with a static address so Packer can reach it, then returns the
adapter to DHCP before the image is sealed.

```hcl title="network-ish values in the project's var files"
vm_ip_address = "172.16.100.192"
vm_ip_netmask = 24
vm_ip_gateway = "172.16.100.1"
vm_dns_list   = ["172.16.11.4", "172.16.11.5"]
```

!!! warning "Shadowed in the Photon, RHEL and Ubuntu projects"

    Those templates define these names in a `locals` block, which takes
    precedence over the variable. Setting them in `*.auto.pkrvars.hcl` has no
    effect there — edit the `locals` block instead. See
    [Configuration reference](../reference/configuration.md#network-guest).

## Storage

Partition and LVM layout are configured per project:

```hcl
vm_disk_device   = "sda"
vm_disk_use_swap = true
vm_disk_partitions = [
  { name = "boot", size = 1024, format = { label = "boot", fstype = "xfs" }, mount = { path = "/boot" } },
  ...
]
```

`size = -1` takes the remaining space and is valid only on the last partition or
logical volume.

## Windows specifics

The Windows Server projects add the answer-file image index and the shutdown
command, and they need a scripts ISO attached at `F:`. That ISO is built from
`builds/windows/files/` — see
[Windows Server builds](../operations/windows-builds.md).

## Full variable reference

Every input variable, its type, default and which projects declare it:
[Configuration reference](../reference/configuration.md).
