#requires -Version 7.4
<#
.SYNOPSIS
Deploys, demonstrates and removes an isolated single-region ANF customer demo.
.DESCRIPTION
Uses a private Ubuntu client operated through Azure Run Command. NAT provides
explicit outbound access. Restore copies only the example file from a snapshot;
it never reverts a volume. Cleanup requires ownership tags and a known inventory.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,14}[a-z0-9]$')][string] $DemoId,
    [ValidateSet('Deploy', 'Prepare', 'Snapshot', 'Change', 'Restore', 'Cleanup')][string] $Action = 'Deploy',
    [ValidateNotNullOrEmpty()][string] $Location = 'westeurope',
    [ValidateNotNullOrEmpty()][string] $VmSize = 'Standard_D2s_v5',
    [ValidateRange(1, 168)][int] $ExpiresInHours = 8,
    [switch] $RegisterProviders,
    [ValidateRange(1, 7200)][int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/Deployment.Common.ps1"
. "$PSScriptRoot/scripts/Demo.Common.ps1"
$groupName = "anfdemo-$DemoId"
$accountName = "anf-$DemoId"
$target = "Subscription $SubscriptionId; $groupName/$Location"
$description = switch ($Action) {
    Deploy { 'Create isolated demo: 4 TiB ANF pool, 100 GiB NFSv3 volume, private Ubuntu client, NAT gateway and outbound public IP (billable)' }
    Prepare { 'Install NFS client tools, mount the demo volume and initialize the example file without overwriting existing demo data' }
    Snapshot { 'Verify original example data and create the demo-baseline snapshot' }
    Change { 'Change only customer-demo/example.txt on the demo volume' }
    Restore { 'Copy only customer-demo/example.txt from demo-baseline and verify its original content; no volume revert' }
    Cleanup { 'Permanently delete the dedicated demo resource group, ALL its data, snapshots, VM, disks and networking after ownership/inventory checks' }
}
if ($WhatIfPreference) {
    $PSCmdlet.ShouldProcess($target, $description) | Out-Null
    return
}
if ($RegisterProviders -and $Action -ne 'Deploy') {
    throw '-RegisterProviders is supported only with -Action Deploy.'
}
Import-AnfModule -Name Az.Accounts, Az.Resources, Az.Network, Az.NetAppFiles, Az.Compute
Initialize-AnfContext -SubscriptionId $SubscriptionId -ProviderNamespace @() -TimeoutSeconds $TimeoutSeconds
$group = Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $groupName
if ($Action -eq 'Deploy') {
    if ($group) {
        throw "Resource group '$groupName' already exists. Use the existing demo steps, choose a new DemoId, or inspect and clean up this demo before redeploying."
    }
}
else {
    Assert-AnfDemoGroup -Group $group -DemoId $DemoId -Location $Location
}
if ($Action -eq 'Cleanup') {
    $inventory = @(Get-AnfDemoInventory -SubscriptionId $SubscriptionId -ResourceGroup $groupName -AccountName $accountName)
    Write-Information ($inventory | Format-Table ResourceType, Name -AutoSize | Out-String) -InformationAction Continue
    # Destructive cleanup prompts by default, even though other demo steps do not.
    if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'Low' }
}
if (-not $PSCmdlet.ShouldProcess($target, $description)) { return }
if ($Action -eq 'Cleanup') {
    $deleted = Remove-AzResourceGroup -Name $groupName -Force -ErrorAction Stop
    if ($deleted -ne $true -or (Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $groupName)) {
        throw "Deletion of '$groupName' was not confirmed complete. Inspect the group in Azure before assuming charges have stopped."
    }
    Write-Output "Deleted demo group '$groupName'."
    return
}
if ($Action -eq 'Deploy') {
    Initialize-AnfContext -SubscriptionId $SubscriptionId `
        -ProviderNamespace Microsoft.NetApp, Microsoft.Network, Microsoft.Compute `
        -RegisterProviders:$RegisterProviders -TimeoutSeconds $TimeoutSeconds
    $image = Get-AnfVmImage -Location $Location -Publisher Canonical -Offer ubuntu-24_04-lts `
        -Sku server -OperatingSystem Linux
    $tags = @{
        anfDemo = 'single-region-v1'; demoId = $DemoId; purpose = 'customer-demo'
        expiresOn = [datetime]::UtcNow.AddHours($ExpiresInHours).ToString('o')
    }
    if (Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $groupName) {
        throw "Resource group '$groupName' appeared during preparation. Choose another DemoId; no demo resources were created."
    }
    New-AzResourceGroup -Name $groupName -Location $Location -Tag $tags -ErrorAction Stop | Out-Null
    $publicIp = New-AzPublicIpAddress -Name 'demo-egress-ip' -ResourceGroupName $groupName -Location $Location `
        -AllocationMethod Static -Sku Standard -Tag $tags -ErrorAction Stop
    $nat = New-AzNatGateway -Name 'demo-nat' -ResourceGroupName $groupName -Location $Location `
        -Sku Standard -PublicIpAddress $publicIp -Tag $tags -ErrorAction Stop
    $denyInbound = New-AzNetworkSecurityRuleConfig -Name 'DenyAllInbound' -Description 'Run Command only; no inbound SSH' `
        -Access Deny -Protocol '*' -Direction Inbound -Priority 100 -SourceAddressPrefix '*' -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange '*' -ErrorAction Stop
    $nsg = New-AzNetworkSecurityGroup -Name 'demo-client-nsg' -ResourceGroupName $groupName -Location $Location `
        -SecurityRules $denyInbound -Tag $tags -ErrorAction Stop
    $delegation = New-AzDelegation -Name netapp -ServiceName 'Microsoft.NetApp/volumes' -ErrorAction Stop
    $anfSubnet = New-AzVirtualNetworkSubnetConfig -Name "$accountName-subnet" -AddressPrefix '10.42.2.0/24' `
        -Delegation $delegation -ErrorAction Stop
    $clientSubnet = New-AzVirtualNetworkSubnetConfig -Name client -AddressPrefix '10.42.1.0/24' `
        -NetworkSecurityGroup $nsg -InputObject $nat -DefaultOutboundAccess $false -ErrorAction Stop
    New-AzVirtualNetwork -Name "$accountName-vnet" -ResourceGroupName $groupName -Location $Location `
        -AddressPrefix '10.42.0.0/16' -Subnet @($anfSubnet, $clientSubnet) -Tag $tags -ErrorAction Stop | Out-Null
    $environment = Initialize-AnfEnvironment -ResourceGroup $groupName -Location $Location -AccountName $accountName `
        -NetworkAddressPrefix '10.42.0.0/16' -SubnetAddressPrefix '10.42.2.0/24' `
        -PoolSizeBytes 4TB -ServiceLevel Standard -TimeoutSeconds $TimeoutSeconds
    $volume = Initialize-AnfVolume -Environment $environment -Name demo-volume -CreationToken demo `
        -SizeBytes 100GB -ServiceLevel Standard -Protocol NFSv3 -AllowedClients @('10.42.1.4/32') `
        -RootAccess $true -EnableSnapshotDirectory -TimeoutSeconds $TimeoutSeconds
    $vnet = Get-AzVirtualNetwork -Name "$accountName-vnet" -ResourceGroupName $groupName -ErrorAction Stop
    $nic = New-AzNetworkInterface -Name 'demo-client-nic' -ResourceGroupName $groupName -Location $Location `
        -SubnetId ($vnet.Subnets | Where-Object Name -EQ client).Id -PrivateIpAddress '10.42.1.4' `
        -NetworkSecurityGroupId $nsg.Id -Tag $tags -ErrorAction Stop
    $password = [securestring]::new()
    foreach ($value in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) {
        $password.AppendChar([char](33 + ($value % 94)))
    }
    $password.MakeReadOnly()
    $credential = [pscredential]::new('demoadmin', $password)
    $vm = New-AzVMConfig -VMName 'demo-client' -VMSize $VmSize -SecurityType Standard
    $vm = $vm | Set-AzVMOperatingSystem -Linux -ComputerName $vm.Name -Credential $credential -DisablePasswordAuthentication
    $vm = $vm | Add-AzVMSshPublicKey -KeyData (Get-AnfDemoPublicKey) -Path '/home/demoadmin/.ssh/authorized_keys'
    $vm = $vm | Set-AzVMSourceImage -PublisherName Canonical -Offer ubuntu-24_04-lts -Skus server -Version $image.Version
    $vm = $vm | Set-AzVMOSDisk -Name 'demo-client-os' -CreateOption FromImage -StorageAccountType StandardSSD_LRS -DeleteOption Delete
    $vm = $vm | Add-AzVMNetworkInterface -Id $nic.Id
    New-AzVM -ResourceGroupName $groupName -Location $Location -VM $vm -Tag $tags -ErrorAction Stop | Out-Null
    Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzVM -ResourceGroupName $groupName -Name 'demo-client' -ErrorAction Stop
    } | Out-Null
    [pscustomobject]@{
        DemoId = $DemoId; ResourceGroup = $groupName; Location = $Location; Client = 'demo-client'
        ExportPath = 'demo'; MountTargets = $volume.MountTargets; ImageVersion = $image.Version
        ExpiresOn = $tags.expiresOn; NextStep = 'Prepare'
    }
    return
}
$environment = [pscustomobject]@{
    ResourceGroup = $groupName; Location = $Location; AccountName = $accountName; PoolName = "$accountName-pool"
}
$volume = Get-AzNetAppFilesVolume -ResourceGroupName $groupName -AccountName $accountName `
    -PoolName "$accountName-pool" -Name demo-volume -ErrorAction Stop
if (-not $volume -or $volume.ProvisioningState -ne 'Succeeded' -or -not $volume.SnapshotDirectoryVisible) {
    throw 'The demo volume must be ready and expose its snapshot directory.'
}
if ($Action -in @('Snapshot', 'Change', 'Restore')) {
    $snapshot = @(Get-AzNetAppFilesSnapshot -ResourceGroupName $groupName -AccountName $accountName `
            -PoolName "$accountName-pool" -VolumeName demo-volume -ErrorAction Stop |
            Where-Object { ($_.Name -split '/')[-1] -eq 'demo-baseline' })
    if ($Action -eq 'Snapshot') {
        if ($snapshot.Count) { throw 'demo-baseline already exists; use Change/Restore or create a fresh demo. It will not be overwritten.' }
        Invoke-AnfDemoClient -ResourceGroup $groupName -DemoId $DemoId -Volume $volume -Action Check | Out-Null
        Initialize-AnfSnapshot -Environment $environment -Volume $volume -Name demo-baseline -TimeoutSeconds $TimeoutSeconds
        return
    }
    if ($snapshot.Count -ne 1 -or $snapshot[0].ProvisioningState -ne 'Succeeded') {
        throw 'Create the demo-baseline snapshot successfully before Change or Restore.'
    }
}
Invoke-AnfDemoClient -ResourceGroup $groupName -DemoId $DemoId -Volume $volume -Action $Action
