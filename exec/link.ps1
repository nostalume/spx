# exec/link.ps1 - CLI: spx link
param ([Parameter(ValueFromRemainingArguments)] [string[]]$Args)

. "$PSScriptRoot/../context.ps1"
. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../lib/Config.ps1"
. "$PSScriptRoot/../modules/Link.ps1"

$p      = Get-ParsedArgs $Args
$app    = $p.Positional[0]
$path   = $p.Options['path'] ?? $p.Options['to']
$global = $p.Options.ContainsKey('global') -or $p.Options.ContainsKey('g')
$wi     = $p.Options.ContainsKey('whatif')

# Export / Import sub-commands
if ($p.Options['export']) {
    Export-LinksConfig -Path $p.Options['export']
    Write-Host "Link config exported to: $($p.Options['export'])"
    return
}
if ($p.Options['import']) {
    Import-LinksConfig -Path $p.Options['import'] -Merge:($p.Options.ContainsKey('merge'))
    Write-Host "Link config imported from: $($p.Options['import'])"
    return
}

if (-not $app)  { Write-Host 'Usage: spx link <app> --path <dir>'; return }
if (-not $path) { Write-Error 'Missing: --path <dir>'; return }

$result = New-AppLink -AppName $app -Path $path -Global:$global -WhatIf:$wi
if ($result) { Write-Host "[link] '$($result.AppName)' → $($result.TargetPath)  (v$($result.Version))" }