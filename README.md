# Azure NetApp Files PowerShell examples

PowerShell and ARM examples for Azure NetApp Files (ANF). These are **paid
proof-of-concept deployments**, not a production-ready database or disaster
recovery solution.

| Entry point | Resources |
|---|---|
| [`ANF-PoC-Deployment.ps1`](ANF-PoC-Deployment.ps1) | Two independent regions, each with a resource group, delegated VNet/subnet, ANF account, pool and NFS volume; optional snapshots |
| [`ANF with JSON`](ANF%20with%20JSON/Readme.md) | One ANF environment using an ARM JSON template |
| [`Oracle on Azure`](Oracle%20on%20Azure/Readme.md) | Windows application VM, Linux Oracle VM, two ANF volumes and VNet peerings |
| [`Test-AzureDeployment.ps1`](Test-AzureDeployment.ps1) | Read-only Azure prerequisite checks, ARM validation and What-If for the single-region ANF template; optional Oracle/application image checks |

## Requirements

- PowerShell **7.4 or newer** on Windows, Linux or macOS; Windows PowerShell
  5.1/ISE is no longer supported.
- Install the required Az modules explicitly before deployment. Scripts never
  install/update modules or change your execution policy:

  ```powershell
  Install-Module Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles -Scope CurrentUser
  # Additionally, for the Oracle infrastructure example:
  Install-Module Az.Compute, Az.MarketplaceOrdering -Scope CurrentUser
  ```

- Use current supported Az modules. No exact Az release has been certified
  against a live subscription for these examples. Record the versions used for
  your environment with `Get-Module Az.* -ListAvailable`.
- Authenticate explicitly, then pass the intended subscription to each script:

  ```powershell
  Connect-AzAccount
  Get-AzSubscription
  # Automation can authenticate separately with a managed identity/service principal.
  ```

- Resource creation requires suitable permissions on the target subscription or
  resource groups. Resource-group creation needs subscription-level permissions.
  Provider registration needs the relevant registration permissions.
- `Microsoft.NetApp` and `Microsoft.Network` must be registered; the Oracle
  scenario also requires `Microsoft.Compute`. Registration is performed only
  when `-RegisterProviders` is explicitly supplied. It has a bounded wait.
- Check ANF region availability, subscription quota, capacity, image availability
  and network connectivity before deployment. Network arguments use canonical
  IPv4 CIDRs; region arguments use identifiers such as `westeurope`.

## Two independent regions

Use your own subscription ID, names and non-conflicting network ranges:

```powershell
$deployment = @{
    SubscriptionId = '<subscription-guid>'
    Location = 'westeurope'
    ResourceGroup = 'anf-poc-west'
    AnfAccountName = 'anfpocwest'
    CreationToken = 'poc-west'
    NetworkAddressPrefix = '10.10.0.0/16'
    SubnetAddressPrefix = '10.10.2.0/24'
    AllowedClients = @('10.10.1.0/24')
    SecondLocation = 'northeurope'
    SecondResourceGroup = 'anf-poc-north'
    SecondAnfAccountName = 'anfpocnorth'
    SecondCreationToken = 'poc-north'
    SecondNetworkAddressPrefix = '10.20.0.0/16'
    SecondSubnetAddressPrefix = '10.20.2.0/24'
    SecondAllowedClients = @('10.20.1.0/24')
}

./ANF-PoC-Deployment.ps1 @deployment -WhatIf
# Review the inputs before executing without -WhatIf:
./ANF-PoC-Deployment.ps1 @deployment
```

Defaults remain **4 TiB per pool**, **100 GiB per volume**, Standard service level
and NFSv3. `-PoolSizeTiB`, `-VolumeSizeGiB`, `-ServiceLevel` and `-Protocol`
configure both regions. NFSv4.1 is also supported. The example deliberately keeps
the conservative 4 TiB/100 GiB baseline; these are not claims about the current
minimum sizes offered by Azure.

Snapshots are now **opt-in** with `-CreateSnapshots`. `-SnapshotName` defaults to
`MyAnfSnapshot`; an existing snapshot with the same name is retained, not refreshed.
Use another name to take a new snapshot. **Cross-region replication is not
implemented**; the two volumes remain independent.

## Preview, repeat runs and failures

- All entry points support `-WhatIf` and `-Confirm`. `-WhatIf` validates local
  inputs and prints a scenario-level operation summary, without importing Az
  modules, authenticating, registering providers or writing Azure resources.
  It is not a resource-by-resource Azure change calculation.
- The ARM entry point additionally offers `-Preview` for an Azure ARM What-If
  against an **existing resource group**. Providers must already be registered.
  Preview does not create the group or register providers.
- Direct ANF deployments reuse matching accounts, pools, VNets, volumes and
  snapshots. Managed configuration differences stop execution rather than
  silently replacing resources or widening access. Existing VNets must already
  contain the expected subnet and delegation. Other unmanaged settings are not
  reconciled. Use dedicated PoC resources.
- The ARM template owns its VNet and inline subnet. Incremental mode does **not**
  mean that unrelated subnets/settings on that VNet will be preserved. Do not
  point this template at a shared VNet; review `-Preview` before redeploying.
- Oracle VM/NIC/NSG resources are deliberately **not adopted or overwritten** on
  a repeat run. Existing resources with the expected names cause an explicit
  failure; see the Oracle README for recovery after a partial deployment.
- Azure command failures stop the script. Provider/resource polling has a
  configurable `-TimeoutSeconds` (default 900 per wait). Synchronous Az command
  durations are governed by Az itself, not this polling timeout.
- Deployments are not transactional. A failure can leave billable resources.
  No automatic rollback or deletion is performed.

## Azure preflight validation

[`Test-AzureDeployment.ps1`](Test-AzureDeployment.ps1) checks the single-region
ANF ARM scenario against Azure **without deploying it**. First edit the
[sample parameters](ANF%20with%20JSON/azuredeploy.parameters.json) for your
environment. Authenticate explicitly and use a pre-existing, dedicated test
resource group:

```powershell
Connect-AzAccount
$validation = @{
    SubscriptionId = '<subscription-guid>'
    ResourceGroup = 'anf-validation-test'
    Location = 'westeurope'
}

# Local parameter checks and operation summary only; no Azure connection:
./Test-AzureDeployment.ps1 @validation -WhatIf

# Real Azure queries, ARM validation and incremental What-If:
$result = ./Test-AzureDeployment.ps1 @validation
$result | Select-Object SubscriptionId, ResourceGroup, Location, ValidationStatus
$result.ResourceCapabilities | Format-Table
$result.WhatIfResult
```

The script requires PowerShell 7.4+, `Az.Accounts` and `Az.Resources`. It checks:

- The selected subscription is enabled and the resource group exists.
- `Microsoft.NetApp` and `Microsoft.Network` are already registered.
- The target region and literal stable API versions are advertised by the
  subscription for each resource type in the template.
- Effective control-plane permissions at the resource-group scope allow the
  baseline deployment/validation/What-If, resource read/write and subnet join
  actions. Permission pages are combined with `NotActions` applied per grant.
- Azure accepts the template validation and returns a successful incremental
  ARM What-If. The complete preview is returned for inspection, not applied.

Use the **identity intended for deployment**, not merely a Reader account.
Validation/What-If do not change infrastructure but require deployment-related
write permissions. The identity also needs subscription/provider/location reads,
`Microsoft.Authorization/permissions/read` at the resource group, and resource
read access. These checks do not assign roles or activate PIM access.
Resource-group-level grants are the conservative baseline: permissions granted
only on individual existing resources may not satisfy it.

To check the Oracle scenario's Linux image, Windows application image and any
Marketplace purchase-plan acceptance as well:

```powershell
# Also requires explicitly installed Az.Compute and Az.MarketplaceOrdering:
$result = ./Test-AzureDeployment.ps1 @validation -CheckOracleImages
$result.Images | Format-Table
```

Image defaults match the Oracle deployment script. Optional overrides are
`-OracleImagePublisher`, `-OracleImageOffer`, `-OracleImageSku`,
`-OracleImageVersion` and `-AppImageSku`. `latest` is resolved and the selected
versions are included in the result. Marketplace terms are checked, **never
accepted**. Without `-CheckOracleImages`, no Compute module/provider or image
queries are required and the result explicitly marks image checks as not run.

`-TemplateFile` and `-TemplateParameterFile` can select local variants of the
repository's single-region ANF template; location is always supplied explicitly.
This is not a general ARM validator: nested resources/deployments, other resource
types, computed API versions and other location expressions are rejected before
Azure access. No registration, resource-group creation, deployment, deletion,
permission assignment or local report file is performed. The active Azure
subscription context is selected for the current process with autosave disabled.

**A successful preflight is not a deployment guarantee.** Effective grant checks
do not independently evaluate deny assignments, RBAC conditions, Azure Policy,
locks, quotas or live regional capacity. ARM may catch some of these, but What-If
can also contain incomplete/ignored changes; inspect the full result and its
diagnostics. The script does not check client routing, NFS mounts, VM sizes,
Oracle licensing or database operation. Optional image checks do not validate
the Oracle network/VM deployment. A later real deployment still requires separate
authorization and may incur costs.

The script is run manually, not by the credential-free GitHub Actions workflow.
Offline regression tests simulate Azure responses; a real run requires your
Azure login and target subscription/resource group.

## Network and access changes

NFS clients must be supplied explicitly; `0.0.0.0/0` is rejected by the
PowerShell entry points. Client networks also need real connectivity; an export
rule alone does not establish routing or peering. Root access is disabled unless
`-AllowRootAccess` (or ARM `netappAllowRootAccess`) is explicitly enabled.
Root squashing and filesystem permissions must be considered when mounting and
initializing workloads.

The Oracle example now uses private NICs, Linux/SSH for Oracle and Windows Server
2022 for the application VM. It does not create public IP addresses, Internet-wide
RDP/SSH rules or a Bastion host. Provide private administrative connectivity
separately. Existing deployments are not automatically migrated.

## Local checks

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

The dependency-free checks cover PowerShell syntax, input boundaries, status
timeouts, offline previews, repeat runs, ARM validation handling and Oracle
orchestration using Azure command doubles. They do not create Azure resources
and do not replace a live integration test or workload validation.

The ARM template uses stable `Microsoft.NetApp` API `2026-08-01` and
`Microsoft.Network` API `2026-03-01`, verified in the published
[Azure REST API specifications](https://github.com/Azure/azure-rest-api-specs).
Validate availability in the intended Azure cloud before deploying.

## Automated quality checks

The [Quality checks workflow](.github/workflows/quality.yml) runs on every pull
request, on pushes to `master`, and manually through the Actions tab once the
workflow is on the default branch. Each run uses both Ubuntu 24.04 and Windows
Server 2025, with PowerShell 7.4+ supplied by the GitHub-hosted runner.

Both platforms run the offline tests, including JSON parsing and ARM sample
parameter checks (required values, types, allowed values, size/length constraints,
CIDRs and capacity). They also analyze deployment scripts with **PSScriptAnalyzer
1.25.0**. Analyzer warnings or errors fail the check. Test command doubles are
excluded from linting, but all PowerShell files are parsed by the test suite.

Checkout is pinned to a commit and the analyzer to an exact version. Runner
images and their bundled PowerShell patches receive GitHub updates. The workflow
has read-only repository permissions, does not persist Git credentials, and
requires no secrets, Azure login or deployments. Only the analyzer installation
needs access to PowerShell Gallery. GitHub Actions usage is subject to the
repository's plan and billing settings; no Azure resources or costs are created.

Failures appear in the pull request checks and Actions logs. To make passing
checks mandatory before merging, configure a repository ruleset or branch
protection rule separately; this workflow does not change repository rules.
Local template checks do not replace Azure ARM validation or integration tests.

## Cost and cleanup

The two-region example allocates two capacity pools; the Oracle example also
allocates VMs and disks. Stopped VMs do not eliminate storage/ANF charges.
After reviewing the **exact** resource groups and their contents, delete dedicated
PoC groups explicitly, for example:

```powershell
Get-AzResource -ResourceGroupName 'anf-poc-west'
Remove-AzResourceGroup -Name 'anf-poc-west' -WhatIf
# Remove -WhatIf only after confirming that the entire group can be deleted.
```

## References

- [ANF resource provider registration](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-register)
- [ANF resource limits](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-resource-limits)
- [ANF network guidelines](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-network-topologies)
- [ARM What-If](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-what-if)

Originally authored by Christian Twilfer, 2020-2021.
