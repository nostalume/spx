# domain/Link.ps1 - recoverable Scoop app relocation

. "$PSScriptRoot/../lib/ScoopState.ps1"

function Get-SpxPersistDefinitions {
    param ($Manifest)
    if (-not $Manifest -or -not $Manifest.Contains('persist')) {
        return @()
    }
    $definitions = foreach ($entry in @($Manifest.persist)) {
        if ($entry -is [string]) {
            Assert-SpxRelativePath $entry 'persist source'; [pscustomobject]@{ Source = $entry; Target = $entry }
        }
        elseif ($entry -is [Collections.IList] -and $entry.Count -gt 0) {
            $source = [string]$entry[0]; $target = $(if ($entry.Count -gt 1) {
                    [string]$entry[1]
                }
                else {
                    $source
                })
            Assert-SpxRelativePath $source 'persist source'; Assert-SpxRelativePath $target 'persist target'
            [pscustomobject]@{ Source = $source; Target = $target }
        }
        else {
            throw [ArgumentException]::new('Unsupported Scoop persist entry.')
        }
    }
    @($definitions)
}

function Resolve-SpxDestination {
    param ([Parameter(Mandatory)][string]$Destination)
    if (-not [IO.Path]::IsPathRooted($Destination)) {
        throw [ArgumentException]::new("Destination must be absolute: $Destination")
    }
    $full = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $ctx = Get-SpxContext
    foreach ($reserved in @($ctx.LocalApps, $ctx.GlobalApps, $ctx.LocalPersist, $ctx.GlobalPersist, $ctx.ConfigRoot)) {
        if ((Test-SpxPathWithin $full $reserved) -or (Test-SpxPathWithin $reserved $full)) {
            throw [ArgumentException]::new("Destination overlaps SPX or Scoop managed storage: $full")
        }
    }
    $full
}

function Remove-SpxLinkOnly {
    param ([Parameter(Mandatory)][string]$Path)
    if (Get-SpxLinkTarget $Path) {
        Remove-SpxOwnedTree $Path
    }
}

function Assert-SpxRecoveryFingerprint {
    param([string]$Path, [string]$Fingerprint, [string[]]$Exclude, [string]$Message)
    if (-not(Test-Path -LiteralPath $Path)) {
        return
    }
    $observed = Get-SpxTreeFingerprint -Root $Path -ExcludeRelative $Exclude
    if (-not $Fingerprint -or $observed -ne $Fingerprint) {
        Stop-SpxError 'Spx.RecoveryConflict' "$Message Preserved '$Path'." $Path
    }
}

function Assert-SpxRecoveryLinkTarget {
    param([string]$Path, [string]$Expected, [string]$Message)
    $actual = Get-SpxLinkTarget $Path
    if (-not $actual -or -not $actual.Equals([IO.Path]::GetFullPath($Expected), [StringComparison]::OrdinalIgnoreCase)) {
        Stop-SpxError 'Spx.RecoveryConflict' "$Message Preserved '$Path'." $Path
    }
}

function New-SpxPersistReference {
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    if (Test-Path -LiteralPath $Target -PathType Container) {
        New-SpxDirectoryJunction -Path $Path -Target $Target
    }
    else {
        $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop
        if (-not (Get-SpxLinkTarget $Path)) {
            throw "Persist link verification failed for '$Path'."
        }
    }
}

function Invoke-SpxRelocateApp {
    param ([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Destination)
    $name = $Snapshot.Name; $scope = $Snapshot.Scope
    $key = $scope.ToLowerInvariant() + '-' + $name
    if (Read-SpxOperation -Kind link -Key $key) {
        Stop-SpxError 'Spx.PendingRecovery' "App '$name' has pending recovery; run Repair-SpxLinkedApp before another mutation." $name
    }
    $targetRoot = Resolve-SpxDestination $Destination
    $targetRootExisted = Test-Path -LiteralPath $targetRoot
    $targetApp = Join-Path $targetRoot $name
    $existingEntry = $Snapshot.LinkEntry
    $hasObservedOwnership = @($Snapshot.Versions | Where-Object IsRelocated).Count -gt 0
    $entryClaimsOwnership = $existingEntry -and [string]$existingEntry.State -eq 'Linked'
    if ($existingEntry -and -not ([IO.Path]::GetFullPath([string]$existingEntry.Path).Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase))) {
        Stop-SpxError 'Spx.AlreadyLinkedElsewhere' "App '$name' is already linked to '$($existingEntry.Path)'. Restore it before choosing another destination." $name
    }
    if (Test-Path -LiteralPath $targetApp) {
        if ((-not $entryClaimsOwnership -and -not $hasObservedOwnership) -or -not ([IO.Path]::GetFullPath([string]$existingEntry.Path).Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase))) {
            Stop-SpxError 'Spx.DestinationCollision' "Destination app directory already exists and is not owned by SPX: $targetApp" $targetApp
        }
    }

    $pendingVersions = @($Snapshot.Versions | Where-Object { -not $_.IsRelocated })
    if ($pendingVersions.Count -eq 0) {
        if ($existingEntry -and [string]$existingEntry.State -eq 'Imported') {
            $existingEntry['State'] = 'Linked'; $existingEntry['Updated'] = (Get-Date).ToUniversalTime().ToString('o')
            Update-LinkEntry -Name $name -Scope $scope -Entry $existingEntry
            return Add-SpxTypeName ([pscustomobject]@{ Name = $name; Scope = $scope; Status = 'Adopted'; Changed = $true; Destination = $targetRoot; Versions = @($Snapshot.Versions.Name); Conflicts = @(); OperationId = $null }) 'SPX.AppMoveResult'
        }
        return Add-SpxTypeName ([pscustomobject]@{ Name = $name; Scope = $scope; Status = 'Unchanged'; Changed = $false; Destination = $targetRoot; Versions = @($Snapshot.Versions.Name); Conflicts = @(); OperationId = $null }) 'SPX.AppMoveResult'
    }

    $operationId = [guid]::NewGuid().ToString('N')
    $persistDefinitions = Get-SpxPersistDefinitions $Snapshot.Manifest
    $exclude = @($persistDefinitions | Select-Object -ExpandProperty Source)
    $planned = foreach ($version in $pendingVersions) {
        $final = Join-Path $targetApp $version.Name
        if (Test-Path -LiteralPath $final) {
            Stop-SpxError 'Spx.DestinationCollision' "Destination version already exists: $final" $final
        }
        [ordered]@{
            name=$version.Name; source=$version.CanonicalPath; target=$final
            stage=(Join-Path $targetApp ('.spx-staging-' + $operationId + '-' + $version.Name))
            backup=(Join-Path $Snapshot.AppPath ('.spx-backup-' + $operationId + '-' + $version.Name))
            linked=$false; fingerprint=(Get-SpxTreeFingerprint $version.DataPath $exclude)
        }
    }
    $operation = [ordered]@{ schema = 1; id = $operationId; kind = 'link'; action = 'Move'; phase = 'Prepared'; name = $name; scope = $scope; destination = $targetRoot; exclude = $exclude; versions = @($planned); persistCreated = @(); conflictCopies = @(); created = (Get-Date).ToUniversalTime().ToString('o') }
    $null = Write-SpxOperation -Kind link -Key $key -Value $operation
    try {
        if (-not (Test-Path -LiteralPath $targetApp)) {
            $null = New-Item -ItemType Directory -Path $targetApp -Force
        }
        foreach ($record in $operation.versions) {
            $version = @($pendingVersions | Where-Object Name -EQ $record.name)[0]
            Copy-SpxTree -Source $version.DataPath -Destination $record.stage -ExcludeRelative $exclude
            if ((Get-SpxTreeFingerprint $version.DataPath $exclude) -ne $record.fingerprint -or $record.fingerprint -ne (Get-SpxTreeFingerprint $record.stage)) {
                throw "Copy verification failed or source changed for '$name/$($version.Name)'."
            }
            Move-Item -LiteralPath $record.stage -Destination $record.target -ErrorAction Stop
            Update-SpxMovedInternalLinks -Root $record.target -PreviousRoot $record.stage
            Move-Item -LiteralPath $record.source -Destination $record.backup -ErrorAction Stop
            Update-SpxMovedInternalLinks -Root $record.backup -PreviousRoot $record.source
            New-SpxDirectoryJunction -Path $record.source -Target $record.target
            $record.linked = $true; $operation.phase = 'Linked'
            $null = Write-SpxOperation -Kind link -Key $key -Value $operation

            foreach ($definition in $persistDefinitions) {
                $sourceData = Join-Path $record.backup $definition.Source
                $targetData = Join-Path $Snapshot.PersistPath $definition.Target
                if (Test-Path -LiteralPath $sourceData) {
                    if (-not (Test-Path -LiteralPath $targetData)) {
                        $operation.persistCreated += [ordered]@{ source = (Join-Path $record.source $definition.Source); target = $targetData }
                        $null = Write-SpxOperation -Kind link -Key $key -Value $operation
                        $targetParent = Split-Path -Parent $targetData
                        if (-not (Test-Path -LiteralPath $targetParent)) {
                            $null = New-Item -ItemType Directory -Path $targetParent -Force
                        }
                        if ((Get-Item -LiteralPath $sourceData).PSIsContainer) {
                            Copy-SpxTree -Source $sourceData -Destination $targetData
                        }
                        else {
                            Copy-Item -LiteralPath $sourceData -Destination $targetData -Force
                        }
                    }
                    else {
                        $conflict = $targetData + '.spx-conflict-' + $operationId
                        $operation.conflictCopies += [ordered]@{ source = (Join-Path $record.source $definition.Source); target = $conflict }
                        $null = Write-SpxOperation -Kind link -Key $key -Value $operation
                        if ((Get-Item -LiteralPath $sourceData).PSIsContainer) {
                            Copy-SpxTree -Source $sourceData -Destination $conflict
                        }
                        else {
                            Copy-Item -LiteralPath $sourceData -Destination $conflict -Force
                        }
                    }
                }
                elseif (-not (Test-Path -LiteralPath $targetData)) {
                    $null = New-Item -ItemType Directory -Path $targetData -Force
                }
                $linkPath = Join-Path $record.target $definition.Source
                if (Test-Path -LiteralPath $linkPath) {
                    throw "Relocated persist path unexpectedly exists: $linkPath"
                }
                New-SpxPersistReference -Path $linkPath -Target $targetData
            }
        }
        $entry = [ordered]@{ Path = $targetRoot; Version = $Snapshot.CurrentVersion; Versions = @($Snapshot.Versions.Name); State = 'Linked'; Updated = (Get-Date).ToUniversalTime().ToString('o'); OperationId = $operationId }
        Update-LinkEntry -Name $name -Scope $scope -Entry $entry
        $operation.phase = 'Committed'; $null = Write-SpxOperation -Kind link -Key $key -Value $operation
        foreach ($record in $operation.versions) {
            if (Test-Path -LiteralPath $record.backup) {
                if ((Get-SpxTreeFingerprint $record.backup $exclude) -ne $record.fingerprint -or (Get-SpxTreeFingerprint $record.target $exclude) -ne $record.fingerprint) {
                    Stop-SpxError 'Spx.CommittedCleanupConflict' "Relocation committed but source or destination changed; backup was preserved. Run Repair-SpxLinkedApp." $record.backup
                }
                Remove-SpxOwnedTree $record.backup
            }
        }
        Remove-SpxOperation -Kind link -Key $key
        Add-SpxTypeName ([pscustomobject]@{ Name = $name; Scope = $scope; Status = 'Moved'; Changed = $true; Destination = $targetRoot; Versions = @($Snapshot.Versions.Name); Conflicts = @($operation.conflictCopies.target); OperationId = $operationId }) 'SPX.AppMoveResult'
    }
    catch {
        $primaryError = $_
        if ($operation.phase -eq 'Committed') {
            Stop-SpxError 'Spx.CommittedCleanupPending' "Relocation committed but cleanup is pending: $($primaryError.Exception.Message) Run Repair-SpxLinkedApp." $name
        }
        $rollbackFailed = $false
        $rollbackMessages = New-Object Collections.Generic.List[string]
        $records = @($operation.versions)
        [array]::Reverse($records)
        foreach ($record in $records) {
            try {
                Remove-SpxLinkOnly $record.source
                if (Test-Path -LiteralPath $record.backup) {
                    Move-Item -LiteralPath $record.backup -Destination $record.source -ErrorAction Stop
                }
                if (Test-Path -LiteralPath $record.target) {
                    Remove-SpxOwnedTree $record.target
                }
                if (Test-Path -LiteralPath $record.stage) {
                    Remove-SpxOwnedTree $record.stage
                }
            }
            catch {
                $rollbackFailed = $true; $rollbackMessages.Add($_.Exception.Message)
            }
        }
        foreach ($copy in @(@($operation.persistCreated) + @($operation.conflictCopies) | Where-Object { $_ -and $_.target })) {
            try {
                if (Test-Path -LiteralPath $copy.target) {
                    if (Test-SpxContentEquivalent $copy.source $copy.target) {
                        Remove-SpxOwnedTree $copy.target
                    }
                    else {
                        throw "Recovery copy changed and was preserved: $($copy.target)"
                    }
                }
            }
            catch {
                $rollbackFailed = $true; $rollbackMessages.Add($_.Exception.Message)
            }
        }
        if ((Test-Path -LiteralPath $targetApp) -and @(Get-ChildItem -LiteralPath $targetApp -Force).Count -eq 0) {
            [IO.Directory]::Delete($targetApp, $false)
        }
        if (-not $targetRootExisted -and (Test-Path -LiteralPath $targetRoot) -and @(Get-ChildItem -LiteralPath $targetRoot -Force).Count -eq 0) {
            [IO.Directory]::Delete($targetRoot, $false)
        }
        if (-not $rollbackFailed) {
            Remove-SpxOperation -Kind link -Key $key
        }
        if ($rollbackFailed) {
            Stop-SpxError 'Spx.RelocationAndRollbackFailed' ("Relocation failed: $($primaryError.Exception.Message) Rollback also failed: $($rollbackMessages -join '; '). Run Repair-SpxLinkedApp.") $name
        }
        throw $primaryError
    }
}

function Move-SpxApp {
    <#
    .SYNOPSIS
    Relocates installed Scoop app versions to an external directory with recoverable junction cutover.
    .DESCRIPTION
    Copies and verifies every installed version, replaces canonical version directories with junctions,
    preserves Scoop persist semantics, commits SPX ownership, and removes only verified backups.
    Each name is a separate transaction; processing stops at the first terminating error.
    .PARAMETER Name
    One or more installed app names. Accepts strings and AppName properties from the pipeline.
    .PARAMETER Destination
    Absolute destination root. It must not overlap Scoop app, persist, or SPX state directories.
    .PARAMETER Scope
    Scoop installation scope. Defaults to Local.
    .OUTPUTS
    SPX.AppMoveResult for each admitted app. No receipt is emitted for a WhatIf-only preview.
    .EXAMPLE
    Move-SpxApp jq,rg -Destination 'D:\Portable Apps' -Scope Local -WhatIf
    .NOTES
    On Spx.PendingRecovery or a recovery-related error, preserve operation evidence and run
    Repair-SpxLinkedApp. Destination collisions and changed recovery data are never overwritten.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local'
    )
    process {
        foreach ($appName in $Name) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) {
                Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName
            }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", "relocate to '$Destination'")) {
                Invoke-SpxOperationLock -Kind link -Key ($Scope.ToLowerInvariant() + '-' + $appName) -Script {
                    $admitted = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                    if (-not $admitted) {
                        Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName
                    }
                    Invoke-SpxRelocateApp -Snapshot $admitted -Destination $Destination
                }
            }
        }
    }
}

function Invoke-SpxRestoreApp {
    param([Parameter(Mandatory)]$Snapshot)
    $appName = $Snapshot.Name; $Scope = $Snapshot.Scope
    $id = [guid]::NewGuid().ToString('N'); $key = $Scope.ToLowerInvariant() + '-' + $appName
    if (Read-SpxOperation -Kind link -Key $key) {
        Stop-SpxError 'Spx.PendingRecovery' "App '$appName' has pending recovery; run Repair-SpxLinkedApp before another mutation." $appName
    }
    $restoreManifest = $Snapshot.PSObject.Properties['Manifest'].Value
    $persistDefinitions = Get-SpxPersistDefinitions $restoreManifest
    $exclude = @($persistDefinitions | Select-Object -ExpandProperty Source)
    $planned = foreach ($version in @($Snapshot.Versions | Where-Object IsRelocated)) {
        [ordered]@{name = $version.Name; source = $version.DataPath; canonical = $version.CanonicalPath; stage = (Join-Path $snapshot.AppPath ('.spx-restore-' + $id + '-' + $version.Name)); restored = $false; fingerprint = (Get-SpxTreeFingerprint $version.DataPath $exclude) }
    }
    $operation = [ordered]@{schema = 1; id = $id; kind = 'link'; action = 'Restore'; phase = 'Prepared'; name = $appName; scope = $Scope; destination = $snapshot.LinkEntry.Path; exclude = $exclude; versions = @($planned) }
    $null = Write-SpxOperation -Kind link -Key $key -Value $operation
    try {
        foreach ($record in $operation.versions) {
            Copy-SpxTree -Source $record.source -Destination $record.stage -ExcludeRelative $exclude
            if ((Get-SpxTreeFingerprint $record.source $exclude) -ne $record.fingerprint -or $record.fingerprint -ne (Get-SpxTreeFingerprint $record.stage)) {
                throw "Restore copy verification failed or source changed for '$appName/$($record.name)'."
            }
            Remove-SpxLinkOnly $record.canonical
            Move-Item -LiteralPath $record.stage -Destination $record.canonical -ErrorAction Stop
            Update-SpxMovedInternalLinks -Root $record.canonical -PreviousRoot $record.stage
            foreach ($definition in $persistDefinitions) {
                $linkPath = Join-Path $record.canonical $definition.Source
                $targetData = Join-Path $snapshot.PersistPath $definition.Target
                if (-not (Test-Path -LiteralPath $linkPath) -and (Test-Path -LiteralPath $targetData)) {
                    New-SpxPersistReference -Path $linkPath -Target $targetData
                }
            }
            $record.restored = $true; $operation.phase = 'Restored'; $null = Write-SpxOperation -Kind link -Key $key -Value $operation
        }
        Update-LinkEntry -Name $appName -Scope $Scope -Remove
        $operation.phase = 'Committed'; $null = Write-SpxOperation -Kind link -Key $key -Value $operation
        foreach ($record in $operation.versions) {
            if (Test-Path -LiteralPath $record.source) {
                if ((Get-SpxTreeFingerprint $record.source $exclude) -ne $record.fingerprint -or (Get-SpxTreeFingerprint $record.canonical $exclude) -ne $record.fingerprint) {
                    Stop-SpxError 'Spx.CommittedCleanupConflict' "Restore committed but source or destination changed; relocated source was preserved. Run Repair-SpxLinkedApp." $record.source
                }
                Remove-SpxOwnedTree $record.source
            }
        }
        $targetApp = Join-Path $snapshot.LinkEntry.Path $appName
        if ((Test-Path -LiteralPath $targetApp) -and @(Get-ChildItem -LiteralPath $targetApp -Force).Count -eq 0) {
            [IO.Directory]::Delete($targetApp, $false)
        }
        Remove-SpxOperation -Kind link -Key $key
        Add-SpxTypeName ([pscustomobject]@{Name = $appName; Scope = $Scope; Status = 'Restored'; Changed = $true; Destination = $snapshot.AppPath; Versions = @($operation.versions.name); OperationId = $id }) 'SPX.AppRestoreResult'
    }
    catch {
        if ($operation.phase -eq 'Committed') {
            Stop-SpxError 'Spx.CommittedCleanupPending' "Restore committed but cleanup is pending: $($_.Exception.Message) Run Repair-SpxLinkedApp." $appName
        }
        throw
    }
}

function Restore-SpxApp {
    <#
    .SYNOPSIS
    Restores an SPX-relocated app to its canonical Scoop apps directory.
    .DESCRIPTION
    Copies and verifies relocated versions back into Scoop, restores persist references, commits
    configuration removal, and then removes only verified SPX-owned relocated data.
    .PARAMETER Name
    One or more managed app names. Accepts strings and AppName properties from the pipeline.
    .PARAMETER Scope
    Scoop installation scope. Defaults to Local.
    .OUTPUTS
    SPX.AppRestoreResult for each restored app.
    .EXAMPLE
    Restore-SpxApp jq -Scope Local -Confirm:$false
    .NOTES
    A pending or interrupted restore must be resolved with Repair-SpxLinkedApp; do not delete the
    journal or preserved source manually.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local'
    )
    process {
        foreach ($appName in $Name) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) {
                Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName
            }
            if (-not $snapshot.LinkEntry) {
                Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is not managed by SPX." $appName
            }
            if (-not $PSCmdlet.ShouldProcess("$Scope app '$appName'", 'restore to Scoop apps directory')) {
                continue
            }
            Invoke-SpxOperationLock -Kind link -Key ($Scope.ToLowerInvariant() + '-' + $appName) -Script {
                $admitted = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                if (-not $admitted -or -not $admitted.LinkEntry) {
                    Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is no longer a managed link." $appName
                }
                Invoke-SpxRestoreApp -Snapshot $admitted
            }
        }
    }
}

function Get-SpxLinkedApp {
    <#
    .SYNOPSIS
    Reports configured app relocations and their observed health state.
    .DESCRIPTION
    Reconciles committed SPX records with Scoop directories, junction targets, persist paths, and
    durable operation evidence without changing any state.
    .PARAMETER Name
    Optional app names. When omitted, returns every configured name in the selected scope.
    .PARAMETER Scope
    Local, Global, or All. Defaults to All.
    .OUTPUTS
    SPX.LinkedApp objects with State, diagnostic evidence, and pending-operation data.
    .EXAMPLE
    Get-SpxLinkedApp -Scope All
    #>
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name, [ValidateSet('Local', 'Global', 'All')][string]$Scope = 'All')
    process {
        $cfg = Get-LinksConfig
        foreach ($currentScope in Resolve-SpxScopes $Scope) {
            $key = $currentScope.ToLowerInvariant(); $names = if ($Name) {
                @($Name)
            }
            else {
                @($cfg[$key].Keys)
            }
            foreach ($appName in $names) {
                if (-not $cfg[$key].Contains($appName)) {
                    continue
                }; $entry = $cfg[$key][$appName]; $operation = Read-SpxOperation -Kind link -Key ($key + '-' + $appName)
                $snapshot = $null; $diagnostic = $null
                try {
                    $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $currentScope
                }
                catch {
                    $diagnostic = $_.Exception.Message
                }
                $state = if ($operation) {
                    'PendingRecovery'
                }
                elseif ($diagnostic -match 'Unmanaged version reparse') {
                    'LinkTargetMismatch'
                }
                elseif ($diagnostic) {
                    'Invalid'
                }
                elseif (-not $snapshot) {
                    'Stale'
                }
                elseif (@($snapshot.Versions | Where-Object { $_.IsRelocated -and -not(Test-Path -LiteralPath $_.DataPath) }).Count) {
                    'TargetMissing'
                }
                elseif ([string]$entry.State -eq 'Imported') {
                    'ImportedIntent'
                }
                elseif (@($snapshot.Versions | Where-Object { -not $_.IsRelocated }).Count) {
                    'VersionDrift'
                }
                else {
                    'Healthy'
                }
                if ($state -eq 'Healthy') {
                    foreach ($version in $snapshot.Versions) {
                        foreach ($definition in Get-SpxPersistDefinitions $snapshot.Manifest) {
                            $expected = Join-Path $snapshot.PersistPath $definition.Target
                            $actual = Get-SpxLinkTarget (Join-Path $version.DataPath $definition.Source)
                            if (-not $actual -or -not $actual.Equals([IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $expected)) {
                                $state = 'PersistDrift'; break
                            }
                        }
                        if ($state -eq 'PersistDrift') {
                            break
                        }
                    }
                }
                Add-SpxTypeName ([pscustomobject]@{Name=$appName; Scope=$currentScope; State=$state; Destination=$entry.Path; Version=$entry.Version; Versions=$(if ($snapshot) {
                                @($snapshot.Versions.Name)
                            }
                            else {
                                @()
                            }); Updated=$entry.Updated; Evidence=$diagnostic; PendingOperation=$operation
                    }) 'SPX.LinkedApp'
            }
        }
    }
}

function Sync-SpxLinkedApp {
    <#
    .SYNOPSIS
    Relocates newly installed versions for apps already managed by SPX.
    .DESCRIPTION
    Reuses each committed destination and applies the normal verified relocation transaction to
    versions Scoop installed after the app was first linked.
    .PARAMETER Name
    Optional managed app names. When omitted, synchronizes all configured names in the scope.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .OUTPUTS
    SPX.AppMoveResult objects for apps that reach relocation processing.
    .EXAMPLE
    Sync-SpxLinkedApp jq -Scope Local -WhatIf
    .NOTES
    Each app is independent. Resolve Spx.PendingRecovery with Repair-SpxLinkedApp before retrying.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name, [ValidateSet('Local', 'Global')][string]$Scope = 'Local')
    process {
        $cfg = Get-LinksConfig; $key = $Scope.ToLowerInvariant(); $names = if ($Name) {
            @($Name)
        }
        else {
            @($cfg[$key].Keys)
        }
        foreach ($appName in $names) {
            if (-not $cfg[$key].Contains($appName)) {
                Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is not managed by SPX." $appName
            }
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) {
                continue
            }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", 'synchronize relocated versions')) {
                Invoke-SpxOperationLock -Kind link -Key ($key + '-' + $appName) -Script {
                    $freshConfig = Get-LinksConfig
                    if (-not $freshConfig[$key].Contains($appName)) {
                        Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is no longer managed by SPX." $appName
                    }
                    $fresh = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                    if ($fresh) {
                        Invoke-SpxRelocateApp -Snapshot $fresh -Destination $freshConfig[$key][$appName].Path
                    }
                }
            }
        }
    }
}

function Repair-SpxLinkedApp {
    <#
    .SYNOPSIS
    Completes or rolls back interrupted SPX app relocation operations.
    .DESCRIPTION
    Uses durable operation data plus observed paths and fingerprints to roll forward a committed
    operation or restore its safe pre-state. It refuses ambiguous or changed evidence.
    .PARAMETER Name
    Optional app names. When omitted, repairs every pending operation in the selected scope.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .OUTPUTS
    SPX.LinkedAppRepairResult objects for repaired operations.
    .EXAMPLE
    Repair-SpxLinkedApp jq -Scope Local -Confirm:$false
    .NOTES
    Preserve paths named by Spx.RecoveryConflict and inspect them before retrying.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name, [ValidateSet('Local', 'Global')][string]$Scope = 'Local')
    process {
        $key = $Scope.ToLowerInvariant()
        $names = if ($Name) {
            @($Name)
        }
        else {
            $found = New-Object Collections.Generic.List[string]
            $dir = Join-Path (Get-SpxContext).Operations 'link'
            if (Test-Path -LiteralPath $dir) {
                foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
                    $op = Read-SpxOperation -Kind link -Key $file.BaseName; if ($op.scope -eq $Scope) {
                        $found.Add([string]$op.name)
                    }
                }
            }
            @($found | Select-Object -Unique)
        }
        foreach ($appName in $names) {
            $operation = Read-SpxOperation -Kind link -Key ($key + '-' + $appName)
            if (-not $operation) {
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("$Scope app '$appName'", 'repair pending relocation')) {
                continue
            }
            Invoke-SpxOperationLock -Kind link -Key ($key + '-' + $appName) -Script {
                $operation = Read-SpxOperation -Kind link -Key ($key + '-' + $appName)
                if (-not $operation) {
                    return
                }
                $cfg = Get-LinksConfig
                $entry = if ($cfg[$key].Contains($appName)) {
                    $cfg[$key][$appName]
                }
                else {
                    $null
                }
                if ($operation.action -eq 'Restore') {
                    if (-not $entry) {
                        foreach ($record in @($operation.versions)) {
                            if (-not(Test-Path -LiteralPath $record.canonical) -or (Get-SpxLinkTarget $record.canonical)) {
                                Stop-SpxError 'Spx.RecoveryConflict' "Restore completion lacks a verified canonical directory. Preserved recovery evidence for '$($record.canonical)'." $record.canonical
                            }
                            $excludePaths = @($operation['exclude'])
                            Assert-SpxRecoveryFingerprint $record.canonical $record.fingerprint $excludePaths 'Restore completion found changed canonical data.'
                            if (Test-Path -LiteralPath $record.source) {
                                Assert-SpxRecoveryFingerprint $record.source $record.fingerprint $excludePaths 'Restore completion found changed relocated data.'
                                Remove-SpxOwnedTree $record.source
                            }
                            if (Test-Path -LiteralPath $record.stage) {
                                Remove-SpxOwnedTree $record.stage
                            }
                        }
                        $status = 'Completed'
                    }
                    else {
                        $excludePaths = @($operation['exclude'])
                        foreach ($record in @($operation.versions)) {
                            if (-not(Test-Path -LiteralPath $record.source)) {
                                Stop-SpxError 'Spx.RecoveryConflict' "Restore rollback lacks its relocated source. Preserved recovery evidence for '$($record.canonical)'." $record.canonical
                            }
                            Assert-SpxRecoveryFingerprint $record.source $record.fingerprint $excludePaths 'Restore rollback found changed relocated data.'
                            if (Test-Path -LiteralPath $record.canonical) {
                                $canonicalTarget = Get-SpxLinkTarget $record.canonical
                                if ($canonicalTarget) {
                                    Assert-SpxRecoveryLinkTarget $record.canonical $record.source 'Restore rollback found a mismatched canonical link.'
                                }
                                else {
                                    Assert-SpxRecoveryFingerprint $record.canonical $record.fingerprint $excludePaths 'Restore rollback found changed canonical data.'
                                }
                            }
                        }
                        foreach ($record in @($operation.versions)) {
                            if (Test-Path -LiteralPath $record.canonical) {
                                if (Get-SpxLinkTarget $record.canonical) {
                                    Remove-SpxLinkOnly $record.canonical
                                }
                                elseif (Test-Path -LiteralPath $record.source) {
                                    Remove-SpxOwnedTree $record.canonical
                                }
                            }
                            if ((Test-Path -LiteralPath $record.source) -and -not (Test-Path -LiteralPath $record.canonical)) {
                                New-SpxDirectoryJunction -Path $record.canonical -Target $record.source
                            }
                            if (Test-Path -LiteralPath $record.stage) {
                                Remove-SpxOwnedTree $record.stage
                            }
                        }
                        $status = 'RolledBack'
                    }
                }
                elseif ($entry -and [string]$entry.OperationId -eq [string]$operation.id) {
                    $excludePaths = @($operation['exclude'])
                    foreach ($record in @($operation.versions)) {
                        if (-not(Test-Path -LiteralPath $record.target)) {
                            Stop-SpxError 'Spx.RecoveryConflict' "Relocation completion target is missing. Preserved recovery evidence for '$($record.target)'." $record.target
                        }
                        Assert-SpxRecoveryLinkTarget $record.source $record.target 'Relocation completion found a mismatched canonical link.'
                        Assert-SpxRecoveryFingerprint $record.target $record.fingerprint $excludePaths 'Relocation completion found changed destination data.'
                        if (Test-Path -LiteralPath $record.backup) {
                            Assert-SpxRecoveryFingerprint $record.backup $record.fingerprint $excludePaths 'Relocation completion found changed backup data.'
                            Remove-SpxOwnedTree $record.backup
                        }
                        if (Test-Path -LiteralPath $record.stage) {
                            Remove-SpxOwnedTree $record.stage
                        }
                    }
                    $status = 'Completed'
                }
                else {
                    $excludePaths = @($operation['exclude'])
                    foreach ($record in @($operation.versions)) {
                        $sourceLink = Get-SpxLinkTarget $record.source
                        if ($sourceLink) {
                            Assert-SpxRecoveryLinkTarget $record.source $record.target 'Relocation rollback found a mismatched canonical link.'
                        }
                        elseif (Test-Path -LiteralPath $record.source) {
                            Assert-SpxRecoveryFingerprint $record.source $record.fingerprint $excludePaths 'Relocation rollback found changed canonical data.'
                        }
                        elseif (-not(Test-Path -LiteralPath $record.backup)) {
                            Stop-SpxError 'Spx.RecoveryConflict' "Relocation rollback lacks a recoverable canonical copy. Preserved '$($record.target)'." $record.target
                        }
                        Assert-SpxRecoveryFingerprint $record.backup $record.fingerprint $excludePaths 'Relocation rollback found changed backup data.'
                        Assert-SpxRecoveryFingerprint $record.target $record.fingerprint $excludePaths 'Relocation rollback found changed destination data.'
                    }
                    $records = @($operation.versions); [array]::Reverse($records)
                    foreach ($record in $records) {
                        Remove-SpxLinkOnly $record.source
                        if (Test-Path -LiteralPath $record.backup) {
                            Move-Item -LiteralPath $record.backup -Destination $record.source
                        }
                        if (Test-Path -LiteralPath $record.target) {
                            Remove-SpxOwnedTree $record.target
                        }
                        if (Test-Path -LiteralPath $record.stage) {
                            Remove-SpxOwnedTree $record.stage
                        }
                    }
                    foreach ($copy in @(@($operation.persistCreated) + @($operation.conflictCopies) | Where-Object { $_ -and $_.target })) {
                        if (Test-Path -LiteralPath $copy.target) {
                            if (-not (Test-SpxContentEquivalent $copy.source $copy.target)) {
                                Stop-SpxError 'Spx.RecoveryConflict' "Recovery-owned copy changed and was preserved: $($copy.target)" $copy.target
                            }
                            Remove-SpxOwnedTree $copy.target
                        }
                    }
                    $status = 'RolledBack'
                }
                Remove-SpxOperation -Kind link -Key ($key + '-' + $appName)
                Add-SpxTypeName ([pscustomobject]@{Name = $appName; Scope = $Scope; Status = $status; Changed = $true; Destination = $operation.destination; Versions = @($operation.versions.name); OperationId = $operation.id }) 'SPX.LinkedAppRepairResult'
            }
        }
    }
}

function Remove-SpxStaleLink {
    <#
    .SYNOPSIS
    Removes configuration for an SPX-linked app that is no longer installed.
    .DESCRIPTION
    Removes only a proven-stale SPX link record. It refuses installed apps and any app with pending
    recovery, and it does not delete destination payloads.
    .PARAMETER Name
    One or more stale app names. Accepts strings and AppName properties from the pipeline.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .OUTPUTS
    SPX.StaleLinkRemovalResult for each removed record.
    .EXAMPLE
    Remove-SpxStaleLink abandoned-app -Scope Local -WhatIf
    .NOTES
    Use Get-SpxLinkedApp to prove State is Stale before cleanup.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name, [ValidateSet('Local', 'Global')][string]$Scope = 'Local')
    process {
        foreach ($appName in $Name) {
            $scopeKey = $Scope.ToLowerInvariant(); $cfg = Get-LinksConfig
            if (-not $cfg[$scopeKey].Contains($appName)) {
                Stop-SpxError 'Spx.LinkNotFound' "App '$appName' has no SPX link record." $appName
            }
            if (Read-SpxOperation -Kind link -Key ($scopeKey + '-' + $appName)) {
                Stop-SpxError 'Spx.PendingRecovery' "App '$appName' has pending recovery; repair it before stale cleanup." $appName
            }
            if (Get-SpxAppSnapshot -Name $appName -Scope $Scope) {
                Stop-SpxError 'Spx.LinkNotStale' "App '$appName' is still installed." $appName
            }
            if ($PSCmdlet.ShouldProcess("$Scope link '$appName'", 'remove stale SPX record')) {
                Invoke-SpxOperationLock -Kind link -Key ($Scope.ToLowerInvariant() + '-' + $appName) -Script {
                    $freshConfig = Get-LinksConfig
                    if (-not $freshConfig[$scopeKey].Contains($appName)) {
                        Stop-SpxError 'Spx.LinkNotFound' "App '$appName' no longer has an SPX link record." $appName
                    }
                    if (Read-SpxOperation -Kind link -Key ($scopeKey + '-' + $appName)) {
                        Stop-SpxError 'Spx.PendingRecovery' "App '$appName' now has pending recovery." $appName
                    }
                    if (Get-SpxAppSnapshot -Name $appName -Scope $Scope) {
                        Stop-SpxError 'Spx.LinkNotStale' "App '$appName' is no longer stale." $appName
                    }
                    Update-LinkEntry -Name $appName -Scope $Scope -Remove
                    Add-SpxTypeName ([pscustomobject]@{Name = $appName; Scope = $Scope; Status = 'Removed'; Changed = $true }) 'SPX.StaleLinkRemovalResult'
                }
            }
        }
    }
}
