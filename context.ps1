# context.ps1 - Scoop path resolution
# Single source of truth. Dot-source this file; never pass paths as parameters.

$Script:ScoopHome   = if ($env:SCOOP)        { $env:SCOOP }        else { Join-Path $HOME 'scoop' }
$Script:ScoopGlobal = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { 'C:\ProgramData\scoop' }

$Script:ScoopPaths = [ordered]@{
    apps    = Join-Path $Script:ScoopHome   'apps'
    global  = Join-Path $Script:ScoopGlobal 'apps'
    buckets = Join-Path $Script:ScoopHome   'buckets'
    persist = Join-Path $Script:ScoopHome   'persist'
    shims   = Join-Path $Script:ScoopHome   'shims'
    cache   = Join-Path $Script:ScoopHome   'cache'
    spx     = Join-Path $Script:ScoopHome   'spx'
}

function Get-SpxConfigFile {
    param ([string]$Name = 'spx.json', [switch]$CreateIfMissing)
    if ($CreateIfMissing) { $null = New-Item $Script:ScoopPaths.spx -ItemType Directory -Force -ErrorAction SilentlyContinue }
    Join-Path $Script:ScoopPaths.spx $Name
}