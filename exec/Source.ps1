# exec/source.ps1
param (
    [Parameter(Position = 0)] [string]$Action,
    [Parameter(ValueFromRemainingArguments)] [string[]]$Rest
)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Source.ps1"

$p     = Get-ParsedArgs $Rest
$force = $p.Options.ContainsKey('force')
$pos   = $p.Positional

$actionKey = if ($Action) { $Action.ToLower() } else { '' }

switch ($actionKey) {
    'list' {
        $all = @(Get-AppSourceList)
        if ($all.Count -eq 0) { Write-Host 'No apps installed.'; return }
        $all | Format-Table @(
            @{ Label = 'App';     Expression = { $_.AppName };                                     Width = 22 }
            @{ Label = 'Bucket';  Expression = { $_.Bucket  };                                     Width = 18 }
            @{ Label = 'Version'; Expression = { $_.Version };                                     Width = 14 }
            @{ Label = 'Scope';   Expression = { if ($_.Global) { 'global' } else { 'local' } } }
        ) -AutoSize
    }

    'show' {
        $app = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        if (-not $app) { Write-Error 'Usage: spx source show <app>'; return }
        $src = Get-AppSource $app
        if (-not $src) { return }
        [PSCustomObject]@{
            App         = $src.AppName
            Bucket      = $src.Bucket
            Version     = $src.Version
            Scope       = if ($src.Global) { 'global' } else { 'local' }
            InstallPath = $src.InstallPath
        } | Format-List
    }

    'change' {
        $app    = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        $bucket = if ($pos.Count -gt 1) { $pos[1] } else { $null }
        if (-not $app -or -not $bucket) { Write-Error 'Usage: spx source change <app> <bucket>'; return }
        $result = Move-AppSource -AppName $app -Bucket $bucket -Force:$force
        if ($result) { Write-Host "[source] '$($result.AppName)': '$($result.OldBucket)' -> '$($result.NewBucket)'" }
    }

    'verify' {
        $apps = if ($pos.Count -gt 0) { @($pos[0]) } else { @(Get-AppSourceList | Select-Object -ExpandProperty AppName) }
        $ok = 0; $fail = 0
        foreach ($app in $apps) {
            if (Test-AppSourceValid $app) { Write-Host "[OK]   $app"; $ok++ }
            else                          { Write-Host "[FAIL] $app"; $fail++ }
        }
        if ($apps.Count -gt 1) { Write-Host "`nResult: $ok OK, $fail failed" }
    }

    'diff' {
        $app    = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        $bucket = if ($pos.Count -gt 1) { $pos[1] } else { $null }
        if (-not $app -or -not $bucket) { Write-Error 'Usage: spx source diff <app> <bucket>'; return }
        $cmp = Compare-AppManifest -AppName $app -Bucket $bucket
        if (-not $cmp) { return }
        Write-Host "`n$($cmp.AppName)  [$($cmp.CurrentBucket) vs $($cmp.CompareBucket)]"
        Write-Host "  Installed : $($cmp.InstalledVersion)"
        Write-Host "  Bucket    : $($cmp.BucketVersion)  $(if ($cmp.VersionMatch) { '(match)' } else { '(MISMATCH)' })"
        if ($cmp.Differences.Count -gt 0) {
            Write-Host "`nField differences:"
            $cmp.Differences | Format-Table Field, Installed, Bucket -AutoSize
        } else { Write-Host 'No manifest differences.' }
    }

    'find' {
        $app = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        if (-not $app) { Write-Error 'Usage: spx source find <app>'; return }
        $results = @(Find-AppBucket $app)
        if ($results.Count -eq 0) { Write-Host "'$app' not found in any added bucket."; return }
        Write-Host "Buckets containing '$app':"
        $results | Format-Table Bucket, Version, URL -AutoSize
    }

    default { & "$PSScriptRoot/../spx.ps1" source -h }
}