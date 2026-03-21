# modules/Mirror.ps1 - Bucket git remote mirror management
# Saves original URLs so mirrors are always reversible. PS5.1+ compatible.

. "$PSScriptRoot/../context.ps1"
. "$PSScriptRoot/../lib/Core.ps1"
. "$PSScriptRoot/../lib/Config.ps1"

#region Git helpers

function Get-BucketRemoteUrl {
    [OutputType([string])]
    param ([Parameter(Mandatory)] [string]$BucketName)
    $path = Join-Path $Script:ScoopPaths.buckets $BucketName
    if (-not (Test-Path (Join-Path $path '.git'))) { return $null }
    Push-Location $path
    try { git remote get-url origin 2>$null } finally { Pop-Location }
}

function Set-BucketRemoteUrl {
    [CmdletBinding(SupportsShouldProcess)]
    param ([Parameter(Mandatory)] [string]$BucketName, [Parameter(Mandatory)] [string]$Url)
    $path = Join-Path $Script:ScoopPaths.buckets $BucketName
    if ($PSCmdlet.ShouldProcess($BucketName, "Set remote URL to $Url")) {
        Push-Location $path
        try { git remote set-url origin $Url } finally { Pop-Location }
    }
}

#endregion

#region Mirror config helpers

function Get-MirrorConfig {
    [OutputType([hashtable])]
    param ()
    $val = Get-SpxConfig -Key 'mirrors'
    if ($null -ne $val) { return $val }
    return $null
}

function Set-MirrorConfig {
    param ([hashtable]$Value)
    Set-SpxConfig -Key 'mirrors' -Value $Value
}

#endregion

#region Public API

function Get-BucketMirror {
    <#
    .SYNOPSIS
        Returns mirror info for every added bucket (or a specific one).
    #>
    [CmdletBinding()]
    param ([string]$BucketName)

    $mirrors     = Get-MirrorConfig   # may be $null
    $bucketsDir  = $Script:ScoopPaths.buckets
    if (-not (Test-Path $bucketsDir)) { return }

    if ($BucketName) {
        $p = Join-Path $bucketsDir $BucketName
        if (-not (Test-Path $p)) { Write-Warning "Bucket '$BucketName' not found."; return }
        $buckets = @(Get-Item $p)
    } else {
        $buckets = @(Get-ChildItem $bucketsDir -Directory)
    }

    foreach ($b in $buckets) {
        $current = Get-BucketRemoteUrl $b.Name

        $savedEntry  = $null
        $origURL     = $null
        $mirrorURL   = $null
        $isMirrored  = $false

        if ($null -ne $mirrors -and $mirrors.ContainsKey($b.Name)) {
            $savedEntry = $mirrors[$b.Name]
            $origURL    = $savedEntry['original']
            $mirrorURL  = $savedEntry['mirror']
            $isMirrored = $true
        }

        [PSCustomObject]@{
            Bucket      = $b.Name
            CurrentURL  = $current
            OriginalURL = $origURL
            MirrorURL   = $mirrorURL
            IsMirrored  = $isMirrored
            IsGitRepo   = ($null -ne $current)
        }
    }
}

function Set-BucketMirror {
    <#
    .SYNOPSIS
        Points a bucket's git remote at a mirror URL, preserving the original.
    .PARAMETER Add  Fail if a mirror already exists (use for 'add' semantics).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param (
        [Parameter(Mandatory)] [string]$BucketName,
        [Parameter(Mandatory)] [string]$Url,
        [switch]$Add
    )

    $bucketPath = Join-Path $Script:ScoopPaths.buckets $BucketName
    if (-not (Test-Path $bucketPath)) { throw "Bucket '$BucketName' not found." }
    if (-not (Test-Path (Join-Path $bucketPath '.git'))) { throw "Bucket '$BucketName' is not a git repository." }

    $mirrors  = Get-MirrorConfig
    if ($null -eq $mirrors) { $mirrors = @{} }
    $existing = if ($mirrors.ContainsKey($BucketName)) { $mirrors[$BucketName] } else { $null }

    if ($Add -and $null -ne $existing) {
        throw "Mirror for '$BucketName' already exists. Use 'set' to change it."
    }

    # Preserve original URL (only on first mirror application)
    $originalUrl = $null
    if ($null -ne $existing -and $null -ne $existing['original']) {
        $originalUrl = $existing['original']
    } else {
        $originalUrl = Get-BucketRemoteUrl $BucketName
    }

    Set-BucketRemoteUrl -BucketName $BucketName -Url $Url

    $mirrors[$BucketName] = @{ original = $originalUrl; mirror = $Url }
    Set-MirrorConfig $mirrors

    [PSCustomObject]@{ Bucket = $BucketName; OriginalURL = $originalUrl; MirrorURL = $Url }
}

function Remove-BucketMirror {
    <#
    .SYNOPSIS
        Restores the original git remote and clears the mirror config entry.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param ([Parameter(Mandatory)] [string]$BucketName)

    $mirrors = Get-MirrorConfig
    if ($null -eq $mirrors -or -not $mirrors.ContainsKey($BucketName)) {
        throw "No mirror configured for '$BucketName'."
    }

    $saved    = $mirrors[$BucketName]
    $original = $saved['original']

    if ($original) { Set-BucketRemoteUrl -BucketName $BucketName -Url $original }

    $mirrors.Remove($BucketName)
    Set-MirrorConfig $mirrors

    [PSCustomObject]@{ Bucket = $BucketName; Restored = $original }
}

#endregion