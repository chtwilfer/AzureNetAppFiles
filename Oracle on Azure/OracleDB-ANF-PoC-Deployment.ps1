#requires -Version 7.4
<#
.SYNOPSIS
Creates a Windows application VM, Linux Oracle VM and two ANF NFS volumes.
.DESCRIPTION
VMs use private IP addresses only. Provide private connectivity for RDP/SSH.
No Bastion, Oracle database initialization or NFS mounts are configured.
Marketplace terms must already be accepted; the script never accepts them.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Location,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $AnfAccountName,
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][pscredential] $Cred,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SshPublicKey,
    [ValidatePattern('^[a-z_][a-z0-9_-]{0,30}$')][string] $OracleAdminUsername = 'azureuser',
    [string] $NetworkAddressPrefix = '10.6.0.0/16',
    [string] $SubnetAddressPrefix = '10.6.2.0/24',
    [string] $AppNetworkAddressPrefix = '10.5.0.0/16',
    [string] $AppSubnetAddressPrefix = '10.5.2.0/24',
    [string] $OracleNetworkAddressPrefix = '10.7.0.0/16',
    [string] $OracleSubnetAddressPrefix = '10.7.2.0/24',
    [ValidateRange(4, 1024)][int] $PoolSizeTiB = 4,
    [ValidateRange(100, 1048576)][int] $VolumeSizeGiB = 100,
    [ValidateSet('Standard', 'Premium', 'Ultra')][string] $ServiceLevel = 'Standard',
    [ValidateNotNullOrEmpty()][string] $VmSize = 'Standard_D2_v3',
    [ValidateNotNullOrEmpty()][string] $AppImageSku = '2022-datacenter',
    [ValidateNotNullOrEmpty()][string] $OracleImagePublisher = 'oracle',
    [ValidateNotNullOrEmpty()][string] $OracleImageOffer = 'oracle-database-19-3',
    [ValidateNotNullOrEmpty()][string] $OracleImageSku = 'oracle-database-19-0904',
    [ValidateNotNullOrEmpty()][string] $OracleImageVersion = 'latest',
    [switch] $AllowRootAccess,
    [switch] $RegisterProviders,
    [ValidateRange(1, 7200)][int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/Deployment.Common.ps1"
foreach ($network in @(
    @($NetworkAddressPrefix, $SubnetAddressPrefix),
    @($AppNetworkAddressPrefix, $AppSubnetAddressPrefix),
    @($OracleNetworkAddressPrefix, $OracleSubnetAddressPrefix)
)) {
    Assert-AnfNetwork -Network $network[0] -Subnet $network[1] -AllowedClients @($OracleSubnetAddressPrefix)
}
$ranges = @($NetworkAddressPrefix, $AppNetworkAddressPrefix, $OracleNetworkAddressPrefix | ForEach-Object { ConvertTo-AnfNetwork $_ })
for ($i = 0; $i -lt $ranges.Count; $i++) {
    for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
        if ($ranges[$i].Start -le $ranges[$j].End -and $ranges[$j].Start -le $ranges[$i].End) {
            throw 'The ANF, application and Oracle VNet address spaces must not overlap.'
        }
    }
}
Assert-AnfCapacity -PoolSizeBytes ($PoolSizeTiB * 1TB) -VolumeSizeBytes ($VolumeSizeGiB * 1GB) -VolumeCount 2
if ($SshPublicKey -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$') {
    throw 'SshPublicKey must contain a single OpenSSH public key, not a path or a private key.'
}
if (-not $PSCmdlet.ShouldProcess("Subscription $SubscriptionId; $ResourceGroup/$Location",
    "Create private App-VM and Linux OracleDB-VM, peer three VNets, create/verify two NFSv3 volumes; root access: $AllowRootAccess; provider registration: $RegisterProviders")) {
    return
}

Import-AnfModule -Name Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles, Az.Compute, Az.MarketplaceOrdering
Initialize-AnfContext -SubscriptionId $SubscriptionId -ProviderNamespace Microsoft.NetApp, Microsoft.Network, Microsoft.Compute `
    -RegisterProviders:$RegisterProviders -TimeoutSeconds $TimeoutSeconds

# Fail before resource creation if an image or its licensing prerequisites are unavailable.
$oracleImage = Get-AzVMImage -Location $Location -PublisherName $OracleImagePublisher -Offer $OracleImageOffer `
    -Skus $OracleImageSku -Version $OracleImageVersion -ErrorAction Stop
if (-not $oracleImage -or $oracleImage.OSDiskImage.OperatingSystem -ne 'Linux') {
    throw 'The selected Oracle Marketplace image must exist in the region and use Linux.'
}
$appImage = Get-AzVMImage -Location $Location -PublisherName MicrosoftWindowsServer -Offer WindowsServer `
    -Skus $AppImageSku -Version latest -ErrorAction Stop
if (-not $appImage -or $appImage.OSDiskImage.OperatingSystem -ne 'Windows') {
    throw 'The selected application image must exist in the region and use Windows.'
}
$plan = $oracleImage.PurchasePlan
if ($plan) {
    $terms = Get-AzMarketplaceTerms -Publisher $plan.Publisher -Product $plan.Product -Name $plan.Name -ErrorAction Stop
    if (-not $terms.Accepted) {
        throw "Accept the Marketplace terms for '$($plan.Publisher)/$($plan.Product)/$($plan.Name)' explicitly before deploying."
    }
}

Initialize-AnfResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
# Existing VMs/NICs/NSGs may have public access or unrelated settings. Never silently reuse them.
foreach ($existing in @(
    @(Get-AzVM -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -In @('App-VM', 'OracleDB-VM')),
    @(Get-AzNetworkInterface -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -In @('AppVM-nic', 'OracleVM-nic')),
    @(Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -In @('AppVMNSG', 'OracleVMNSG'))
)) {
    if ($existing.Count -gt 0) {
        throw 'Oracle VM resources already exist. Review or explicitly remove them before redeploying; no existing VM/network security configuration was changed.'
    }
}

$appVnet = Initialize-AnfVirtualNetwork -ResourceGroup $ResourceGroup -Location $Location -Name 'App-VNet' `
    -AddressPrefix $AppNetworkAddressPrefix -SubnetName 'App-subnet' -SubnetPrefix $AppSubnetAddressPrefix -TimeoutSeconds $TimeoutSeconds
# Preserve the original resource name to avoid an accidental parallel VNet.
$oracleVnet = Initialize-AnfVirtualNetwork -ResourceGroup $ResourceGroup -Location $Location -Name 'OracelVM-VNet' `
    -AddressPrefix $OracleNetworkAddressPrefix -SubnetName 'OracleVM-subnet' -SubnetPrefix $OracleSubnetAddressPrefix -TimeoutSeconds $TimeoutSeconds
$environment = Initialize-AnfEnvironment -ResourceGroup $ResourceGroup -Location $Location -AccountName $AnfAccountName `
    -NetworkAddressPrefix $NetworkAddressPrefix -SubnetAddressPrefix $SubnetAddressPrefix `
    -PoolSizeBytes ($PoolSizeTiB * 1TB) -ServiceLevel $ServiceLevel -TimeoutSeconds $TimeoutSeconds
foreach ($volume in @(
    @{ Name = "$AnfAccountName-volume-db"; Token = 'standard' },
    @{ Name = "$AnfAccountName-volume-logs"; Token = 'standard2' }
)) {
    Initialize-AnfVolume -Environment $environment -Name $volume.Name -CreationToken $volume.Token `
        -SizeBytes ($VolumeSizeGiB * 1GB) -ServiceLevel $ServiceLevel -Protocol NFSv3 `
        -AllowedClients @($OracleSubnetAddressPrefix) -RootAccess $AllowRootAccess.IsPresent -TimeoutSeconds $TimeoutSeconds
}

foreach ($machine in @(
    @{ Name = 'App-VM'; Nic = 'AppVM-nic'; Nsg = 'AppVMNSG'; Vnet = $appVnet; Subnet = 'App-subnet' },
    @{ Name = 'OracleDB-VM'; Nic = 'OracleVM-nic'; Nsg = 'OracleVMNSG'; Vnet = $oracleVnet; Subnet = 'OracleVM-subnet' }
)) {
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Location $Location -Name $machine.Nsg -ErrorAction Stop
    $nic = New-AzNetworkInterface -Name $machine.Nic -ResourceGroupName $ResourceGroup -Location $Location `
        -SubnetId ($machine.Vnet.Subnets | Where-Object Name -EQ $machine.Subnet).Id `
        -NetworkSecurityGroupId $nsg.Id -ErrorAction Stop
    $vm = New-AzVMConfig -VMName $machine.Name -VMSize $VmSize -SecurityType Standard
    if ($machine.Name -eq 'App-VM') {
        $vm = $vm | Set-AzVMOperatingSystem -Windows -ComputerName $machine.Name -Credential $Cred
        $vm = $vm | Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus $AppImageSku -Version $appImage.Version
    } else {
        # The Linux cmdlet requires a credential object even when password authentication is disabled.
        $unusedPassword = [securestring]::new()
        foreach ($value in [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) {
            $unusedPassword.AppendChar([char](33 + ($value % 94)))
        }
        $unusedPassword.MakeReadOnly()
        $linuxCredential = [pscredential]::new($OracleAdminUsername, $unusedPassword)
        $vm = $vm | Set-AzVMOperatingSystem -Linux -ComputerName $machine.Name -Credential $linuxCredential -DisablePasswordAuthentication
        $vm = $vm | Add-AzVMSshPublicKey -KeyData $SshPublicKey -Path "/home/$OracleAdminUsername/.ssh/authorized_keys"
        $vm = $vm | Set-AzVMSourceImage -PublisherName $OracleImagePublisher -Offer $OracleImageOffer `
            -Skus $OracleImageSku -Version $oracleImage.Version
        if ($plan) {
            $vm = $vm | Set-AzVMPlan -Publisher $plan.Publisher -Product $plan.Product -Name $plan.Name
        }
    }
    $vm = $vm | Add-AzVMNetworkInterface -Id $nic.Id
    New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -VM $vm -ErrorAction Stop | Out-Null
    $vmName = $machine.Name
    Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -ErrorAction Stop
    }
}

$anfVnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name "$AnfAccountName-vnet" -ErrorAction Stop
$peerings = @(
    @{ Name = 'PeeringAppVMtoOracleVM'; Local = $appVnet; Remote = $oracleVnet },
    @{ Name = 'PeeringOracleVMtoAPPVM'; Local = $oracleVnet; Remote = $appVnet },
    @{ Name = 'PeeringOracleVMtoANFVolume'; Local = $oracleVnet; Remote = $anfVnet },
    @{ Name = 'PeeringANFVolumetoOracleVM'; Local = $anfVnet; Remote = $oracleVnet }
)
foreach ($peering in $peerings) {
    $localVnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $peering.Local.Name -ErrorAction Stop
    $existingPeering = $localVnet.VirtualNetworkPeerings | Where-Object Name -EQ $peering.Name
    if ($existingPeering) {
        Assert-AnfValue "$($peering.Name) remote VNet" $existingPeering.RemoteVirtualNetwork.Id $peering.Remote.Id
    } else {
        Add-AzVirtualNetworkPeering -Name $peering.Name -VirtualNetwork $localVnet `
            -RemoteVirtualNetworkId $peering.Remote.Id -ErrorAction Stop | Out-Null
    }
}
foreach ($peering in $peerings) {
    Wait-AnfState -Property PeeringState -Success Connected -TimeoutSeconds $TimeoutSeconds -Read {
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $peering.Local.Name -ErrorAction Stop
        $vnet.VirtualNetworkPeerings | Where-Object Name -EQ $peering.Name
    } | Out-Null
}
Write-Output 'Infrastructure deployment completed. Configure private administration access, NFS mounts and the Oracle database separately.'
