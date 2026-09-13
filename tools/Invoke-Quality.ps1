#Requires -Version 5.1

<#
.SYNOPSIS
Runs the canonical SPX parse, format, analyzer, manifest, help, and documentation checks.
#>
[CmdletBinding()]
param (
    [ValidateSet('Check', 'Format')][string]$Mode = 'Check'
)

$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settingsPath = Join-Path $repository 'PSScriptAnalyzerSettings.psd1'
$requiredAnalyzer = [version]'1.25.0'
$analyzer = Get-Module -ListAvailable PSScriptAnalyzer |
    Where-Object { $_.Version -eq $requiredAnalyzer } |
    Select-Object -First 1
if (-not $analyzer) {
    throw "PSScriptAnalyzer $requiredAnalyzer is required. Install-Module PSScriptAnalyzer -RequiredVersion $requiredAnalyzer -Scope CurrentUser"
}
Import-Module $analyzer.Path -Force -ErrorAction Stop
$settings = Import-PowerShellDataFile $settingsPath

$sourceFiles = @(
    Get-ChildItem -LiteralPath $repository -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }
    foreach ($directory in 'lib', 'domain', 'tests', 'tools') {
        Get-ChildItem -LiteralPath (Join-Path $repository $directory) -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }
        }
    ) | Sort-Object FullName -Unique

    $parseFailures = New-Object Collections.Generic.List[object]
    foreach ($file in $sourceFiles) {
        $tokens = $null
        $failures = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$failures)
        foreach ($failure in @($failures)) { $parseFailures.Add($failure) }
    }
    if ($parseFailures.Count) {
        throw ('PowerShell parse failures:' + [Environment]::NewLine + (($parseFailures | ForEach-Object { $_.Message }) -join [Environment]::NewLine))
    }

    $formatFailures = New-Object Collections.Generic.List[string]
    $utf8 = New-Object Text.UTF8Encoding $false
    foreach ($file in $sourceFiles) {
        $source = [IO.File]::ReadAllText($file.FullName)
        $formatted = Invoke-Formatter -ScriptDefinition $source -Settings $settingsPath
        if ($source -ceq $formatted) { continue }
        if ($Mode -eq 'Format') {
            [IO.File]::WriteAllText($file.FullName, $formatted, $utf8)
        }
        else {
            $formatFailures.Add($file.FullName.Substring($repository.Length + 1))
        }
    }
    if ($formatFailures.Count) {
        throw ("PowerShell formatting differs in: " + ($formatFailures -join ', ') + ". Run ./tools/Invoke-Quality.ps1 -Mode Format.")
    }

    $analysis = @($sourceFiles | ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settingsPath -Severity Error, Warning
        })
    if ($analysis.Count) {
        $messages = $analysis | ForEach-Object { '{0}:{1}:{2} {3} {4}' -f $_.ScriptName, $_.Line, $_.Column, $_.RuleName, $_.Message }
        throw ('PSScriptAnalyzer failures:' + [Environment]::NewLine + ($messages -join [Environment]::NewLine))
    }

    $manifestPath = Join-Path $repository 'SPX.psd1'
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    $package = Get-Content -LiteralPath (Join-Path $repository 'spx.json') -Raw | ConvertFrom-Json
    if ([string]$manifest.Version -ne [string]$package.version) { throw 'SPX.psd1 and spx.json versions differ.' }
    if ([string]$package.bin -ne 'spx.ps1') { throw 'spx.json must expose bin = spx.ps1.' }
    if ([string]$package.psmodule.name -ne 'SPX') { throw 'spx.json must retain psmodule.name = SPX.' }

    Remove-Module SPX -ErrorAction SilentlyContinue
    Import-Module $manifestPath -Force -ErrorAction Stop
    . (Join-Path $repository 'lib\Cli.ps1')
    $specification = Get-SpxCliSpecification
    $exports = @(Get-Command -Module SPX | Select-Object -ExpandProperty Name | Sort-Object)
    $targets = @($specification.Values.Function | Sort-Object -Unique)
    if (Compare-Object $exports $targets) { throw 'CLI dispatch targets and module exports differ.' }

    $scriptCommand = Get-Command (Join-Path $repository 'spx.ps1')
    $declaredScriptParameters = @($scriptCommand.Parameters.Keys)
    foreach ($item in $specification.GetEnumerator()) {
        $target = Get-Command $item.Value.Function -Module SPX
        foreach ($parameter in $item.Value.Parameters) {
            if ($parameter -notin $declaredScriptParameters) { throw "CLI leaf '$($item.Key)' uses undeclared script parameter '$parameter'." }
            if (-not $target.Parameters.ContainsKey($parameter)) { throw "CLI leaf '$($item.Key)' cannot pass '$parameter' to '$($target.Name)'." }
        }
        if ($item.Value.IdentityParameter -and -not $target.Parameters.ContainsKey($item.Value.IdentityParameter)) {
            throw "CLI leaf '$($item.Key)' identity parameter is absent from '$($target.Name)'."
        }
    }

    $apiText = Get-Content -LiteralPath (Join-Path $repository 'docs\api.md') -Raw
    $cliText = Get-Content -LiteralPath (Join-Path $repository 'docs\cli.md') -Raw
    foreach ($name in $exports) {
        if ($apiText -notmatch [regex]::Escape("``$name``")) { throw "docs/api.md omits '$name'." }
        $help = Get-Help $name -Full
        if ([string]::IsNullOrWhiteSpace(($help.Description.Text -join ' '))) { throw "'$name' has no help description." }
        if (@($help.Examples.Example).Count -eq 0) { throw "'$name' has no help example." }
        if (-not $help.ReturnValues) { throw "'$name' has no outputs help." }
        foreach ($parameter in (Get-Command $name).Parameters.Keys) {
            if ($parameter -in [Management.Automation.Cmdlet]::CommonParameters -or $parameter -in [Management.Automation.Cmdlet]::OptionalCommonParameters) { continue }
            $parameterHelp = @($help.Parameters.Parameter | Where-Object Name -EQ $parameter)
            if (-not $parameterHelp -or [string]::IsNullOrWhiteSpace(($parameterHelp.Description.Text -join ' '))) {
                throw "'$name' has no meaningful help for '-$parameter'."
            }
        }
    }
    foreach ($key in $specification.Keys) {
        $display = 'spx ' + $key.Replace('/', ' ')
        if ($cliText -notmatch [regex]::Escape($display)) { throw "docs/cli.md omits '$display'." }
    }

    $markdownFiles = Get-ChildItem -LiteralPath $repository -Recurse -File -Filter '*.md' |
        Where-Object { $_.FullName -notmatch '[\\/]\.agents[\\/]' }
foreach ($file in $markdownFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
        $link = $match.Groups[1].Value.Trim('<', '>')
        if ($link -match '^(?:[a-z]+:|#)') { continue }
        $pathPart = ($link -split '#', 2)[0]
        if (-not $pathPart) { continue }
        $candidate = Join-Path $file.DirectoryName ([Uri]::UnescapeDataString($pathPart))
        if (-not (Test-Path -LiteralPath $candidate)) { throw "Broken local Markdown link '$link' in '$($file.FullName)'." }
    }
}

[pscustomobject]@{
    Mode = $Mode
    Analyzer = $requiredAnalyzer.ToString()
    Sources = $sourceFiles.Count
    Exports = $exports.Count
    CliLeaves = $specification.Count
    Status = 'Passed'
}
