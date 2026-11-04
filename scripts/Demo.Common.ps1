#requires -Version 7.4
[CmdletBinding()]
param()

function Assert-AnfDemoGroup {
    param($Group, [string] $DemoId, [string] $Location)

    if (-not $Group -or -not $Group.Tags -or $Group.Tags['anfDemo'] -ne 'single-region-v1' -or
        $Group.Tags['demoId'] -ne $DemoId -or
        [string]::IsNullOrWhiteSpace($Group.Tags['expiresOn'])) {
        throw 'Resource group is missing or is not owned by this demo. No changes were made.'
    }
    Assert-AnfValue 'Demo resource group location' $Group.Location $Location
}

function Get-AnfDemoInventory {
    param([guid] $SubscriptionId, [string] $ResourceGroup, [string] $AccountName)

    $volumePath = "$AccountName/$AccountName-pool/demo-volume"
    $allowed = @{
        'Microsoft.Network/publicIPAddresses'                             = @('demo-egress-ip')
        'Microsoft.Network/natGateways'                                   = @('demo-nat')
        'Microsoft.Network/networkSecurityGroups'                         = @('demo-client-nsg')
        'Microsoft.Network/networkInterfaces'                             = @('demo-client-nic')
        'Microsoft.Network/virtualNetworks'                               = @("$AccountName-vnet")
        'Microsoft.Compute/virtualMachines'                               = @('demo-client')
        'Microsoft.Compute/disks'                                         = @('demo-client-os')
        'Microsoft.Compute/virtualMachines/extensions'                    = @('demo-client/RunCommandLinux')
        'Microsoft.NetApp/netAppAccounts'                                 = @($AccountName)
        'Microsoft.NetApp/netAppAccounts/capacityPools'                   = @("$AccountName/$AccountName-pool")
        'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'           = @($volumePath)
        'Microsoft.NetApp/netAppAccounts/capacityPools/volumes/snapshots' = @("$volumePath/demo-baseline")
    }
    $resources = @(Get-AzResource -ResourceGroupName $ResourceGroup -ErrorAction Stop)
    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers"
    $allowedIds = @{}
    foreach ($type in $allowed.Keys) {
        $typeParts = $type.Split('/')
        foreach ($name in $allowed[$type]) {
            $nameParts = $name.Split('/')
            $id = "$prefix/$($typeParts[0])"
            for ($index = 0; $index -lt $nameParts.Count; $index++) {
                $id += "/$($typeParts[$index + 1])/$($nameParts[$index])"
            }
            $allowedIds[$id] = $true
        }
    }
    foreach ($resource in $resources) {
        if (-not $resource.ResourceId -or -not $allowedIds.ContainsKey($resource.ResourceId)) {
            throw "Unexpected resource '$($resource.ResourceType)/$($resource.Name)'. Inspect the group; automatic cleanup was refused."
        }
    }
    $resources
}

function Get-AnfDemoPublicKey {
    # Azure requires a key even though this client is operated exclusively through Run Command.
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $stream = [IO.MemoryStream]::new()
    try {
        $key = $rsa.ExportParameters($false)
        $parts = @([Text.Encoding]::ASCII.GetBytes('ssh-rsa'), $key.Exponent, [byte[]](@(0) + $key.Modulus))
        foreach ($part in $parts) {
            $length = [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder([int] $part.Length))
            $stream.Write($length, 0, $length.Length)
            $stream.Write($part, 0, $part.Length)
        }
        'ssh-rsa ' + [Convert]::ToBase64String($stream.ToArray())
    }
    finally {
        $stream.Dispose()
        $rsa.Dispose()
    }
}

function Invoke-AnfDemoClient {
    param(
        [string] $ResourceGroup,
        [ValidatePattern('^[a-z][a-z0-9-]{1,14}[a-z0-9]$')][string] $DemoId, $Volume,
        [ValidateSet('Prepare', 'Check', 'Change', 'Restore')][string] $Action
    )

    $server = [string] @($Volume.MountTargets)[0].IpAddress
    $address = $null
    if (-not [Net.IPAddress]::TryParse($server, [ref] $address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $server -cne $address.ToString() -or $Volume.CreationToken -cne 'demo') {
        throw 'The demo volume did not return a valid IPv4 mount target and expected export path.'
    }
    $runId = [guid]::NewGuid().ToString('N')
    $scriptText = (Get-Content -LiteralPath "$PSScriptRoot/../demo/client.sh" -Raw).Replace("`r`n", "`n")
    $scriptText = $scriptText.Replace('__SERVER__', $server).Replace('__ACTION__', $Action).
    Replace('__DEMO_ID__', $DemoId).Replace('__RUN_ID__', $runId).
    Replace('__MOUNT_ROOT__', '/mnt/anf-demo')
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName 'demo-client' `
        -CommandId 'RunShellScript' -ScriptString $scriptText -ErrorAction Stop
    $messages = @($result.Value)
    $output = ($messages | ForEach-Object Message) -join "`n"
    $marker = "ANF_DEMO_OK:$Action`:$runId"
    if (@($messages | Where-Object Code -Match '/failed$').Count -or
        $output -notmatch "(?m)^$([regex]::Escape($marker))\r?$") {
        throw "Client step '$Action' did not complete successfully. Check VM agent readiness, outbound access and NFS connectivity. Guest output:`n$output"
    }
    Write-Information $output -InformationAction Continue
    [pscustomobject]@{ Action = $Action; ResourceGroup = $ResourceGroup; Client = 'demo-client'; Output = $output }
}
