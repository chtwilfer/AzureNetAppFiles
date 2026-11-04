#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$root/scripts/Deployment.Common.ps1"
$script:failures = 0
$script:passed = 0

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) {
        throw "Expected '$Expected', received '$Actual'."
    }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Message)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if (-not $caught -or $caught.Exception.Message -notlike "*$Message*") {
        throw "Expected error containing '$Message'; received '$caught'."
    }
}

function Test-Case {
    param([string] $Name, [scriptblock] $Action)
    try {
        & $Action
        $script:passed++
        Write-Output "PASS $Name"
    } catch {
        $script:failures++
        Write-Output "FAIL $Name`: $_"
        Write-Output $_.ScriptStackTrace
    }
}

$twoRegions = @{
    Location = 'westeurope'; ResourceGroup = 'anf-test-west'; AnfAccountName = 'anftestwest'
    CreationToken = 'testwest'; SubnetAddressPrefix = '10.1.2.0/24'; NetworkAddressPrefix = '10.1.0.0/16'
    SecondLocation = 'northeurope'; SecondResourceGroup = 'anf-test-north'; SecondAnfAccountName = 'anftestnorth'
    SecondCreationToken = 'testnorth'; SecondSubnetAddressPrefix = '10.2.2.0/24'; SecondNetworkAddressPrefix = '10.2.0.0/16'
    SubscriptionId = '11111111-1111-1111-1111-111111111111'
    AllowedClients = @('10.1.1.0/24'); SecondAllowedClients = @('10.2.1.0/24')
    CreateSnapshots = $true
}
$arm = @{
    Location = 'westeurope'; ResourceGroup = 'anf-test-arm'
    SubscriptionId = $twoRegions.SubscriptionId
}
$oracle = @{
    Location = 'westeurope'; ResourceGroup = 'anf-test-oracle'; AnfAccountName = 'anftestoracle'
    SubscriptionId = $twoRegions.SubscriptionId
    Cred = [pscredential]::new('testadmin', (ConvertTo-SecureString 'TestsOnly-NotARealPassword1!' -AsPlainText -Force))
    SshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
}

Test-Case 'All scripts parse and declare a leading parameter block' {
    foreach ($file in Get-ChildItem $root -Recurse -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
        Assert-Equal $errors.Count 0
        if ($file.Name -ne 'Deployment.Common.ps1' -and -not $ast.ParamBlock) {
            throw "$($file.Name) has no script parameter block."
        }
    }
}
Test-Case 'CIDR validation handles ranges and rejects host bits/invalid addresses' {
    Assert-Equal (ConvertTo-AnfNetwork '255.255.255.255/32').End 4294967295L
    Assert-Throws { ConvertTo-AnfNetwork '10.0.0.1/24' } 'host bits'
    Assert-Throws { ConvertTo-AnfNetwork '999.0.0.0/24' } 'Invalid IPv4'
    Assert-Throws { ConvertTo-AnfNetwork '::/64' } 'Invalid IPv4'
    Assert-Throws { ConvertTo-AnfNetwork '10.0.0.0/33' } 'Invalid IPv4'
    Assert-Throws { ConvertTo-AnfNetwork '010.0.0.0/8' } 'Invalid IPv4'
}
Test-Case 'Network containment, subnet size and explicit export restrictions' {
    Assert-AnfNetwork '10.1.0.0/16' '10.1.2.0/24' @('10.2.0.1/32')
    Assert-Throws { Assert-AnfNetwork '10.1.0.0/16' '10.2.2.0/24' @('10.1.1.0/24') } 'must be inside'
    Assert-Throws { Assert-AnfNetwork '10.1.0.0/16' '10.1.2.0/29' @('10.1.1.0/24') } 'must be inside'
    Assert-Throws { Assert-AnfNetwork '10.1.0.0/16' '10.1.2.0/24' @('0.0.0.0/0') } 'unrestricted'
}
Test-Case 'Capacity units and boundaries are enforced' {
    Assert-AnfCapacity 4TB 100GB
    Assert-Equal (4 * 1TB) 4398046511104L
    Assert-Equal (100 * 1GB) 107374182400L
    Assert-Throws { Assert-AnfCapacity 3TB 100GB } 'at least 4 TiB'
    Assert-Throws { Assert-AnfCapacity 4TB 99GB } 'at least 100 GiB'
    Assert-Throws { Assert-AnfCapacity 4TB 3TB -VolumeCount 2 } 'total volume capacity'
}
Test-Case 'State polling handles success, failure, missing status and timeout' {
    $script:polls = 0
    $result = Wait-AnfState -IntervalSeconds 0 -Read {
        $script:polls++
        [pscustomobject]@{ ProvisioningState = $(if ($script:polls -eq 1) { 'Creating' } else { 'Succeeded' }) }
    }
    Assert-Equal $script:polls 2
    Assert-Equal $result.ProvisioningState 'Succeeded'
    Assert-Throws { Wait-AnfState -Read { [pscustomobject]@{ ProvisioningState = 'Failed' } } } 'terminal state'
    Assert-Throws { Wait-AnfState -Read { [pscustomobject]@{} } } 'was not returned'
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-Throws { Wait-AnfState -TimeoutSeconds 1 -IntervalSeconds 5 -Read {
        [pscustomobject]@{ ProvisioningState = 'Creating' }
    } } 'Timed out'
    if ($timer.Elapsed.TotalSeconds -gt 3) {
        throw 'Polling slept beyond the configured timeout instead of limiting the last interval.'
    }
}
Test-Case 'All three WhatIf entry points run offline without Azure modules or authentication' {
    & "$root/ANF-PoC-Deployment.ps1" @twoRegions -WhatIf
    & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -WhatIf
    & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle -WhatIf
}
Test-Case 'Invalid Oracle network/key inputs fail before Azure access' {
    $invalid = $oracle.Clone()
    $invalid.OracleNetworkAddressPrefix = '10.6.0.0/16'
    $invalid.OracleSubnetAddressPrefix = '10.6.3.0/24'
    Assert-Throws { & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @invalid -WhatIf } 'must not overlap'
    $invalid = $oracle.Clone()
    $invalid.SshPublicKey = '-----BEGIN OPENSSH PRIVATE KEY-----'
    Assert-Throws { & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @invalid -WhatIf } 'OpenSSH public key'
}
Test-Case 'ARM template uses consistent names, service levels, protocols and explicit exports' {
    $template = Get-Content "$root/ANF with JSON/azuredeploy.json" -Raw | ConvertFrom-Json -AsHashtable
    $parameters = (Get-Content "$root/ANF with JSON/azuredeploy.parameters.json" -Raw | ConvertFrom-Json -AsHashtable).parameters
    foreach ($name in $parameters.Keys) {
        Assert-Equal $template.parameters.ContainsKey($name) $true
    }
    $pool = $template.resources | Where-Object type -EQ 'Microsoft.NetApp/netAppAccounts/capacityPools'
    Assert-Equal $pool.name "[concat(parameters('netappAccountName'), '/', parameters('netappPoolName'))]"
    Assert-Equal $pool.properties.serviceLevel "[parameters('netappVolumeServicelevel')]"
    $volume = $template.resources | Where-Object type -EQ 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
    $rule = $volume.properties.exportPolicy.rules[0]
    Assert-Equal $rule.nfsv3 "[equals(parameters('netappVolumeProtocol'), 'NFSv3')]"
    Assert-Equal $rule.nfsv41 "[equals(parameters('netappVolumeProtocol'), 'NFSv4.1')]"
    Assert-Equal $rule.allowedClients "[join(parameters('netappAllowedClients'), ',')]"
    Assert-Equal $rule.hasRootAccess "[parameters('netappAllowRootAccess')]"
    Assert-Equal $template.parameters.netappAllowRootAccess.defaultValue $false
    Assert-Equal $template.outputs.Count 4
    $vnet = $template.resources | Where-Object type -EQ 'Microsoft.Network/virtualNetworks'
    Assert-Equal $vnet.properties.subnets.Count 1
}

# Azure command doubles validate orchestration and repeat runs without accessing a subscription.
$global:AnfTestState = @{
    Groups = @{}; Vnets = @{}; Accounts = @{}; Pools = @{}; Volumes = @{}; Snapshots = @{}
    Vms = @{}; Nics = @{}; Nsgs = @{}; TermsAccepted = $true; OracleOS = 'Linux'; Authenticated = $true
    Writes = 0; Imports = 0; ProviderState = 'Registered'; Registrations = 0; ValidationErrors = @()
}
function Get-Module { param($Name, [switch] $ListAvailable) [pscustomobject]@{ Name = $Name } }
function Import-Module { [CmdletBinding()] param($Name) $global:AnfTestState.Imports++ }
function Get-AzContext {
    [CmdletBinding()] param()
    if ($global:AnfTestState.Authenticated) { [pscustomobject]@{ Account = 'test' } }
}
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Set-AzContext {
    [CmdletBinding()] param($SubscriptionId, $Scope)
    [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $SubscriptionId } }
}
function Get-AzResourceProvider {
    [CmdletBinding()] param($ProviderNamespace)
    [pscustomobject]@{ RegistrationState = $global:AnfTestState.ProviderState }
}
function Register-AzResourceProvider {
    [CmdletBinding()] param($ProviderNamespace)
    $global:AnfTestState.Registrations++
    $global:AnfTestState.ProviderState = 'Registered'
}
function Get-AzResourceGroup { [CmdletBinding()] param() $global:AnfTestState.Groups.Values }
function New-AzResourceGroup {
    [CmdletBinding()] param($Name, $Location)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Groups[$Name] = [pscustomobject]@{ ResourceGroupName = $Name; Location = $Location }
    $global:AnfTestState.Groups[$Name]
}
function New-AzDelegation { [CmdletBinding()] param($Name, $ServiceName) [pscustomobject]@{ ServiceName = $ServiceName } }
function New-AzVirtualNetworkSubnetConfig {
    [CmdletBinding()] param($Name, $AddressPrefix, $Delegation)
    [pscustomobject]@{ Name = $Name; AddressPrefix = $AddressPrefix; Delegations = @($Delegation); Id = "/subnets/$Name" }
}
function New-AzVirtualNetwork {
    [CmdletBinding()] param($ResourceGroupName, $Location, $Name, $AddressPrefix, $Subnet)
    if (-not $Subnet) { throw 'Subnet must be created before the VNet.' }
    $global:AnfTestState.Writes++
    $global:AnfTestState.Vnets["$ResourceGroupName/$Name"] = [pscustomobject]@{
        Name = $Name; Location = $Location; AddressSpace = @{ AddressPrefixes = @($AddressPrefix) }
        Subnets = @($Subnet); ProvisioningState = 'Succeeded'; Id = "/vnets/$ResourceGroupName/$Name"; VirtualNetworkPeerings = @()
    }
}
function Get-AzVirtualNetwork {
    [CmdletBinding()] param($ResourceGroupName, $Name)
    if ($Name) { return $global:AnfTestState.Vnets["$ResourceGroupName/$Name"] }
    foreach ($key in $global:AnfTestState.Vnets.Keys) {
        if ($key.StartsWith("$ResourceGroupName/")) { $global:AnfTestState.Vnets[$key] }
    }
}
function New-AzNetAppFilesAccount {
    [CmdletBinding()] param($ResourceGroupName, $Location, $Name)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Accounts["$ResourceGroupName/$Name"] = [pscustomobject]@{ Name = $Name; Location = $Location; ProvisioningState = 'Succeeded' }
}
function Get-AzNetAppFilesAccount {
    [CmdletBinding()] param($ResourceGroupName, $Name)
    if ($Name) { return $global:AnfTestState.Accounts["$ResourceGroupName/$Name"] }
    foreach ($key in $global:AnfTestState.Accounts.Keys) {
        if ($key.StartsWith("$ResourceGroupName/")) { $global:AnfTestState.Accounts[$key] }
    }
}
function New-AzNetAppFilesPool {
    [CmdletBinding()] param($ResourceGroupName, $Location, $AccountName, $Name, $PoolSize, $ServiceLevel)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Pools["$ResourceGroupName/$AccountName/$Name"] = [pscustomobject]@{
        Name = "$AccountName/$Name"; Size = $PoolSize; ServiceLevel = $ServiceLevel; ProvisioningState = 'Succeeded'
    }
}
function Get-AzNetAppFilesPool {
    [CmdletBinding()] param($ResourceGroupName, $AccountName, $Name)
    if ($Name) { return $global:AnfTestState.Pools["$ResourceGroupName/$AccountName/$Name"] }
    foreach ($key in $global:AnfTestState.Pools.Keys) {
        if ($key.StartsWith("$ResourceGroupName/$AccountName/")) { $global:AnfTestState.Pools[$key] }
    }
}
function New-AzNetAppFilesExportPolicyRuleObject {
    [CmdletBinding()]
    param($RuleIndex, $AllowedClient, [switch] $Nfsv3, [switch] $Nfsv41, [switch] $UnixReadOnly, [switch] $UnixReadWrite, [switch] $HasRootAccess)
    [pscustomobject]@{
        RuleIndex = $RuleIndex; AllowedClients = $AllowedClient; Nfsv3 = $Nfsv3.IsPresent; Nfsv41 = $Nfsv41.IsPresent
        UnixReadOnly = $UnixReadOnly.IsPresent; UnixReadWrite = $UnixReadWrite.IsPresent; HasRootAccess = $HasRootAccess.IsPresent
    }
}
function New-AzNetAppFilesExportPolicyObject { [CmdletBinding()] param($Rule) [pscustomobject]@{ Rules = @($Rule) } }
function New-AzNetAppFilesVolume {
    [CmdletBinding()]
    param($ResourceGroupName, $AccountName, $PoolName, $Name, $Location, $UsageThreshold, $SubnetId,
        $CreationToken, $ServiceLevel, $ProtocolType, $ExportPolicy)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Volumes["$ResourceGroupName/$AccountName/$PoolName/$Name"] = [pscustomobject]@{
        Name = "$AccountName/$PoolName/$Name"; Location = $Location; UsageThreshold = $UsageThreshold
        SubnetId = $SubnetId; CreationToken = $CreationToken; ServiceLevel = $ServiceLevel
        ProtocolTypes = @($ProtocolType); ExportPolicy = $ExportPolicy; FileSystemId = 'test-filesystem'
        ProvisioningState = 'Succeeded'; VolumeType = 'Regular'
    }
}
function Get-AzNetAppFilesVolume {
    [CmdletBinding()] param($ResourceGroupName, $AccountName, $PoolName, $Name)
    if ($Name) { return $global:AnfTestState.Volumes["$ResourceGroupName/$AccountName/$PoolName/$Name"] }
    foreach ($key in $global:AnfTestState.Volumes.Keys) {
        if ($key.StartsWith("$ResourceGroupName/$AccountName/$PoolName/")) { $global:AnfTestState.Volumes[$key] }
    }
}
function New-AzNetAppFilesSnapshot {
    [CmdletBinding()] param($ResourceGroupName, $AccountName, $PoolName, $VolumeName, $Name, $Location, $FileSystemId)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Snapshots["$ResourceGroupName/$AccountName/$PoolName/$VolumeName/$Name"] = [pscustomobject]@{
        Name = $Name; FileSystemId = $FileSystemId; ProvisioningState = 'Succeeded'
    }
}
function Get-AzNetAppFilesSnapshot {
    [CmdletBinding()] param($ResourceGroupName, $AccountName, $PoolName, $VolumeName, $Name)
    if ($Name) { return $global:AnfTestState.Snapshots["$ResourceGroupName/$AccountName/$PoolName/$VolumeName/$Name"] }
    foreach ($key in $global:AnfTestState.Snapshots.Keys) {
        if ($key.StartsWith("$ResourceGroupName/$AccountName/$PoolName/$VolumeName/")) { $global:AnfTestState.Snapshots[$key] }
    }
}
function Test-AzResourceGroupDeployment {
    [CmdletBinding()] param($ResourceGroupName, $TemplateFile, $TemplateParameterObject)
    Assert-Equal $TemplateParameterObject.location $arm.Location
    $global:AnfTestState.ValidationErrors
}
function Get-AzResourceGroupDeploymentWhatIfResult {
    [CmdletBinding()] param($ResourceGroupName, $TemplateFile, $TemplateParameterObject)
    'ARM preview'
}
function New-AzResourceGroupDeployment {
    [CmdletBinding()] param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $Name, $Mode)
    Assert-Equal $Mode 'Incremental'
    $global:AnfTestState.Writes++
    [pscustomobject]@{ ProvisioningState = 'Succeeded' }
}
function Get-AzVMImage {
    [CmdletBinding()] param($Location, $PublisherName, $Offer, $Skus, $Version)
    if ($PublisherName -eq 'MicrosoftWindowsServer') {
        return [pscustomobject]@{ OSDiskImage = @{ OperatingSystem = 'Windows' }; Version = '1.0.0' }
    }
    [pscustomobject]@{
        OSDiskImage = @{ OperatingSystem = $global:AnfTestState.OracleOS }; Version = '1.0.0'
        PurchasePlan = @{ Publisher = $PublisherName; Product = $Offer; Name = $Skus }
    }
}
function Get-AzMarketplaceTerms {
    [CmdletBinding()] param($Publisher, $Product, $Name)
    [pscustomobject]@{ Accepted = $global:AnfTestState.TermsAccepted }
}
function Get-AzVM {
    [CmdletBinding()] param($ResourceGroupName, $Name)
    if ($Name) { return $global:AnfTestState.Vms["$ResourceGroupName/$Name"] }
    foreach ($key in $global:AnfTestState.Vms.Keys) {
        if ($key.StartsWith("$ResourceGroupName/")) { $global:AnfTestState.Vms[$key] }
    }
}
function Get-AzNetworkInterface {
    [CmdletBinding()] param($ResourceGroupName)
    foreach ($key in $global:AnfTestState.Nics.Keys) {
        if ($key.StartsWith("$ResourceGroupName/")) { $global:AnfTestState.Nics[$key] }
    }
}
function Get-AzNetworkSecurityGroup {
    [CmdletBinding()] param($ResourceGroupName)
    foreach ($key in $global:AnfTestState.Nsgs.Keys) {
        if ($key.StartsWith("$ResourceGroupName/")) { $global:AnfTestState.Nsgs[$key] }
    }
}
function New-AzNetworkSecurityGroup {
    [CmdletBinding()] param($ResourceGroupName, $Location, $Name)
    $global:AnfTestState.Writes++
    $nsg = [pscustomobject]@{ Name = $Name; Id = "/nsgs/$Name" }
    $global:AnfTestState.Nsgs["$ResourceGroupName/$Name"] = $nsg
    $nsg
}
function New-AzNetworkInterface {
    [CmdletBinding()] param($Name, $ResourceGroupName, $Location, $SubnetId, $NetworkSecurityGroupId)
    $global:AnfTestState.Writes++
    $nic = [pscustomobject]@{ Name = $Name; Id = "/nics/$Name"; PublicIpAddress = $null }
    $global:AnfTestState.Nics["$ResourceGroupName/$Name"] = $nic
    $nic
}
function New-AzVMConfig {
    param($VMName, $VMSize, $SecurityType)
    Assert-Equal $SecurityType 'Standard'
    @{ Name = $VMName; Size = $VMSize; ProvisioningState = 'Succeeded' }
}
function Set-AzVMOperatingSystem {
    param([Parameter(ValueFromPipeline)] $VM, [switch] $Windows, [switch] $Linux, $ComputerName,
        [pscredential] $Credential, [switch] $DisablePasswordAuthentication)
    process {
        $VM.OS = $(if ($Linux) { 'Linux' } else { 'Windows' })
        $VM.PasswordDisabled = $DisablePasswordAuthentication.IsPresent
        $VM
    }
}
function Set-AzVMSourceImage {
    param([Parameter(ValueFromPipeline)] $VM, $PublisherName, $Offer, $Skus, $Version)
    process { $VM.Image = "$PublisherName/$Offer/$Skus/$Version"; $VM }
}
function Add-AzVMSshPublicKey {
    param([Parameter(ValueFromPipeline)] $VM, $KeyData, $Path)
    process { $VM.SshKey = $KeyData; $VM }
}
function Set-AzVMPlan {
    param([Parameter(ValueFromPipeline)] $VM, $Publisher, $Product, $Name)
    process { $VM.Plan = "$Publisher/$Product/$Name"; $VM }
}
function Add-AzVMNetworkInterface {
    param([Parameter(ValueFromPipeline)] $VM, $Id)
    process { $VM.NicId = $Id; $VM }
}
function New-AzVM {
    [CmdletBinding()] param($ResourceGroupName, $Location, $VM)
    $global:AnfTestState.Writes++
    $global:AnfTestState.Vms["$ResourceGroupName/$($VM.Name)"] = [pscustomobject] $VM
}
function Add-AzVirtualNetworkPeering {
    [CmdletBinding()] param($Name, $VirtualNetwork, $RemoteVirtualNetworkId)
    $global:AnfTestState.Writes++
    $VirtualNetwork.VirtualNetworkPeerings += [pscustomobject]@{
        Name = $Name; RemoteVirtualNetwork = @{ Id = $RemoteVirtualNetworkId }; PeeringState = 'Connected'
    }
}

Test-Case 'WhatIf never imports modules or registers providers even when explicitly requested' {
    & "$root/ANF-PoC-Deployment.ps1" @twoRegions -RegisterProviders -WhatIf
    & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -RegisterProviders -WhatIf
    & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle -RegisterProviders -WhatIf
    Assert-Equal $global:AnfTestState.Imports 0
    Assert-Equal $global:AnfTestState.Writes 0
    Assert-Equal $global:AnfTestState.Registrations 0
}
Test-Case 'Two-region create, snapshot and repeat run preserve matching resources' {
    & "$root/ANF-PoC-Deployment.ps1" @twoRegions | Out-Null
    Assert-Equal $global:AnfTestState.Volumes.Count 2
    Assert-Equal $global:AnfTestState.Snapshots.Count 2
    $writes = $global:AnfTestState.Writes
    & "$root/ANF-PoC-Deployment.ps1" @twoRegions | Out-Null
    Assert-Equal $global:AnfTestState.Writes $writes
}
Test-Case 'NFSv4.1 exports are consistent and snapshots are optional' {
    $v4 = $twoRegions.Clone()
    $v4.ResourceGroup = 'anf-v4-west'; $v4.SecondResourceGroup = 'anf-v4-north'
    $v4.Protocol = 'NFSv4.1'; $v4.CreateSnapshots = $false
    & "$root/ANF-PoC-Deployment.ps1" @v4 | Out-Null
    $volume = $global:AnfTestState.Volumes['anf-v4-west/anftestwest/anftestwest-pool/anftestwest-vVolume']
    Assert-Equal $volume.ExportPolicy.Rules[0].Nfsv3 $false
    Assert-Equal $volume.ExportPolicy.Rules[0].Nfsv41 $true
    Assert-Equal $volume.ExportPolicy.Rules[0].HasRootAccess $false
    Assert-Equal $global:AnfTestState.Snapshots.Count 2
}
Test-Case 'Configuration drift fails without replacing resources' {
    $drift = $twoRegions.Clone()
    $drift.VolumeSizeGiB = 200
    $writes = $global:AnfTestState.Writes
    Assert-Throws { & "$root/ANF-PoC-Deployment.ps1" @drift } 'size differs'
    Assert-Equal $global:AnfTestState.Writes $writes
}
Test-Case 'Missing provider fails explicitly; opt-in registration succeeds' {
    $global:AnfTestState.ProviderState = 'NotRegistered'
    Assert-Throws { Initialize-AnfContext -SubscriptionId $twoRegions.SubscriptionId } 'not registered'
    Assert-Equal $global:AnfTestState.Registrations 0
    Initialize-AnfContext -SubscriptionId $twoRegions.SubscriptionId -RegisterProviders
    Assert-Equal $global:AnfTestState.Registrations 1
}
Test-Case 'Missing login fails without starting resource creation' {
    $global:AnfTestState.Authenticated = $false
    $writes = $global:AnfTestState.Writes
    Assert-Throws { & "$root/ANF-PoC-Deployment.ps1" @twoRegions } 'No Azure login found'
    Assert-Equal $global:AnfTestState.Writes $writes
    $global:AnfTestState.Authenticated = $true
}
Test-Case 'Explicit root access is honored for new volumes' {
    $explicit = $twoRegions.Clone()
    $explicit.ResourceGroup = 'anf-root-west'; $explicit.SecondResourceGroup = 'anf-root-north'
    $explicit.CreateSnapshots = $false
    & "$root/ANF-PoC-Deployment.ps1" @explicit -AllowRootAccess | Out-Null
    Assert-Equal $global:AnfTestState.Volumes['anf-root-west/anftestwest/anftestwest-pool/anftestwest-vVolume'].ExportPolicy.Rules[0].HasRootAccess $true
}
Test-Case 'ARM deployment is validated and uses an explicit incremental deployment' {
    & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm | Out-Null
    Assert-Equal $global:AnfTestState.Groups.ContainsKey($arm.ResourceGroup) $true
}
Test-Case 'ARM preview is read-only and refuses to create a missing group or register providers' {
    $writes = $global:AnfTestState.Writes
    Assert-Equal (& "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -Preview) 'ARM preview'
    Assert-Equal $global:AnfTestState.Writes $writes
    $missing = $arm.Clone(); $missing.ResourceGroup = 'missing'
    Assert-Throws { & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @missing -Preview } 'existing resource group'
    $global:AnfTestState.ProviderState = 'NotRegistered'
    $registrations = $global:AnfTestState.Registrations
    Assert-Throws { & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -Preview -RegisterProviders } 'not registered'
    Assert-Equal $global:AnfTestState.Registrations $registrations
    $global:AnfTestState.ProviderState = 'Registered'
}
Test-Case 'ARM validation errors prevent deployment' {
    $global:AnfTestState.ValidationErrors = @([pscustomobject]@{ Message = 'Invalid template' })
    $writes = $global:AnfTestState.Writes
    Assert-Throws { & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm } 'ARM validation failed'
    Assert-Equal $global:AnfTestState.Writes $writes
    $global:AnfTestState.ValidationErrors = @()
}
Test-Case 'ARM local validation handles template defaults, unknown parameters and missing values' {
    $file = New-TemporaryFile
    try {
        $document = Get-Content "$root/ANF with JSON/azuredeploy.parameters.json" -Raw | ConvertFrom-Json -AsHashtable
        $document.parameters.Remove('netappVirtualNetworkAddressPrefix')
        $document.parameters.Remove('netappVirtualNetworkSubnetAddressPrefix')
        $document.parameters.location = @{ value = 'northeurope' }
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file.FullName
        & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -TemplateParameterFile $file.FullName -WhatIf
        & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -TemplateParameterFile $file.FullName -Preview | Out-Null
        $document.parameters.unknown = @{ value = 'invalid' }
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file.FullName
        Assert-Throws { & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -TemplateParameterFile $file.FullName -WhatIf } 'Unknown template parameter'
        $document.parameters.Remove('unknown')
        $document.parameters.Remove('netappAllowedClients')
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file.FullName
        Assert-Throws { & "$root/ANF with JSON/ANF_JSON_Deployment.ps1" @arm -TemplateParameterFile $file.FullName -WhatIf } 'Missing required template parameter'
    } finally {
        Remove-Item -LiteralPath $file.FullName
    }
}
Test-Case 'Oracle image and licensing checks fail before resource creation' {
    $writes = $global:AnfTestState.Writes
    $global:AnfTestState.OracleOS = 'Windows'
    Assert-Throws { & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle } 'must exist in the region and use Linux'
    $global:AnfTestState.OracleOS = 'Linux'
    $global:AnfTestState.TermsAccepted = $false
    Assert-Throws { & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle } 'Accept the Marketplace terms'
    Assert-Equal $global:AnfTestState.Writes $writes
    $global:AnfTestState.TermsAccepted = $true
}
Test-Case 'Oracle infrastructure uses private NICs, Linux/SSH, restricted exports and bidirectional peerings' {
    & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle | Out-Null
    $vm = $global:AnfTestState.Vms['anf-test-oracle/OracleDB-VM']
    Assert-Equal $vm.OS 'Linux'
    Assert-Equal $vm.PasswordDisabled $true
    Assert-Equal $vm.SshKey $oracle.SshPublicKey
    Assert-Equal $vm.Plan 'oracle/oracle-database-19-3/oracle-database-19-0904'
    Assert-Equal $global:AnfTestState.Vms['anf-test-oracle/App-VM'].OS 'Windows'
    Assert-Equal $global:AnfTestState.Nics['anf-test-oracle/OracleVM-nic'].PublicIpAddress $null
    Assert-Equal $global:AnfTestState.Nics['anf-test-oracle/AppVM-nic'].PublicIpAddress $null
    $volume = $global:AnfTestState.Volumes['anf-test-oracle/anftestoracle/anftestoracle-pool/anftestoracle-volume-db']
    Assert-Equal $volume.ExportPolicy.Rules[0].AllowedClients '10.7.2.0/24'
    Assert-Equal $global:AnfTestState.Vnets['anf-test-oracle/OracelVM-VNet'].VirtualNetworkPeerings.Count 2
    Assert-Equal $global:AnfTestState.Vnets['anf-test-oracle/App-VNet'].VirtualNetworkPeerings.Count 1
    Assert-Equal $global:AnfTestState.Vnets['anf-test-oracle/anftestoracle-vnet'].VirtualNetworkPeerings.Count 1
}
Test-Case 'Oracle refuses existing VMs/NICs/NSGs instead of silently adopting insecure resources' {
    $writes = $global:AnfTestState.Writes
    Assert-Throws { & "$root/Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1" @oracle } 'already exist'
    Assert-Equal $global:AnfTestState.Writes $writes
}

Write-Output "$script:passed passed; $script:failures failed."
Remove-Variable AnfTestState -Scope Global
if ($script:failures -gt 0) { exit 1 }
