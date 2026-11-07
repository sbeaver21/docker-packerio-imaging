---
icon: octicons/shield-check-24
---

# Least Privilege

Create a custom vSphere role with the required privileges to integrate HashiCorp Packer with VMware
vSphere. A service account can be added to the role to ensure that Packer has least privilege access
to the infrastructure.

## Required Privileges

:fontawesome-regular-clone: &nbsp; Clone the default **Read-Only** vSphere role and add the
following privileges:

| Category | Privilege | Reference |
| --- | --- | --- |
| Content Library | Add library item | `ContentLibrary.AddLibraryItem` |
| Content Library | Update Library Item | `ContentLibrary.UpdateLibraryItem` |
| Cryptographic Operations | Direct Access <br/> (Required for `packer_cache` upload.) | `Cryptographer.Access` |
| Cryptographic Operations | Encrypt <br/> (Required for vTPM.) | `Cryptographer.Encrypt` |
| Datastore | Allocate space | `Datastore.AllocateSpace` |
| Datastore | Browse datastore | `Datastore.Browse` |
| Datastore | Low level file operations | `Datastore.FileManagement` |
| Host | Configuration > System Management | `Host.Config.SystemManagement` |
| Network | Assign network | `Network.Assign` |
| Resource | Assign virtual machine to resource pool | `Resource.AssignVMToPool` |
| vApp | Export | `vApp.Export` |
| Virtual Machine | Configuration > Add new disk | `VirtualMachine.Config.AddNewDisk` |
| Virtual Machine | Configuration > Add or remove device | `VirtualMachine.Config.AddRemoveDevice` |
| Virtual Machine | Configuration > Advanced configuration | `VirtualMachine.Config.AdvancedConfig` |
| Virtual Machine | Configuration > Change CPU count | `VirtualMachine.Config.CPUCount` |
| Virtual Machine | Configuration > Change memory | `VirtualMachine.Config.Memory` |
| Virtual Machine | Configuration > Change settings | `VirtualMachine.Config.Settings` |
| Virtual Machine | Configuration > Change Resource | `VirtualMachine.Config.Resource` |
| Virtual Machine | Configuration > Modify device settings | `VirtualMachine.Config.EditDevice` |
| Virtual Machine | Configuration > Set annotation | `VirtualMachine.Config.Annotation` |
| Virtual Machine | Edit Inventory > Create from existing | `VirtualMachine.Inventory.CreateFromExisting` |
| Virtual Machine | Edit Inventory > Create new | `VirtualMachine.Inventory.Create` |
| Virtual Machine | Edit Inventory > Remove | `VirtualMachine.Inventory.Delete` |
| Virtual Machine | Interaction > Configure CD media | `VirtualMachine.Interact.SetCDMedia` |
| Virtual Machine | Interaction > Configure floppy media | `VirtualMachine.Interact.SetFloppyMedia` |
| Virtual Machine | Interaction > Connect devices | `VirtualMachine.Interact.DeviceConnection` |
| Virtual Machine | Interaction > Inject USB HID scan codes | `VirtualMachine.Interact.PutUsbScanCodes` |
| Virtual Machine | Interaction > Power off | `VirtualMachine.Interact.PowerOff` |
| Virtual Machine | Interaction > Power on | `VirtualMachine.Interact.PowerOn` |
| Virtual Machine | Provisioning > Create template from virtual machine | `VirtualMachine.Provisioning.CreateTemplateFromVM` |
| Virtual Machine | Provisioning > Mark as template | `VirtualMachine.Provisioning.MarkAsTemplate` |
| Virtual Machine | Provisioning > Mark as virtual machine | `VirtualMachine.Provisioning.MarkAsVM` |
| Virtual Machine | State > Create snapshot | `VirtualMachine.State.CreateSnapshot` |

Once the custom vSphere role is created, assign **Global Permissions** in vSphere for the service
account that will be used for the HashiCorp Packer to VMware vSphere integration in the next step.
Global permissions are required for the content library.

For example:

1. Log in to the vCenter Server at _`https://<management_vcenter_server_fqdn>/ui`_ as
   `administrator@vsphere.local`.

1. Select **Menu** > **Administration**.

1. Create service account in vSphere SSO if it does not exist: In the left pane, select **Single
   Sign On** > **Users and Groups** and click on **Users**, from the dropdown select the domain in
   which you want to create the user (_e.g.,_`example.com`) and click **ADD**, fill all the username
   (_e.g.,_ `svc-packer-vsphere)` and all required details, then click **ADD** to create the user.

1. In the left pane, select **Access control** > **Global permissions** and click the **Add
   permissions** icon.

1. In the **Add permissions** dialog box, enter the service account (_e.g.,_
   `svc-packer-vsphere@example.com`), select the custom role (_e.g.,_ Packer to vSphere Integration
   Role) and the **Propagate to children** checkbox, and click **OK**.

In an environment with many vCenter Server instances, such as management and workload domains, you
may wish to further reduce the scope of access across the infrastructure in vSphere for the service
account. For example, if you do not want Packer to have access to your management domain, but only
allow access to workload domains:

1. From the **Hosts and clusters** inventory, select management domain vCenter Server to restrict
   scope, and click the **Permissions** tab.

1. Select the service account with the custom role assigned and click the **Edit**.

1. In the **Change role** dialog box, from the **Role** drop-down menu, select **No Access**, select
   the **Propagate to children** checkbox, and click **OK**.

### :material-terraform: Terraform Example

If you would like to automate the creation of the custom vSphere role, a Terraform module is
included in the project. It creates exactly the privileges listed above, and updating the module is
how the role changes when that list changes.

1. Fetch the pinned Terraform — the module is checked against this version, not whatever is on
   `PATH`.

      ```shell
      ./scripts/bootstrap/fetch-terraform.sh    # Windows: .\scripts\bootstrap\fetch-terraform.ps1
      ```

2. Navigate to the directory for the example and create the variable file.

      ```shell
      cd terraform/vsphere-role
      cp terraform.tfvars.example terraform.tfvars
      ```

3. Open `terraform.tfvars` and set the vCenter FQDN, an account that can create roles, its
   password, and `vsphere_insecure = true` if vCenter uses its self-signed certificate. **Leave
   `packer_vsphere_privileges` as it is** — it is the list above.

4. Initialize, validate, and review the plan. `validate` contacts nothing; `plan` is the first
   command that reaches vCenter and it changes nothing.

      ```shell
      ../../tools/terraform/terraform init -backend=false
      ../../tools/terraform/terraform validate
      ../../tools/terraform/terraform plan -out=tfplan
      ```

5. Apply the plan you reviewed.

      ```shell
      ../../tools/terraform/terraform apply tfplan
      ```

6. Confirm the role in **Administration** > **Access control** > **Roles**, then assign it as
   described above.

!!! tip "The full runbook"
    [Deploy the vSphere role](../operations/terraform-role-deploy.md) covers each step in detail:
    what every variable must be and where to find it, what a correct plan looks like, how to verify
    the permission in vCenter and with PowerCLI, how to prove the role with a first build, and what
    to do when an apply or a build fails.
