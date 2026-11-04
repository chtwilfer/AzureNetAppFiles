#requires -Version 7.4
<#
.SYNOPSIS
Checks Azure command names, parameter names and parameter sets without executing Azure commands.
.DESCRIPTION
Imports exact module versions from the quality-tools cache and examines production
PowerShell ASTs. Literal hashtable splats are checked conservatively against every
definition of that variable, including forwarding through helper parameters.
Dynamic commands and unresolved Azure splats are rejected, not silently skipped.
This does not validate runtime argument values, Azure APIs or server behavior.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $ToolsPath = (Join-Path ([IO.Path]::GetTempPath()) 'anf-quality-tools'),
    [string[]] $Path
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tools = Import-PowerShellDataFile "$PSScriptRoot/QualityTools.psd1"
$moduleRoot = Join-Path ([IO.Path]::GetFullPath($ToolsPath)) 'Modules'
$env:AZUREPS_DATA_COLLECTION = 'false'
foreach ($name in $tools.Modules.Keys | Sort-Object) {
    $manifest = Join-Path $moduleRoot "$name/$($tools.Modules[$name])/$name.psd1"
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Missing pinned module '$name'. Run ./tests/Install-QualityTools.ps1 -ToolsPath '$ToolsPath'."
    }
    Import-Module $manifest -ErrorAction Stop
    $loaded = Get-Module -Name $name
    if (@($loaded).Count -ne 1 -or $loaded.Version.ToString() -ne $tools.Modules[$name]) {
        throw "Module '$name' was not loaded exclusively at version '$($tools.Modules[$name])'. Use a fresh pwsh process."
    }
}

$files = if ($Path) {
    @($Path | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction Stop })
}
else {
    @(Get-ChildItem $root -Recurse -Filter '*.ps1' | Where-Object {
            [IO.Path]::GetRelativePath($root, $_.FullName) -notmatch '^tests[\\/]'
        })
}
$asts = @($files | ForEach-Object {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $tokens, [ref] $parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
        $ast
    })
function Get-ContractScope {
    param([System.Management.Automation.Language.Ast] $Node)
    while ($Node -and $Node -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $Node = $Node.Parent
    }
    if ($Node) { return $Node.Name }
    return ''
}
function Get-AzContractCheck {
    param([System.Management.Automation.Language.ScriptBlockAst[]] $Asts)

    $splats = @{}
    foreach ($ast in $Asts) {
        foreach ($assignment in $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)) {
            $tables = @($assignment.Right.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.HashtableAst]
                    }, $true))
            if ($tables.Count -ne 1) { continue }
            $name = "$(Get-ContractScope $assignment):$($assignment.Left.VariablePath.UserPath)"
            $keys = @($tables[0].KeyValuePairs | ForEach-Object { $_.Item1.SafeGetValue() })
            if (-not $splats.ContainsKey($name)) { $splats[$name] = @() }
            $splats[$name] += , $keys
        }
    }
    foreach ($ast in $Asts) {
        foreach ($assignment in $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node.Left.Expression -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)) {
            $name = "$(Get-ContractScope $assignment):$($assignment.Left.Expression.VariablePath.UserPath)"
            if ($splats.ContainsKey($name)) {
                $memberName = $assignment.Left.Member.SafeGetValue()
                $splats[$name] = @($splats[$name] | ForEach-Object { , @($_ + $memberName | Sort-Object -Unique) })
            }
        }
    }

    $checked = 0
    $failures = @()
    foreach ($ast in $Asts) {
        foreach ($call in $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)) {
            $name = $call.GetCommandName()
            if (-not $name) {
                # The polling callback is local code; it is not an Azure command.
                $pollCallback = (Get-ContractScope $call) -eq 'Wait-AnfState' -and $call.CommandElements[0].Extent.Text -eq '$Read'
                if ($call.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot -and -not $pollCallback) {
                    $failures += "$($call.Extent.File):$($call.Extent.StartLineNumber): Dynamic command cannot be checked."
                }
                continue
            }
            if ($name -notmatch '^[^-]+-Az') { continue }
            $checked++
            try {
                $command = Get-Command $name -CommandType Cmdlet, Function -ErrorAction Stop
                if ($command.ModuleName -notin $tools.Modules.Keys) {
                    throw "Command '$name' does not belong to a pinned Az module."
                }
                $explicit = @($call.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst]
                    } | ForEach-Object ParameterName)
                $variants = @(, $explicit)
                foreach ($splat in $call.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
                    }) {
                    $variable = $splat.VariablePath.UserPath
                    $key = "$(Get-ContractScope $call):$variable"
                    if (-not $splats.ContainsKey($key)) { $key = ":$variable" }
                    if (-not $splats.ContainsKey($key)) { throw "Unresolved Azure splat '@$variable'." }
                    $expanded = @()
                    foreach ($variant in $variants) {
                        foreach ($keys in $splats[$key]) { $expanded += , @($variant + $keys) }
                    }
                    $variants = $expanded
                }
                foreach ($variant in $variants) {
                    $canonical = @($variant | ForEach-Object {
                            $parameter = $_
                            $parameterMatches = @($command.Parameters.Values | Where-Object {
                                    $_.Name -ieq $parameter -or $parameter -in $_.Aliases
                                })
                            if ($parameterMatches.Count -ne 1) { throw "Unknown or abbreviated parameter '-$parameter' on '$name'." }
                            $parameterMatches[0].Name
                        })
                    if (@($canonical | Sort-Object -Unique).Count -ne $canonical.Count) {
                        throw "Duplicate parameter on '$name': $($canonical -join ', ')."
                    }
                    $sets = @($command.ParameterSets | Where-Object {
                            $setNames = $_.Parameters.Name
                            $pipelineInput = $call.Parent -is [System.Management.Automation.Language.PipelineAst] -and
                            $call.Parent.PipelineElements[0] -ne $call
                            $missingRequired = @($_.Parameters | Where-Object {
                                    $_.IsMandatory -and $_.Name -notin $canonical -and
                                    -not ($pipelineInput -and ($_.ValueFromPipeline -or $_.ValueFromPipelineByPropertyName))
                                })
                            @($canonical | Where-Object { $_ -notin $setNames }).Count -eq 0 -and $missingRequired.Count -eq 0
                        })
                    if ($sets.Count -eq 0) {
                        throw "No parameter set supports '$name' with: $($canonical -join ', ')."
                    }
                }
            }
            catch {
                $failures += "$($call.Extent.File):$($call.Extent.StartLineNumber): $($_.Exception.Message)"
            }
        }
    }
    [pscustomobject]@{ Checked = $checked; Failures = $failures }
}

$result = Get-AzContractCheck -Asts $asts
if ($result.Checked -eq 0) { throw 'No Azure commands were found for contract checks.' }
if ($result.Failures.Count) {
    throw "Azure command contract checks failed:`n$($result.Failures -join "`n")"
}
Write-Output "Az $($tools.AzRelease): $($result.Checked) Azure command call sites match the pinned module contracts. No Azure command was executed."

if (-not $Path) {
    $validFixtures = @(
        'Get-AzResourceGroup -Name test',
        '$p = @{ Name = "test"; ErrorAction = "Stop" }; Get-AzResourceGroup @p',
        'function One { $p = @{ Name = "test" }; Get-AzResourceGroup @p }; function Two { $p = @{ ResourceGroupName = "test"; AccountName = "test" }; Get-AzNetAppFilesAccount @p }',
        '$vm | Set-AzVMOperatingSystem -Linux -ComputerName test -Credential $cred -DisablePasswordAuthentication'
    )
    foreach ($code in $validFixtures) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref] $tokens, [ref] $parseErrors)
        $positive = Get-AzContractCheck -Asts @($ast)
        if ($parseErrors.Count -or $positive.Failures.Count -or $positive.Checked -eq 0) {
            throw "Contract checker rejected a valid fixture: $code`n$($positive.Failures -join "`n")"
        }
    }
    Write-Output "PASS $($validFixtures.Count) valid contract fixtures (including scoped splats and pipeline input)"
    $fixtures = @(
        @{ Name = 'unknown parameter'; Code = 'Get-AzResourceGroup -NotARealParameter x' },
        @{ Name = 'unknown cmdlet'; Code = 'Get-AzNonexistentAnfCommand' },
        @{ Name = 'incompatible parameter set'; Code = 'Get-AzNetAppFilesVolume -ResourceId /test -ResourceGroupName test -AccountName test -PoolName test' },
        @{ Name = 'missing mandatory parameter'; Code = 'New-AzNetAppFilesVolume -Name test' },
        @{ Name = 'unresolved splat'; Code = 'Get-AzResourceGroup @notDefined' },
        @{ Name = 'invalid splatted parameter'; Code = '$p = @{ NotARealParameter = 1 }; Get-AzResourceGroup @p' },
        @{ Name = 'invalid appended parameter'; Code = '$p = @{ Name = "test" }; $p.NotARealParameter = 1; Get-AzResourceGroup @p' },
        @{ Name = 'duplicate parameter'; Code = '$p = @{ Name = "test" }; Get-AzResourceGroup -Name test @p' }
    )
    foreach ($fixture in $fixtures) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($fixture.Code, [ref] $tokens, [ref] $parseErrors)
        if ($parseErrors.Count) { throw "Invalid contract fixture '$($fixture.Name)'." }
        $negative = Get-AzContractCheck -Asts @($ast)
        if ($negative.Failures.Count -eq 0) {
            throw "Contract checker did not reject fixture '$($fixture.Name)'."
        }
        Write-Output "PASS contract rejection: $($fixture.Name)"
    }
}
