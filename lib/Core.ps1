# lib/Core.ps1 - Shared utilities
# Pure functions only. No Write-Host. Outputs objects, not strings.

. "$PSScriptRoot/../context.ps1"

#region JSON

function ConvertFrom-JsonAsHashtable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory, ValueFromPipeline)] [string]$Json)
    process {
        if (-not $Json) { return @{} }
        try {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                return $Json | ConvertFrom-Json -AsHashtable -Depth 20
            }
            $obj = $Json | ConvertFrom-Json
            $ht  = [ordered]@{}
            $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        } catch {
            Write-Warning "JSON parse failed: $_"
            return @{}
        }
    }
}

#endregion

#region Admin / privilege

function Test-IsAdmin {
    [OutputType([bool])]
    param ()
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

#endregion

#region App filesystem helpers

function Get-AppBasePath {
    [OutputType([string])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $base = if ($Global) { $Script:ScoopPaths.global } else { $Script:ScoopPaths.apps }
    Join-Path $base $AppName
}

function Test-AppInstalled {
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    Test-Path (Get-AppBasePath $AppName -Global:$Global)
}

function Get-AppVersions {
    [OutputType([System.IO.DirectoryInfo[]])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $base = Get-AppBasePath $AppName -Global:$Global
    if (-not (Test-Path $base)) { return @() }
    @(Get-ChildItem $base -Directory | Where-Object Name -ne 'current')
}

function Get-AppCurrentVersion {
    [OutputType([System.IO.DirectoryInfo])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $link = Join-Path (Get-AppBasePath $AppName -Global:$Global) 'current'
    if (Test-Path $link -PathType Container) {
        $item   = Get-Item $link -Force
        $target = if ($item.LinkType) { $item.Target } else { $item.FullName }
        if ($target -and (Test-Path $target)) { return Get-Item $target }
    }
    # Fallback: newest version directory
    Get-AppVersions $AppName -Global:$Global | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-AppInstallManifest {
    [OutputType([hashtable])]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
    $ver = Get-AppCurrentVersion $AppName -Global:$Global
    if (-not $ver) { return $null }
    $file = Join-Path $ver.FullName 'install.json'
    if (-not (Test-Path $file)) { return $null }
    Get-Content $file -Raw | ConvertFrom-JsonAsHashtable
}

function Get-AppPersistPath {
    [OutputType([string])]
    param ([Parameter(Mandatory)] [string]$AppName)
    Join-Path $Script:ScoopPaths.persist $AppName
}

function Resolve-VersionSymlink {
    # Returns the real path a version directory points to (or itself if not a link)
    [OutputType([string])]
    param ([Parameter(Mandatory)] [System.IO.DirectoryInfo]$Dir)
    if ($Dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { $Dir.Target } else { $Dir.FullName }
}

#endregion

#region File operations

function Invoke-RobocopyMove {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    if (-not $PSCmdlet.ShouldProcess("$Source → $Destination", 'Move')) { return }
    Write-Verbose "Moving: $Source → $Destination"
    $null = robocopy $Source $Destination /MIR /MOVE /NFL /NDL /NJH /NJS /NP /NS /NC
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed (exit code $LASTEXITCODE): $Source → $Destination"
    }
}

function New-Symlink {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Target
    )
    if (-not $PSCmdlet.ShouldProcess($Path, "Create symlink → $Target")) { return }
    # Remove stale link if present
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force
}

#endregion

#region Persist link management

function Update-PersistLinks {
    [CmdletBinding(SupportsShouldProcess)]
    param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)

    $ver = Get-AppCurrentVersion $AppName -Global:$Global
    if (-not $ver) { Write-Verbose "No current version for '$AppName'"; return }

    $manifest = Get-AppInstallManifest $AppName -Global:$Global
    # Scoop stores the full manifest inside install.json under the 'manifest' key
    $persist = $manifest?['manifest']?['persist'] ?? $manifest?['persist']
    if (-not $persist) { Write-Verbose "No persist for '$AppName'"; return }

    $persistDir = Get-AppPersistPath $AppName
    $null = New-Item $persistDir -ItemType Directory -Force -ErrorAction SilentlyContinue

    foreach ($entry in @($persist)) {
        $srcRel, $tgtRel = switch ($true) {
            ($entry -is [string])              { $entry, $entry; break }
            ($entry.Count -ge 2)               { $entry[0], ($entry[1] ?? $entry[0]); break }
            default                            { "$entry", "$entry" }
        }

        $srcFull = Join-Path $ver.FullName $srcRel.TrimEnd('/\')
        $tgtFull = Join-Path $persistDir   $tgtRel.TrimEnd('/\')

        $null = New-Item (Split-Path $tgtFull -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $srcFull) {
            $item = Get-Item -LiteralPath $srcFull -Force
            if ($item.LinkType -and $item.Target -eq $tgtFull) { continue }  # already correct
            Remove-Item -LiteralPath $srcFull -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Symlink -Path $srcFull -Target $tgtFull
    }
}

#endregion