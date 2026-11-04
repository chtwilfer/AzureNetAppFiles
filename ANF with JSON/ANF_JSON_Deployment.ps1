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
$inputData = Get-AnfTemplateInput -TemplateFile $TemplateFile -TemplateParameterFile $TemplateParameterFile -Location $Location

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
    ResourceGroupName = $ResourceGroup; TemplateFile = $inputData.TemplateFile
    TemplateParameterObject = $inputData.Parameters; ErrorAction = 'Stop'
}
Assert-AnfArmValidation -Deployment $deployment
if ($Preview) {
    Get-AzResourceGroupDeploymentWhatIfResult @deployment
} else {
    $result = New-AzResourceGroupDeployment @deployment -Name $DeploymentName -Mode Incremental
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "ARM deployment ended in state '$($result.ProvisioningState)'."
    }
    $result
}
