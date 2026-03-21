# exec/cleanup.ps1
param ([Parameter(ValueFromRemainingArguments)] [string[]]$Args)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Link.ps1"

$p      = Get-ParsedArgs $Args
$dryRun = $p.Options.ContainsKey('dry-run')
$force  = $p.Options.ContainsKey('force')
$stale  = @(Get-StaleLinkEntries)

if ($stale.Count -eq 0) { Write-Host 'No stale entries. All linked apps are valid.'; return }

Write-Host "Found $($stale.Count) stale link(s):"
foreach ($entry in $stale) {
    Write-Host "  [$($entry.Scope)] $($entry.AppName)  (was -> $($entry.LinkPath), v$($entry.Version))"
}

if ($dryRun) { Write-Host "`n[dry-run] Nothing changed. Remove --dry-run to clean up."; return }

if (-not $force) {
    $r = Read-Host "`nRemove all stale entries? [y/N]"
    if ($r -notmatch '^y') { Write-Host 'Aborted.'; return }
}

foreach ($entry in $stale) {
    Remove-StaleLinkEntry -AppName $entry.AppName -Global:$entry.Global -Confirm:$false
    Write-Host "  Removed: $($entry.AppName)"
}
Write-Host 'Cleanup complete.'