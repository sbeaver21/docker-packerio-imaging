# data

Shared unattended-install template sets, kept at the repository root.

```text
data/
├── data9/          RHEL 9 kickstart set
│   ├── ks.pkrtpl.hcl
│   ├── network.pkrtpl.hcl
│   └── storage.pkrtpl.hcl
├── data10/         RHEL 10 kickstart set
├── photon4/        Photon OS 4 kickstart set
├── photon5/        Photon OS 5 kickstart set
└── ubuntu/         Ubuntu autoinstall set
    ├── meta-data
    ├── network.pkrtpl.hcl
    ├── storage.pkrtpl.hcl
    └── user-data.pkrtpl.hcl
```

---

## Important: no build reads from here

Every build resolves its answer file from **its own** `data/` directory, because
the template uses `${path.root}`:

```hcl
data_source_content = {
  "/ks.cfg" = templatefile("${abspath(path.root)}/data/ks.pkrtpl.hcl", { … })
}
```

`path.root` is the project directory. Nothing in `builds/` references
`../../data/…`, so a change made in this directory has **no effect on any
build** until it is copied into a project.

This directory is a staging area: the sets are kept together so the variants can
be compared, and so a project that has lost its own `data/` can be restored from
them.

---

## Restoring a project's data directory

Every project in `builds/` currently carries the templates it renders. If one
loses them, restore from here:

| Project | Source here |
| :------ | :---------- |
| `builds/linux/rhel/96` | `data9/` |
| `builds/linux/rhel/100` | `data10/` |
| `builds/linux/photon/4` | `photon4/` |
| `builds/linux/photon/5` | `photon5/` |
| `builds/linux/ubuntu/*` | that project's own `data/` — not this directory |

```shell
cp data/data9/ks.pkrtpl.hcl data/data9/network.pkrtpl.hcl data/data9/storage.pkrtpl.hcl \
   builds/linux/rhel/96/data/
packer validate builds/linux/rhel/96
```

!!! warning "These sets are per major version; the projects are per minor"
    `data9/` is the RHEL 9 set, serving RHEL 9.6, and `data10/` serves RHEL
    10.0. If a minor release needs a different package set or partition layout,
    the copy taken from here carries the wrong one. Render the answer file after
    copying and read it before relying on the result.

---

## Local variants

Several sets contain sibling files left over from editing, for example:

```text
data/photon5/
├── ks.pkrtpl.hcl
├── ks.pkrtpl.hcl.backup
├── ks.pkrtpl.hcl.example
├── ks.pkrtpl.hcl.last
├── network.pkrtpl.hcl
├── network.pkrtpl.hcl.example
├── network.pkrtpl.hcl.sample
└── storage.pkrtpl.hcl
```

The `.backup`, `.last` and `.sample` variants are local scratch and are
gitignored (`*.bak`, `*.save`, `*.backup`, `*.old`, `*.last`, `*.sample`). The
`.example` variants are kept.

Before deleting one, check whether it is the only copy of a change you want:

```shell
diff data/photon5/ks.pkrtpl.hcl data/photon5/ks.pkrtpl.hcl.last
```

---

## Why the sets are not merged

The most recent copy of each file is not necessarily the right one. A set may
hold a file whose name does not match its siblings but which something else
depends on, and the `.backup`/`.last`/`.sample` copies sit beside the file they
were edited from with no indication of which one was applied last. Read a set
before collapsing it.

The same applies across versions: `data9` and `data10` diverge in package names
— `dnf` and `update-crypto-policies` are 9-era, and RHEL 10 uses
`DEFAULT:AD-SUPPORT` with a different baseline package set. Collapsing them into
one set with conditionals would be harder to read than two files.
