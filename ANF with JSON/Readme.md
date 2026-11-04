# Azure NetApp Files with ARM JSON

Creates one ANF account, capacity pool, delegated VNet/subnet and NFS volume.
Use PowerShell 7.4+ and explicitly install `Az.Accounts` and `Az.Resources`.
Authenticate with `Connect-AzAccount` before deployment.

## Parameters

Edit [`azuredeploy.parameters.json`](azuredeploy.parameters.json) before use.
Specify names, whole-TiB pool capacity in **bytes**, volume capacity in **bytes**,
service level, protocol and network ranges. The pool name and service level now
consistently apply to both pool and volume. Supported protocols are `NFSv3` and
`NFSv4.1`, with matching export rules.

`netappAllowedClients` is a required array of explicit IPv4 client CIDRs.
The sample `10.3.1.0/24` is only a placeholder; use your actual client network
and establish connectivity separately. `netappAllowRootAccess` defaults to
`false`. The PowerShell wrapper rejects an unrestricted `0.0.0.0/0` export.
If deploying the JSON directly with another tool, perform equivalent CIDR and
capacity checks yourself; ARM parameter constraints alone do not enforce them.

Default sample sizes remain 4 TiB (`4398046511104` bytes) and 100 GiB
(`107374182400` bytes). The wrapper requires a pool of at least 4 TiB in whole
TiB increments, a volume of at least 100 GiB and volume quota no larger than the pool.

## Run from the repository root

```powershell
$deployment = @{
    SubscriptionId = '<subscription-guid>'
    ResourceGroup = 'anf-json-poc'
    Location = 'westeurope'
}

# Local checks and operation summary; no Azure access or writes:
& './ANF with JSON/ANF_JSON_Deployment.ps1' @deployment -WhatIf

# Requires an existing group and already registered providers; no Azure resource writes:
& './ANF with JSON/ANF_JSON_Deployment.ps1' @deployment -Preview

# Creates the group if missing, validates the template and deploys incrementally:
& './ANF with JSON/ANF_JSON_Deployment.ps1' @deployment
```

For a new resource group, `-Preview` intentionally fails rather than creating it.
Create a dedicated empty resource group explicitly if you need ARM What-If before
the first deployment. Add `-RegisterProviders` only to an actual deployment if
`Microsoft.NetApp`/`Microsoft.Network` are not already registered.

`-TemplateFile` and `-TemplateParameterFile` accept alternative local files.
Defaults resolve beside the script, not relative to the shell's working
directory. `-Location` always overrides any parameter-file location. Parameter
files must contain ordinary `value` entries; Key Vault `reference` entries are
not supported by this wrapper.

**Use a dedicated VNet.** The template owns the complete VNet address space and
inline subnet list. Incremental deployment can still modify existing resources,
including removal of subnets not declared by this template. Always review the
Azure preview before updating an existing environment.

Outputs: `accountId`, `poolId`, `volumeId` and `subnetId`. Provisioning errors are
reported as failures; no automatic cleanup is performed.

For subscription state, effective resource-group permissions and advertised
API/region checks **before** ARM validation and What-If, use
[`Test-AzureDeployment.ps1`](../Test-AzureDeployment.ps1). See the
[Azure preflight instructions](../README.md#azure-preflight-validation).
It requires an existing test resource group and never creates resources or
registers providers.
