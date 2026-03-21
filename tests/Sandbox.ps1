# tests/Sandbox.ps1 - Isolated test environment helper
# Import only in test files. Not part of the production load path.

$script:OriginalSCOOP        = $null
$script:OriginalSCOOP_GLOBAL = $null

function Enter-Sandbox {
    param ([string]$Root = (Join-Path $TestDrive 'spx_sandbox'))
    $script:OriginalSCOOP        = $env:SCOOP
    $script:OriginalSCOOP_GLOBAL = $env:SCOOP_GLOBAL

    $env:SCOOP        = Join-Path $Root 'scoop'
    $env:SCOOP_GLOBAL = Join-Path $Root 'scoop_global'

    # Re-run context.ps1 so ScoopPaths reflects sandbox paths
    . "$PSScriptRoot/../context.ps1"

    $dirs = @(
        $env:SCOOP
        $env:SCOOP_GLOBAL
        (Join-Path $env:SCOOP 'apps')
        (Join-Path $env:SCOOP_GLOBAL 'apps')
        (Join-Path $env:SCOOP 'buckets')
        (Join-Path $env:SCOOP 'persist')
        (Join-Path $env:SCOOP 'shims')
        (Join-Path $env:SCOOP 'spx')
    )
    $dirs | ForEach-Object { $null = New-Item $_ -ItemType Directory -Force }

    [PSCustomObject]@{ Root = $Root; ScoopHome = $env:SCOOP; GlobalHome = $env:SCOOP_GLOBAL }
}

function Exit-Sandbox {
    $env:SCOOP        = $script:OriginalSCOOP
    $env:SCOOP_GLOBAL = $script:OriginalSCOOP_GLOBAL
    . "$PSScriptRoot/../context.ps1"
}

# Creates a minimal Scoop app directory structure with an install.json
function New-SandboxApp {
    param (
        [Parameter(Mandatory)] [string]$AppName,
        [string]$Version   = '1.0.0',
        [string]$Bucket    = 'main',
        [hashtable]$Persist = $null,
        [switch]$Global
    )
    $base    = if ($Global) { Join-Path $env:SCOOP_GLOBAL 'apps' } else { Join-Path $env:SCOOP 'apps' }
    $appDir  = Join-Path $base $AppName
    $verDir  = Join-Path $appDir $Version
    $currDir = Join-Path $appDir 'current'

    $null = New-Item $verDir -ItemType Directory -Force
    'dummy' | Set-Content (Join-Path $verDir 'app.exe') -Encoding UTF8

    $installData = @{ bucket = $Bucket; version = $Version }
    if ($Persist) { $installData['manifest'] = @{ persist = $Persist } }
    $installData | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $verDir 'install.json') -Encoding UTF8

    # Prefer symlink; fall back to directory copy for restricted environments
    try {
        $null = New-Item -ItemType SymbolicLink -Path $currDir -Target $verDir -Force -ErrorAction Stop
    } catch {
        $null = New-Item $currDir -ItemType Directory -Force
        Copy-Item (Join-Path $verDir '*') $currDir -Recurse -Force
    }

    [PSCustomObject]@{
        AppName    = $AppName
        AppDir     = $appDir
        VersionDir = $verDir
        CurrentDir = $currDir
        Version    = $Version
        Bucket     = $Bucket
    }
}

# Creates a fake bucket directory with a .git stub (no real git required)
function New-SandboxBucketDir {
    param ([Parameter(Mandatory)] [string]$Name)
    $path = Join-Path $env:SCOOP "buckets\$Name"
    # Fake .git so module's Test-Path checks pass without a real repo
    $null = New-Item (Join-Path $path '.git') -ItemType Directory -Force
    $path
}

# Creates a bucket directory and writes a manifest file for an app
function New-SandboxBucketManifest {
    param (
        [Parameter(Mandatory)] [string]$BucketName,
        [Parameter(Mandatory)] [string]$AppName,
        [string]$Version = '1.0.0',
        [hashtable]$Extra = @{}
    )
    $manifestDir = Join-Path $env:SCOOP "buckets\$BucketName\bucket"
    $null = New-Item $manifestDir -ItemType Directory -Force

    $data = @{ version = $Version; description = "Test $AppName" }
    foreach ($k in $Extra.Keys) { $data[$k] = $Extra[$k] }
    $data | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $manifestDir "$AppName.json") -Encoding UTF8

    $manifestDir
}

# Writes a link entry directly into links.json (bypasses module logic — for setup only)
function Write-SandboxLinkEntry {
    param (
        [Parameter(Mandatory)] [string]$AppName,
        [string]$Path    = 'D:\FakeApps',
        [string]$Version = '1.0.0',
        [switch]$Global
    )
    $linksFile = Join-Path $env:SCOOP 'spx\links.json'
    $data = if (Test-Path $linksFile) {
        Get-Content $linksFile -Raw | ConvertFrom-Json
        # Use raw PS object; we'll rebuild below
    } else { $null }

    $scope  = if ($Global) { 'global' } else { 'local' }
    $config = @{ local = @{}; global = @{} }

    if ($data) {
        foreach ($s in 'local', 'global') {
            if ($data.$s) {
                $data.$s.PSObject.Properties | ForEach-Object { $config[$s][$_.Name] = @{ Path = $_.Value.Path; Version = $_.Value.Version; Updated = $_.Value.Updated } }
            }
        }
    }
    $config[$scope][$AppName] = @{ Path = $Path; Version = $Version; Updated = '2025-01-01 00:00:00' }
    $config | ConvertTo-Json -Depth 10 | Set-Content $linksFile -Encoding UTF8
}