# exec/mirror.ps1
param (
    [Parameter(Position = 0)] [string]$Action,
    [Parameter(ValueFromRemainingArguments)] [string[]]$Rest
)

. "$PSScriptRoot/../lib/Parse.ps1"
. "$PSScriptRoot/../modules/Mirror.ps1"

$p   = Get-ParsedArgs $Rest
$pos = $p.Positional

$actionKey = if ($Action) { $Action.ToLower() } else { '' }

switch ($actionKey) {
    'list' {
        $mirrors = @(Get-BucketMirror)
        if ($mirrors.Count -eq 0) { Write-Host 'No buckets found.'; return }
        $mirrors | Format-Table @(
            @{ Label = 'Bucket';    Expression = { $_.Bucket };                                   Width = 16 }
            @{ Label = 'Mirrored'; Expression = { if ($_.IsMirrored) { 'yes' } else { 'no' } }; Width = 9  }
            @{ Label = 'Active URL'; Expression = { $_.CurrentURL } }
        ) -AutoSize
    }

    'show' {
        $bucket = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        if (-not $bucket) { Write-Error 'Usage: spx mirror show <bucket>'; return }
        $info = Get-BucketMirror -BucketName $bucket
        if ($info) { $info | Format-List }
    }

    'add' {
        $bucket = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        $url    = if ($pos.Count -gt 1) { $pos[1] } else { $null }
        if (-not $bucket -or -not $url) { Write-Error 'Usage: spx mirror add <bucket> <url>'; return }
        $r = Set-BucketMirror -BucketName $bucket -Url $url -Add
        Write-Host "[mirror] '$($r.Bucket)' now -> $($r.MirrorURL)  (original: $($r.OriginalURL))"
    }

    'set' {
        $bucket = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        $url    = if ($pos.Count -gt 1) { $pos[1] } else { $null }
        if (-not $bucket -or -not $url) { Write-Error 'Usage: spx mirror set <bucket> <url>'; return }
        $r = Set-BucketMirror -BucketName $bucket -Url $url
        Write-Host "[mirror] '$($r.Bucket)' now -> $($r.MirrorURL)  (original: $($r.OriginalURL))"
    }

    'remove' {
        $bucket = if ($pos.Count -gt 0) { $pos[0] } else { $null }
        if (-not $bucket) { Write-Error 'Usage: spx mirror remove <bucket>'; return }
        $r = Remove-BucketMirror -BucketName $bucket
        Write-Host "[mirror] '$($r.Bucket)' restored to $($r.Restored)"
    }

    default { & "$PSScriptRoot/../spx.ps1" mirror -h }
}