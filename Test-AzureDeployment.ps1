#requires -Version 7.4
<#
.SYNOPSIS
Checks Azure prerequisites and previews the repository's single-region ANF ARM deployment.
.DESCRIPTION
Requires an existing Azure login and resource group. Reads subscription state,
provider capabilities and effective resource-group permissions, then requests ARM
validation and incremental What-If. No resources, registrations, role assignments,
Marketplace agreements or deployments are created. WhatIf runs local checks only.
.EXAMPLE
./Test-AzureDeployment.ps1 -SubscriptionId '<guid>' -ResourceGroup 'anf-test' -Location 'westeurope'
.EXAMPLE
./Test-AzureDeployment.ps1 -SubscriptionId '<guid>' -ResourceGroup 'anf-test' -Location 'westeurope' -CheckOracleImages
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
    [string] $TemplateFile = "$PSScriptRoot/ANF with JSON/azuredeploy.json",
    [string] $TemplateParameterFile = "$PSScriptRoot/ANF with JSON/azuredeploy.parameters.json",
    [switch] $CheckOracleImages,
    [ValidateNotNullOrEmpty()][string] $AppImageSku = '2022-datacenter',
    [ValidateNotNullOrEmpty()][string] $OracleImagePublisher = 'oracle',
    [ValidateNotNullOrEmpty()][string] $OracleImageOffer = 'oracle-database-19-3',
    [ValidateNotNullOrEmpty()][string] $OracleImageSku = 'oracle-database-19-0904',
    [ValidateNotNullOrEmpty()][string] $OracleImageVersion = 'latest'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/Deployment.Common.ps1"
$inputData = Get-AnfTemplateInput -TemplateFile $TemplateFile -TemplateParameterFile $TemplateParameterFile -Location $Location
$supportedTypes = @(
    'Microsoft.NetApp/netAppAccounts',
    'Microsoft.NetApp/netAppAccounts/capacityPools',
    'Microsoft.NetApp/netAppAccounts/capacityPools/volumes',
    'Microsoft.Network/virtualNetworks'
)
$resources = @($inputData.Template.resources)
if ($resources.Count -eq 0) {
    throw 'The ANF template must contain resources.'
}
foreach ($resource in $resources) {
    if ($resource.type -notin $supportedTypes -or $resource.resources -or
        $resource.location -ne "[parameters('location')]" -or $resource.apiVersion -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw 'Preflight supports only the single-region ANF template with literal stable APIs and no nested resources.'
    }
}
if (-not $PSCmdlet.ShouldProcess("Subscription $SubscriptionId; existing group $ResourceGroup; region $Location",
    "Read Azure prerequisites and permissions; validate ANF ARM template and request incremental What-If; Oracle image checks: $CheckOracleImages")) {
    return
}

$modules = @('Az.Accounts', 'Az.Resources')
$providers = @('Microsoft.NetApp', 'Microsoft.Network')
if ($CheckOracleImages) {
    $modules += @('Az.Compute', 'Az.MarketplaceOrdering')
    $providers += 'Microsoft.Compute'
}
Import-AnfModule -Name $modules
Initialize-AnfContext -SubscriptionId $SubscriptionId -ProviderNamespace $providers
$subscription = Get-AzSubscription -SubscriptionId $SubscriptionId.ToString() -ErrorAction Stop
if (-not $subscription -or $subscription.State -ne 'Enabled') {
    throw 'The requested Azure subscription is not enabled.'
}
$group = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction Stop
if (-not $group) {
    throw 'Azure validation requires an existing resource group. No resource group was created.'
}
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$([uri]::EscapeDataString($ResourceGroup))"
$region = Get-AzLocation -ErrorAction Stop | Where-Object Location -EQ $Location
if (-not $region) {
    throw "Azure region identifier '$Location' is not available in this subscription."
}

$capabilities = foreach ($resource in $resources) {
    $namespace, $resourceType = $resource.type -split '/', 2
    $provider = Get-AzResourceProvider -ProviderNamespace $namespace -ErrorAction Stop
    $type = $provider.ResourceTypes | Where-Object ResourceTypeName -EQ $resourceType
    if (-not $type -or $resource.apiVersion -notin $type.ApiVersions) {
        throw "API '$($resource.apiVersion)' for '$($resource.type)' is not advertised by this subscription."
    }
    if ($Location -notin $type.Locations -and $region.DisplayName -notin $type.Locations) {
        throw "Region '$Location' is not advertised for '$($resource.type)'. Availability could not be confirmed."
    }
    [pscustomobject]@{ Type = $resource.type; ApiVersion = $resource.apiVersion; Location = $Location }
}

# Each permission entry is Actions minus its own NotActions; separate grants are additive.
$permissions = @()
$permissionsPath = "$scope/providers/Microsoft.Authorization/permissions"
$pagePath = "${permissionsPath}?api-version=2022-04-01"
$visited = @{}
do {
    if ($visited.ContainsKey($pagePath)) {
        throw 'Azure permissions pagination returned a repeated link.'
    }
    $visited[$pagePath] = $true
    $response = Invoke-AzRestMethod -Method GET -Path $pagePath -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        throw "Reading effective resource-group permissions failed (HTTP $($response.StatusCode)): $($response.Content)"
    }
    $page = $response.Content | ConvertFrom-Json -AsHashtable
    if (-not $page.ContainsKey('value')) {
        throw 'Azure permissions response did not contain a value collection.'
    }
    $permissions += @($page.value)
    $pagePath = $null
    if ($page.nextLink) {
        # Use ARM's configured endpoint, never a server-provided alternate host.
        $nextUri = [uri] $page.nextLink
        $pagePath = if ($nextUri.IsAbsoluteUri) { $nextUri.PathAndQuery } else { [string] $page.nextLink }
        if (($pagePath -split '\?', 2)[0] -ine $permissionsPath) {
            throw 'Azure permissions pagination returned an unexpected scope.'
        }
    }
} while ($pagePath)

$requiredActions = @(
    'Microsoft.Resources/subscriptions/resourceGroups/read',
    'Microsoft.Resources/deployments/read',
    'Microsoft.Resources/deployments/write',
    'Microsoft.Resources/deployments/validate/action',
    'Microsoft.Resources/deployments/whatIf/action',
    'Microsoft.Network/virtualNetworks/subnets/join/action'
) + @($resources | ForEach-Object { "$($_.type)/read"; "$($_.type)/write" })
foreach ($action in $requiredActions | Sort-Object -Unique) {
    $allowed = $false
    foreach ($permission in $permissions) {
        $grants = @($permission.actions | Where-Object { $action -like $_ })
        $excludes = @($permission.notActions | Where-Object { $action -like $_ })
        if ($grants.Count -gt 0 -and $excludes.Count -eq 0) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) {
        throw "Required action '$action' is not granted at the resource-group scope. No permissions were changed."
    }
}

$images = @()
if ($CheckOracleImages) {
    $oracle = Get-AnfVmImage -Location $Location -Publisher $OracleImagePublisher -Offer $OracleImageOffer `
        -Sku $OracleImageSku -Version $OracleImageVersion -OperatingSystem Linux
    $app = Get-AnfVmImage -Location $Location -Publisher MicrosoftWindowsServer -Offer WindowsServer `
        -Sku $AppImageSku -OperatingSystem Windows
    $images = @(
        [pscustomobject]@{ Role = 'Oracle'; Urn = "${OracleImagePublisher}:${OracleImageOffer}:${OracleImageSku}:$($oracle.Version)" },
        [pscustomobject]@{ Role = 'Application'; Urn = "MicrosoftWindowsServer:WindowsServer:${AppImageSku}:$($app.Version)" }
    )
}
$deployment = @{
    ResourceGroupName = $ResourceGroup; TemplateFile = $inputData.TemplateFile
    TemplateParameterObject = $inputData.Parameters; ErrorAction = 'Stop'
}
Assert-AnfArmValidation -Deployment $deployment
$preview = Get-AzResourceGroupDeploymentWhatIfResult @deployment -Mode Incremental
if (-not $preview -or $preview.Status -ne 'Succeeded' -or $preview.Error) {
    throw "ARM What-If did not succeed: $($preview | ConvertTo-Json -Depth 20 -Compress)"
}
Write-Warning 'Preflight is not a deployment guarantee: quotas, live capacity, deny assignments, RBAC conditions, policy and workload connectivity still require verification. Inspect What-If diagnostics and ignored changes. Optional image checks do not validate the Oracle VM/network deployment.'
[pscustomobject]@{
    SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; Location = $Location
    ValidationStatus = 'Succeeded'; ResourceCapabilities = @($capabilities)
    PermissionActionsChecked = @($requiredActions | Sort-Object -Unique)
    OracleImagesChecked = $CheckOracleImages.IsPresent; Images = $images; WhatIfResult = $preview
}
