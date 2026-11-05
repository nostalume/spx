# Scoop roots and installed layout facts.

function Get-SpxContext {
    [CmdletBinding()]
    param ()

    $userRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'scoop' }
    $globalRoot = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { 'C:\ProgramData\scoop' }
    $userRoot = [IO.Path]::GetFullPath($userRoot)
    $globalRoot = [IO.Path]::GetFullPath($globalRoot)
    [pscustomobject]@{
        UserRoot      = $userRoot
        GlobalRoot    = $globalRoot
        LocalApps     = Join-Path $userRoot 'apps'
        GlobalApps    = Join-Path $globalRoot 'apps'
        LocalPersist  = Join-Path $userRoot 'persist'
        GlobalPersist = Join-Path $globalRoot 'persist'
        Buckets       = Join-Path $userRoot 'buckets'
        ConfigRoot    = Join-Path $userRoot 'spx'
        Operations    = Join-Path $userRoot 'spx\operations'
    }
}





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
    $state = Get-SpxLinkRecord $Name $Scope $cfg
    $linkEntry = $state.Active

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
        if ($target -and -not $managed) { Stop-SpxError 'Spx.LinkTargetMismatch' "Unmanaged version reparse point: $canonicalPath" $canonicalPath }
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
            if ($target -and -not $managed) { Stop-SpxError 'Spx.LinkTargetMismatch' "Unmanaged version reparse point: $($dir.FullName)" $dir.FullName }
            $versions += [pscustomobject]@{ Name = $dir.Name; CanonicalPath = $dir.FullName; DataPath = $(if ($target) { $target } else { $dir.FullName }); IsRelocated = [bool]$target }
        }
    }
    if (-not $currentName -and (Test-Path -LiteralPath $currentPath) -and @($versions).Count -eq 1) { $currentName = $versions[0].Name }
    elseif (-not $currentName -and @($versions).Count -eq 1) { $currentName = $versions[0].Name }
    if (-not $currentName -or -not (@($versions.Name) -contains $currentName)) { throw "Cannot determine current version for '$Name' in $Scope scope." }
    if (-not $CurrentOnly) {
        foreach ($version in $versions) {
            $version | Add-Member NoteProperty Manifest (Read-SpxJsonFile ([IO.Path]::Combine($version.DataPath, 'manifest.json')) ([ordered]@{}))
        }
    }
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
        $names = if ($Name) { @($Name) } else { @(Get-SpxInstalledNames $currentScope $ctx) }
        foreach ($appName in $names) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $currentScope -LinksConfig $linksConfig -Context $ctx -CurrentOnly:$CurrentOnly
            if ($snapshot) { $snapshot }
        }
    }
}

function Get-SpxBucketNames {
    $root = (Get-SpxContext).Buckets
    if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Directory | Select-Object -ExpandProperty Name }
}

function Get-SpxInstalledNames {
    param ([ValidateSet('Local', 'Global')][string]$Scope, $Context = (Get-SpxContext))
    $root = if ($Scope -eq 'Global') { $Context.GlobalApps } else { $Context.LocalApps }
    if ([IO.Directory]::Exists($root)) {
        foreach ($path in [IO.Directory]::EnumerateDirectories($root)) { [IO.Path]::GetFileName($path.TrimEnd('\')) }
    }
}

function Get-SpxBucketManifest {
    param ([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Bucket)
    Assert-SpxName $Bucket 'bucket name'
    $root = Join-Path (Get-SpxContext).Buckets $Bucket
    foreach ($path in @((Join-Path $root "bucket\$Name.json"), (Join-Path $root "$Name.json"))) {
        if (Test-Path -LiteralPath $path) { return Read-SpxJsonFile $path }
    }
    $null
}
