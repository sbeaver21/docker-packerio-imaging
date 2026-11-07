# Template Tests

`tests/` holds golden-file tests for the unattended-install templates. They exist
because a partition table or a network stanza is nearly impossible to review by
reading: what matters is the text the installer will receive.

The tests render the templates with a fixed set of variables and compare the
result against a committed expected file. Any difference fails the test.

---

## How the harness works

There is no vSphere involved. `tests/<suite>/test.pkr.hcl` declares a
**null-ish build** whose only job is to render the template into a file:

```text
tests/storage/
├── test                        bats test script
├── test.pkr.hcl                renders the templates, no builder
├── variables.pkr.hcl           the inputs the templates take
├── test-lvm.pkrvars.hcl        one var file per scenario
├── test-lvm-swap.pkrvars.hcl
├── test-direct.pkrvars.hcl
├── test-direct-swap.pkrvars.hcl
├── templates/                  copies of the real templates under test
│   ├── kickstart.pkrtpl
│   ├── autoinstall.pkrtpl
│   └── preseed.pkrtpl
└── golden/                     expected output, one file per scenario
```

The test script runs:

```shell
packer build -var-file="test-lvm.pkrvars.hcl" -var "output_folder=output/lvm" \
    -only "autoinstall.*" .
diff -u output/lvm/autoinstall golden/lvm-autoinstall
```

`-only "autoinstall.*"` selects one source, so each installer family is rendered
and compared separately.

---

## The two suites

### `tests/network`

Renders the network stanza of all four installer families, with DHCP and with a
static address.

| Scenario | Installer | Output | Golden file |
| :------- | :-------- | :----- | :---------- |
| DHCP | Autoinstall | `output/dhcp/autoinstall` | `golden/dhcp-autoinstall` |
| DHCP | Kickstart | `output/dhcp/kickstart` | `golden/dhcp-kickstart` |
| DHCP | Preseed | `output/dhcp/preseed` | `golden/dhcp-preseed` |
| DHCP | Photon | `output/dhcp/photon` | `golden/dhcp-photon` |
| Static | Autoinstall | `output/static/autoinstall` | `golden/static-autoinstall` |
| Static | Kickstart | `output/static/kickstart` | `golden/static-kickstart` |
| Static | Preseed | `output/static/preseed` | `golden/static-preseed` |
| Static | Photon | `output/static/photon` | `golden/static-photon` |

Variable files: `test-dhcp.pkrvars.hcl`, `test-static.pkrvars.hcl`.

### `tests/storage`

Renders the partition layout: LVM or direct partitions, each with and without a
swap volume, for three installer families.

| Layout | Swap | Autoinstall | Kickstart | Preseed |
| :----- | :--: | :---------- | :-------- | :------ |
| LVM | no | `lvm-autoinstall` | `lvm-kickstart` | `lvm-preseed` |
| LVM | yes | `lvm-autoinstall-swap` | `lvm-kickstart-swap` | `lvm-preseed-swap` |
| Direct | no | `direct-autoinstall` | `direct-kickstart` | `direct-preseed` |
| Direct | yes | `direct-autoinstall-swap` | `direct-kickstart-swap` | `direct-preseed-swap` |

Variable files: `test-lvm.pkrvars.hcl`, `test-lvm-swap.pkrvars.hcl`,
`test-direct.pkrvars.hcl`, `test-direct-swap.pkrvars.hcl`.

Photon OS has no storage test, because its layout comes from its kickstart
rather than from the shared storage template.

---

## Running them

The tests use [Bats](https://bats-core.readthedocs.io/).

### Linux / macOS

```shell
# Install once
brew install bats-core            # macOS
sudo apt install bats             # Debian/Ubuntu

# Run
cd tests/network && bats test
cd tests/storage && bats test
```

### Windows (WSL)

```shell
sudo apt install bats
cd tests/network && bats test
cd tests/storage && bats test
```

The harness needs Packer and network access for `packer init` on the first run.
`tests/temp/` holds the Windows plugin binaries, so a Windows host can run the
same tests without re-downloading them.

`tests/.gitignore` excludes `output/`, which is regenerated on every run.

---

## When a test fails

A failure means the rendered template changed. That is either a regression or an
intended change, and the diff tells you which:

```shell
cd tests/storage
bats test
# 1..12
# not ok 1 storage with Autoinstall using LVM layout
```

Reproduce a single scenario by hand:

```shell
cd tests/storage
mkdir -p output/lvm
packer build -var-file=test-lvm.pkrvars.hcl \
    -var "output_folder=output/lvm" -only "autoinstall.*" .
diff -u output/lvm/autoinstall golden/lvm-autoinstall
```

If the change is intended, update the golden file **and commit both together**,
so the review shows what the output became:

```shell
cp output/lvm/autoinstall golden/lvm-autoinstall
git add golden/lvm-autoinstall templates/
```

!!! warning "Do not update a golden file to make a test pass"
    The golden files are the specification of the installer input. Updating one
    because the output "looks fine" removes the only check that the partition
    layout or the network stanza did not change accidentally. Read the diff,
    confirm it is what you intended, then update.

---

## What these tests do not cover

| Not covered | Why | Checked instead by |
| :---------- | :-- | :----------------- |
| Whether an image boots | Needs vSphere | A real build and a booted clone |
| Whether packages install | Needs a guest | The build log |
| Whether the boot command timing works | Needs a guest | A real build |
| Whether the scripts run correctly | Needs a guest | A real build, or the scripts' own `--dry-run` |

The templates under `tests/*/templates/` are **copies**. A change to a real
template in `builds/` must be copied into the test suite, or the tests will keep
passing against a stale copy. `tests/README.md` records the upstream references
for each installer's syntax.
