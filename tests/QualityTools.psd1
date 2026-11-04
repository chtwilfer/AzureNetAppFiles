@{
    AzRelease = '16.5.0'
    AzArchive = @{
        Uri = 'https://github.com/Azure/azure-powershell/releases/download/v16.5.0-November2026/Az-Cmdlets-16.5.0.41350.tar.gz'
        Sha256 = 'f9410e26aad7eaa51fbcb48469273740db8239cb82df904f8139cd1082183f96'
    }
    Modules = @{
        'Az.Accounts' = '5.5.4'
        'Az.Compute' = '11.11.0'
        'Az.MarketplaceOrdering' = '2.2.0'
        'Az.NetAppFiles' = '1.4.1'
        'Az.Network' = '8.4.0'
        'Az.Resources' = '10.2.2'
    }
    Analyzer = @{
        Version = '1.25.0'
        Uri = 'https://github.com/PowerShell/PSScriptAnalyzer/releases/download/1.25.0/PSScriptAnalyzer.1.25.0.nupkg'
        Sha256 = '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60'
    }
}
