#Requires -Module Pester

Describe 'SPX reclaim and source recovery after process termination' {
    BeforeAll {
        . "$PSScriptRoot/TestSupport.ps1"
        $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $child = Join-Path $TestDrive 'interrupt-source-reclaim.ps1'
        @'
param ($Repository, $Root, $Action, $Boundary)
$ErrorActionPreference = 'Stop'
. "$Repository/tests/TestSupport.ps1"
$null = Enter-SpxTestSandbox $Root
Import-Module "$Repository/SPX.psd1" -Force
& (Get-Module SPX) {
    param ($Boundary, $Marker)
    $script:Boundary = $Boundary; $script:Marker = $Marker
    function script:Stop-SpxChild {
        [IO.File]::WriteAllText($script:Marker, $script:Boundary)
        Stop-Process -Id $PID -Force
    }
    foreach ($command in 'Write-SpxOperation', 'Remove-SpxReclaimEntry', 'Update-LinkEntry', 'Remove-SpxOperation', 'Invoke-SpxGit', 'Save-SpxMirrorOutcome') {
        Set-Variable -Scope Script -Name ('Real' + $command.Replace('-', '')) -Value (Get-Command $command).ScriptBlock
    }
    function script:Write-SpxOperation {
        param ($Kind, $Key, $Value)
        & $script:RealWriteSpxOperation @PSBoundParameters
        if ($script:Boundary -eq 'Prepared' -and $Value.phase -eq 'Prepared') { Stop-SpxChild }
    }
    function script:Remove-SpxReclaimEntry {
        param ($Path, $Entry)
        & $script:RealRemoveSpxReclaimEntry @PSBoundParameters
        if ($script:Boundary -eq 'EntryDeleted' -or ($script:Boundary -eq 'RootDeleted' -and (Split-Path $Path -Leaf) -like '.spx-backup-*')) { Stop-SpxChild }
    }
    function script:Update-LinkEntry {
        param ($Name, $Scope, $Entry, [switch]$Remove, $Retained, $Intent, $OperationId, $Action, $Outcome, $RemoveRetained)
        & $script:RealUpdateLinkEntry @PSBoundParameters
        if ($script:Boundary -eq 'Committed') { Stop-SpxChild }
    }
    function script:Invoke-SpxGit {
        param ($BucketPath, $Arguments)
        & $script:RealInvokeSpxGit @PSBoundParameters
        if ($script:Boundary -eq 'GitChanged' -and $Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'set-url') { Stop-SpxChild }
    }
    function script:Save-SpxMirrorOutcome {
        param ($Operation, $Committed)
        & $script:RealSaveSpxMirrorOutcome @PSBoundParameters
        if ($script:Boundary -eq 'Committed') { Stop-SpxChild }
    }
    function script:Remove-SpxOperation {
        param ($Kind, $Key)
        & $script:RealRemoveSpxOperation @PSBoundParameters
        if ($script:Boundary -eq 'Settled') { Stop-SpxChild }
    }
} $Boundary (Join-Path $Root 'crash-reached')
if ($Action -eq 'Reclaim') { Remove-SpxRetainedCopy crash -Confirm:$false }
else { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false }
throw 'Requested interruption was not reached.'
'@ | Set-Content -LiteralPath $child -Encoding UTF8
    }
    BeforeEach {
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }
    AfterEach { Exit-SpxTestSandbox }

    It 'recovers <Action> at <Boundary> without deleting active data or rewriting Git' -ForEach @(
        foreach ($boundary in 'Prepared', 'EntryDeleted', 'RootDeleted', 'Committed', 'Settled') { @{ Action = 'Reclaim'; Boundary = $boundary } }
        foreach ($boundary in 'Prepared', 'GitChanged', 'Committed', 'Settled') { @{ Action = 'Mirror'; Boundary = $boundary } }
    ) {
        if ($Action -eq 'Reclaim') {
            $app = New-SpxTestApp crash -Version 1
            Move-SpxApp crash (Join-Path $sb.Root 'destination') -Confirm:$false | Out-Null
            $copy = (Get-SpxLinkedApp crash -Scope Local).RetainedCopies[0]
        }
        else { New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null }
        $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + $child + '"'), '-Repository', ('"' + $repository + '"'), '-Root', ('"' + $sb.Root + '"'), '-Action', $Action, '-Boundary', $Boundary)
        $process = Start-Process (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $sb.Root 'child.out') -RedirectStandardError (Join-Path $sb.Root 'child.err') -PassThru
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Child timed out.' }
        $process.ExitCode | Should -Not -Be 0
        if (-not(Test-Path -LiteralPath (Join-Path $sb.Root 'crash-reached'))) { throw ((Get-Content (Join-Path $sb.Root 'child.out') -Raw) + (Get-Content (Join-Path $sb.Root 'child.err') -Raw)) }
        [IO.File]::ReadAllText((Join-Path $sb.Root 'crash-reached')) | Should -Be $Boundary
        [IO.File]::ReadAllText((Join-Path $sb.Root 'child.err')) | Should -Not -Match 'interruption was not reached|ParserError|CommandNotFound'
        if ($Action -eq 'Reclaim') {
            Repair-SpxLinkedApp crash -Confirm:$false | Out-Null
            Test-Path -LiteralPath $copy.Path | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $app.VersionPath 'payload.txt')) | Should -Be payload-crash-1
            @(Repair-SpxLinkedApp crash -Confirm:$false).Count | Should -Be 0
        }
        else {
            $remote = (Get-SpxBucketMirror main).CurrentUrl
            if ($Boundary -ne 'Settled') { Repair-SpxBucketMirror main -Confirm:$false | Out-Null }
            (Get-SpxBucketMirror main).CurrentUrl | Should -Be $remote
            (Get-SpxBucketMirror main).IsMirrored | Should -Be ($Boundary -ne 'Prepared')
            { Repair-SpxBucketMirror main -Confirm:$false } | Should -Throw -ErrorId 'Spx.NoPendingRecovery*'
        }
    }
}

Describe 'SPX non-destructive recovery' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
    BeforeEach {
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $destination = Join-Path $sb.Root 'destination'
    }
    AfterEach { Exit-SpxTestSandbox }

    It 'preserves writes after cutover when the configuration commit fails' {
        $app = New-SpxTestApp -Name demo -Version 1
        & (Get-Module SPX) {
            $script:RealJournal = (Get-Command Write-SpxOperation).ScriptBlock
            function script:Write-SpxOperation {
                param ($Kind, $Key, $Value)
                if ($Value.phase -eq 'Linked') {
                    [IO.File]::WriteAllText((Join-Path $Value.destination 'demo\1\new.txt'), 'unique-write')
                    throw 'Injected failure after cutover'
                }
                & $script:RealJournal @PSBoundParameters
            }
        }
        { Move-SpxApp demo $destination -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText((Join-Path $destination 'demo\1\new.txt')) | Should -Be unique-write
        Test-Path (Join-Path $env:SCOOP 'spx\operations\link\local-demo.json') | Should -BeTrue
        (Get-SpxStatus demo -Scope Local).Status | Should -Be NeedsRecovery
        { Repair-SpxLinkedApp demo -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryConflict*'
        [IO.File]::ReadAllText((Join-Path $destination 'demo\1\new.txt')) | Should -Be unique-write
    }

    It 'restores contained junction topology and records the other copy during automatic rollback' {
        $app = New-SpxTestApp -Name demo -Version 1
        $real = Join-Path $app.VersionPath 'real'; $null = New-Item -ItemType Directory -Path $real
        [IO.File]::WriteAllText((Join-Path $real 'inside.txt'), 'inside')
        $null = New-Item -ItemType Junction -Path (Join-Path $app.VersionPath 'alias') -Target $real
        & (Get-Module SPX) {
            $script:RealJournal = (Get-Command Write-SpxOperation).ScriptBlock
            function script:Write-SpxOperation {
                param ($Kind, $Key, $Value)
                if ($Value.phase -eq 'Linked') { throw 'Injected failure after cutover' }
                & $script:RealJournal @PSBoundParameters
            }
        }
        { Move-SpxApp demo $destination -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'alias\inside.txt')) | Should -Be inside
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        Test-Path (Join-Path $env:SCOOP 'spx\operations\link\local-demo.json') | Should -BeFalse
        (Get-SpxLinkedApp demo -Scope Local).RetainedCopies.Count | Should -Be 1
        @(Repair-SpxLinkedApp demo -Confirm:$false).Count | Should -Be 0
    }

    It 'recognizes a durable commit even when its acknowledgement is lost' {
        $app = New-SpxTestApp -Name demo -Version 1
        & (Get-Module SPX) {
            $script:RealCommit = (Get-Command Update-LinkEntry).ScriptBlock
            $script:FailCommitOnce = $true
            function script:Update-LinkEntry {
                param ($Name, $Scope, $Entry, [switch]$Remove, $Retained, $Intent, $OperationId, $Action, $Outcome)
                & $script:RealCommit @PSBoundParameters
                if ($script:FailCommitOnce) { $script:FailCommitOnce = $false; throw 'Commit acknowledgement lost' }
            }
        }
        { Move-SpxApp demo $destination -Confirm:$false } | Should -Throw -ErrorId 'Spx.CommittedCleanupPending*'
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        (Get-SpxLinkedApp demo -Scope Local).State | Should -Be PendingRecovery
        (Repair-SpxLinkedApp demo -Confirm:$false).Status | Should -Be Completed
        (Get-SpxLinkedApp demo -Scope Local).State | Should -Be Healthy
        (Get-SpxLinkedApp demo -Scope Local).RetainedCopies.Count | Should -Be 1
        @(Repair-SpxLinkedApp demo -Confirm:$false).Count | Should -Be 0
    }

    It 'keeps version-specific persist conflicts distinct and uses each installed manifest' {
        $v1 = New-SpxTestApp -Name demo -Version 1 -Persist @('settings.ini', 'old.ini')
        [IO.File]::WriteAllText((Join-Path $v1.VersionPath 'settings.ini'), 'one')
        [IO.File]::WriteAllText((Join-Path $v1.VersionPath 'old.ini'), 'old')
        [IO.Directory]::Delete($v1.CurrentPath, $false)
        $v2 = New-SpxTestApp -Name demo -Version 2 -Persist @('settings.ini', 'new.ini')
        [IO.File]::WriteAllText((Join-Path $v2.VersionPath 'settings.ini'), 'two')
        [IO.File]::WriteAllText((Join-Path $v2.VersionPath 'new.ini'), 'new')
        $persist = Join-Path $env:SCOOP 'persist\demo'; $null = New-Item -ItemType Directory -Path $persist -Force
        [IO.File]::WriteAllText((Join-Path $persist 'settings.ini'), 'active')
        $result = Move-SpxApp demo $destination -Confirm:$false
        @($result.Conflicts | Select-Object -Unique).Count | Should -Be 2
        @($result.Conflicts | ForEach-Object { [IO.File]::ReadAllText($_) } | Sort-Object) | Should -Be @('one', 'two')
        [IO.File]::ReadAllText((Join-Path $v1.VersionPath 'old.ini')) | Should -Be old
        [IO.File]::ReadAllText((Join-Path $v2.VersionPath 'new.ini')) | Should -Be new
        (Get-SpxLinkedApp demo -Scope Local).State | Should -Be Healthy
        Restore-SpxApp demo -Confirm:$false | Out-Null
        [IO.File]::ReadAllText((Join-Path $v1.VersionPath 'old.ini')) | Should -Be old
        [IO.File]::ReadAllText((Join-Path $v2.VersionPath 'new.ini')) | Should -Be new
    }

    It 'leaves restore, sync, import, export and repair previews byte-identical' {
        $app = New-SpxTestApp -Name demo -Version 1
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $importPath = Join-Path $sb.Root 'input.json'
        [IO.File]::WriteAllText($importPath, '{"local":{},"global":{}}')
        $config = Join-Path $env:SCOOP 'spx\links.json'; $before = [IO.File]::ReadAllBytes($config)
        $files = @(Get-ChildItem -LiteralPath $sb.Root -Recurse -Force).FullName
        $portable = Join-Path $sb.Root 'preview.json'
        Restore-SpxApp demo -WhatIf
        Sync-SpxLinkedApp demo -WhatIf
        Export-SpxLinkConfiguration $portable -WhatIf
        Import-SpxLinkConfiguration $importPath -WhatIf
        Repair-SpxLinkedApp demo -WhatIf
        [IO.File]::ReadAllBytes($config) | Should -Be $before
        @(Get-ChildItem -LiteralPath $sb.Root -Recurse -Force).FullName | Should -Be $files
        Test-Path -LiteralPath $portable | Should -BeFalse
    }
}

Describe 'SPX nested persist representation' {
    It 'preserves a nested source-target pair across JSON runtimes' {
        . "$PSScriptRoot/TestSupport.ps1"
        Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive 'pair')
        try {
            $app = New-SpxTestApp -Name demo -Version 1
            [IO.File]::WriteAllText((Join-Path $app.VersionPath 'manifest.json'), '{"version":"1","persist":[["data","renamed"]]}')
            $data = Join-Path $app.VersionPath 'data'; $null = New-Item -ItemType Directory -Path $data
            [IO.File]::WriteAllText((Join-Path $data 'state.txt'), 'paired-state')
            Move-SpxApp demo (Join-Path $sb.Root 'destination') -Confirm:$false | Out-Null
            [IO.File]::ReadAllText((Join-Path $env:SCOOP 'persist\demo\renamed\state.txt')) | Should -Be paired-state
            (Get-SpxLinkedApp demo -Scope Local).State | Should -Be Healthy
            Restore-SpxApp demo -Confirm:$false | Out-Null
            [IO.File]::ReadAllText((Join-Path $app.VersionPath 'data\state.txt')) | Should -Be paired-state
        }
        finally { Exit-SpxTestSandbox }
    }
}

Describe 'SPX recovery after abrupt process termination' {
    BeforeAll {
        . "$PSScriptRoot/TestSupport.ps1"
        $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $child = Join-Path $TestDrive 'interrupt.ps1'
        @'
param ($Repository, $Root, $Action, $Boundary, $Destination, [int]$InterruptAt)
$ErrorActionPreference = 'Stop'
. "$Repository/tests/TestSupport.ps1"
$null = Enter-SpxTestSandbox $Root
Import-Module "$Repository/SPX.psd1" -Force
& (Get-Module SPX) {
    param ($Boundary, $Marker, $InterruptAt)
    $script:Boundary = $Boundary
    $script:CrashMarker = $Marker
    $script:InterruptAt = $InterruptAt; $script:Hits = 0
    function script:Stop-SpxTestProcess {
        $script:Hits++
        if ($script:Hits -eq $script:InterruptAt) { [IO.File]::WriteAllText($script:CrashMarker, $script:Boundary); Stop-Process -Id $PID -Force }
    }
    foreach ($command in 'Write-SpxOperation', 'Copy-SpxTree', 'Move-SpxTree', 'Update-SpxMovedInternalLinks', 'New-SpxDirectoryJunction', 'New-SpxPersistReference', 'Remove-SpxLinkOnly', 'Update-LinkEntry', 'Remove-SpxOperation') {
        Set-Variable -Scope Script -Name ('Original' + $command.Replace('-', '')) -Value (Get-Command $command).ScriptBlock
    }
    function script:Write-SpxOperation {
        param ($Kind, $Key, $Value)
        & $script:OriginalWriteSpxOperation @PSBoundParameters
        if ($script:Boundary -eq 'Prepared' -and $Value.phase -eq 'Prepared') { Stop-SpxTestProcess }
    }
    function script:Copy-SpxTree {
        param ($Source, $Destination, $ExcludeRelative)
        & $script:OriginalCopySpxTree @PSBoundParameters
        if ($script:Boundary -eq 'Copied' -and (Split-Path $Destination -Leaf) -like '.spx-*') { Stop-SpxTestProcess }
    }
    function script:Move-SpxTree {
        param ($Source, $Destination, $ExcludeRelative)
        & $script:OriginalMoveSpxTree @PSBoundParameters
        if (($script:Boundary -eq 'Published' -and (Split-Path $Source -Leaf) -like '.spx-*') -or ($script:Boundary -eq 'Backup' -and (Split-Path $Destination -Leaf) -like '.spx-backup-*')) { Stop-SpxTestProcess }
    }
    function script:New-SpxDirectoryJunction {
        param ($Path, $Target)
        & $script:OriginalNewSpxDirectoryJunction @PSBoundParameters
        if ($script:Boundary -eq 'Linked' -and (Split-Path $Path -Leaf) -notin 'data', 'alias') { Stop-SpxTestProcess }
    }
    function script:Update-SpxMovedInternalLinks {
        param ($Root, $PreviousRoot, $ExcludeRelative)
        if ($script:Boundary -eq 'BeforeRebase' -and (Split-Path $Root -Leaf) -notlike '.spx-*') { Stop-SpxTestProcess }
        & $script:OriginalUpdateSpxMovedInternalLinks @PSBoundParameters
    }
    function script:New-SpxPersistReference {
        param ($Path, $Target)
        & $script:OriginalNewSpxPersistReference @PSBoundParameters
        if ($script:Boundary -eq 'PersistLinked') { Stop-SpxTestProcess }
    }
    function script:Remove-SpxLinkOnly {
        param ($Path)
        & $script:OriginalRemoveSpxLinkOnly @PSBoundParameters
        if ($script:Boundary -eq 'Unlinked') { Stop-SpxTestProcess }
    }
    function script:Update-LinkEntry {
        param ($Name, $Scope, $Entry, [switch]$Remove, $Retained, $Intent, $OperationId, $Action, $Outcome)
        & $script:OriginalUpdateLinkEntry @PSBoundParameters
        if ($script:Boundary -eq 'Committed') { Stop-SpxTestProcess }
    }
    function script:Remove-SpxOperation {
        param ($Kind, $Key)
        & $script:OriginalRemoveSpxOperation @PSBoundParameters
        if ($script:Boundary -eq 'Settled') { Stop-SpxTestProcess }
    }
} $Boundary (Join-Path $Root 'crash-reached') $InterruptAt
if ($Action -eq 'Move') { Move-SpxApp crash $Destination -Confirm:$false } else { Restore-SpxApp crash -Confirm:$false }
throw 'The requested interruption was not reached.'
'@ | Set-Content -LiteralPath $child -Encoding UTF8
    }
    BeforeEach {
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $destination = Join-Path $sb.Root 'destination'
    }
    AfterEach { Exit-SpxTestSandbox }

    It 'recovers <Action> / <VersionCount> versions / <Boundary> #<InterruptAt> and remains idempotent' -ForEach @(
        foreach ($action in 'Move', 'Restore') {
            foreach ($count in 1, 2) {
                $boundaries = @('Prepared', 'Copied', 'Published', 'BeforeRebase', 'PersistLinked', 'Committed', 'Settled') + $(if ($action -eq 'Move') { @('Backup', 'Linked') } else { @('Unlinked') })
                foreach ($boundary in $boundaries) {
                    $hits = if ($boundary -in 'Prepared', 'Committed', 'Settled') { 1 } else { $count }
                    foreach ($hit in 1..$hits) { @{ Action = $action; VersionCount = $count; Boundary = $boundary; InterruptAt = $hit } }
                }
            }
        }
    ) {
        $apps = @(foreach ($version in 1..$VersionCount) {
                if ($version -gt 1) { [IO.Directory]::Delete($appsRootCurrent, $false) }
                $item = New-SpxTestApp -Name crash -Version ([string]$version) -Persist @('data')
                $appsRootCurrent = $item.CurrentPath
                $real = Join-Path $item.VersionPath 'real'; $null = New-Item -ItemType Directory -Path $real
                [IO.File]::WriteAllText((Join-Path $real 'inside.txt'), ('inside-' + $version))
                $null = New-Item -ItemType Junction -Path (Join-Path $item.VersionPath 'alias') -Target $real
                $data = Join-Path $item.VersionPath 'data'; $null = New-Item -ItemType Directory -Path $data
                [IO.File]::WriteAllText((Join-Path $data 'value.txt'), ('persist-' + $version))
                $item
            })
        if ($Action -eq 'Restore') { Move-SpxApp crash $destination -Confirm:$false | Out-Null }
        $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + $child + '"'), '-Repository', ('"' + $repository + '"'), '-Root', ('"' + $sb.Root + '"'), '-Action', $Action, '-Boundary', $Boundary, '-Destination', ('"' + $destination + '"'), '-InterruptAt', $InterruptAt)
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $sb.Root 'child.out') -RedirectStandardError (Join-Path $sb.Root 'child.err') -PassThru
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Interruption child timed out.' }
        $process.ExitCode | Should -Not -Be 0
        [IO.File]::ReadAllText((Join-Path $sb.Root 'crash-reached')) | Should -Be $Boundary
        [IO.File]::ReadAllText((Join-Path $sb.Root 'child.err')) | Should -Not -Match 'requested interruption was not reached|ParserError|AuthorizationManager|CommandNotFound'
        $op = Join-Path $env:SCOOP 'spx\operations\link\local-crash.json'
        if ($Boundary -ne 'Settled') { Test-Path -LiteralPath $op | Should -BeTrue }
        Repair-SpxLinkedApp crash -Confirm:$false | Out-Null
        Test-Path -LiteralPath $op | Should -BeFalse
        foreach ($app in $apps) {
            [IO.File]::ReadAllText((Join-Path $app.VersionPath 'payload.txt')) | Should -Be ('payload-crash-' + (Split-Path $app.VersionPath -Leaf))
            [IO.File]::ReadAllText((Join-Path $app.VersionPath 'alias\inside.txt')) | Should -Be ('inside-' + (Split-Path $app.VersionPath -Leaf))
            $isLinked = (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
            $isLinked | Should -Be (($Action -eq 'Move') -eq ($Boundary -in 'Committed', 'Settled'))
        }
        $before = if (Test-Path (Join-Path $env:SCOOP 'spx\links.json')) { [IO.File]::ReadAllText((Join-Path $env:SCOOP 'spx\links.json')) }
        @(Repair-SpxLinkedApp crash -Confirm:$false).Count | Should -Be 0
        if ($before) { [IO.File]::ReadAllText((Join-Path $env:SCOOP 'spx\links.json')) | Should -BeExactly $before }
        foreach ($copy in (Get-SpxStatus crash -Scope Local).RetainedCopies) { Test-Path -LiteralPath $copy.Path | Should -BeTrue }
    }
}
