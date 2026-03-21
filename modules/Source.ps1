# modules/Source.ps1 - App bucket source management
# Stateless: reads/writes Scoop's own install.json. PS5.1+ compatible.

. "$PSScriptRoot/../context.ps1"
. "$PSScriptRoot/../lib/Core.ps1"

#region Public API

function Get-AppSource {
    <#
    .SYNOPSIS
        Returns source (bucket) info for an installed app.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$AppName)

    $isLocal  = Test-AppInstalled $AppName
    $isGlobal = Test-AppInstalled $AppName -Global

    if (-not $isLocal -and -not $isGlobal) {
        Write-Warning "App '$AppName' is not installed."
        return $null
    }

    $global     = $isGlobal -and -not $isLocal
    $currentDir = Join-Path (Get-AppBasePath $AppName -Global:$global) 'current'

    if (-not (Test-Path $currentDir)) {
        Write-Warning "App '$AppName' has no 'current' directory."
        return $null
    }

    $installFile = Join-Path $currentDir 'install.json'
    if (-not (Test-Path $installFile)) {
        Write-Warning "App '$AppName' has no install.json."
        return $null
    }

    try {
        $info = Get-Content $installFile -Raw | ConvertFrom-JsonAsHashtable
        [PSCustomObject]@{
            AppName     = $AppName
            Bucket      = $info['bucket']
            Version     = $info['version']
            URL         = $info['url']
            Global      = $global
            InstallPath = $currentDir
            Manifest    = $info['manifest']
        }
    } catch {
        Write-Warning "Failed to read install info for '$AppName': $_"
        return $null
    }
}

function Get-AppSourceList {
    [CmdletBinding()]
    param ()

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pairs   = @(
        @{ Path = $Script:ScoopPaths.apps;   Global = $false }
        @{ Path = $Script:ScoopPaths.global; Global = $true  }
    )

    foreach ($pair in $pairs) {
        if (-not (Test-Path $pair.Path)) { continue }
        foreach ($dir in Get-ChildItem $pair.Path -Directory | Where-Object { $_.Name -ne 'scoop' }) {
            $src = Get-AppSource -AppName $dir.Name
            if ($null -ne $src -and ($src.Global -eq $pair.Global)) { $results.Add($src) }
        }
    }
    $results
}

function Move-AppSource {
    <#
    .SYNOPSIS
        Changes an app's registered bucket by rewriting install.json.
    .PARAMETER Force  Proceed even when installed version differs from bucket manifest.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$Bucket,
        [switch]$Force
    )

    $current = Get-AppSource $AppName
    if (-not $current) { throw "App '$AppName' is not installed." }
    if ($current.Bucket -eq $Bucket) { Write-Warning "'$AppName' is already in bucket '$Bucket'."; return }

    $bucketPath = Join-Path $Script:ScoopPaths.buckets $Bucket
    if (-not (Test-Path $bucketPath)) { throw "Bucket '$Bucket' is not added. Run: scoop bucket add $Bucket" }

    $targetManifest = Get-BucketManifest $AppName $Bucket
    if (-not $targetManifest) { throw "Package '$AppName' not found in bucket '$Bucket'." }

    $installedVer = $current.Version
    $bucketVer    = $targetManifest['version']

    if ($installedVer -ne $bucketVer -and -not $Force) {
        Write-Warning "Version mismatch: installed '$installedVer', bucket '$bucketVer'. Use -Force to proceed."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($AppName, "Change bucket: '$($current.Bucket)' -> '$Bucket'")) { return }

    $installFile = Join-Path $current.InstallPath 'install.json'
    $info        = Get-Content $installFile -Raw | ConvertFrom-JsonAsHashtable
    $info['bucket']   = $Bucket
    $info['manifest'] = $targetManifest
    $info | ConvertTo-Json -Depth 20 | Set-Content $installFile -Encoding UTF8

    [PSCustomObject]@{
        AppName   = $AppName
        OldBucket = $current.Bucket
        NewBucket = $Bucket
        Version   = $installedVer
    }
}

function Test-AppSourceValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [string]$AppName)

    $src = Get-AppSource $AppName
    if (-not $src -or -not $src.Bucket) { return $false }

    $bucketPath = Join-Path $Script:ScoopPaths.buckets $src.Bucket
    if (-not (Test-Path $bucketPath)) { Write-Warning "Bucket '$($src.Bucket)' not installed."; return $false }

    $manifest = Get-BucketManifest $AppName $src.Bucket
    if (-not $manifest) { Write-Warning "'$AppName' not found in bucket '$($src.Bucket)'."; return $false }

    if ($src.Version -ne $manifest['version']) {
        Write-Warning "Version mismatch: installed '$($src.Version)', bucket '$($manifest['version'])'."
        return $false
    }
    $true
}

function Compare-AppManifest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$Bucket
    )

    $src = Get-AppSource $AppName
    if (-not $src) { return $null }

    $bucketManifest = Get-BucketManifest $AppName $Bucket
    if (-not $bucketManifest) { Write-Warning "'$AppName' not found in '$Bucket'."; return $null }

    $diffs = foreach ($key in 'description', 'homepage', 'license', 'url', 'bin', 'shortcuts') {
        $a = if ($null -ne $src.Manifest) { $src.Manifest[$key] } else { $null }
        $b = $bucketManifest[$key]
        if ($a -ne $b) { [PSCustomObject]@{ Field = $key; Installed = $a; Bucket = $b } }
    }

    [PSCustomObject]@{
        AppName          = $AppName
        CurrentBucket    = $src.Bucket
        CompareBucket    = $Bucket
        InstalledVersion = $src.Version
        BucketVersion    = $bucketManifest['version']
        VersionMatch     = ($src.Version -eq $bucketManifest['version'])
        Differences      = @($diffs)
    }
}

function Find-AppBucket {
    <#
    .SYNOPSIS
        Searches all added buckets for a package.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$AppName)

    $bucketsPath = $Script:ScoopPaths.buckets
    if (-not (Test-Path $bucketsPath)) { return }

    foreach ($bucket in Get-ChildItem $bucketsPath -Directory) {
        $manifest = Get-BucketManifest $AppName $bucket.Name
        if ($null -ne $manifest) {
            [PSCustomObject]@{
                Bucket  = $bucket.Name
                Version = $manifest['version']
                URL     = $manifest['url']
            }
        }
    }
}

function Get-BucketList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()
    $p = $Script:ScoopPaths.buckets
    if (-not (Test-Path $p)) { return @() }
    @(Get-ChildItem $p -Directory | Select-Object -ExpandProperty Name)
}

#endregion

#region Private helpers

function Get-BucketManifest {
    [OutputType([hashtable])]
    param ([Parameter(Mandatory)] [string]$AppName, [Parameter(Mandatory)] [string]$Bucket)

    $bucketDir = Join-Path $Script:ScoopPaths.buckets $Bucket
    if (-not (Test-Path $bucketDir)) { return $null }

    $candidates = @(
        (Join-Path $bucketDir "bucket\$AppName.json")
        (Join-Path $bucketDir "$AppName.json")
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try { return Get-Content $c -Raw | ConvertFrom-JsonAsHashtable } catch { Write-Debug "Bad manifest at $c" }
        }
    }
    $null
}

#endregion