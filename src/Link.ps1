

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
    if (-not (Test-SpxAbsolutePath $Destination)) {
        throw [ArgumentException]::new("Destination must be absolute: $Destination")
    }
    $full = [IO.Path]::GetFullPath($Destination)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\') }
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
        [IO.Directory]::Delete($Path, $false)
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
        New-SpxSymbolicLink -Path $Path -Target $Target
        if (-not (Get-SpxLinkTarget $Path)) {
            throw "Persist link verification failed for '$Path'."
        }
    }
}


# Link effects and both recovery entry points share one durable operation.

function ConvertTo-SpxLinkOperation {
    param ($Operation, $State)
    if ([string]$Operation.schema -eq '1') {
        foreach ($record in $Operation.versions) {
            $record['canonical'] = if ($Operation.action -eq 'Move') { $record.source } else { $record.canonical }
            $record['target'] = if ($Operation.action -eq 'Move') { $record.target } else { $record.source }
            $record['backup'] = if ($record.backup) { $record.backup } else { Join-Path (Split-Path $record.canonical -Parent) ('.spx-backup-' + $Operation.id + '-' + $record.name) }
            $record['exclude'] = @($Operation.exclude)
        }
        $Operation['beforeActive'] = if ($State.Active.OperationId -ne $Operation.id) { $State.Active }
        $Operation['beforeIntent'] = $State.Intent
    }
    $Operation
}

function Get-SpxOperationCopies {
    param ($Operation, [bool]$Committed)
    foreach ($record in $Operation.versions) {
        $roles = if ($Operation.action -eq 'Move') {
            if ($Committed) { @('backup', 'stage') } else { @('target', 'stage') }
        }
        else {
            if ($Committed) { @('target', 'stage', 'backup') } else { @('backup', 'stage') }
        }
        foreach ($role in $roles) {
            $path = [string]$record[$role]
            if ($path -and (Test-Path -LiteralPath $path)) {
                [ordered]@{ Id = ($Operation.id + ':' + $record.name + ':' + $role); OperationId = $Operation.id; Version = $record.name; Role = $role; Path = $path; Fingerprint = $record.fingerprint; Exclude = @($record.exclude) }
            }
        }
    }
    foreach ($copy in @(@($Operation.persistCreated) + @($Operation.conflictCopies) | Where-Object { $_ -and (Test-Path -LiteralPath $_.target) })) {
        # Created persist targets remain active after commit; conflict copies never do.
        if (-not $Committed -or $copy.conflict) {
            [ordered]@{ Id = ($Operation.id + ':persist:' + $copy.target); OperationId = $Operation.id; Version = $copy.version; Role = 'persist'; Path = $copy.target; Fingerprint = $null; Exclude = @() }
        }
    }
}

function Save-SpxLinkOutcome {
    param ($Operation, [bool]$Committed)
    $entry = if ($Committed) {
        if ($Operation.action -eq 'Move') { $Operation.entry }
    }
    else { $Operation.beforeActive }
    $intent = if (-not $Committed) { $Operation.beforeIntent }
    Update-LinkEntry -Name $Operation.name -Scope $Operation.scope -Entry $entry -Remove:($null -eq $entry) -Intent $intent -Retained @(Get-SpxOperationCopies $Operation $Committed) -OperationId $Operation.id -Action $Operation.action -Outcome $(if ($Committed) { 'Committed' } else { 'RolledBack' })
}

function Invoke-SpxLinkRecovery {
    param ($Operation)
    $state = Get-SpxLinkRecord $Operation.name $Operation.scope
    $operation = ConvertTo-SpxLinkOperation $Operation $state
    $committed = ($state.LastOperation.Id -eq $operation.id -and $state.LastOperation.Outcome -eq 'Committed') -or ($state.Active.OperationId -eq $operation.id)
    if ($state.LastOperation.Id -eq $operation.id -and $state.LastOperation.Outcome -eq 'RolledBack') {
        Remove-SpxOperation link ($operation.scope.ToLowerInvariant() + '-' + $operation.name)
        return 'RolledBack'
    }
    # An old restore lacks a tombstone: require both real copies, not config absence alone.
    if ([string]$operation.schema -eq '1' -and $operation.action -eq 'Restore' -and -not $state.Active) {
        $committed = $true
    }
    foreach ($record in $operation.versions) {
        $exclude = @($record.exclude)
        $canonicalLink = Get-SpxLinkTarget $record.canonical
        if ($committed) {
            if ($operation.action -eq 'Move') {
                Assert-SpxRecoveryLinkTarget $record.canonical $record.target 'Committed relocation link changed.'
                if (-not (Test-Path -LiteralPath $record.target)) { Stop-SpxError 'Spx.RecoveryConflict' 'Committed target is missing.' $record.target }
                Update-SpxMovedInternalLinks $record.target $record.stage $exclude
                Assert-SpxRecoveryFingerprint $record.target $record.fingerprint $exclude 'Committed target changed.'
            }
            else {
                if ($canonicalLink -or -not(Test-Path -LiteralPath $record.canonical)) { Stop-SpxError 'Spx.RecoveryConflict' 'Restore lacks its canonical copy.' $record.canonical }
                Update-SpxMovedInternalLinks $record.canonical $record.stage $exclude
                Assert-SpxRecoveryFingerprint $record.canonical $record.fingerprint $exclude 'Restored copy changed.'
            }
            continue
        }
        # Validate all versions before changing which copy is active. Partial stages are retained.
        if ($operation.action -eq 'Move') {
            if ($canonicalLink) { Assert-SpxRecoveryLinkTarget $record.canonical $record.target 'Canonical target changed.' }
            if (Test-Path -LiteralPath $record.backup) {
                if (-not $canonicalLink -and (Test-Path -LiteralPath $record.canonical)) { Stop-SpxError 'Spx.RecoveryConflict' 'Both canonical and backup directories exist.' $record.canonical }
                Update-SpxMovedInternalLinks $record.backup $record.canonical $exclude
                Assert-SpxRecoveryFingerprint $record.backup $record.fingerprint $exclude 'Backup changed.'
            }
            elseif ($canonicalLink -or -not(Test-Path -LiteralPath $record.canonical)) { Stop-SpxError 'Spx.RecoveryConflict' 'No recoverable canonical copy.' $record.canonical }
            else { Assert-SpxRecoveryFingerprint $record.canonical $record.fingerprint $exclude 'Canonical copy changed.' }
            if (Test-Path -LiteralPath $record.target) {
                Update-SpxMovedInternalLinks $record.target $record.stage $exclude
                Assert-SpxRecoveryFingerprint $record.target $record.fingerprint $exclude 'Published copy changed.'
            }
        }
        else {
            if (-not(Test-Path -LiteralPath $record.target)) { Stop-SpxError 'Spx.RecoveryConflict' 'Restore rollback lacks the relocated copy.' $record.target }
            Assert-SpxRecoveryFingerprint $record.target $record.fingerprint $exclude 'Relocated copy changed.'
            if ($canonicalLink) { Assert-SpxRecoveryLinkTarget $record.canonical $record.target 'Canonical target changed.' }
            elseif (Test-Path -LiteralPath $record.canonical) {
                Update-SpxMovedInternalLinks $record.canonical $record.stage $exclude
                Assert-SpxRecoveryFingerprint $record.canonical $record.fingerprint $exclude 'Restored copy changed.'
                if (Test-Path -LiteralPath $record.backup) { Stop-SpxError 'Spx.RecoveryConflict' 'Restore backup already exists.' $record.backup }
            }
        }
    }
    if (-not $committed) {
        $records = @($operation.versions); [array]::Reverse($records)
        foreach ($record in $records) {
            $exclude = @($record.exclude)
            if ($operation.action -eq 'Move') {
                Remove-SpxLinkOnly $record.canonical
                if (Test-Path -LiteralPath $record.backup) { Move-SpxTree $record.backup $record.canonical $exclude }
            }
            else {
                if (-not(Get-SpxLinkTarget $record.canonical) -and (Test-Path -LiteralPath $record.canonical)) { Move-SpxTree $record.canonical $record.backup $exclude }
                if (-not(Test-Path -LiteralPath $record.canonical)) { New-SpxDirectoryJunction $record.canonical $record.target }
            }
        }
    }
    Save-SpxLinkOutcome $operation $committed
    Remove-SpxOperation link ($operation.scope.ToLowerInvariant() + '-' + $operation.name)
    if ($committed) { 'Completed' } else { 'RolledBack' }
}

function Set-SpxVersionPersist {
    param ($Operation, $Record, $Snapshot)
    foreach ($definition in $Record.persist) {
        $linkPath = Join-Path $(if ($Operation.action -eq 'Move') { $Record.target } else { $Record.canonical }) $definition.Source
        $targetData = Join-Path $Snapshot.PersistPath $definition.Target
        if ($Operation.action -eq 'Move') {
            $sourceData = Join-Path $Record.backup $definition.Source
            $sourceLink = Get-SpxLinkTarget $sourceData
            if ($sourceLink -and $sourceLink -ne [IO.Path]::GetFullPath($targetData)) { Stop-SpxError 'Spx.RecoveryConflict' 'Persist link has an unexpected target.' $sourceData }
            if (-not $sourceLink -and (Test-Path -LiteralPath $sourceData)) {
                $conflict = Test-Path -LiteralPath $targetData
                $copyPath = if ($conflict) { $targetData + '.spx-conflict-' + $Operation.id + '-' + $Record.name } else { $targetData }
                $copy = [ordered]@{ source = (Join-Path $Record.canonical $definition.Source); target = $copyPath; version = $Record.name; conflict = [bool]$conflict }
                if ($conflict) { $Operation.conflictCopies += $copy } else { $Operation.persistCreated += $copy }
                $null = Write-SpxOperation link ($Operation.scope.ToLowerInvariant() + '-' + $Operation.name) $Operation
                $parent = Split-Path $copyPath -Parent
                if (-not(Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
                if ((Get-Item -LiteralPath $sourceData -Force).PSIsContainer) { Copy-SpxTree $sourceData $copyPath }
                else { [IO.File]::Copy($sourceData, $copyPath, $false) }
                if (-not(Test-SpxContentEquivalent $sourceData $copyPath)) { throw "Persist copy verification failed: $copyPath" }
            }
            elseif (-not(Test-Path -LiteralPath $targetData)) {
                if ($sourceLink) { Stop-SpxError 'Spx.RecoveryConflict' 'Persist target is missing.' $targetData }
                $null = New-Item -ItemType Directory -Path $targetData -ErrorAction Stop
            }
        }
        if (-not(Test-Path -LiteralPath $targetData)) { Stop-SpxError 'Spx.RecoveryConflict' 'Persist target is missing.' $targetData }
        New-SpxPersistReference $linkPath $targetData
    }
}

function Invoke-SpxLinkChange {
    param ($Snapshot, [ValidateSet('Move', 'Restore')][string]$Action, [string]$Destination)
    $name = $Snapshot.Name; $scope = $Snapshot.Scope; $key = $scope.ToLowerInvariant() + '-' + $name
    if (Read-SpxOperation link $key) { Stop-SpxError 'Spx.PendingRecovery' "App '$name' has pending recovery." $name }
    $state = Get-SpxLinkRecord $name $scope
    $targetRoot = if ($Action -eq 'Move') { Resolve-SpxDestination $Destination } else { $state.Active.Path }
    if (-not $targetRoot) { Stop-SpxError 'Spx.LinkNotFound' "App '$name' is not relocated." $name }
    if ($state.Active -and [IO.Path]::GetFullPath([string]$state.Active.Path) -ne $targetRoot) { Stop-SpxError 'Spx.AlreadyLinkedElsewhere' "Restore '$name' before choosing another destination." $name }
    $targetApp = Join-Path $targetRoot $name
    if ($Action -eq 'Move' -and (Test-Path -LiteralPath $targetApp) -and -not $state.Active) { Stop-SpxError 'Spx.DestinationCollision' "Destination exists; inspect retained or unowned data: $targetApp" $targetApp }
    $versions = @($Snapshot.Versions | Where-Object { $_.IsRelocated -eq ($Action -eq 'Restore') })
    if (-not $versions.Count) {
        return Add-SpxTypeName ([pscustomobject]@{ Name = $name; Scope = $scope; Status = 'Unchanged'; Changed = $false; Destination = $targetRoot; Versions = @($Snapshot.Versions.Name); Conflicts = @(); OperationId = $null; RetainedCopies = @($state.Retained) }) 'SPX.AppMoveResult'
    }
    $id = [guid]::NewGuid().ToString('N')
    $planned = foreach ($version in $versions) {
        $target = Join-Path $targetApp $version.Name
        if ($Action -eq 'Move' -and (Test-Path -LiteralPath $target)) { Stop-SpxError 'Spx.DestinationCollision' "Destination version exists: $target" $target }
        $persist = @(Get-SpxPersistDefinitions $version.Manifest)
        $exclude = @($persist | Select-Object -ExpandProperty Source)
        [ordered]@{ name = $version.Name; canonical = $version.CanonicalPath; target = $target; stage = (Join-Path $(if ($Action -eq 'Move') { $targetApp } else { $Snapshot.AppPath }) ($(if ($Action -eq 'Move') { '.spx-staging-' } else { '.spx-restore-' }) + $id + '-' + $version.Name)); backup = (Join-Path $Snapshot.AppPath ('.spx-backup-' + $id + '-' + $version.Name)); fingerprint = (Get-SpxTreeFingerprint $version.DataPath $exclude); exclude = $exclude; persist = $persist }
    }
    $operation = [ordered]@{ schema = 2; id = $id; kind = 'link'; action = $Action; phase = 'Prepared'; name = $name; scope = $scope; destination = $targetRoot; beforeActive = $state.Active; beforeIntent = $state.Intent; versions = @($planned); persistCreated = @(); conflictCopies = @(); entry = [ordered]@{ Path = $targetRoot; Version = $Snapshot.CurrentVersion; Versions = @($Snapshot.Versions.Name); State = 'Linked'; Updated = (Get-Date).ToUniversalTime().ToString('o'); OperationId = $id } }
    $null = Write-SpxOperation link $key $operation
    try {
        if ($Action -eq 'Move' -and -not(Test-Path -LiteralPath $targetApp)) { $null = New-Item -ItemType Directory -Path $targetApp -Force }
        foreach ($record in $operation.versions) {
            $source = if ($Action -eq 'Move') { $record.canonical } else { $record.target }
            Copy-SpxTree $source $record.stage $record.exclude
            if ((Get-SpxTreeFingerprint $source $record.exclude) -ne $record.fingerprint -or (Get-SpxTreeFingerprint $record.stage) -ne $record.fingerprint) { throw 'Copy verification failed or source changed.' }
            if ($Action -eq 'Move') {
                Move-SpxTree $record.stage $record.target $record.exclude
                Move-SpxTree $record.canonical $record.backup $record.exclude
                New-SpxDirectoryJunction $record.canonical $record.target
            }
            else {
                Assert-SpxRecoveryLinkTarget $record.canonical $record.target 'Restore target changed.'
                Remove-SpxLinkOnly $record.canonical
                Move-SpxTree $record.stage $record.canonical $record.exclude
            }
            Set-SpxVersionPersist $operation $record $Snapshot
            $operation.phase = if ($Action -eq 'Move') { 'Linked' } else { 'Restored' }
            $null = Write-SpxOperation link $key $operation
        }
        Save-SpxLinkOutcome $operation $true
        $operation.phase = 'Committed'; $null = Write-SpxOperation link $key $operation
        Remove-SpxOperation link $key
        Add-SpxTypeName ([pscustomobject]@{ Name = $name; Scope = $scope; Status = $(if ($Action -eq 'Move') { 'Moved' } else { 'Restored' }); Changed = $true; Destination = $(if ($Action -eq 'Move') { $targetRoot } else { $Snapshot.AppPath }); Versions = @($operation.versions.name); Conflicts = @($operation.conflictCopies.target); OperationId = $id; RetainedCopies = @((Get-SpxLinkRecord $name $scope).Retained) }) $(if ($Action -eq 'Move') { 'SPX.AppMoveResult' } else { 'SPX.AppRestoreResult' })
    }
    catch {
        $primary = $_
        $committed = $operation.phase -eq 'Committed'
        try {
            $receipt = (Get-SpxLinkRecord $name $scope).LastOperation
            $committed = $committed -or ($receipt.Id -eq $id -and $receipt.Outcome -eq 'Committed')
            $pending = Read-SpxOperation link $key
            if ($pending -and -not $committed) { $null = Invoke-SpxLinkRecovery $pending }
        }
        catch { Stop-SpxError $(if ($committed) { 'Spx.CommittedCleanupPending' } else { 'Spx.RelocationAndRollbackFailed' }) ("$($primary.Exception.Message) Recovery preserved evidence: $($_.Exception.Message)") $name }
        if ($committed) { Stop-SpxError 'Spx.CommittedCleanupPending' ("Operation committed; finalization failed: $($primary.Exception.Message). Inspect and run Repair-SpxLinkedApp.") $name }
        throw $primary
    }
}

function Get-SpxLinkObservation {
    param ([string]$Name, [string]$Scope, $Config)
    $record = Get-SpxLinkRecord $Name $Scope $Config
    $pending = $null; $snapshot = $null; $issues = @(); $errorId = $null
    try { $pending = Read-SpxOperation link ($Scope.ToLowerInvariant() + '-' + $Name) }
    catch { $issues += [pscustomobject]@{ Code = 'InvalidState'; Message = $_.Exception.Message } }
    try { $snapshot = Get-SpxAppSnapshot -Name $Name -Scope $Scope -LinksConfig $Config }
    catch { $errorId = $_.FullyQualifiedErrorId; $issues += [pscustomobject]@{ Code = $(if ($errorId -like 'Spx.LinkTargetMismatch*') { 'TargetMismatch' } else { 'InvalidState' }); Message = $_.Exception.Message } }
    $state = if ($pending) { 'PendingRecovery' } elseif ($errorId -like 'Spx.LinkTargetMismatch*') { 'LinkTargetMismatch' } elseif ($issues.Count) { 'Invalid' } elseif (-not $snapshot) { 'Stale' } elseif (@($snapshot.Versions | Where-Object { $_.IsRelocated -and -not(Test-Path -LiteralPath $_.DataPath) }).Count) { 'TargetMissing' } elseif (-not $record.Active -and $record.Intent) { 'ImportedIntent' } elseif ($record.Active -and @($snapshot.Versions | Where-Object { -not $_.IsRelocated }).Count) { 'VersionDrift' } else { 'Healthy' }
    if ($state -eq 'Healthy' -and $record.Active) {
        try {
            foreach ($version in $snapshot.Versions) {
                foreach ($definition in Get-SpxPersistDefinitions $version.Manifest) {
                    $expected = Join-Path $snapshot.PersistPath $definition.Target
                    $reference = Join-Path $version.DataPath $definition.Source
                    if (-not(Test-Path -LiteralPath $reference) -and -not(Test-Path -LiteralPath $expected)) { continue }
                    if ((Get-SpxLinkTarget (Join-Path $version.DataPath $definition.Source)) -ne [IO.Path]::GetFullPath($expected) -or -not(Test-Path -LiteralPath $expected)) { $state = 'PersistDrift' }
                }
            }
        }
        catch { $state = 'Invalid'; $issues += [pscustomobject]@{ Code = 'InvalidState'; Message = $_.Exception.Message } }
    }
    if (-not $issues.Count -and $state -ne 'Healthy') { $issues += [pscustomobject]@{ Code = $state; Message = $state } }
    $placement = if (-not $snapshot) { if ($errorId) { 'Unknown' } else { 'Missing' } } elseif (@($snapshot.Versions | Where-Object IsRelocated).Count -eq $snapshot.Versions.Count) { 'Relocated' } elseif (@($snapshot.Versions | Where-Object IsRelocated).Count) { 'Mixed' } else { 'Canonical' }
    $summary = switch ($state) { 'Healthy' { 'Ready' } 'VersionDrift' { 'NeedsSync' } 'ImportedIntent' { 'NeedsSync' } 'PendingRecovery' { 'NeedsRecovery' } 'Stale' { 'Missing' } 'TargetMissing' { 'Missing' } 'Invalid' { 'Invalid' } default { 'Conflict' } }
    $entry = if ($record.Active) { $record.Active } else { $record.Intent }
    [pscustomobject]@{ Name = $Name; Scope = $Scope; State = $state; Status = $summary; Placement = $placement; IsManaged = [bool]($record.Active -or $record.Intent -or $record.Retained.Count -or $pending); Destination = $entry.Path; Version = $entry.Version; Versions = $(if ($snapshot) { @($snapshot.Versions.Name) } else { @() }); Updated = $entry.Updated; Evidence = ($issues.Message -join '; '); Issues = @($issues); PendingOperation = $pending; RetainedCopies = @($record.Retained); NextActions = @(switch ($summary) { 'NeedsRecovery' { 'Repair' } 'NeedsSync' { 'Sync' } 'Conflict' { 'Inspect' } 'Invalid' { 'Inspect' } }); Snapshot = $snapshot }
}

function Get-SpxLinkNames {
    param ([string]$Scope, $Config, [switch]$Installed)
    $key = $Scope.ToLowerInvariant()
    $names = @(foreach ($name in $Config[$key].Keys) {
            $record = $Config[$key][$name]
            if ($record.Active -or $record.Intent -or $record.Retained.Count) { $name }
        })
    $prefix = $key + '-'
    $names += @(Get-SpxOperationKeys link | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.Substring($prefix.Length) })
    if ($Installed) { $names += @(Get-SpxInstalledNames $Scope) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names | Where-Object { $seen.Add([string]$_) }
}


function Move-SpxApp {
    <#
    .SYNOPSIS
    Relocates installed Scoop app versions to an external directory with recoverable junction cutover.
    .DESCRIPTION
    Copies and verifies every installed version, replaces canonical version directories with junctions,
    preserves Scoop persist semantics, commits SPX ownership, and retains previous copies for explicit inspection and reclamation.
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
            if (Read-SpxOperation link ($Scope.ToLowerInvariant() + '-' + $appName)) { Stop-SpxError 'Spx.PendingRecovery' "App '$appName' has pending recovery." $appName }
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) {
                Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName
            }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", "relocate to '$Destination'")) {
                Invoke-SpxMutation {
                    $admitted = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                    if (-not $admitted) {
                        Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName
                    }
                    Invoke-SpxLinkChange -Snapshot $admitted -Action Move -Destination $Destination
                }
            }
        }
    }
}


function Restore-SpxApp {
    <#
    .SYNOPSIS
    Restores an SPX-relocated app to its canonical Scoop apps directory.
    .DESCRIPTION
    Copies and verifies relocated versions back into Scoop, restores persist references, commits
    configuration removal, and retains the relocated data as a recorded non-active copy.
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
            if (Read-SpxOperation link ($Scope.ToLowerInvariant() + '-' + $appName)) { Stop-SpxError 'Spx.PendingRecovery' "App '$appName' has pending recovery." $appName }
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
            Invoke-SpxMutation {
                $admitted = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                if (-not $admitted -or -not $admitted.LinkEntry) {
                    Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is no longer a managed link." $appName
                }
                Invoke-SpxLinkChange -Snapshot $admitted -Action Restore
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
            $known = @(Get-SpxLinkNames $currentScope $cfg)
            $names = if ($Name) { @($Name | Where-Object { $_ -in $known }) } else { $known }
            foreach ($appName in $names) {
                $view = Get-SpxLinkObservation $appName $currentScope $cfg
                Add-SpxTypeName ($view | Select-Object * -ExcludeProperty Snapshot) 'SPX.LinkedApp'
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
    Optional managed app names. When omitted, synchronizes active destinations and imported intent in the scope.
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
            @($cfg[$key].Keys | Where-Object { $cfg[$key][$_].Active -or $cfg[$key][$_].Intent })
        }
        foreach ($appName in $names) {
            if (-not $cfg[$key].Contains($appName) -or (-not $cfg[$key][$appName].Active -and -not $cfg[$key][$appName].Intent)) {
                Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is not managed by SPX." $appName
            }
            if (Read-SpxOperation link ($Scope.ToLowerInvariant() + '-' + $appName)) { Stop-SpxError 'Spx.PendingRecovery' "App '$appName' has pending recovery." $appName }
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) {
                continue
            }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", 'synchronize relocated versions')) {
                Invoke-SpxMutation {
                    $freshConfig = Get-LinksConfig
                    if (-not $freshConfig[$key].Contains($appName) -or (-not $freshConfig[$key][$appName].Active -and -not $freshConfig[$key][$appName].Intent)) {
                        Stop-SpxError 'Spx.LinkNotFound' "App '$appName' is no longer managed by SPX." $appName
                    }
                    $fresh = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                    if ($fresh) {
                        Invoke-SpxLinkChange -Snapshot $fresh -Action Move -Destination $(if ($freshConfig[$key][$appName].Active) { $freshConfig[$key][$appName].Active.Path } else { $freshConfig[$key][$appName].Intent.Path })
                    }
                }
            }
        }
    }
}


function Repair-SpxLinkedApp {
    <#
    .SYNOPSIS
    Recovers interrupted SPX app relocation, restore, or retained-copy reclamation.
    .DESCRIPTION
    Uses durable operation data plus observed paths and fingerprints to roll forward a committed
    operation or restore its safe pre-state. Reclamation resumes only unchanged entries from the
    immutable deletion inventory. It refuses ambiguous or changed evidence.
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
        $cfg = Get-LinksConfig
        $names = if ($Name) { @($Name) } else { @(Get-SpxLinkNames $Scope $cfg) }
        foreach ($appName in $names) {
            $key = $Scope.ToLowerInvariant() + '-' + $appName
            $pending = Read-SpxOperation link $key
            if (-not $pending) { continue }
            $repairAction = if ($pending.action -eq 'Reclaim') { 'resume verified retained-copy reclamation' } else { 'recover layout while retaining other copies' }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", $repairAction)) {
                Invoke-SpxMutation {
                    $op = Read-SpxOperation link $key
                    if (-not $op) { return }
                    if ($op.id -ne $pending.id) { Stop-SpxError 'Spx.StateChanged' 'Pending operation changed before repair; inspect and retry.' $appName }
                    $result = if ($op.action -eq 'Reclaim') { Invoke-SpxReclaimRecovery $op } else { Invoke-SpxLinkRecovery $op }
                    Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Scope = $Scope; Status = $result; Changed = $true; Destination = $op.destination; Versions = @($op.versions.name); OperationId = $op.id; RetainedCopies = @((Get-SpxLinkRecord $appName $Scope).Retained) }) 'SPX.LinkedAppRepairResult'
                }
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
                Invoke-SpxMutation {
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
                    $record = $freshConfig[$scopeKey][$appName]
                    $retained = @()
                    if ($record.Active) {
                        $target = Join-Path $record.Active.Path $appName
                        if (Test-Path -LiteralPath $target) { $retained = @([ordered]@{ Id = ('stale:' + $appName); Path = $target; Role = 'stale'; OperationId = $record.Active.OperationId; Version = $record.Active.Version }) }
                    }
                    Update-LinkEntry -Name $appName -Scope $Scope -Remove -Retained $retained
                    Add-SpxTypeName ([pscustomobject]@{Name = $appName; Scope = $Scope; Status = 'Removed'; Changed = $true }) 'SPX.StaleLinkRemovalResult'
                }
            }
        }
    }
}



function Assert-SpxRetainedOwnership {
    param ($Copy, [string]$Name, [string]$Scope)
    Assert-SpxName ([string]$Copy.OperationId) 'retained operation'
    Assert-SpxName ([string]$Copy.Version) 'retained version'
    if ($Copy.Role -notin 'backup', 'target', 'stage' -or $Copy.Id -ne ($Copy.OperationId + ':' + $Copy.Version + ':' + $Copy.Role) -or [string]$Copy.Fingerprint -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Copy has no version ownership and fingerprint.' }
    $ctx = Get-SpxContext
    $canonicalApp = Join-Path $(if ($Scope -eq 'Global') { $ctx.GlobalApps } else { $ctx.LocalApps }) $Name
    $path = [IO.Path]::GetFullPath([string]$Copy.Path)
    $parent = [IO.Path]::GetDirectoryName($path); $leaf = [IO.Path]::GetFileName($path)
    $isCanonical = $parent -eq $canonicalApp
    if ($Copy.Role -eq 'backup') {
        if (-not $isCanonical -or $leaf -ne ('.spx-backup-' + $Copy.OperationId + '-' + $Copy.Version)) { throw 'Copy backup path does not match its owner.' }
    }
    else {
        if ($Copy.Role -eq 'stage') {
            $prefix = if ($isCanonical) { '.spx-restore-' } else { '.spx-staging-' }
            if ($leaf -ne ($prefix + $Copy.OperationId + '-' + $Copy.Version)) { throw 'Copy stage path does not match its owner.' }
        }
        elseif ($isCanonical -or $leaf -ne $Copy.Version) { throw 'Copy target path does not match its version.' }
        if (-not $isCanonical) {
            if ([IO.Path]::GetFileName($parent) -ne $Name) { throw 'Copy target app identity differs.' }
            $null = Resolve-SpxDestination ([IO.Path]::GetDirectoryName($parent))
        }
    }
    foreach ($relative in @($Copy.Exclude)) { Assert-SpxRelativePath $relative 'copy persist path' }
    Assert-SpxPlainPath $path
    $config = Get-LinksConfig
    foreach ($scopeKey in 'local', 'global') {
        foreach ($otherName in $config[$scopeKey].Keys) {
            $active = $config[$scopeKey][$otherName].Active
            if ($active) {
                $activeRoot = Join-Path $active.Path $otherName
                if ((Test-SpxPathWithin $path $activeRoot) -or (Test-SpxPathWithin $activeRoot $path)) { throw 'Copy overlaps an active SPX destination.' }
            }
        }
    }
}

function Get-SpxReclaimEntry {
    param ($Item, [string]$Root, $Persist, [string]$PersistRoot)
    $relative = $Item.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
    $kind = if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'Link' } elseif ($Item.PSIsContainer) { 'Directory' } else { 'File' }
    if ($kind -ne 'Link') { Assert-SpxReclaimStreams $Item.FullName }
    $target = $null
    if ($kind -eq 'Link') {
        $resolved = Get-SpxItemLinkTarget $Item
        $definition = @($Persist | Where-Object { $_.Source.Replace('\', '/') -eq $relative })
        if ($definition.Count -eq 1 -and $resolved -eq (Join-Path $PersistRoot $definition[0].Target)) { $target = 'persist:' + $definition[0].Target.Replace('\', '/') }
        elseif ($resolved -and (Test-SpxPathWithin $resolved $Root)) { $target = 'internal:' + $resolved.Substring($Root.Length).TrimStart('\').Replace('\', '/') }
        else { throw "Unowned reparse target: $($Item.FullName)" }
    }
    [ordered]@{ Relative = $relative; Kind = $kind; Directory = [bool]$Item.PSIsContainer; Hash = $(if ($kind -eq 'File') { Get-SpxFileFingerprint $Item.FullName }); Target = $target; LinkType = $(if ($kind -eq 'Link') { [string]$Item.LinkType }) }
}



function Assert-SpxReclaimReferences {
    param ([string]$Path)
    $ctx = Get-SpxContext; $config = Get-LinksConfig
    $roots = @($ctx.LocalApps, $ctx.GlobalApps, $ctx.LocalPersist, $ctx.GlobalPersist)
    foreach ($scopeKey in 'local', 'global') {
        foreach ($name in $config[$scopeKey].Keys) {
            if ($config[$scopeKey][$name].Active) { $roots += Join-Path $config[$scopeKey][$name].Active.Path $name }
        }
    }
    foreach ($root in @($roots | Select-Object -Unique)) {
        if (-not(Test-Path -LiteralPath $root)) { continue }
        $exclude = @()
        if (Test-SpxPathWithin $Path $root) { $exclude = @($Path.Substring($root.TrimEnd('\').Length).TrimStart('\')) }
        foreach ($item in Get-SpxTreeEntries $root -ExcludeRelative $exclude) {
            if (-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $target = Get-SpxItemLinkTarget $item
            if ($target -and ((Test-SpxPathWithin $target $Path) -or (Test-SpxPathWithin $Path $target))) { throw "Managed reference still reaches the retained copy: $($item.FullName)" }
        }
    }
}

function Get-SpxReclaimInventory {
    param ($Plan, $Snapshot)
    $root = [IO.Path]::GetFullPath([string]$Plan.copy.Path).TrimEnd('\')
    $alternative = [IO.Path]::GetFullPath([string]$Plan.alternative).TrimEnd('\')
    $version = @($Snapshot.Versions | Where-Object { $_.Name -eq $Plan.copy.Version })
    if ($version.Count -ne 1 -or $version[0].DataPath -ne $alternative -or (Test-SpxPathWithin $root $alternative) -or (Test-SpxPathWithin $alternative $root)) { throw 'Active alternative changed or overlaps the copy.' }
    Assert-SpxPlainPath $alternative
    if ((Get-SpxTreeFingerprint $alternative -ExcludeRelative $Plan.copy.Exclude) -ne $Plan.copy.Fingerprint) { throw 'Active alternative no longer matches the version fingerprint.' }
    $persist = @(Get-SpxPersistDefinitions $version[0].Manifest)
    if ((@($persist.Source | Sort-Object) -join '|') -ne (@($Plan.copy.Exclude | Sort-Object) -join '|')) { throw 'Persist definitions differ from the retained version evidence.' }
    foreach ($definition in $persist) {
        $link = Join-Path $alternative $definition.Source
        $target = Join-Path $Snapshot.PersistPath $definition.Target
        if (-not(Test-Path -LiteralPath $link) -and -not(Test-Path -LiteralPath $target)) { continue }
        if ((Get-SpxLinkTarget $link) -ne $target) { throw 'Active persist reference differs from the admitted manifest.' }
        Assert-SpxPlainPath $target
    }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return }
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Retained root is not a plain directory.' }
    Assert-SpxReclaimStreams $root
    foreach ($item in Get-SpxTreeEntries $root) {
        $entry = Get-SpxReclaimEntry $item $root $persist $Snapshot.PersistPath
        $otherPath = Join-Path $alternative $entry.Relative
        # Persist content is compared to the scoped persist tree, never followed through a copy link.
        if ($entry.Kind -ne 'Link') {
            foreach ($definition in $persist) {
                $source = $definition.Source.Replace('\', '/')
                if ($entry.Relative -eq $source -or $entry.Relative.StartsWith($source + '/', [StringComparison]::OrdinalIgnoreCase)) {
                    $otherRoot = Join-Path $Snapshot.PersistPath $definition.Target
                    $suffix = $entry.Relative.Substring($source.Length).TrimStart('/')
                    $otherPath = if ($suffix) { Join-Path $otherRoot $suffix } else { $otherRoot }
                    break
                }
            }
        }
        if ($entry.Kind -ne 'Link') { Assert-SpxPlainPath $otherPath }
        $other = Get-Item -LiteralPath $otherPath -Force -ErrorAction Stop
        if ($entry.Kind -eq 'Link') {
            $otherEntry = Get-SpxReclaimEntry $other $alternative $persist $Snapshot.PersistPath
            if (($entry | ConvertTo-Json -Compress) -cne ($otherEntry | ConvertTo-Json -Compress)) { throw "Link has no equivalent active reference: $($entry.Relative)" }
        }
        elseif (($other.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [bool]$other.PSIsContainer -ne [bool]$entry.Directory -or ($entry.Kind -eq 'File' -and $entry.Hash -ne (Get-SpxFileFingerprint $otherPath))) { throw "Copy contains unique or changed content: $($entry.Relative)" }
        $entry
    }
}

function Assert-SpxReclaimOperation {
    param ($Operation)
    if ([string]$Operation.schema -ne '2' -or $Operation.phase -ne 'Prepared' -or $Operation.copies -isnot [Collections.IList] -or -not $Operation.copies.Count) { throw 'Invalid reclaim journal.' }
    $ids = @{}
    foreach ($plan in $Operation.copies) {
        Assert-SpxRetainedOwnership $plan.copy $Operation.name $Operation.scope
        if (-not(Test-SpxAbsolutePath $plan.alternative) -or $plan.entries -isnot [Collections.IList] -or $ids.ContainsKey([string]$plan.copy.Id)) { throw 'Invalid reclaim copy evidence.' }
        $ids[[string]$plan.copy.Id] = $true
        $paths = @{}
        foreach ($entry in $plan.entries) {
            Assert-SpxRelativePath ([string]$entry.Relative) 'reclaim entry'
            if ($entry.Kind -notin 'Directory', 'File', 'Link' -or $paths.ContainsKey([string]$entry.Relative) -or ($entry.Kind -eq 'File' -and [string]$entry.Hash -notmatch '^[A-Fa-f0-9]{64}$')) { throw 'Invalid immutable reclaim inventory.' }
            $paths[[string]$entry.Relative] = $true
        }
    }
}

function Invoke-SpxReclaimRecovery {
    param ($Operation)
    $record = Get-SpxLinkRecord $Operation.name $Operation.scope
    $snapshot = Get-SpxAppSnapshot $Operation.name $Operation.scope
    if (-not $snapshot) { Stop-SpxError 'Spx.RecoveryConflict' 'No active installed alternative; preserved reclaim journal.' $Operation.name }
    foreach ($plan in $Operation.copies) {
        Assert-SpxRetainedOwnership $plan.copy $Operation.name $Operation.scope
        $owned = @($record.Retained | Where-Object { $_.Id -eq $plan.copy.Id })
        if (-not $owned.Count) {
            if ($record.LastOperation.Id -ne $Operation.id -or $record.LastOperation.Outcome -ne 'Committed' -or (Test-Path -LiteralPath $plan.copy.Path)) { Stop-SpxError 'Spx.RecoveryConflict' 'Copy ownership changed; preserved reclaim journal.' $Operation.name }
            continue
        }
        if (($owned[0] | ConvertTo-Json -Depth 10 -Compress) -cne ($plan.copy | ConvertTo-Json -Depth 10 -Compress)) { Stop-SpxError 'Spx.RecoveryConflict' 'Retained record differs from the reclaim journal.' $Operation.name }
        $inventory = @{}
        foreach ($entry in $plan.entries) { $inventory[[string]$entry.Relative] = $entry }
        try {
            Assert-SpxReclaimReferences $plan.copy.Path
            $remaining = @(Get-SpxReclaimInventory $plan $snapshot)
            foreach ($entry in $remaining) {
                if (-not $inventory.ContainsKey([string]$entry.Relative) -or ($entry | ConvertTo-Json -Compress) -cne ($inventory[[string]$entry.Relative] | ConvertTo-Json -Compress)) { throw 'Copy has new or changed entries after reclamation began.' }
            }
        }
        catch { Stop-SpxError 'Spx.RecoveryConflict' $_.Exception.Message $plan.copy.Path }
        $version = @($snapshot.Versions | Where-Object { $_.Name -eq $plan.copy.Version })[0]
        $persist = @(Get-SpxPersistDefinitions $version.Manifest)
        foreach ($entry in @($remaining | Sort-Object { $_.Relative.Length } -Descending)) {
            $path = Join-Path $plan.copy.Path $entry.Relative
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $fresh = Get-SpxReclaimEntry $item $plan.copy.Path $persist $snapshot.PersistPath
            if (($fresh | ConvertTo-Json -Compress) -cne ($entry | ConvertTo-Json -Compress)) { Stop-SpxError 'Spx.RecoveryConflict' 'Copy changed immediately before deletion.' $path }
            Remove-SpxReclaimEntry $path $entry
        }
        if (Test-Path -LiteralPath $plan.copy.Path) { Remove-SpxReclaimEntry $plan.copy.Path @{ Kind = 'Directory'; Directory = $true } }
    }
    Update-LinkEntry -Name $Operation.name -Scope $Operation.scope -Entry $record.Active -Intent $record.Intent -RemoveRetained @($Operation.copies.copy.Id) -OperationId $Operation.id -Action Reclaim -Outcome Committed
    Remove-SpxOperation link ($Operation.scope.ToLowerInvariant() + '-' + $Operation.name)
    'Completed'
}

function Remove-SpxReclaimEntry {
    param ([string]$Path, $Entry)
    # Never recurse; a newly introduced child prevents directory deletion.
    if ($Entry.Kind -ne 'Link') {
        $attributes = [IO.File]::GetAttributes($Path)
        [IO.File]::SetAttributes($Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
    }
    if ($Entry.Directory) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::Delete($Path) }
}

function Get-SpxReclaimSelection {
    param ([string]$AppName, [string]$Scope, [string[]]$CopyId)
    $record = Get-SpxLinkRecord $appName $Scope
    $snapshot = Get-SpxAppSnapshot $appName $Scope
    $plans = @(); $blocked = @()
    foreach ($copy in @($record.Retained | Where-Object { -not $CopyId -or $_.Id -in $CopyId })) {
        try {
            Assert-SpxRetainedOwnership $copy $appName $Scope
            Assert-SpxReclaimReferences $copy.Path
            if (-not $snapshot -or -not(Test-Path -LiteralPath $copy.Path)) { throw 'Copy or active installed alternative is missing.' }
            if ($copy.Role -ne 'stage' -and (Get-SpxTreeFingerprint $copy.Path -ExcludeRelative $copy.Exclude) -ne $copy.Fingerprint) { throw 'Retained copy changed since the recorded version baseline.' }
            $version = @($snapshot.Versions | Where-Object { $_.Name -eq $copy.Version })
            if ($version.Count -ne 1) { throw 'No installed alternative for this version.' }
            $plan = [ordered]@{ copy = $copy; alternative = $version[0].DataPath; entries = @() }
            $plan.entries = @(Get-SpxReclaimInventory $plan $snapshot)
            $plans += $plan
        }
        catch { $blocked += [pscustomobject]@{ Id = $copy.Id; Path = $copy.Path; Reason = $_.Exception.Message } }
    }
    [pscustomobject]@{ Plans = @($plans); BlockedCopies = @($blocked) }
}

function Remove-SpxRetainedCopy {
    <#
    .SYNOPSIS
    Reclaims recorded inactive copies with a verified active alternative.
    .DESCRIPTION
    Keeps changed, unique, unowned, and ambiguous copies. Writes an immutable deletion inventory
    before removing entries without recursion. Repair-SpxLinkedApp resumes an interrupted reclaim.
    .PARAMETER Name
    Installed app names whose recorded retained copies should be inspected.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .PARAMETER CopyId
    Optional retained identities. Omit to inspect all retained copies for each app.
    .OUTPUTS
    SPX.RetainedCopyRemovalResult with Removed and BlockedCopies collections.
    .EXAMPLE
    Remove-SpxRetainedCopy jq -Scope Local -WhatIf
    .NOTES
    Stop external writers while comparing and deleting. There is no Force bypass.
    WhatIf publishes read-only qualification evidence on the information stream.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local', [string[]]$CopyId)
    process {
        foreach ($appName in $Name) {
            Assert-SpxName $appName 'app'
            $key = $Scope.ToLowerInvariant() + '-' + $appName
            if (Read-SpxOperation link $key) { Stop-SpxError 'Spx.PendingRecovery' 'Repair the pending app operation before reclamation.' $appName }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", 'reclaim equivalent retained copies')) {
                Invoke-SpxMutation {
                    if (Read-SpxOperation link $key) { Stop-SpxError 'Spx.PendingRecovery' 'Repair the pending app operation before reclamation.' $appName }
                    $selection = Get-SpxReclaimSelection $appName $Scope $CopyId
                    $plans = @($selection.Plans); $blocked = @($selection.BlockedCopies)
                    $operation = $null
                    if ($plans.Count) {
                        $operation = [ordered]@{ schema = 2; id = [guid]::NewGuid().ToString('N'); kind = 'link'; action = 'Reclaim'; phase = 'Prepared'; name = $appName; scope = $Scope; copies = @($plans) }
                        $null = Write-SpxOperation link $key $operation
                        $null = Invoke-SpxReclaimRecovery $operation
                    }
                    Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Scope = $Scope; Status = $(if ($plans.Count -and $blocked.Count) { 'PartiallyReclaimed' } elseif ($plans.Count) { 'Reclaimed' } elseif ($blocked.Count) { 'Blocked' } else { 'Unchanged' }); Changed = [bool]$plans.Count; Removed = @($plans | ForEach-Object { $_.copy.Id }); BlockedCopies = @($blocked); OperationId = $operation.id }) 'SPX.RetainedCopyRemovalResult'
                }
            }
            elseif ($WhatIfPreference) {
                $selection = Get-SpxReclaimSelection $appName $Scope $CopyId
                $preview = [pscustomobject]@{ Name = $appName; Scope = $Scope; Status = 'Preview'; Changed = $false; EligibleCopies = @($selection.Plans | ForEach-Object { $_.copy }); BlockedCopies = @($selection.BlockedCopies) }
                Write-Information -MessageData (Add-SpxTypeName $preview 'SPX.RetainedCopyPreview')
            }
        }
    }
}

function Export-LinksConfig {
    param ([string]$Path)
    Invoke-SpxMutation {
        $cfg = Get-LinksConfig
        $portable = [ordered]@{ schema = 1; generation = $cfg.generation; local = [ordered]@{}; global = [ordered]@{} }
        foreach ($scope in 'local', 'global') {
            foreach ($name in $cfg[$scope].Keys) {
                $record = $cfg[$scope][$name]
                $entry = if ($record.Active) { $record.Active } else { $record.Intent }
                if ($entry) { $portable[$scope][$name] = [ordered]@{ Path = $entry.Path; Version = $entry.Version; Versions = @($entry.Versions); State = 'Imported' } }
            }
        }
        Write-SpxJsonFileAtomic ([IO.Path]::GetFullPath($Path)) $portable
    }
}

function Import-LinksConfig {
    param ([string]$Path, [switch]$Merge)
    $imported = Read-SpxJsonFile ([IO.Path]::GetFullPath($Path))
    if ($imported -isnot [Collections.IDictionary] -or ($imported.Contains('schema') -and [string]$imported.schema -ne '1')) { throw [IO.InvalidDataException]::new('Unsupported portable links format.') }
    foreach ($scope in 'local', 'global') {
        if ($imported[$scope] -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("Invalid imported scope '$scope'.") }
        $imported[$scope] = ConvertTo-SpxNameMap $imported[$scope]
        foreach ($name in $imported[$scope].Keys) {
            Assert-SpxName ([string]$name)
            $entry = $imported[$scope][$name]
            if ($entry -isnot [Collections.IDictionary] -or -not $entry.Path -or -not (Test-SpxAbsolutePath $entry.Path)) { throw [IO.InvalidDataException]::new("Invalid imported link '$name'.") }
        }
    }
    Invoke-SpxMutation {
        $cfg = Get-LinksConfig
        foreach ($scope in 'local', 'global') {
            foreach ($name in @(@($cfg[$scope].Keys) + @($imported[$scope].Keys | Where-Object { -not $cfg[$scope].Contains([string]$_) }))) {
                $record = Get-SpxLinkRecord $name $scope $cfg
                $entry = $imported[$scope][$name]
                if (Read-SpxOperation link ($scope + '-' + $name)) { Stop-SpxError 'Spx.PendingRecovery' "Repair '$name' before importing intent." $name }
                if ($record.Active -and ((-not $entry -and -not $Merge) -or ($entry -and [IO.Path]::GetFullPath([string]$entry.Path) -ne [IO.Path]::GetFullPath([string]$record.Active.Path)))) {
                    Stop-SpxError 'Spx.AlreadyLinkedElsewhere' "Import cannot replace active ownership of '$name'. Restore it first." $name
                }
                if ($entry) { $record.Intent = [ordered]@{ Path = $entry.Path; Version = $entry.Version; Versions = @($entry.Versions); State = 'Imported' } }
                elseif (-not $Merge) { $record.Intent = $null }
                $cfg[$scope][$name] = $record
            }
        }
        $cfg.generation = [int64]$cfg.generation + 1
        Write-SpxJsonFileAtomic (Get-SpxConfigFile 'links.json') $cfg -RetainPrevious
    }
}

function Export-SpxLinkConfiguration {
    <#
    .SYNOPSIS
    Atomically exports portable link intent.
    .DESCRIPTION
    Exports portable destinations and intent atomically; ownership and retained-copy authority stay in SPX state.
    .PARAMETER Path
    Destination file path outside SPX state storage.
    .PARAMETER Force
    Allows replacement when the destination already exists.
    .OUTPUTS
    SPX.LinkConfigurationExportResult.
    .EXAMPLE
    Export-SpxLinkConfiguration -Path '.\spx-links.json' -Force -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][string]$Path, [switch]$Force)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-SpxPathWithin $fullPath (Get-SpxContext).ConfigRoot) { Stop-SpxError 'Spx.ExportStateConflict' 'Export outside SPX state storage so portable intent cannot overwrite ownership or recovery records.' $fullPath }
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) { Stop-SpxError 'Spx.ExportExists' "Export path already exists: $fullPath" $fullPath }
    if ($PSCmdlet.ShouldProcess($fullPath, 'export SPX link configuration')) {
        Export-LinksConfig -Path $fullPath
        Add-SpxTypeName ([pscustomobject]@{ Path = $fullPath; Status = 'Exported'; Changed = $true }) 'SPX.LinkConfigurationExportResult'
    }
}

function Import-SpxLinkConfiguration {
    <#
    .SYNOPSIS
    Atomically replaces or merges a validated SPX link configuration.
    .DESCRIPTION
    Reads and validates an exported configuration, then atomically replaces current link intent or
    merges its entries. It records intent only and does not relocate app files.
    .PARAMETER Path
    Existing configuration export to import.
    .PARAMETER Merge
    Merges entries instead of replacing the complete link configuration.
    .OUTPUTS
    SPX.LinkConfigurationImportResult.
    .EXAMPLE
    Import-SpxLinkConfiguration -Path '.\spx-links.json' -Merge -WhatIf
    .NOTES
    Inspect with Get-SpxLinkedApp, then use Sync-SpxLinkedApp or Repair-SpxLinkedApp as indicated.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory)][string]$Path, [switch]$Merge)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { Stop-SpxError 'Spx.ImportNotFound' "Import path was not found: $fullPath" $fullPath }
    if ($PSCmdlet.ShouldProcess($fullPath, $(if ($Merge) { 'merge SPX link configuration' } else { 'replace SPX link configuration' }))) {
        Import-LinksConfig -Path $fullPath -Merge:$Merge
        Add-SpxTypeName ([pscustomobject]@{ Path = $fullPath; Status = $(if ($Merge) { 'Merged' } else { 'Imported' }); Changed = $true }) 'SPX.LinkConfigurationImportResult'
    }
}
