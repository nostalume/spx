# exec/linked.ps1
param ([Parameter(ValueFromRemainingArguments)] [string[]]$Args)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Link.ps1"

$p      = Get-ParsedArgs $Args
$global = $p.Options.ContainsKey('global') -or $p.Options.ContainsKey('g')
$status = $p.Options.ContainsKey('status')
$scopes = if ($global) { @('global') } else { @('local', 'global') }

$found = $false
foreach ($scope in $scopes) {
    $isGlobal = ($scope -eq 'global')
    $entries  = @(Get-AppLinkStatus -Global:$isGlobal)
    if ($entries.Count -eq 0) { continue }

    $found = $true
    Write-Host "`n$($scope.ToUpper()) linked apps:"
    Write-Host ('-' * 40)

    foreach ($e in $entries) {
        if ($status) {
            $tag = if ($e.Status -eq 'Stale') { ' [STALE]' } else { '' }
            Write-Host ("  {0,-22} -> {1}  (v{2}){3}" -f $e.AppName, $e.TargetPath, $e.Version, $tag)
        } else {
            Write-Host ("  {0,-22} -> {1}  (v{2})" -f $e.AppName, $e.TargetPath, $e.Version)
        }
    }
}

if (-not $found) { Write-Host 'No linked apps found.' }