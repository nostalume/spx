# lib/Context.ps1 - dynamic Scoop path resolution (PowerShell 5.1+)

function Get-SpxContext {
    [CmdletBinding()]
    param ()

    $userRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'scoop' }
    $globalRoot = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { 'C:\ProgramData\scoop' }
    [pscustomobject]@{
        UserRoot      = [IO.Path]::GetFullPath($userRoot)
        GlobalRoot    = [IO.Path]::GetFullPath($globalRoot)
        LocalApps     = Join-Path $userRoot 'apps'
        GlobalApps    = Join-Path $globalRoot 'apps'
        LocalPersist  = Join-Path $userRoot 'persist'
        GlobalPersist = Join-Path $globalRoot 'persist'
        Buckets       = Join-Path $userRoot 'buckets'
        ConfigRoot    = Join-Path $userRoot 'spx'
        Operations    = Join-Path $userRoot 'spx\operations'
    }
}

function Get-SpxConfigFile {
    param ([string]$Name = 'spx.json', [switch]$CreateIfMissing)
    $root = (Get-SpxContext).ConfigRoot
    if ($CreateIfMissing -and -not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Path $root -Force
    }
    Join-Path $root $Name
}
