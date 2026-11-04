# Azure NetApp Files customer demos

Disposable PowerShell/ARM examples for short Azure NetApp Files (ANF) customer
presentations, **not a production platform, database or disaster recovery
solution**. All setup, demonstration and cleanup instructions are in this file.
Run commands from the repository root.

**Live Azure deployment, real NFS/snapshot recovery and end-to-end cleanup remain
unverified.** Offline checks do not establish deployment compatibility.

| Start here | Purpose |
|---|---|
| [Single-region customer demo](#single-region-customer-demo) | Recommended: private Linux client, NFS usage, snapshot file recovery and guarded cleanup |
| [ARM JSON](#arm-json) | Alternative: single-region infrastructure through a template |
| [Two independent regions](#two-independent-regions) | Infrastructure in two regions; **no replication** |
| [Oracle infrastructure](#oracle-infrastructure) | Advanced infrastructure example; **no database setup** |
| [Azure preflight validation](#azure-preflight-validation) | Read-only Azure checks for the ARM JSON scenario |
| [Offline quality checks](#offline-quality-checks) | Local/CI checks without Azure credentials |

## Requirements

Use **PowerShell 7.4+** on Windows, Linux or macOS; Windows PowerShell 5.1/ISE is
not supported. Install modules explicitly, then authenticate:

```powershell
# Recommended customer demo and two-region example:
Install-Module Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles, Az.Compute -Scope CurrentUser
# Additionally for Oracle deployment or optional Oracle preflight image checks:
Install-Module Az.MarketplaceOrdering -Scope CurrentUser
Connect-AzAccount
Get-AzSubscription
```

The two-region script does not need `Az.Compute`; ARM JSON and its basic
preflight need only `Az.Accounts` and `Az.Resources`. Scripts never install
modules, change execution policy or accept Marketplace terms. Automation may
authenticate separately using a managed identity/service principal.

Before a meeting, verify regional ANF availability, quota/capacity, VM size and
image availability, permissions and connectivity. Resource-group creation needs
subscription-level permissions; other operations need appropriate resource
permissions. The client demo also needs
`Microsoft.Compute/virtualMachines/runCommand/action`. Policy, locks, deny
assignments and outbound restrictions may block operations; no roles, policy
exemptions or PIM access are configured.

Register `Microsoft.NetApp` and `Microsoft.Network`, plus `Microsoft.Compute` for
VM scenarios. Deployment scripts register providers only with explicit
`-RegisterProviders` permission/approval. Use region identifiers such as
`westeurope`, explicit subscription IDs and canonical IPv4 CIDRs.

All deployment/preflight entry points support `-WhatIf` and `-Confirm`.
**`-WhatIf` is an offline input check and operation summary, not an Azure
resource-level change calculation.** It does not import Az modules, authenticate,
register providers or access resources. Polling defaults to 900 seconds per wait
(`-TimeoutSeconds`); synchronous Az calls have their own durations.
No scenario performs automatic rollback: partial failures may leave billable
resources.

## Single-region customer demo

[`Invoke-AnfDemo.ps1`](Invoke-AnfDemo.ps1) provides:
**Deploy -> Prepare -> Snapshot -> Change -> Restore -> Cleanup**.
Deploy and Prepare belong **before** the meeting; Azure provisioning and Run
Command may take several minutes, with no guaranteed completion time.

### Resources and access

Everything is created in a **new, dedicated** group `anfdemo-<DemoId>`.

| Resource | Configuration |
|---|---|
| ANF account/pool | `anf-<DemoId>`, Standard, **4 TiB** pool |
| Volume | `demo-volume`, 100 GiB, NFSv3, export `demo`, visible snapshot directory |
| VNet | `10.42.0.0/16`; ANF subnet `10.42.2.0/24`, client subnet `10.42.1.0/24` |
| Ubuntu 24.04 LTS VM | `demo-client`, `Standard_D2s_v5`, Standard SSD OS disk, private IP `10.42.1.4` |
| Administration | Azure Run Command; no VM public IP, inbound SSH/RDP, VPN or Bastion |
| Outbound connectivity | Standard NAT gateway and outbound-only Standard public IP for Azure services and Ubuntu repositories |

An NSG on the client subnet/NIC denies inbound connections; stateful responses to
client-initiated traffic remain permitted. Default outbound rules are retained.
The NAT public IP is not assigned to the VM and provides no inbound access.
There is no peering with existing networks. A generated provisioning SSH key's
private half is discarded; there is intentionally no SSH login path.

NFS permits only **`10.42.1.4/32`**. Root access is deliberately enabled because
Run Command executes as root; do not copy this setting into production.
The group and supported client/network resources carry `anfDemo`, `demoId`,
`purpose` and `expiresOn` tags. ANF children use deterministic names; group tags
are not inherited. **Expiry defaults to eight hours and is a reminder, not
automatic deletion.** The 4 TiB/100 GiB baseline is conservative, not a claim
about Azure's current minimum sizes.

### Prepare before the meeting

Edit [`demo/demo.parameters.psd1`](demo/demo.parameters.psd1): replace the
subscription placeholder, choose a region and a unique, non-sensitive DemoId.
IDs must be 3-16 lowercase characters, start with a letter, end with a letter or
digit, and otherwise contain only letters, digits and hyphens.

```powershell
$demo = Import-PowerShellDataFile ./demo/demo.parameters.psd1
./Invoke-AnfDemo.ps1 @demo -Action Deploy -WhatIf
# Billable; add -RegisterProviders only if needed and authorized:
./Invoke-AnfDemo.ps1 @demo -Action Deploy
./Invoke-AnfDemo.ps1 @demo -Action Prepare
```

Deploy returns the resolved Ubuntu image version (`latest` is resolved anew for
each fresh demo). `-VmSize` selects an available compatible size;
`-ExpiresInHours` changes the expiry reminder.

Prepare waits for cloud-init, installs `nfs-common` if missing, mounts the export
at `/mnt/anf-demo`, and initializes `customer-demo/example.txt`. Output shows
original content and its SHA-256 hash. Repeat runs preserve existing demo data
and refuse unexpected mounts or a nonempty local mount directory.

**Complete Prepare successfully before the presentation.** The VM needs outbound
HTTPS for its agent/Run Command and access to Ubuntu package sources. NAT does
not bypass firewall policy. If the agent is not ready, wait and retry Prepare;
guest errors or missing completion markers fail explicitly with diagnostic
output. This path has no resource-level Azure preview; the ARM preflight below
does not validate the client/NAT deployment.

### Present to the customer

Open the group in the portal and show the account, pool, volume, NFSv3 protocol,
delegated subnet and restricted export. Prepare has demonstrated real NFS
writing/reading when run in Azure. Then execute these steps individually:

```powershell
# Verify and flush original data BEFORE creating demo-baseline; show it in the portal:
./Invoke-AnfDemo.ps1 @demo -Action Snapshot
# Show changed content and a different hash:
./Invoke-AnfDemo.ps1 @demo -Action Change
# Recover the original content/hash and compare it with the snapshot:
./Invoke-AnfDemo.ps1 @demo -Action Restore
```

Restore copies only
`/mnt/anf-demo/.snapshot/demo-baseline/customer-demo/example.txt` back to the
example file. **This is file-level snapshot recovery, not a volume revert,
backup/DR solution, database-consistent recovery or performance benchmark.**
Other files remain untouched; never put real customer data in this environment.

Change/Restore can be repeated against the same baseline. Snapshot refuses an
existing baseline rather than overwriting it; use a fresh demo for a new initial
state. After a VM restart, rerun Prepare to remount; no `/etc/fstab` entry is
created. Run Command is not interactive; do not run steps concurrently or
manually change demo files during a step.

### Cleanup and failure recovery

**ANF capacity, VM, disks, NAT and public IP incur charges. Stopping the VM does
not stop other charges.** Pricing depends on region, runtime and subscription.

```powershell
# Offline target/deletion summary only; no inventory query:
./Invoke-AnfDemo.ps1 @demo -Action Cleanup -WhatIf
# Inspect the displayed inventory, then confirm permanent deletion:
./Invoke-AnfDemo.ps1 @demo -Action Cleanup
```

Cleanup reselects the subscription, checks group ownership/location and rejects
resource IDs outside the known demo inventory. It deletes **the entire group,
all data and snapshots**, and checks deletion completion. Tags guard accidental
deletion, not authorization: never retag an existing group to pass this check or
add unrelated resources. Resource-list APIs may omit children; all children are
deleted with their dedicated demo parents. No other groups are searched and
expired demos are not deleted automatically.

Deploy refuses every existing target group, including partial deployments; it
does not adopt resources or resume a partial VM. After failure, inspect the group,
then run Cleanup with the same configuration. A partially populated, correctly
tagged group is eligible. Redeploy only after deletion finishes. Missing/changed
tags, unexpected resources, locks or permission failures require manual review,
not bypassing safeguards. Fix reported guest/connectivity/data errors before
retrying; never create a replacement baseline over changed data.

## ARM JSON

[`ANF with JSON/ANF_JSON_Deployment.ps1`](ANF%20with%20JSON/ANF_JSON_Deployment.ps1)
creates one account, pool, delegated VNet/subnet and NFS volume, **without a
client**. Edit
[`azuredeploy.parameters.json`](ANF%20with%20JSON/azuredeploy.parameters.json):
names, ranges, actual allowed client CIDRs, protocol and sizes. Samples use
4 TiB (`4398046511104` bytes) and 100 GiB (`107374182400` bytes); pool sizes must
be whole TiB, at least 4 TiB, and volume quota at least 100 GiB and no larger than
the pool. NFSv3/NFSv4.1 are supported; root access defaults to false.
The sample client `10.3.1.0/24` is a placeholder, not established connectivity.

```powershell
$arm = @{
    SubscriptionId = '<subscription-guid>'
    ResourceGroup = 'anf-json-poc'
    Location = 'westeurope'
}
& './ANF with JSON/ANF_JSON_Deployment.ps1' @arm -WhatIf
# Requires an existing group and registered providers; does not create resources:
& './ANF with JSON/ANF_JSON_Deployment.ps1' @arm -Preview
# Creates the group if missing, validates and deploys incrementally:
& './ANF with JSON/ANF_JSON_Deployment.ps1' @arm
```

Preview intentionally fails for a missing group; create a dedicated empty group
first if needed. `-TemplateFile`/`-TemplateParameterFile` accept local alternatives;
defaults resolve beside the script. `-Location` overrides file values. Only
ordinary parameter `value` entries are supported, not Key Vault `reference`.
The wrapper rejects unrestricted `0.0.0.0/0` exports and checks CIDR/capacity;
direct JSON deployment requires equivalent checks beyond ARM constraints.

**Use a dedicated VNet.** The template owns its address space and inline subnet
list: incremental deployment may remove undeclared subnets/settings. Review
Preview before updating existing resources. Outputs are `accountId`, `poolId`,
`volumeId`, `subnetId`. APIs are NetApp `2026-08-01` and Network `2026-03-01`;
validate availability in your cloud. No automatic cleanup is provided.

## Two independent regions

[`ANF-PoC-Deployment.ps1`](ANF-PoC-Deployment.ps1) creates an ANF environment in
each region, without clients or cross-region replication:

```powershell
$regions = @{
    SubscriptionId = '<subscription-guid>'
    Location = 'westeurope'; ResourceGroup = 'anf-poc-west'
    AnfAccountName = 'anfpocwest'; CreationToken = 'poc-west'
    NetworkAddressPrefix = '10.10.0.0/16'; SubnetAddressPrefix = '10.10.2.0/24'
    AllowedClients = @('10.10.1.0/24')
    SecondLocation = 'northeurope'; SecondResourceGroup = 'anf-poc-north'
    SecondAnfAccountName = 'anfpocnorth'; SecondCreationToken = 'poc-north'
    SecondNetworkAddressPrefix = '10.20.0.0/16'; SecondSubnetAddressPrefix = '10.20.2.0/24'
    SecondAllowedClients = @('10.20.1.0/24')
}
./ANF-PoC-Deployment.ps1 @regions -WhatIf
./ANF-PoC-Deployment.ps1 @regions
```

Defaults per region: 4 TiB pool, 100 GiB volume, Standard, NFSv3.
`-PoolSizeTiB`, `-VolumeSizeGiB`, `-ServiceLevel`, `-Protocol` (also NFSv4.1)
configure both. Snapshots are opt-in with `-CreateSnapshots`; `-SnapshotName`
defaults to `MyAnfSnapshot`. Existing snapshots are retained, not refreshed.
Matching resources are reused; managed configuration drift aborts without
replacing resources or widening access. Existing VNets must contain the expected
subnet/delegation; other unmanaged settings are not reconciled.
NFS exports reject `0.0.0.0/0`; root access needs explicit `-AllowRootAccess`.
Client routing and filesystem permissions must be arranged separately.

## Oracle infrastructure

[`OracleDB-ANF-PoC-Deployment.ps1`](Oracle%20on%20Azure/OracleDB-ANF-PoC-Deployment.ps1)
creates a private Windows Server 2022 application VM, Linux Oracle Marketplace
VM, one 4 TiB pool, two 100 GiB NFSv3 volumes and three VNets.
Bidirectional peerings connect App-to-Oracle and Oracle-to-ANF. Peering is not
transitive: App has no direct ANF connection.

**Infrastructure only:** no database initialization, mounts, Oracle Direct NFS,
listener rules, Bastion/VPN/NAT, performance or licensing validation. Arrange
private administration and outbound access separately. Default NSG rules permit
virtual-network/peered traffic, not Internet-wide SSH/RDP.

```powershell
$oracle = @{
    SubscriptionId = '<subscription-guid>'; Location = 'westeurope'
    ResourceGroup = 'oracle-anf-poc'; AnfAccountName = 'oracleanfpoc'
    Cred = Get-Credential -Message 'Windows application VM administrator'
    SshPublicKey = (Get-Content ~/.ssh/id_ed25519.pub -Raw).Trim()
}
& './Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1' @oracle -WhatIf
& './Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1' @oracle
```

Supply a public key value, never a private key or filename. Default Oracle image:
`oracle:oracle-database-19-3:oracle-database-19-0904:latest`. Availability is checked
before resource creation; purchase-plan terms must already be accepted. VM
security type is `Standard` for the original generation-1 image.
Override `-OracleImagePublisher`, `-OracleImageOffer`, `-OracleImageSku`,
`-OracleImageVersion`; a concrete version improves reproducibility.

Defaults: App `10.5.0.0/16`/`10.5.2.0/24`, ANF `10.6.0.0/16`/`10.6.2.0/24`,
Oracle `10.7.0.0/16`/`10.7.2.0/24`. VNets must not overlap. Only the Oracle
subnet is exported; root access is off unless `-AllowRootAccess` is specified.
Options include `-OracleAdminUsername`, `-VmSize`, `-AppImageSku`,
`-PoolSizeTiB`, `-VolumeSizeGiB`, `-ServiceLevel` and network parameters.

Matching ANF/VNet resources are reused. Existing VMs/NICs/NSGs cause failure,
not adoption/overwrite. After partial failure, inspect and explicitly remove or
migrate conflicting resources before retrying; do not delete data volumes to
bypass checks. The historical name `OracelVM-VNet` is intentionally retained.

For these infrastructure-only scenarios, review each exact group's contents
before manually removing dedicated groups; do not use the single-region demo's
Cleanup action on them:

```powershell
Get-AzResource -ResourceGroupName 'anf-poc-west'
Remove-AzResourceGroup -Name 'anf-poc-west' -WhatIf
# Remove -WhatIf only after confirming the entire group can be deleted.
```

## Azure preflight validation

[`Test-AzureDeployment.ps1`](Test-AzureDeployment.ps1) checks the **ARM JSON
scenario**, not the recommended client/NAT demo or Oracle network/VM deployment.
Edit the ARM parameter file and use an existing dedicated group with registered
providers and the intended deployment identity, not merely a Reader account:

```powershell
$validation = @{
    SubscriptionId = '<subscription-guid>'
    ResourceGroup = 'existing-anf-test-group'; Location = 'westeurope'
}
./Test-AzureDeployment.ps1 @validation -WhatIf
$result = ./Test-AzureDeployment.ps1 @validation
$result | Select-Object SubscriptionId, ResourceGroup, Location, ValidationStatus
$result.ResourceCapabilities | Format-Table
$result.WhatIfResult
# Optional Oracle/application image and purchase-plan checks:
$result = ./Test-AzureDeployment.ps1 @validation -CheckOracleImages
$result.Images | Format-Table
```

Checks subscription enabled state, group existence, providers, advertised
API/region support, baseline resource-group grants, ARM validation and incremental
What-If. Grants are paginated with `NotActions` applied per grant. Requires
subscription/provider/location/resource reads,
`Microsoft.Authorization/permissions/read` and deployment-related validation/
What-If write permissions, resource read/write and subnet join. Grants only on
individual resources may not satisfy this conservative baseline.

Optional image checks use the Oracle image overrides and `-AppImageSku`, return
resolved versions, and never accept terms. Without them, no Compute module/
provider or image queries are needed. `-TemplateFile`/`-TemplateParameterFile`
select local variants; this is not a general ARM validator: nested deployments/
resources, other resource types, computed APIs/unsupported location expressions
are rejected. Context is selected only for the process with autosave disabled.
No registration, creation, deletion, role assignment or report file is performed.

**Success is not a deployment guarantee:** deny assignments, RBAC conditions,
Policy, locks, quotas, live capacity, routing, mounts, VM sizes, licensing and
database operation are not independently validated. Inspect full What-If
diagnostics, including incomplete/ignored changes. This is manual, not part of
credential-free CI.

## Offline quality checks

```powershell
# Dependency-free PowerShell regression suite:
pwsh -NoProfile -File ./tests/Run-Tests.ps1
# Complete local/CI checks; explicitly download tools once:
pwsh -NoProfile -File ./tests/Invoke-QualityChecks.ps1 -InstallTools
# Reuse cache without network or Azure login:
pwsh -NoProfile -File ./tests/Invoke-QualityChecks.ps1
```

Regression checks cover syntax, JSON/ARM samples, input boundaries, failures,
repeat runs, orchestration, snapshot ordering and cleanup guards using Azure
command doubles. Non-Windows runs also exercise the Linux guest script with
local mount/agent fixtures and real temporary files, **not actual NFS**.

The full runner imports real **Az 16.5.0** component metadata to check command/
parameter names, mandatory parameters, parameter sets, literal splats/appended
keys/helper forwarding and pipeline binding metadata. Unknown commands and
unresolved/unsupported constructs fail; valid/invalid fixtures check the checker.
This does not validate runtime argument values/types, actual pipeline objects,
Azure responses or deployment success. Fresh `pwsh -NoProfile` subprocesses
isolate mocks from real modules.

[`QualityTools.psd1`](tests/QualityTools.psd1) pins six Az components and
**PSScriptAnalyzer 1.25.0**. `-InstallTools` downloads official GitHub release
assets with SHA-256 verification (Az archive about 139 MB), not PowerShell Gallery.
Requires `tar`, PowerShell 7.4+ and access to GitHub releases. The isolated cache
defaults to the OS temporary directory; use `-ToolsPath '/path/outside/the/repo'`
consistently for a persistent cache. Cached executable code is trusted, not
rehashed each run; never share a writable cache with untrusted users.
No global modules are installed or fallback versions/sources selected.
Record deployment modules with `Get-Module Az.* -ListAvailable`.

The [quality workflow](.github/workflows/quality.yml) runs the same entry point
on PRs, pushes to `master` and manual dispatch, on Ubuntu 24.04/Windows Server
2025. All PowerShell scripts are parsed; analyzer warnings/errors fail, with
only the mock-heavy `tests/Run-Tests.ps1` excluded from linting. Checkout is
commit-pinned; OS images and PowerShell patches remain runner-managed.
Permissions are read-only, credentials are not persisted, and no Azure secrets/
login/deployments are used. GitHub Actions plan/billing limits still apply.
Mandatory passing checks require separately configured branch protection/rulesets.

## References

- [ANF provider registration](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-register)
- [ANF limits](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-resource-limits)
- [ANF networking](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-network-topologies)
- [ARM What-If](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if)

Originally authored by Christian Twilfer, 2020-2021.
