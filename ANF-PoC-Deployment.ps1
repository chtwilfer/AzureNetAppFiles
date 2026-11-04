#requires -Version 7.4
<#
.SYNOPSIS
Creates two independent Azure NetApp Files NFS environments.
.DESCRIPTION
Requires an existing Azure login and explicitly selected subscription.
Existing resources are reused only when their managed configuration matches.
This script does not configure cross-region replication.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $AnfAccountName,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{0,79}$')][string] $CreationToken,
    [Parameter(Mandatory)][string] $SubnetAddressPrefix,
    [Parameter(Mandatory)][string] $NetworkAddressPrefix,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SecondLocation,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SecondResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SecondAnfAccountName,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{0,79}$')][string] $SecondCreationToken,
    [Parameter(Mandatory)][string] $SecondSubnetAddressPrefix,
    [Parameter(Mandatory)][string] $SecondNetworkAddressPrefix,
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][string[]] $AllowedClients,
    [Parameter(Mandatory)][string[]] $SecondAllowedClients,
    [ValidateRange(4, 1024)][int] $PoolSizeTiB = 4,
    [ValidateRange(100, 1048576)][int] $VolumeSizeGiB = 100,
    [ValidateSet('Standard', 'Premium', 'Ultra')][string] $ServiceLevel = 'Standard',
    [ValidateSet('NFSv3', 'NFSv4.1')][string] $Protocol = 'NFSv3',
    [switch] $AllowRootAccess,
    [switch] $CreateSnapshots,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{0,63}$')][string] $SnapshotName = 'MyAnfSnapshot',
    [switch] $RegisterProviders,
    [ValidateRange(1, 7200)][int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/Deployment.Common.ps1"
Assert-AnfNetwork -Network $NetworkAddressPrefix -Subnet $SubnetAddressPrefix -AllowedClients $AllowedClients
Assert-AnfNetwork -Network $SecondNetworkAddressPrefix -Subnet $SecondSubnetAddressPrefix -AllowedClients $SecondAllowedClients
Assert-AnfCapacity -PoolSizeBytes ($PoolSizeTiB * 1TB) -VolumeSizeBytes ($VolumeSizeGiB * 1GB)
if ($Location -eq $SecondLocation) {
    throw 'Select two different Azure region identifiers, for example westeurope and northeurope.'
}
if ($ResourceGroup -eq $SecondResourceGroup -and $AnfAccountName -eq $SecondAnfAccountName) {
    throw 'The two environments must use different resource group/account combinations.'
}

$description = "Create or verify two independent ANF environments ($AnfAccountName, $SecondAnfAccountName), " +
    "$PoolSizeTiB TiB per pool, $VolumeSizeGiB GiB per volume, $Protocol; snapshots: $CreateSnapshots; " +
    "root access: $AllowRootAccess; provider registration: $RegisterProviders"
if (-not $PSCmdlet.ShouldProcess("Subscription $SubscriptionId; $ResourceGroup/$Location and $SecondResourceGroup/$SecondLocation", $description)) {
    return
}

Import-AnfModule -Name Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles
Initialize-AnfContext -SubscriptionId $SubscriptionId -RegisterProviders:$RegisterProviders -TimeoutSeconds $TimeoutSeconds

$regions = @(
    @{ Location = $Location; ResourceGroup = $ResourceGroup; AccountName = $AnfAccountName
        NetworkAddressPrefix = $NetworkAddressPrefix; SubnetAddressPrefix = $SubnetAddressPrefix
        CreationToken = $CreationToken; AllowedClients = $AllowedClients; VolumeName = "$AnfAccountName-vVolume" },
    @{ Location = $SecondLocation; ResourceGroup = $SecondResourceGroup; AccountName = $SecondAnfAccountName
        NetworkAddressPrefix = $SecondNetworkAddressPrefix; SubnetAddressPrefix = $SecondSubnetAddressPrefix
        CreationToken = $SecondCreationToken; AllowedClients = $SecondAllowedClients; VolumeName = "$SecondAnfAccountName-volume" }
)
foreach ($region in $regions) {
    $environment = Initialize-AnfEnvironment -ResourceGroup $region.ResourceGroup -Location $region.Location `
        -AccountName $region.AccountName -NetworkAddressPrefix $region.NetworkAddressPrefix `
        -SubnetAddressPrefix $region.SubnetAddressPrefix -PoolSizeBytes ($PoolSizeTiB * 1TB) `
        -ServiceLevel $ServiceLevel -TimeoutSeconds $TimeoutSeconds
    $volume = Initialize-AnfVolume -Environment $environment -Name $region.VolumeName -CreationToken $region.CreationToken `
        -SizeBytes ($VolumeSizeGiB * 1GB) -ServiceLevel $ServiceLevel -Protocol $Protocol `
        -AllowedClients $region.AllowedClients -RootAccess $AllowRootAccess.IsPresent -TimeoutSeconds $TimeoutSeconds
    if ($CreateSnapshots) {
        Initialize-AnfSnapshot -Environment $environment -Volume $volume -Name $SnapshotName -TimeoutSeconds $TimeoutSeconds
    }
    $volume
}
