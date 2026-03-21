# exec/unlink.ps1
param ([Parameter(ValueFromRemainingArguments)] [string[]]$Args)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Link.ps1"

$p      = Get-ParsedArgs $Args
$apps   = $p.Positional
$global = $p.Options.ContainsKey('global') -or $p.Options.ContainsKey('g')
$wi     = $p.Options.ContainsKey('whatif')

if ($apps.Count -eq 0) { Write-Host 'Usage: spx unlink <app> [<app2> ...]'; return }

foreach ($app in $apps) {
    $result = Remove-AppLink -AppName $app -Global:$global -WhatIf:$wi
    if ($result) { Write-Host "[unlink] '$($result.AppName)' restored to Scoop directory." }
}