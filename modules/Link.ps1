# modules/Link.ps1 - App relocation via symbolic links
# Returns PSCustomObjects. PS5.1+ compatible.

. "$PSScriptRoot/../context.ps1"
. "$PSScriptRoot/../lib/Core.ps1"
. "$PSScriptRoot/../lib/Config.ps1"

#region Public API

function New-AppLink {
	<#
    .SYNOPSIS
        Moves an installed app to a custom path and leaves a symlink in its place.
    .PARAMETER AppName   Scoop app name.
    .PARAMETER Path      Absolute target directory. Must not contain 'scoop'.
    .PARAMETER Global    Operate on the global Scoop installation.
    #>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param (
		[Parameter(Mandatory, Position = 0)] [string]$AppName,
		[Parameter(Mandatory)]               [string]$Path,
		[switch]$Global
	)

	if ($Global -and -not (Test-IsAdmin)) { throw 'Administrator privileges are required for global apps.' }
	if (-not (Test-AppInstalled $AppName -Global:$Global)) { throw "App '$AppName' is not installed." }

	$targetPath = Resolve-LinkTargetPath $Path
	$versions = Get-AppVersions $AppName -Global:$Global
	if ($versions.Count -eq 0) { throw "App '$AppName' has no installed versions." }

	$targetAppDir = Join-Path $targetPath $AppName
	$null = New-Item $targetAppDir -ItemType Directory -Force

	foreach ($ver in $versions) {
		$realSource = Resolve-VersionSymlink $ver
		$targetVerDir = Join-Path $targetAppDir $ver.Name

		if ($realSource -eq $targetVerDir) { Write-Verbose "'$AppName/$($ver.Name)' already at target."; continue }
		if (-not $PSCmdlet.ShouldProcess("$AppName/$($ver.Name)", "Move to $targetVerDir")) { continue }

		Invoke-RobocopyMove -Source $realSource -Destination $targetVerDir -WhatIf:$false -Confirm:$false
		New-Symlink -Path $ver.FullName -Target $targetVerDir -WhatIf:$false -Confirm:$false
	}

	$current = Get-AppCurrentVersion $AppName -Global:$Global
	Update-PersistLinks -AppName $AppName -Global:$Global

	$verName = if ($current) { $current.Name } else { 'unknown' }
	Set-LinkEntry -AppName $AppName -Path $targetPath -Version $verName -Global:$Global

	[PSCustomObject]@{
		AppName    = $AppName
		TargetPath = $targetPath
		Version    = $verName
		Global     = $Global.IsPresent
	}
}

function Remove-AppLink {
	<#
    .SYNOPSIS
        Moves an app back to the Scoop directory and removes the symlink.
    #>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	param (
		[Parameter(Mandatory, Position = 0)] [string]$AppName,
		[switch]$Global
	)

	if ($Global -and -not (Test-IsAdmin)) { throw 'Administrator privileges required for global apps.' }
	if (-not (Test-AppInstalled $AppName -Global:$Global)) { throw "App '$AppName' is not installed." }

	$versions = Get-AppVersions $AppName -Global:$Global
	if ($versions.Count -eq 0) { throw "App '$AppName' has no installed versions." }

	foreach ($ver in $versions) {
		$realSource = Resolve-VersionSymlink $ver
		if ($realSource -eq $ver.FullName) { Write-Verbose "'$AppName/$($ver.Name)' already in Scoop dir."; continue }
		if (-not $PSCmdlet.ShouldProcess("$AppName/$($ver.Name)", 'Restore to Scoop directory')) { continue }

		if ($ver.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item $ver.FullName -Force }
		Invoke-RobocopyMove -Source $realSource -Destination $ver.FullName -WhatIf:$false -Confirm:$false
	}

	$entry = Get-LinkEntry $AppName -Global:$Global
	if ($null -ne $entry -and $entry.Path) {
		$orphan = Join-Path $entry.Path $AppName
		if ((Test-Path $orphan) -and $PSCmdlet.ShouldProcess($orphan, 'Remove orphaned directory')) {
			Remove-Item $orphan -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	Remove-LinkEntry -AppName $AppName -Global:$Global
	[PSCustomObject]@{ AppName = $AppName; Restored = $true }
}

function Get-AppLinkStatus {
	<#
    .SYNOPSIS
        Returns link status objects: Linked | Stale | (nothing for unlisted apps).
    #>
	[CmdletBinding()]
	param ([string]$AppName, [switch]$Global)

	$scope = if ($Global) { 'global' } else { 'local' }
	$cfg = Get-LinksConfig
	$entries = if ($AppName) {
		if ($cfg[$scope].ContainsKey($AppName)) { @{ $AppName = $cfg[$scope][$AppName] } } else { @{} }
	}
 else {
		$cfg[$scope]
	}

	foreach ($name in $entries.Keys) {
		$info = $entries[$name]
		$appPath = Get-AppBasePath $name -Global:$Global
		$status = if (Test-Path $appPath) { 'Linked' } else { 'Stale' }
		[PSCustomObject]@{
			AppName    = $name
			Status     = $status
			TargetPath = $info.Path
			Version    = $info.Version
			Updated    = $info.Updated
			Global     = $Global.IsPresent
			Scope      = $scope
		}
	}
}

function Sync-AppLinks {
	<#
    .SYNOPSIS
        Reconciles link config with actual installed state.
        - Removes stale entries for uninstalled apps.
        - Moves a newly-upgraded version to the custom path.
    #>
	[CmdletBinding(SupportsShouldProcess)]
	param ([string]$AppName, [switch]$Global)

	$scope = if ($Global) { 'global' } else { 'local' }
	$cfg = Get-LinksConfig
	$targets = if ($AppName) { @($AppName) } else { @($cfg[$scope].Keys) }

	foreach ($name in $targets) {
		if (-not $cfg[$scope].ContainsKey($name)) {
			Write-Warning "'$name' is not in the link config."
			continue
		}

		if (-not (Test-AppInstalled $name -Global:$Global)) {
			if ($PSCmdlet.ShouldProcess($name, 'Remove stale link entry')) {
				Remove-LinkEntry -AppName $name -Global:$Global
				Write-Verbose "Removed stale entry: $name"
			}
			continue
		}

		$entry = $cfg[$scope][$name]
		$current = Get-AppCurrentVersion $name -Global:$Global

		if ($null -ne $current -and $entry.Version -ne $current.Name) {
			$targetAppDir = Join-Path $entry.Path $name
			$targetVerDir = Join-Path $targetAppDir $current.Name
			$null = New-Item $targetVerDir -ItemType Directory -Force -ErrorAction SilentlyContinue

			if ($current.FullName -ne $targetVerDir) {
				if ($PSCmdlet.ShouldProcess("$name/$($current.Name)", "Sync new version to $targetVerDir")) {
					Invoke-RobocopyMove -Source $current.FullName -Destination $targetVerDir -WhatIf:$false -Confirm:$false
					New-Symlink -Path $current.FullName -Target $targetVerDir -WhatIf:$false -Confirm:$false
					Set-LinkEntry -AppName $name -Path $entry.Path -Version $current.Name -Global:$Global
					Write-Verbose "Synced [$name]: $($entry.Version) -> $($current.Name)"
				}
			}
		}

		Update-PersistLinks -AppName $name -Global:$Global
	}
}

function Get-StaleLinkEntries {
	<#
    .SYNOPSIS
        Returns link entries whose app directory no longer exists.
    #>
	[CmdletBinding()]
	[OutputType([PSCustomObject[]])]
	param ()

	$cfg = Get-LinksConfig
	$stale = foreach ($scope in 'local', 'global') {
		$isGlobal = ($scope -eq 'global')
		foreach ($name in $cfg[$scope].Keys) {
			if (-not (Test-Path (Get-AppBasePath $name -Global:$isGlobal))) {
				$info = $cfg[$scope][$name]
				[PSCustomObject]@{
					AppName  = $name
					Scope    = $scope
					Global   = $isGlobal
					LinkPath = $info.Path
					Version  = $info.Version
					Updated  = $info.Updated
				}
			}
		}
	}
	@($stale)
}

function Remove-StaleLinkEntry {
	[CmdletBinding(SupportsShouldProcess)]
	param ([Parameter(Mandatory)] [string]$AppName, [switch]$Global)
	if ($PSCmdlet.ShouldProcess($AppName, 'Remove stale link entry')) {
		Remove-LinkEntry -AppName $AppName -Global:$Global
	}
}

#endregion

#region Private helpers

function Resolve-LinkTargetPath {
	param ([Parameter(Mandatory)] [string]$Path)
	if ($Path -match 'scoop') { throw "Target path must not contain 'scoop': $Path" }
	if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "Target path must be absolute: $Path" }
	$full = [System.IO.Path]::GetFullPath($Path)
	$null = New-Item $full -ItemType Directory -Force -ErrorAction SilentlyContinue
	$full
}

#endregion