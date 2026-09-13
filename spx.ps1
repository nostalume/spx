#Requires -Version 5.1

<#
.SYNOPSIS
Runs SPX as a Scoop-style script command.

.DESCRIPTION
Uses native PowerShell parameter binding, validates the selected SPX subcommand,
and delegates to the retained SPX module transaction engine.

.PARAMETER Command
Top-level command: link, unlink, linked, sync, repair, cleanup, config, source,
mirror, or help.

.PARAMETER Arguments
Command action and app or bucket identities.

.PARAMETER Destination
Destination root used by the link command.

.PARAMETER Scope
Scoop scope. Each command admits only its documented values.

.PARAMETER Path
Configuration import or export path.

.PARAMETER Bucket
Bucket selected by source commands.

.PARAMETER Url
Git remote URL selected by mirror commands.

.PARAMETER Force
Permits the documented source or export override.

.PARAMETER Merge
Merges imported link configuration.

.PARAMETER Help
Displays root or command-specific help without importing the SPX module.

.PARAMETER Version
Displays the package version without importing the SPX module.

.EXAMPLE
spx link jq -Destination 'D:\Portable Apps' -Scope Local -WhatIf

.EXAMPLE
spx source set jq -Bucket extras -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Arguments,
    [string]$Destination,
    [ValidateSet('Local', 'Global', 'All')][string]$Scope,
    [string]$Path,
    [string]$Bucket,
    [string]$Url,
    [switch]$Force,
    [switch]$Merge,
    [switch]$Help,
    [switch]$Version
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Cli.ps1"

$passiveCommon = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
    'OutBuffer', 'PipelineVariable', 'ProgressAction'
)

if ($Version) {
    $invalid = @($PSBoundParameters.Keys | Where-Object { $_ -notin @('Version') -and $_ -notin $passiveCommon })
    if ($invalid.Count) {
        Stop-SpxCliUsage "-Version cannot be combined with '-$($invalid[0])'." $invalid[0]
    }
    $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'SPX.psd1')
    [string]$manifest.ModuleVersion
    return
}

if (-not $Command) {
    if (($PSBoundParameters.Keys | Where-Object { $_ -notin @('Help') -and $_ -notin $passiveCommon }).Count) {
        Stop-SpxCliUsage "A command is required. Run 'spx -Help'." $PSBoundParameters
    }
    Get-SpxCliHelp
    return
}

if ($Command.Equals('help', [StringComparison]::OrdinalIgnoreCase)) {
    $invalid = @($PSBoundParameters.Keys | Where-Object { $_ -notin @('Command', 'Arguments') -and $_ -notin $passiveCommon })
    if ($invalid.Count) {
        Stop-SpxCliUsage "Parameter '-$($invalid[0])' is not valid for 'help'." $invalid[0]
    }
    if ($Arguments.Count -eq 0) {
        Get-SpxCliHelp
    }
    else {
        Get-SpxCliHelp -Command $Arguments[0] -Arguments @($Arguments | Select-Object -Skip 1)
    }
    return
}

if ($Help) {
    $resolved = Resolve-SpxCliLeaf -Command $Command -Arguments $Arguments
    $allowed = @('Command', 'Arguments', 'Help') + @($resolved.Leaf.Parameters) + $passiveCommon
    $invalid = @($PSBoundParameters.Keys | Where-Object { $_ -notin $allowed })
    if ($invalid.Count) {
        Stop-SpxCliUsage "Parameter '-$($invalid[0])' is not valid for '$($resolved.Key.Replace('/', ' '))'." $invalid[0]
    }
    Get-SpxCliHelp -Command $Command -Arguments $Arguments
    return
}

$resolved = Resolve-SpxCliLeaf -Command $Command -Arguments $Arguments
Invoke-SpxCli -RepositoryRoot $PSScriptRoot -Resolved $resolved -BoundParameters $PSBoundParameters
