# Single-region customer demo

This is the recommended path for a short customer presentation, not a production
deployment. It creates **one ANF environment and a usable NFS client**. Prepare it
before the meeting; Azure provisioning and Run Command can take several minutes
and are not guaranteed to finish within a particular time.

## What is created

Everything belongs to a **new, dedicated resource group** `anfdemo-<DemoId>`:

| Resource | Configuration |
|---|---|
| ANF account and capacity pool | `anf-<DemoId>`, Standard, **4 TiB** pool |
| ANF volume | `demo-volume`, 100 GiB, NFSv3, export path `demo`, visible snapshot directory |
| VNet | `10.42.0.0/16`, delegated ANF subnet `10.42.2.0/24`, client subnet `10.42.1.0/24` |
| Ubuntu 24.04 LTS client | `demo-client`, `Standard_D2s_v5`, Standard SSD OS disk, private IP `10.42.1.4` |
| Client access | Azure Run Command; no VM public IP, Bastion, VPN or inbound SSH/RDP |
| Outbound access | Standard NAT gateway and an outbound-only Standard public IP for Azure services and Ubuntu repositories |

The client subnet and NIC use an NSG denying inbound connections; stateful
responses to client-initiated traffic remain permitted. Default NSG outbound
rules are retained. The NAT public IP is **not assigned to the VM** and provides
no inbound administrative access.

Only `10.42.1.4/32` is allowed by the NFS export. **Root access is deliberately
enabled for this demo** because Run Command executes as root. Do not copy this
setting into a production workload. No network is peered with existing networks.
An ephemeral SSH key pair is generated for Azure provisioning; the private key
is discarded. There is intentionally no SSH login path.

The group and supported client/network resources carry `anfDemo`, `demoId`,
`purpose` and `expiresOn` tags. ANF child resources are identified by their group
and deterministic names; group tags are not automatically inherited.
Expiry defaults to eight hours and is **a reminder only, not automatic deletion**.

## Before the customer meeting

1. Use PowerShell 7.4+ and explicitly install the modules:

   ```powershell
   Install-Module Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles, Az.Compute -Scope CurrentUser
   Connect-AzAccount
   Get-AzSubscription
   ```

2. Check that the selected subscription allows ANF in the chosen region and has
   capacity/quota, the VM size and Ubuntu image are available, and your identity
   can create/delete resource groups and the listed resources. Running guest
   commands also requires `Microsoft.Compute/virtualMachines/runCommand/action`.
   Provider registration needs additional permissions if not already done.
   Azure Policy, locks, deny assignments and outbound restrictions may prevent
   deployment. No roles, policy exemptions or Marketplace agreements are
   configured by this example.

3. Edit [`demo.parameters.psd1`](demo.parameters.psd1): replace the subscription
   placeholder, select a region, and choose a unique, non-sensitive `DemoId`.
   IDs must be 3-16 lowercase characters, start with a letter, end with a letter
   or digit, and otherwise contain only letters, digits and hyphens.
   Never use a group containing customer or shared resources.

4. From the repository root, preview and deploy:

   ```powershell
   $demo = Import-PowerShellDataFile ./demo/demo.parameters.psd1

   # Local operation summary only; no Azure connection or resource-level preview:
   ./Invoke-AnfDemo.ps1 @demo -Action Deploy -WhatIf

   # Billable deployment. Add -RegisterProviders only if needed and authorized:
   ./Invoke-AnfDemo.ps1 @demo -Action Deploy
   ```

   `Microsoft.NetApp`, `Microsoft.Network` and `Microsoft.Compute` must already
   be registered unless `-RegisterProviders` is explicitly supplied. The resolved
   Ubuntu image version is returned by deployment; `latest` is resolved anew for
   each fresh demo. `-VmSize` can select an available compatible VM size.
   `-ExpiresInHours` changes the expiry reminder. Pool and volume sizes remain
   the conservative baseline used by this repository, not a claim about Azure's
   current minimums.

5. Prepare the guest and verify a real NFS write/read:

   ```powershell
   ./Invoke-AnfDemo.ps1 @demo -Action Prepare
   ```

   This waits for cloud-init, installs `nfs-common` if missing, mounts the export
   at `/mnt/anf-demo` and initializes `customer-demo/example.txt`. Output shows
   original content and its SHA-256 hash. **Run this successfully before the
   presentation.** Prepare can be repeated; it does not overwrite existing demo
   data. It refuses unexpected mounts or a nonempty local mount directory.

   The guest needs outbound HTTPS access for the Azure VM agent/Run Command and
   access to Ubuntu package sources. NAT supplies a route, not a firewall-policy
   exemption. If the agent is not ready yet, wait and retry Prepare. Guest errors
   and missing completion markers fail explicitly; inspect the returned output.

The existing `Test-AzureDeployment.ps1` remains a preflight for the **ARM JSON
scenario**, not a validator or What-If preview for this client/NAT deployment.
There is no Azure resource-level preview for this new direct PowerShell path.

## During the presentation

Open the dedicated group in the Azure portal. Show the ANF account, pool, volume,
NFSv3 protocol, delegated subnet and export rule restricted to the private client.
Prepare has already demonstrated writing and reading through the NFS mount.

### 1. Capture the populated volume

```powershell
./Invoke-AnfDemo.ps1 @demo -Action Snapshot
```

The guest checks that the original file exists and flushes its writes **before**
`demo-baseline` is created. Show this snapshot in the portal. An existing snapshot
is never silently reused or replaced by this step.

### 2. Change the example file

```powershell
./Invoke-AnfDemo.ps1 @demo -Action Change
```

Output now contains `ANF demo: changed during presentation` and a different hash.
The step also verifies that the snapshot contains the expected original data.

### 3. Recover the file from the snapshot

```powershell
./Invoke-AnfDemo.ps1 @demo -Action Restore
```

This copies the original example from
`/mnt/anf-demo/.snapshot/demo-baseline/customer-demo/example.txt` and compares it
with the restored file. The content and hash match the original again.
**This is file-level snapshot recovery, not a whole-volume revert, backup/DR
solution, database-consistent recovery or a performance benchmark.** Other files
are not modified. Keep real customer data out of this disposable environment.

Change and Restore can be repeated using the same baseline. Snapshot must not
be repeated: it intentionally refuses to overwrite an existing baseline. Use a
fresh demo for a new initial state. If the VM restarts, rerun Prepare to remount;
no persistent `/etc/fstab` entry is created. Do not change files manually while
a demo step is running. Run Command is not an interactive terminal and commands
on the same VM must not run concurrently.

## After the meeting: cleanup

**ANF capacity, the VM, disks, NAT gateway and public IP incur charges. Stopping
the VM does not stop the other charges.** No fixed price is quoted because it
depends on region, runtime and subscription pricing.

```powershell
# Offline summary of the target and destructive action; does not read inventory:
./Invoke-AnfDemo.ps1 @demo -Action Cleanup -WhatIf

# Reads ownership and inventory, displays resources, then asks for confirmation:
./Invoke-AnfDemo.ps1 @demo -Action Cleanup
```

Cleanup selects the explicit subscription again, requires matching ownership
tags and location, and rejects resource IDs outside the known demo inventory.
It deletes **the entire dedicated group**, including all data and snapshots.
Tags are an accidental-deletion guard, not an authorization boundary. Do not
retag an existing group to make it eligible or add unrelated resources.
Resource-list APIs may omit some child resources; all children of the dedicated
demo resources are deleted with their parents. Cleanup never searches other
groups or deletes expired demos automatically.

## Failures and restarting

- Deployment refuses every existing target group, including an earlier partial
  deployment. It does not adopt resources or resume a partly created VM.
- After failure, inspect `anfdemo-<DemoId>` in the portal, then run Cleanup with
  the same configuration. A partially populated, correctly tagged group can
  be cleaned up. Deploy again only after deletion has completed.
- A group with missing/changed ownership tags or unexpected resources is refused.
  Inspect it manually; do not bypass the guard by changing tags or deleting
  unreviewed data. Locks or insufficient permissions also require manual review.
- There is no automatic rollback: partial deployments can continue to cost money.
- If a guest step fails, fix the reported connectivity, mount or data issue
  before retrying. Do not create a replacement baseline over changed data.

Offline regression, real Az command-contract checks and Linux guest fixtures
cover the implementation. **Live Azure deployment, real NFS/snapshot behavior
and end-to-end cleanup have not yet been verified in a subscription.**
