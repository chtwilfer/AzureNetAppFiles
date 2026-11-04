#requires -Version 7.4

function ConvertTo-AnfNetwork {
    param([Parameter(Mandatory)][string] $Cidr)

    $parts = $Cidr.Split('/')
    $address = $null
    $prefix = 0
    if ($parts.Count -ne 2 -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref] $address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $parts[0] -or
        -not [int]::TryParse($parts[1], [ref] $prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid IPv4 CIDR: '$Cidr'."
    }

    [long] $value = 0
    foreach ($octet in $address.GetAddressBytes()) {
        $value = ($value * 256) + $octet
    }
    [long] $size = [math]::Pow(2, 32 - $prefix)
    if ($value % $size -ne 0) {
        throw "CIDR '$Cidr' contains host bits. Use the network address."
    }
    [pscustomobject]@{ Start = $value; End = $value + $size - 1; Prefix = $prefix }
}

function Assert-AnfNetwork {
    param(
        [Parameter(Mandatory)][string] $Network,
        [Parameter(Mandatory)][string] $Subnet,
        [Parameter(Mandatory)][string[]] $AllowedClients
    )

    $vnet = ConvertTo-AnfNetwork $Network
    $delegated = ConvertTo-AnfNetwork $Subnet
    if ($delegated.Start -lt $vnet.Start -or $delegated.End -gt $vnet.End -or $delegated.Prefix -gt 28) {
        throw "Subnet '$Subnet' must be inside '$Network' and have a prefix of /28 or larger."
    }
    if ($AllowedClients.Count -eq 0) {
        throw 'At least one allowed NFS client CIDR is required.'
    }
    foreach ($client in $AllowedClients) {
        if ((ConvertTo-AnfNetwork $client).Prefix -eq 0) {
            throw 'An unrestricted NFS export (0.0.0.0/0) is not supported.'
        }
    }
}

function Assert-AnfCapacity {
    param([long] $PoolSizeBytes, [long] $VolumeSizeBytes, [int] $VolumeCount = 1)

    if ($PoolSizeBytes -lt 4TB -or $PoolSizeBytes % 1TB -ne 0) {
        throw 'These examples require a pool of at least 4 TiB in whole TiB increments.'
    }
    if ($VolumeSizeBytes -lt 100GB -or $VolumeSizeBytes -gt ($PoolSizeBytes / $VolumeCount)) {
        throw 'Each volume must be at least 100 GiB, and total volume capacity must not exceed the pool.'
    }
}

function Import-AnfModule {
    param([Parameter(Mandatory)][string[]] $Name)

    foreach ($module in $Name) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "Missing module '$module'. Install it explicitly with: Install-Module $module -Scope CurrentUser"
        }
        Import-Module $module -ErrorAction Stop
    }
}

function Get-AnfTemplateInput {
    param([string] $TemplateFile, [string] $TemplateParameterFile, [string] $Location)

    $templatePath = (Resolve-Path -LiteralPath $TemplateFile -ErrorAction Stop).Path
    $parameterPath = (Resolve-Path -LiteralPath $TemplateParameterFile -ErrorAction Stop).Path
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -AsHashtable
    $document = Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json -AsHashtable
    $parameters = @{}
    foreach ($name in $document.parameters.Keys) {
        if (-not $template.parameters.ContainsKey($name)) {
            throw "Unknown template parameter '$name'."
        }
        if (-not $document.parameters[$name].ContainsKey('value')) {
            throw "Parameter '$name' must contain a value. Key Vault references are not supported by this wrapper."
        }
        $parameters[$name] = $document.parameters[$name].value
    }
    # The explicit script location always wins over a parameter-file location.
    $parameters.location = $Location
    foreach ($name in $template.parameters.Keys) {
        if (-not $parameters.ContainsKey($name)) {
            if (-not $template.parameters[$name].ContainsKey('defaultValue')) {
                throw "Missing required template parameter '$name'."
            }
            $parameters[$name] = $template.parameters[$name].defaultValue
        }
    }
    Assert-AnfNetwork -Network $parameters.netappVirtualNetworkAddressPrefix `
        -Subnet $parameters.netappVirtualNetworkSubnetAddressPrefix -AllowedClients $parameters.netappAllowedClients
    Assert-AnfCapacity -PoolSizeBytes $parameters.netappPoolSize -VolumeSizeBytes $parameters.netappVolumeSize
    [pscustomobject]@{
        TemplateFile = $templatePath; Template = $template; Parameters = $parameters
    }
}

function Assert-AnfArmValidation {
    param([Parameter(Mandatory)][hashtable] $Deployment)

    $validationErrors = @(Test-AzResourceGroupDeployment @Deployment)
    if ($validationErrors.Count -gt 0) {
        throw "ARM validation failed: $($validationErrors | ConvertTo-Json -Depth 10 -Compress)"
    }
}

function Get-AnfVmImage {
    param(
        [string] $Location, [string] $Publisher, [string] $Offer, [string] $Sku,
        [string] $Version = 'latest', [ValidateSet('Windows', 'Linux')][string] $OperatingSystem
    )

    $image = Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer `
        -Skus $Sku -Version $Version -ErrorAction Stop
    if (-not $image -or $image.OSDiskImage.OperatingSystem -ne $OperatingSystem) {
        throw "Image '$Publisher/$Offer/$Sku/$Version' must exist in the region and use $OperatingSystem."
    }
    if ([string]::IsNullOrWhiteSpace($image.Version)) {
        throw "Image '$Publisher/$Offer/$Sku/$Version' returned no resolved version."
    }
    $plan = $image.PurchasePlan
    if ($plan) {
        $terms = Get-AzMarketplaceTerms -Publisher $plan.Publisher -Product $plan.Product -Name $plan.Name -ErrorAction Stop
        if (-not $terms.Accepted) {
            throw "Accept the Marketplace terms for '$($plan.Publisher)/$($plan.Product)/$($plan.Name)' explicitly before deploying."
        }
    }
    $image
}

function Wait-AnfState {
    param(
        [Parameter(Mandatory)][scriptblock] $Read,
        [string] $Property = 'ProvisioningState',
        [string] $Success = 'Succeeded',
        [ValidateRange(1, 7200)][int] $TimeoutSeconds = 900,
        [ValidateRange(0, 60)][int] $IntervalSeconds = 5
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $resource = & $Read
        if ($null -eq $resource -or -not $resource.PSObject.Properties[$Property] -or
            [string]::IsNullOrWhiteSpace([string] $resource.$Property)) {
            throw "Resource status '$Property' was not returned."
        }
        $state = [string] $resource.$Property
        if ($state -eq $Success) {
            return $resource
        }
        if ($state -in @('Failed', 'Canceled', 'Cancelled', 'Deleting', 'Disconnected')) {
            throw "Resource entered terminal state '$state'."
        }
        $remainingSeconds = $TimeoutSeconds - $timer.Elapsed.TotalSeconds
        if ($remainingSeconds -le 0) {
            throw "Timed out after $TimeoutSeconds seconds waiting for '$Success'; last state: '$state'."
        }
        Start-Sleep -Seconds ([math]::Min($IntervalSeconds, $remainingSeconds))
    } while ($true)
}

function Initialize-AnfContext {
    param(
        [Parameter(Mandatory)][guid] $SubscriptionId,
        [string[]] $ProviderNamespace = @('Microsoft.NetApp', 'Microsoft.Network'),
        [switch] $RegisterProviders,
        [int] $TimeoutSeconds = 900
    )

    if (-not (Get-AzContext -ErrorAction Stop)) {
        throw 'No Azure login found. Run Connect-AzAccount (or authenticate with a managed identity/service principal) first.'
    }
    Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
    $context = Set-AzContext -SubscriptionId $SubscriptionId.ToString() -Scope Process -ErrorAction Stop
    if ($context.Subscription.Id -ne $SubscriptionId.ToString()) {
        throw 'Azure subscription context does not match the requested subscription.'
    }

    foreach ($namespace in $ProviderNamespace) {
        $provider = Get-AzResourceProvider -ProviderNamespace $namespace -ErrorAction Stop
        if ($provider.RegistrationState -ne 'Registered') {
            if (-not $RegisterProviders) {
                throw "Provider '$namespace' is not registered. Register it explicitly or pass -RegisterProviders."
            }
            Register-AzResourceProvider -ProviderNamespace $namespace -ErrorAction Stop | Out-Null
            Wait-AnfState -Property RegistrationState -Success Registered -TimeoutSeconds $TimeoutSeconds -Read {
                Get-AzResourceProvider -ProviderNamespace $namespace -ErrorAction Stop
            } | Out-Null
        }
    }
}

function Assert-AnfValue {
    param([string] $Description, $Actual, $Expected)

    if ([string] $Actual -ine [string] $Expected) {
        throw "$Description differs: existing '$Actual', requested '$Expected'. No automatic replacement is performed."
    }
}

function Initialize-AnfResourceGroup {
    param([string] $Name, [string] $Location)

    $group = Get-AzResourceGroup -ErrorAction Stop | Where-Object ResourceGroupName -EQ $Name
    if (-not $group) {
        $group = New-AzResourceGroup -Name $Name -Location $Location -ErrorAction Stop
    }
    $group
}

function Initialize-AnfVirtualNetwork {
    param(
        [string] $ResourceGroup, [string] $Location, [string] $Name,
        [string] $AddressPrefix, [string] $SubnetName, [string] $SubnetPrefix,
        [switch] $Delegated, [int] $TimeoutSeconds = 900
    )

    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -EQ $Name
    if (-not $vnet) {
        $subnetArguments = @{ Name = $SubnetName; AddressPrefix = $SubnetPrefix; ErrorAction = 'Stop' }
        if ($Delegated) {
            $subnetArguments.Delegation = New-AzDelegation -Name 'netapp' -ServiceName 'Microsoft.NetApp/volumes' -ErrorAction Stop
        }
        $subnet = New-AzVirtualNetworkSubnetConfig @subnetArguments
        New-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Location $Location -Name $Name `
            -AddressPrefix $AddressPrefix -Subnet $subnet -ErrorAction Stop | Out-Null
    }
    $vnet = Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    }
    Assert-AnfValue "$Name location" $vnet.Location $Location
    Assert-AnfValue "$Name address space" ($vnet.AddressSpace.AddressPrefixes -join ',') $AddressPrefix
    $subnet = $vnet.Subnets | Where-Object Name -EQ $SubnetName
    if (-not $subnet) {
        throw "Existing VNet '$Name' does not contain subnet '$SubnetName'."
    }
    Assert-AnfValue "$Name/$SubnetName address prefix" ($subnet.AddressPrefix -join ',') $SubnetPrefix
    if ($Delegated -and 'Microsoft.NetApp/volumes' -notin @($subnet.Delegations.ServiceName)) {
        throw "Subnet '$SubnetName' is not delegated to Microsoft.NetApp/volumes."
    }
    $vnet
}

function Initialize-AnfEnvironment {
    param(
        [string] $ResourceGroup, [string] $Location, [string] $AccountName,
        [string] $NetworkAddressPrefix, [string] $SubnetAddressPrefix,
        [long] $PoolSizeBytes, [string] $ServiceLevel, [int] $TimeoutSeconds = 900
    )

    Initialize-AnfResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
    $vnet = Initialize-AnfVirtualNetwork -ResourceGroup $ResourceGroup -Location $Location -Name "$AccountName-vnet" `
        -AddressPrefix $NetworkAddressPrefix -SubnetName "$AccountName-subnet" -SubnetPrefix $SubnetAddressPrefix `
        -Delegated -TimeoutSeconds $TimeoutSeconds
    $account = Get-AzNetAppFilesAccount -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object Name -EQ $AccountName
    if (-not $account) {
        New-AzNetAppFilesAccount -ResourceGroupName $ResourceGroup -Location $Location -Name $AccountName -ErrorAction Stop | Out-Null
    }
    $account = Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzNetAppFilesAccount -ResourceGroupName $ResourceGroup -Name $AccountName -ErrorAction Stop
    }
    Assert-AnfValue "$AccountName location" $account.Location $Location
    $poolName = "$AccountName-pool"
    $pool = Get-AzNetAppFilesPool -ResourceGroupName $ResourceGroup -AccountName $AccountName -ErrorAction Stop |
        Where-Object { ($_.Name -split '/')[-1] -eq $poolName }
    if (-not $pool) {
        New-AzNetAppFilesPool -ResourceGroupName $ResourceGroup -Location $Location -AccountName $AccountName `
            -Name $poolName -PoolSize $PoolSizeBytes -ServiceLevel $ServiceLevel -ErrorAction Stop | Out-Null
    }
    $pool = Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzNetAppFilesPool -ResourceGroupName $ResourceGroup -AccountName $AccountName -Name $poolName -ErrorAction Stop
    }
    Assert-AnfValue "$poolName size" $pool.Size $PoolSizeBytes
    Assert-AnfValue "$poolName service level" $pool.ServiceLevel $ServiceLevel
    [pscustomobject]@{
        ResourceGroup = $ResourceGroup; Location = $Location; AccountName = $AccountName; PoolName = $poolName
        SubnetId = ($vnet.Subnets | Where-Object Name -EQ "$AccountName-subnet").Id
    }
}

function Initialize-AnfVolume {
    param(
        [Parameter(Mandatory)] $Environment,
        [string] $Name, [string] $CreationToken, [long] $SizeBytes,
        [string] $ServiceLevel, [ValidateSet('NFSv3', 'NFSv4.1')][string] $Protocol,
        [string[]] $AllowedClients, [bool] $RootAccess = $false, [int] $TimeoutSeconds = 900
    )

    $arguments = @{
        ResourceGroupName = $Environment.ResourceGroup; AccountName = $Environment.AccountName
        PoolName = $Environment.PoolName; ErrorAction = 'Stop'
    }
    $volume = Get-AzNetAppFilesVolume @arguments | Where-Object { ($_.Name -split '/')[-1] -eq $Name }
    if (-not $volume) {
        $rule = New-AzNetAppFilesExportPolicyRuleObject -RuleIndex 1 -AllowedClient ($AllowedClients -join ',') `
            -Nfsv3:($Protocol -eq 'NFSv3') -Nfsv41:($Protocol -eq 'NFSv4.1') `
            -UnixReadOnly:$false -UnixReadWrite -HasRootAccess:$RootAccess
        $exportPolicy = New-AzNetAppFilesExportPolicyObject -Rule $rule -ErrorAction Stop
        New-AzNetAppFilesVolume @arguments -Name $Name -Location $Environment.Location -UsageThreshold $SizeBytes `
            -SubnetId $Environment.SubnetId -CreationToken $CreationToken -ServiceLevel $ServiceLevel `
            -ProtocolType $Protocol -ExportPolicy $exportPolicy | Out-Null
    }
    $volume = Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read {
        Get-AzNetAppFilesVolume @arguments -Name $Name
    }
    Assert-AnfValue "$Name subnet" $volume.SubnetId $Environment.SubnetId
    Assert-AnfValue "$Name creation token" $volume.CreationToken $CreationToken
    Assert-AnfValue "$Name size" $volume.UsageThreshold $SizeBytes
    Assert-AnfValue "$Name service level" $volume.ServiceLevel $ServiceLevel
    Assert-AnfValue "$Name protocol" ($volume.ProtocolTypes -join ',') $Protocol
    if ($volume.VolumeType -match 'DataProtection') {
        throw "Volume '$Name' is a replication destination, not an independent volume."
    }
    $rules = @($volume.ExportPolicy.Rules)
    if ($rules.Count -ne 1) {
        throw "Volume '$Name' has a different export policy. Review it before rerunning."
    }
    Assert-AnfValue "$Name allowed clients" (($rules[0].AllowedClients -split ',' | Sort-Object) -join ',') (($AllowedClients | Sort-Object) -join ',')
    Assert-AnfValue "$Name root access" $rules[0].HasRootAccess $RootAccess
    Assert-AnfValue "$Name NFSv3 export" $rules[0].Nfsv3 ($Protocol -eq 'NFSv3')
    Assert-AnfValue "$Name NFSv4.1 export" $rules[0].Nfsv41 ($Protocol -eq 'NFSv4.1')
    Assert-AnfValue "$Name read/write export" $rules[0].UnixReadWrite $true
    Assert-AnfValue "$Name read-only export" $rules[0].UnixReadOnly $false
    $volume
}

function Initialize-AnfSnapshot {
    param($Environment, $Volume, [string] $Name, [int] $TimeoutSeconds = 900)

    $arguments = @{
        ResourceGroupName = $Environment.ResourceGroup; AccountName = $Environment.AccountName
        PoolName = $Environment.PoolName; VolumeName = ($Volume.Name -split '/')[-1]; ErrorAction = 'Stop'
    }
    $snapshot = Get-AzNetAppFilesSnapshot @arguments | Where-Object { ($_.Name -split '/')[-1] -eq $Name }
    if (-not $snapshot) {
        New-AzNetAppFilesSnapshot @arguments -Name $Name -Location $Environment.Location -FileSystemId $Volume.FileSystemId | Out-Null
    }
    Wait-AnfState -TimeoutSeconds $TimeoutSeconds -Read { Get-AzNetAppFilesSnapshot @arguments -Name $Name }
}
