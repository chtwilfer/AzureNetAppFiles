#requires -Version 7.4
<#
.SYNOPSIS
Downloads checksum-pinned quality tools into an isolated local cache.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $ToolsPath = (Join-Path ([IO.Path]::GetTempPath()) 'anf-quality-tools')
)

$ErrorActionPreference = 'Stop'
$tools = Import-PowerShellDataFile "$PSScriptRoot/QualityTools.psd1"
$ToolsPath = [IO.Path]::GetFullPath($ToolsPath)
$moduleRoot = Join-Path $ToolsPath 'Modules'
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
$downloadPath = Join-Path $ToolsPath ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $downloadPath | Out-Null

try {
    $missingModules = @($tools.Modules.Keys | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $moduleRoot "$_/$($tools.Modules[$_])/$_.psd1"))
    })
    if ($missingModules.Count -gt 0) {
        $archive = Join-Path $downloadPath 'az.tar.gz'
        Invoke-WebRequest -Uri $tools.AzArchive.Uri -OutFile $archive -TimeoutSec 300 -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $tools.AzArchive.Sha256) {
            throw 'Az archive checksum mismatch. No downloaded modules will be installed.'
        }
        foreach ($name in $missingModules) {
            $version = $tools.Modules[$name]
            $packageName = "$name.$version.nupkg"
            & tar -xzf $archive -C $downloadPath $packageName
            if ($LASTEXITCODE -ne 0) {
                throw "Could not extract '$packageName' from the Az archive."
            }
            $stage = Join-Path $downloadPath $name
            [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $downloadPath $packageName), $stage)
            $manifest = Import-PowerShellDataFile (Join-Path $stage "$name.psd1")
            if ($manifest.ModuleVersion -ne $version) {
                throw "Downloaded module '$name' does not have the required version '$version'."
            }
            $target = Join-Path $moduleRoot $name
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $versionTarget = Join-Path $target $version
            if (Test-Path -LiteralPath $versionTarget) {
                throw "Incomplete tools cache at '$versionTarget'. Inspect and remove that version directory before retrying."
            }
            Move-Item -LiteralPath $stage -Destination $versionTarget -ErrorAction Stop
        }
    }
    $analyzerTarget = Join-Path $moduleRoot "PSScriptAnalyzer/$($tools.Analyzer.Version)"
    if (-not (Test-Path -LiteralPath (Join-Path $analyzerTarget 'PSScriptAnalyzer.psd1'))) {
        $package = Join-Path $downloadPath 'analyzer.nupkg'
        Invoke-WebRequest -Uri $tools.Analyzer.Uri -OutFile $package -TimeoutSec 120 -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ine $tools.Analyzer.Sha256) {
            throw 'PSScriptAnalyzer package checksum mismatch.'
        }
        $stage = Join-Path $downloadPath 'PSScriptAnalyzer'
        [IO.Compression.ZipFile]::ExtractToDirectory($package, $stage)
        New-Item -ItemType Directory -Path (Split-Path $analyzerTarget -Parent) -Force | Out-Null
        if (Test-Path -LiteralPath $analyzerTarget) {
            throw "Incomplete tools cache at '$analyzerTarget'. Inspect and remove that version directory before retrying."
        }
        Move-Item -LiteralPath $stage -Destination $analyzerTarget -ErrorAction Stop
    }
} finally {
    Remove-Item -LiteralPath $downloadPath -Recurse -Force
}
Write-Output "Quality tools available at '$moduleRoot'. No Azure login or global module installation was performed."
