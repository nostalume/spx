# lib/ScoopState.ps1 - the single Scoop installation representation

. "$PSScriptRoot/Context.ps1"
. "$PSScriptRoot/Core.ps1"
. "$PSScriptRoot/Config.ps1"

function Resolve-SpxScopes {
    param ([ValidateSet('Local', 'Global', 'All')][string]$Scope = 'All')
    if ($Scope -eq 'All') { return @('Local', 'Global') }
    @($Scope)
}

function Get-SpxAppSnapshot {
    param (
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Local', 'Global')][string]$Scope,
        [AllowNull()]$LinksConfig,
        [AllowNull()]$Context,
        [switch]$CurrentOnly
    )
    Assert-SpxName $Name 'app name'
    $ctx = if ($null -ne $Context) { $Context } else { Get-SpxContext }
    $appsRoot = if ($Scope -eq 'Global') { $ctx.GlobalApps } else { $ctx.LocalApps }
    $persistRoot = if ($Scope -eq 'Global') { $ctx.GlobalPersist } else { $ctx.LocalPersist }
    $appPath = [IO.Path]::Combine($appsRoot, $Name)
    if (-not (Test-SpxPathWithin $appPath $appsRoot)) { throw "App path escapes Scoop root: $Name" }
    if (-not [IO.Directory]::Exists($appPath)) { return $null }

    $linkEntry = $null
    $cfg = if ($null -ne $LinksConfig) { $LinksConfig } else { Get-LinksConfig }
    $scopeKey = $Scope.ToLowerInvariant()
    if ($cfg[$scopeKey].Contains($Name)) { $linkEntry = $cfg[$scopeKey][$Name] }

    $currentPath = [IO.Path]::Combine($appPath, 'current')
    $currentTarget = Get-SpxLinkTarget $currentPath
    $currentName = $null
    if ($currentTarget) {
        if (-not (Test-SpxPathWithin $currentTarget $appPath)) { throw "Current junction escapes the canonical app directory for '$Name'." }
        $currentName = [IO.Path]::GetFileName($currentTarget.TrimEnd('\'))
    }

    $versions = @()
    if ($CurrentOnly -and $currentName) {
        $canonicalPath = [IO.Path]::Combine($appPath, $currentName)
        if (-not [IO.Path]::GetFullPath($currentTarget).Equals([IO.Path]::GetFullPath($canonicalPath), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Current junction is not a direct version child for '$Name'."
        }
        $attributes = [IO.File]::GetAttributes($canonicalPath)
        $target = if ($attributes -band [IO.FileAttributes]::ReparsePoint) { Get-SpxLinkTarget $canonicalPath } else { $null }
        $managed = $false
        if ($target -and $linkEntry -and $linkEntry.Path) {
            $expected = [IO.Path]::Combine($linkEntry.Path, $Name, $currentName)
            $managed = [IO.Path]::GetFullPath($target).Equals([IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)
        }
        if ($target -and -not $managed) { throw "Unmanaged version reparse point: $canonicalPath" }
        $versions = @([pscustomobject]@{ Name = $currentName; CanonicalPath = $canonicalPath; DataPath = $(if ($target) { $target } else { $canonicalPath }); IsRelocated = [bool]$target })
    }
    else {
        foreach ($dir in @(Get-ChildItem -LiteralPath $appPath -Directory -Force | Where-Object { $_.Name -ne 'current' -and $_.Name -notlike '.spx-*' })) {
            $target = Get-SpxLinkTarget $dir.FullName
            $managed = $false
            if ($target -and $linkEntry -and $linkEntry.Path) {
                $expected = Join-Path (Join-Path $linkEntry.Path $Name) $dir.Name
                $managed = [IO.Path]::GetFullPath($target).Equals([IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)
            }
            if ($target -and -not $managed) { throw "Unmanaged version reparse point: $($dir.FullName)" }
            $versions += [pscustomobject]@{ Name = $dir.Name; CanonicalPath = $dir.FullName; DataPath = $(if ($target) { $target } else { $dir.FullName }); IsRelocated = [bool]$target }
        }
    }
    if (-not $currentName -and (Test-Path -LiteralPath $currentPath) -and @($versions).Count -eq 1) { $currentName = $versions[0].Name }
    elseif (-not $currentName -and @($versions).Count -eq 1) { $currentName = $versions[0].Name }
    if (-not $currentName -or -not (@($versions.Name) -contains $currentName)) { throw "Cannot determine current version for '$Name' in $Scope scope." }
    $current = @($versions | Where-Object Name -EQ $currentName)[0]
    $installPath = [IO.Path]::Combine($current.DataPath, 'install.json')
    $manifestPath = [IO.Path]::Combine($current.DataPath, 'manifest.json')
    $install = Read-SpxJsonFile -Path $installPath -Default ([ordered]@{})
    $manifest = Read-SpxJsonFile -Path $manifestPath -Default ([ordered]@{})
    [pscustomobject]@{
        Name = $Name; Scope = $Scope; AppPath = $appPath; AppsRoot = $appsRoot
        PersistPath = [IO.Path]::Combine($persistRoot, $Name); Versions = @($versions); CurrentVersion = $currentName
        CurrentPath = $current.DataPath; InstallPath = $installPath; ManifestPath = $manifestPath
        Install = $install; Manifest = $manifest; LinkEntry = $linkEntry
    }
}

function Find-SpxAppSnapshots {
    param ([string[]]$Name, [ValidateSet('Local', 'Global', 'All')][string]$Scope = 'All', [switch]$CurrentOnly)
    $linksConfig = Get-LinksConfig
    $ctx = Get-SpxContext
    foreach ($currentScope in Resolve-SpxScopes $Scope) {
        $root = if ($currentScope -eq 'Global') { $ctx.GlobalApps } else { $ctx.LocalApps }
        $names = if ($Name) { @($Name) } elseif ([IO.Directory]::Exists($root)) {
            @(foreach ($path in [IO.Directory]::EnumerateDirectories($root)) { [IO.Path]::GetFileName($path.TrimEnd('\')) })
        }
        else { @() }
        foreach ($appName in $names) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $currentScope -LinksConfig $linksConfig -Context $ctx -CurrentOnly:$CurrentOnly
            if ($snapshot) { $snapshot }
        }
    }
}
