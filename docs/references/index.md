---
icon: octicons/book-24
---

# Reference material

Everything in [`references/`][references-dir] answers a question that starts
where a finished image stops. The build projects under `builds/` produce a
vSphere template; these pages cover what happens to it next - who initialises
it, how it is named, how it joins a domain - and the one alternative builder
for clusters that are not a plain vCenter.

!!! note "Vendor material, not this repository's reference"

    This tab is external: Broadcom procedures and sample templates, carried so
    the operational half of the picture travels with the images. For this
    repository's own reference - build projects, input variables, scripts - see
    the **Reference** tab.

!!! note "Nothing here runs during a build"

    `packer build builds/...` never reads `references/`, and no CronJob in
    `kubernetes/` touches it.

## The three sets

| Page | Directory | Answers |
| :--- | :--- | :--- |
| [vSphere Supervisor images](vsphere-supervisor.md) | `references/supervisor-images/` | How do I build an image when the target is a Supervisor cluster, and publish it as a VM image? |
| [Windows VCF Automation image](windows-vcf-image.md) | `references/windows-vcf-image/` | How must a Windows image be prepared so VCF Automation can initialise it on first boot? |
| [Active Directory join](vcfa-ad-join.md) | `references/vcfa-ad-join/` | How do machines join Active Directory now that VCF Automation 9.0 removed ABX? |

The three are independent. A Windows image for VCF Automation on a Supervisor
cluster uses all three; a Linux image built with `vsphere-iso` and deployed on
plain vSphere uses none of them.

## Where this sits

```text
builds/                     template produced
  └── <project>/            vsphere-iso → Content Library
                                    │
                                    ▼
references/                 template consumed
  ├── windows-vcf-image     how VCF Automation initialises a Windows guest
  ├── vcfa-ad-join          how the provisioned machine reaches the domain
  └── supervisor-images/    an alternative path: build on the cluster itself
        ├── examples/       the upstream sample set, unchanged
        └── site/           the set this site builds from
```

The first two are steps of a deployment pipeline that this repository does not
automate - they happen in VCF Automation, not on the build host. The third
replaces the builder rather than following it.

## What has been checked

| Check | Result |
| :--- | :--- |
| `packer fmt -check -recursive .` | Clean, and it covers `references/` because it walks the repository root |
| `packer validate -syntax-only` on all 15 supervisor templates | Pass |
| YAML parse of the cloud-init files, both `cleanup-playbook.yml` files and the four sysprep files | Pass |
| Every `bootstrap_data_file` default | Resolves to a file in its own directory |
| Full `packer validate` | Not possible: the builder reads the current context's namespace from a kubeconfig, and there is no Supervisor cluster here |
| Any build from this material | No |

The [validation report](../operations/validation.md) records the same scope for
the `builds/` projects.

## Licensing

None of this material is BSD 2-Clause. The supervisor templates are Mozilla
Public License 2.0, the Cloudbase-Init configuration fragments are from
Cloudbase Solutions, and the rest is Broadcom documentation. Each set's terms
are listed in [`references/README.md`][references-readme] and in
`references/supervisor-images/LICENSE`.

[references-dir]: https://github.com/sbeaver21/docker-packerio-imaging/tree/main/references
[references-readme]: https://github.com/sbeaver21/docker-packerio-imaging/blob/main/references/README.md
