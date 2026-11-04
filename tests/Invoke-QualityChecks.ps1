#requires -Version 7.4
<#
.SYNOPSIS
Runs the same offline quality checks locally and in GitHub Actions.
.DESCRIPTION
Downloads tools only with explicit InstallTools approval. Each check uses a fresh
PowerShell process to isolate test command doubles from actual Az modules.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $ToolsPath = (Join-Path ([IO.Path]::GetTempPath()) 'anf-quality-tools'),
    [switch] $InstallTools
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ToolsPath = [IO.Path]::GetFullPath($ToolsPath)
$tools = Import-PowerShellDataFile "$PSScriptRoot/QualityTools.psd1"
if ($InstallTools) {
    & "$PSScriptRoot/Install-QualityTools.ps1" -ToolsPath $ToolsPath
}
$analyzerManifest = Join-Path $ToolsPath "Modules/PSScriptAnalyzer/$($tools.Analyzer.Version)/PSScriptAnalyzer.psd1"
if (-not (Test-Path -LiteralPath $analyzerManifest)) {
    throw 'Quality tools are missing. Run ./tests/Invoke-QualityChecks.ps1 -InstallTools first.'
}
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
& $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/Run-Tests.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Offline regression tests failed.' }
& $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/Test-AzCommandContracts.ps1" -ToolsPath $ToolsPath
if ($LASTEXITCODE -ne 0) { throw 'Azure command contract checks failed.' }
Import-Module $analyzerManifest -ErrorAction Stop
if ((Get-Module PSScriptAnalyzer).Version.ToString() -ne $tools.Analyzer.Version) {
    throw 'The loaded PSScriptAnalyzer version does not match QualityTools.psd1.'
}
$scripts = @(Get-ChildItem $root -Recurse -Filter '*.ps1' | Where-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName) -notmatch '^tests[\\/]Run-Tests\.ps1$'
})
if ($scripts.Count -eq 0) { throw 'No production scripts found for analysis.' }
$issues = @($scripts | Invoke-ScriptAnalyzer -Severity Error,Warning -ErrorAction Stop)
if ($issues.Count) {
    $issues | Format-Table ScriptName, Line, RuleName, Message -AutoSize -Wrap
    throw "PSScriptAnalyzer reported $($issues.Count) warning(s) or error(s)."
}
Write-Output "Quality checks passed with PowerShell $($PSVersionTable.PSVersion), Az $($tools.AzRelease) and PSScriptAnalyzer $($tools.Analyzer.Version). Azure deployment compatibility remains unverified."
