# lib/Config.ps1 - SPX configuration I/O
# Thin read/write layer. No business logic. PS5.1+ compatible.

. "$PSScriptRoot/../context.ps1"
. "$PSScriptRoot/Core.ps1"

#region Generic spx.json

function Get-SpxConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([string]$Name = 'spx.json', [string]$Key)

    $file = Get-SpxConfigFile -Name $Name -CreateIfMissing
    if (-not (Test-Path $file) -or (Get-Item $file).Length -eq 0) { return $null }

    $raw  = Get-Content $file -Raw -ErrorAction SilentlyContinue
    $data = if ($raw) { $raw | ConvertFrom-JsonAsHashtable } else { @{} }

    if ($Key) { return $data[$Key] }
    $data
}

function Set-SpxConfig {
    [CmdletBinding()]
    param ([string]$Name = 'spx.json', [Parameter(Mandatory)] [string]$Key, $Value)

    $file   = Get-SpxConfigFile -Name $Name -CreateIfMissing
    $raw    = if (Test-Path $file) { Get-Content $file -Raw -ErrorAction SilentlyContinue } else { $null }
    $data   = if ($raw) { $raw | ConvertFrom-JsonAsHashtable } else { @{} }
    $data[$Key] = $Value
    $data | ConvertTo-Json -Depth 20 | Set-Content $file -Encoding UTF8
}

#endregion

#region links.json

function Get-LinksConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $file = Get-SpxConfigFile -Name 'links.json' -CreateIfMissing
    if (-not (Test-Path $file) -or (Get-Item $file).Length -eq 0) {
        return @{ local = @{}; global = @{} }
    }

    $raw  = Get-Content $file -Raw -ErrorAction SilentlyContinue
    $data = if ($raw) { $raw | ConvertFrom-JsonAsHashtable } else { @{} }

    foreach ($scope in 'local', 'global') {
        if (-not $data.ContainsKey($scope) -or $data[$scope] -isnot [hashtable]) {
            $data[$scope] = @{}
        }
    }
    $data
}

function Set-LinksConfig {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [hashtable]$Config)
    $file = Get-SpxConfigFile -Name 'links.json' -CreateIfMissing
    $Config | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding UTF8
}

function Get-LinkEntry {
    [OutputType([hashtable])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $scope = if ($Global) { 'global' } else { 'local' }
    $cfg   = Get-LinksConfig
    if ($cfg[$scope].ContainsKey($AppName)) { return $cfg[$scope][$AppName] }
    return $null
}

function Set-LinkEntry {
    param (
        [Parameter(Mandatory)] [string]$AppName,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Version,
        [switch]$Global
    )
    $scope           = if ($Global) { 'global' } else { 'local' }
    $cfg             = Get-LinksConfig
    $cfg[$scope][$AppName] = @{
        Path    = $Path
        Version = $Version
        Updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Set-LinksConfig $cfg
}

function Remove-LinkEntry {
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $scope = if ($Global) { 'global' } else { 'local' }
    $cfg   = Get-LinksConfig
    if ($cfg[$scope].ContainsKey($AppName)) {
        $cfg[$scope].Remove($AppName)
        Set-LinksConfig $cfg
    }
}

function Export-LinksConfig {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)
    Get-LinksConfig | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding UTF8
    Write-Verbose "Link config exported to $Path"
}

function Import-LinksConfig {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path, [switch]$Merge)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    $imported = Get-Content $Path -Raw | ConvertFrom-JsonAsHashtable
    if ($Merge) {
        $current = Get-LinksConfig
        foreach ($scope in 'local', 'global') {
            if ($null -ne $imported[$scope]) {
                foreach ($key in $imported[$scope].Keys) {
                    $current[$scope][$key] = $imported[$scope][$key]
                }
            }
        }
        Set-LinksConfig $current
    } else {
        Set-LinksConfig $imported
    }
    Write-Verbose "Link config imported from $Path"
}

#endregion