# exec/sync.ps1
param ([Parameter(ValueFromRemainingArguments)] [string[]]$Args)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Link.ps1"

$p      = Get-ParsedArgs $Args
$apps   = $p.Positional
$global = $p.Options.ContainsKey('global') -or $p.Options.ContainsKey('g')
$wi     = $p.Options.ContainsKey('whatif')

if ($apps.Count -eq 0) {
    Write-Host 'Syncing all linked apps...'
    Sync-AppLinks -Global:$global -WhatIf:$wi
} else {
    foreach ($app in $apps) {
        Write-Host "Syncing '$app'..."
        Sync-AppLinks -AppName $app -Global:$global -WhatIf:$wi
    }
}
Write-Host 'Sync complete.'