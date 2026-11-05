#Requires -Version 5.1
<#
.SYNOPSIS
Relocates Scoop apps, observes sources, and recovers or reclaims recorded copies.
.DESCRIPTION
Uses native PowerShell binding. Run spx -Help or spx source -Help for modes and examples.
Import-Module SPX enables context completion in the current session without changing a profile.
.EXAMPLE
spx source jq -Bucket extras -WhatIf
.EXAMPLE
spx source -Bucket main -Url https://mirror.example/main.git -WhatIf
#>
[CmdletBinding()]
param (
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('Name', 'AppName')][object[]]$Arguments,
    [string]$Destination,
    [ValidateSet('Local', 'Global', 'All')][string]$Scope,
    [string]$Bucket,
    [switch]$Buckets,
    [string]$Url,
    [switch]$Reset,
    [switch]$Find,
    [string]$Compare,
    [switch]$CheckVersion,
    [switch]$Force,
    [switch]$WhatIf,
    [switch]$Confirm,
    [switch]$Help,
    [switch]$Version
)
begin {
    $entryParameters = @{}
    foreach ($key in $PSBoundParameters.Keys) { $entryParameters[$key] = $PSBoundParameters[$key] }
    $entryRoot = $PSScriptRoot
    . "$entryRoot/src/Cli.ps1"
    $entryProcessed = $false
    $entryAction = {
        $ErrorActionPreference = 'Stop'
        $common = @([Management.Automation.Cmdlet]::CommonParameters)
        $names = @($Arguments | Where-Object { $null -ne $_ } | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.AppName) { $_.AppName } elseif ($_.Name) { $_.Name } else { $_ } } | ForEach-Object { [string]$_ })
        if ($Help -and $Command -and $Command -ne 'help' -and -not $Version) {
            $invocation = Resolve-SpxCliInvocation -Command $Command -Names $names -BoundParameters $entryParameters -ForHelp
            $selectors = @($entryParameters.Keys | Where-Object { $_ -notin @('Command', 'Arguments', 'Help') + $common })
            Get-SpxCliHelp -Command $Command -ModeKey $(if ($selectors.Count) { $invocation.Key })
            return
        }
        if ($Version -or -not $Command -or $Command -eq 'help' -or $Help) {
            $allowed = @('Command', 'Arguments', 'Help') + $common
            if ($Version) { $allowed = @('Version') + $common }
            $invalid = @($entryParameters.Keys | Where-Object { $_ -notin $allowed })
            if ($invalid.Count) { Stop-SpxCliUsage "Parameter '-$($invalid[0])' is not valid for help/version." $invalid[0] }
            if ($Version) { [string](Import-PowerShellDataFile "$entryRoot/SPX.psd1").ModuleVersion; return }
            if ($Command -eq 'help') {
                if ($Arguments.Count -gt 1) { Stop-SpxCliUsage 'Use spx help <command>.' $Arguments }
                Get-SpxCliHelp -Command $Arguments[0]
            }
            else { Get-SpxCliHelp -Command $Command }
            return
        }
        $invocation = Resolve-SpxCliInvocation -Command $Command -Names $names -BoundParameters $entryParameters
        Invoke-SpxCli -RepositoryRoot $entryRoot -Invocation $invocation
    }
}
process {
    $entryProcessed = $true
    & $entryAction
}
end {
    # An independent -File invocation may inherit an empty native stdin pipe.
    # An empty PowerShell object pipeline must not become a scope-wide action.
    if (-not $entryProcessed -and (-not $MyInvocation.ExpectingInput -or [string]::IsNullOrEmpty($MyInvocation.Line))) { & $entryAction }
}
