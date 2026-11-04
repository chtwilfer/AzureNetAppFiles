#requires -Version 7.4
<#
.SYNOPSIS
Validates and deploys the Azure NetApp Files ARM template.
.DESCRIPTION
WhatIf provides an offline operation summary. Preview requests an Azure ARM
What-If against an existing resource group without creating or registering anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroup,
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [string] $TemplateFile = "$PSScriptRoot/azuredeploy.json",
    [string] $TemplateParameterFile = "$PSScriptRoot/azuredeploy.parameters.json",
    [ValidateNotNullOrEmpty()][string] $DeploymentName = 'NetApp-Deployment',
    [switch] $Preview,
    [switch] $RegisterProviders,
    [ValidateRange(1, 7200)][int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/Deployment.Common.ps1"
$TemplateFile = (Resolve-Path -LiteralPath $TemplateFile -ErrorAction Stop).Path
$TemplateParameterFile = (Resolve-Path -LiteralPath $TemplateParameterFile -ErrorAction Stop).Path
$template = Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json -AsHashtable
$parameterDocument = Get-Content -LiteralPath $TemplateParameterFile -Raw | ConvertFrom-Json -AsHashtable
$parameters = @{}
foreach ($name in $parameterDocument.parameters.Keys) {
    if (-not $template.parameters.ContainsKey($name)) {
        throw "Unknown template parameter '$name'."
    }
    if (-not $parameterDocument.parameters[$name].ContainsKey('value')) {
        throw "Parameter '$name' must contain a value. Key Vault references are not supported by this wrapper."
    }
    $parameters[$name] = $parameterDocument.parameters[$name].value
}
# The script's explicit location always wins over a parameter-file location.
$parameters.location = $Location
foreach ($name in $template.parameters.Keys) {
    if (-not $template.parameters[$name].ContainsKey('defaultValue') -and -not $parameters.ContainsKey($name)) {
        throw "Missing required template parameter '$name'."
    }
    if (-not $parameters.ContainsKey($name)) {
        $parameters[$name] = $template.parameters[$name].defaultValue
    }
}
Assert-AnfNetwork -Network $parameters.netappVirtualNetworkAddressPrefix `
    -Subnet $parameters.netappVirtualNetworkSubnetAddressPrefix -AllowedClients $parameters.netappAllowedClients
Assert-AnfCapacity -PoolSizeBytes $parameters.netappPoolSize -VolumeSizeBytes $parameters.netappVolumeSize

if (-not $PSCmdlet.ShouldProcess("Subscription $SubscriptionId; $ResourceGroup/$Location",
    "Validate ARM template and $(if ($Preview) { 'request read-only ARM What-If' } else { 'deploy incrementally' }); provider registration: $($RegisterProviders -and -not $Preview)")) {
    return
}
Import-AnfModule -Name Az.Accounts, Az.Resources
Initialize-AnfContext -SubscriptionId $SubscriptionId -RegisterProviders:($RegisterProviders -and -not $Preview) `
    -TimeoutSeconds $TimeoutSeconds
if ($Preview) {
    $group = Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $ResourceGroup
    if (-not $group) {
        throw 'ARM preview requires an existing resource group. No resource group was created.'
    }
} else {
    Initialize-AnfResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
}

$deployment = @{
    ResourceGroupName = $ResourceGroup; TemplateFile = $TemplateFile
    TemplateParameterObject = $parameters; ErrorAction = 'Stop'
}
$validationErrors = @(Test-AzResourceGroupDeployment @deployment)
if ($validationErrors.Count -gt 0) {
    throw "ARM validation failed: $($validationErrors | ConvertTo-Json -Depth 10 -Compress)"
}
if ($Preview) {
    Get-AzResourceGroupDeploymentWhatIfResult @deployment
} else {
    $result = New-AzResourceGroupDeployment @deployment -Name $DeploymentName -Mode Incremental
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "ARM deployment ended in state '$($result.ProvisioningState)'."
    }
    $result
}
