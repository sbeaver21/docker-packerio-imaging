# AD Join/Delete for VCF Automation

This repository contains scripts and documentation for adding provisioned machines to Active Directory (AD) and removing them when needed, specifically for **VCF Automation 9.0** (formerly VMware Aria Automation).

## Overview

Due to architecture and design changes in **VCF Automation 9.0**, the option to add machines to Active Directory no longer exists out of the box. This functionality is deprecated with the removal of ABX (Action Based Extensibility) functionality.

This README documents the solution from Broadcom Knowledge Base article [393273](https://knowledge.broadcom.com/external/article/393273/adding-provisioned-machines-to-active-di.html), which uses Orchestrator workflows, event subscriptions, and configuration elements to replicate the AD join/delete functionality.

## Prerequisites

- VCF Automation 9.0 (or later)
- Access to the **Orchestrate** tab (`automation/#/orchestrate`)
- Active Directory servers accessible from the Orchestrator
- Domain credentials with permission to join/remove computers from the domain
- Appropriate permissions to create workflows, configurations, and subscriptions in VCF Automation

## Solution Architecture

The solution uses the following VCF Automation components:

1. **Orchestrator Inventory** - Active Directory server(s) added as managed resources
2. **Configurations** - OUs defined as configuration variables for target organization units
3. **Action Scripts & Workflows** - Imported package handling the AD join/delete logic
4. **Event Subscription** - Triggers on deployment create/delete events to run the workflow
5. **Blueprint** - Uses `metadata.name` as the AD computer object name (15 character limit)

## Configuration Steps

### 1. Add Active Directory Server(s) to Orchestrator Inventory

1. Navigate to the **Orchestrate** tab (`automation/#/orchestrate`).
2. On the left panel, click **Workflows**.
3. Search for the workflow **Add an Active Directory server**.
4. Run this workflow to add each AD server to the Orchestrator inventory.
   - Each Active Directory server requires a single run of this workflow.

### 2. Add OUs as Configurations

1. Under the **Orchestrate** tab, click **Configurations** on the left panel.
2. Use the **New Configuration** button and provide a descriptive name (e.g., `ad_ou_list`).
   - Note the **Configuration ID** displayed — this will be used as the `CONFIGURATION_LIST_ID` in the setup script.
3. Click the **Variables** tab and choose **New**.
   - Give the variable a descriptive name.
   - Set the **Type** to `AD:OrganizationalUnit`.
   - Set the **Value** to the actual OU distinguished name (e.g., `OU=Workstations,DC=domain,DC=com`).
   - Note: The **Name** field value will be the `OU_VARIABLE_NAME_FROM_CONFIGURATION` used in the setup script.
4. Repeat to add additional OUs as needed.

### 3. Get the Project ID

1. Navigate to the **Manage & Govern** tab.
2. Click **Projects** from the left panel.
3. Select a project and find the **Project ID** in the URL (the UUID before `/summary`).
   - This value becomes the `PROJECT_ID` in the setup script.

### 4. Import the Workflow Package

1. Download the attached package: **`active.directory.create.delete.package`** (see Attachments section in the KB article).
2. Navigate to **Orchestrate → Assets → Packages**.
3. Click **Import** and select the downloaded package.
4. This imports the Action Scripts and Workflows needed for AD join/delete operations.

### 5. Create and Subscribe to the Event

1. Under **Subscriptions**, create a new Subscription.
2. Choose the **Iaas Resource Event** event topic as the trigger.
3. Select the workflow imported in the previous step.
4. In the **Condition** block, add:
   ```
   event.data.object.reason == "CreateSuccess" || event.data.object.reason == "DeleteSuccess"
   ```
5. Enable **Project Scope** toggle to run against **Any Project**.
6. Save the Subscription.

> **Verify**: Check subscription runs under **Build & Deploy → Event Subscriptions → Events** after a deployment to confirm the workflow executed successfully.

### 6. Blueprint Configuration

The blueprint must be configured so the `metadata.name` property maps to the AD computer object name.

Example blueprint snippet (YAML):

```yaml
formatVersion: 1
resources:
  CCI_Supervisor_Namespace_1:
    type: CCI.Supervisor.Namespace
    properties:
      name: ###-#####-#########
      existing: true
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
      wait:
        conditions:
          - type: VirtualMachineCreated
            status: 'True'
```

> **Note**: The `metadata.name` is used as the AD computer object name and is **limited to 15 characters** due to Active Directory constraints. Replace `###-#####-#########` and other placeholder values with appropriate names for your environment.

### 7. Multiple OU / Multiple AD Server Scenario

To support multiple OUs or multiple AD servers:

1. **Additional AD servers**: Re-run the **Add an Active Directory server** workflow for each server.
2. **Additional OUs**: Add them as configuration variables within the same Configuration List (`ad_ou_list`).
3. **Project associations**: Under **Orchestrate → Actions**, find the setup action script. Inside the `project_associations` JSON, add the additional `PROJECT_ID: OU` mappings and click **Save**.

This allows multiple Project-to-AD-OU associations. The workflow runs against all projects, but the `project_associations` JSON ensures machines are only created on the specified projects.

## Removing Machines from Active Directory

AD account cleanup is handled automatically by the imported workflow when triggered by a `DeleteSuccess` event. The workflow removes the computer account from the domain when the provisioned machine is deleted.

### Manual Cleanup

If manual cleanup is needed:

1. If the machine is still online, remove it from the domain:
   ```powershell
   Remove-Computer -UnjoinDomaincredential (Get-Credential) -WorkgroupName WORKGROUP -Restart
   ```
2. If the machine is unavailable, delete its computer account from **Active Directory Users and Computers**.
3. Clean up any stale DNS entries if necessary.

## Notes

- The `metadata.name` field in the blueprint is used as the AD computer account name and is **limited to 15 characters** (Active Directory constraint).
- Ensure machine names do not conflict with existing AD computer accounts.
- AD computer accounts may require a replication delay before changes are reflected across the domain.
- The subscription condition `event.data.object.reason == "CreateSuccess" || event.data.object.reason == "DeleteSuccess"` ensures the workflow runs only on successful deployments or deletions.
- The `project_associations` configuration in the action script controls which projects are mapped to which OUs.

## Attachments

- **`active.directory.create.delete.package`** - The Orchestrator package containing Action Scripts and Workflows for AD join/delete operations. Available for download from the Broadcom KB article.

## References

- Broadcom KB Article 393273: [Adding Provisioned Machines to Active Directory](https://knowledge.broadcom.com/external/article/393273/adding-provisioned-machines-to-active-di.html)
- VCF Automation 9.0 Documentation
- Active Directory computer account management best practices