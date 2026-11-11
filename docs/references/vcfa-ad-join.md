---
icon: octicons/organization-24
---

# Active Directory join for VCF Automation 9.0

In VCF Automation 8.x and earlier, a cloud template could join a provisioned
machine to Active Directory out of the box. **9.0 removed that**, along with the
ABX (Action Based Extensibility) functionality it was built on. A deployment now
comes up workgroup-joined, and nothing in the product joins it for you.

Broadcom KB 393273 describes the replacement: an Orchestrator workflow driven by
an event subscription, with the target OU held in a configuration element. This
page summarises that procedure and records where the attachment lives in this
repository. The authoritative text is the KB article and
`references/vcfa-ad-join/README.md`.

| Property | Value |
| :--- | :--- |
| Product | VCF Automation 9.0 or later (formerly VMware Aria Automation) |
| Replaces | The ABX-based AD join in 8.x |
| Attachment | `references/vcfa-ad-join/packages/active.directory.create.delete.package` |
| Reference | Broadcom KB 393273 |

## Components

| Component | Where | Why it is needed |
| :--- | :--- | :--- |
| Active Directory server | **Orchestrate → Workflows → Add an Active Directory server** | Puts the domain in the Orchestrator inventory, so the workflow has something to bind to |
| Configuration element | **Orchestrate → Configurations** | Holds the target OUs as `AD:OrganizationalUnit` variables; the workflow reads the one mapped to the project |
| Action scripts and workflows | Imported package | The join and delete logic itself |
| Event subscription | **Subscriptions** | Runs the workflow on deployment create and delete |
| Blueprint | **Design** | Supplies the computer account name through `metadata.name` |

## Procedure

### 1. Add the AD servers to the Orchestrator inventory

**Orchestrate → Workflows**, search for *Add an Active Directory server*, run it
once per domain controller or AD server you want available. Each server needs
its own run.

### 2. Create the OU configuration

**Orchestrate → Configurations → New Configuration**, named for its purpose, for
example `ad_ou_list`. Note the **Configuration ID** - it is the
`CONFIGURATION_LIST_ID` in the setup script.

Then open **Variables → New** for each OU:

| Field | Value |
| :--- | :--- |
| Name | The variable name used as `OU_VARIABLE_NAME_FROM_CONFIGURATION` |
| Type | `AD:OrganizationalUnit` |
| Value | The distinguished name, for example `OU=Workstations,DC=domain,DC=com` |

### 3. Note the project ID

**Manage & Govern → Projects**, select the project, read the UUID before
`/summary` in the URL. That is `PROJECT_ID` in the setup script.

### 4. Import the package

**Orchestrate → Assets → Packages → Import**, and choose
`active.directory.create.delete.package` from this repository. That installs the
action scripts and workflows the subscription will call.

### 5. Create the subscription

1. **Subscriptions → New Subscription.**
2. Event topic **Iaas Resource Event**.
3. Workflow: the one the package imported.
4. Condition:

   ```text
   event.data.object.reason == "CreateSuccess" || event.data.object.reason == "DeleteSuccess"
   ```

5. Enable **Project Scope** for **Any Project**.
6. Save.

Verify after a deployment under **Build & Deploy → Event Subscriptions →
Events**: the workflow run appears there, and its log says whether the join
succeeded.

### 6. Name the machine in the blueprint

The workflow uses `metadata.name` from the provisioned `VirtualMachine` object as
the **AD computer account name**. It is not optional and it is not derived from
the deployment name:

```yaml
resources:
  ad_vm_123:
    type: CCI.Supervisor.Resource
    properties:
      context: ${resource.CCI_Supervisor_Namespace_1.id}
      manifest:
        apiVersion: vmoperator.vmware.com/v1alpha3
        kind: VirtualMachine
        metadata:
          name: test-vm-${env.shortDeploymentId}
        spec:
          className: best-effort-xsmall
          imageName: vmi-#################
          powerState: PoweredOn
          storageClass: development
```

!!! warning "15 characters"

    Active Directory computer account names are limited to **15 characters**.
    `metadata.name` is used verbatim, so a longer name either fails to create the
    account or is truncated by AD - and then the machine cannot find its own
    account on reboot. Keep the rendered name under the limit; `test-vm-` plus a
    short deployment id is deliberately close to it.

### 7. Map projects to OUs

**Orchestrate → Actions**, open the setup action script, and edit
`project_associations`:

```json
{
  "<PROJECT_ID>": "<OU_VARIABLE_NAME_FROM_CONFIGURATION>"
}
```

One entry per project. The subscription runs for every project, and this map is
what decides which OU, or none, a given project's machines go to.

## Multiple OUs and multiple AD servers

- **Another AD server**: re-run *Add an Active Directory server* for it.
- **Another OU**: add another variable to the same configuration element.
- **Another project**: add another `project_associations` entry, then **Save**.

A project with no entry is not joined, which is the safe default.

## Deletion

The `DeleteSuccess` half of the condition is what removes the computer account
when the deployment is destroyed. No separate workflow is needed.

If a machine has to be removed by hand:

=== "Machine still running"

    ```powershell
    Remove-Computer -UnjoinDomaincredential (Get-Credential) -WorkgroupName WORKGROUP -Restart
    ```

=== "Machine gone"

    1. Delete the computer account in **Active Directory Users and Computers**.
    2. Remove any stale DNS `A` and `PTR` records.

An orphaned computer account holds the name. Clear it before re-using that name,
and allow for AD replication before expecting the change everywhere.

## Checks when the join does not happen

Each of these follows directly from a step above, in the order worth checking:

| Symptom | Look at |
| :--- | :--- |
| Deployment completes, no computer account | The subscription: is it enabled for the project, does the condition match `CreateSuccess`, and does `project_associations` have an entry for the project? |
| No workflow run in **Events** at all | The subscription is disabled, or the event topic is not *Iaas Resource Event* |
| Workflow runs and fails against the domain | The AD server in the Orchestrator inventory, and the credentials it was added with |
| Account created, machine not joined | `metadata.name` over 15 characters, or an account of that name already existed |
| Joined, then the domain relationship is lost after a reboot | The name was longer than 15 characters and AD truncated it; shorten `metadata.name` |

## Related

- [Windows VCF Automation image](windows-vcf-image.md) - the image has to
  initialise correctly before a join can succeed.
- [vSphere Supervisor images](vsphere-supervisor.md) - builds that publish the
  images such a blueprint references.
