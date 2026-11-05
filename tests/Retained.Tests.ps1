#Requires -Module Pester

Describe 'SPX explicit retained copy reclamation' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
    BeforeEach {
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $destination = Join-Path $sb.Root 'destination'
        $app = New-SpxTestApp demo -Version 1
    }
    AfterEach { Exit-SpxTestSandbox }

    It 'reclaims a move backup, then a restored target, and is idempotent' {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Status | Should -Be Reclaimed
        $result.Removed | Should -Contain $copy.Id
        Test-Path -LiteralPath $copy.Path | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'payload.txt')) | Should -Be payload-demo-1
        $repeat = Remove-SpxRetainedCopy demo -CopyId $copy.Id -Confirm:$false
        $repeat.Status | Should -Be Unchanged
        $repeat.Removed.Count | Should -Be 0
        Restore-SpxApp demo -Confirm:$false | Out-Null
        (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Reclaimed
        (Get-SpxStatus demo -Scope Local).Placement | Should -Be Canonical
    }

    It 'keeps previews byte-identical without creating a journal' {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $path = Join-Path $env:SCOOP 'spx\links.json'
        $before = [IO.File]::ReadAllBytes($path)
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        Remove-SpxRetainedCopy demo -WhatIf
        [IO.File]::ReadAllBytes($path) | Should -Be $before
        Test-Path -LiteralPath $copy.Path | Should -BeTrue
        Test-Path (Join-Path $env:SCOOP 'spx\operations\link\local-demo.json') | Should -BeFalse
    }

    It 'blocks changed, added or missing files while keeping the active installation' -ForEach @(@{ Change = 'changed' }, @{ Change = 'new' }, @{ Change = 'missing' }) {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        $file = Join-Path $copy.Path $(if ($Change -eq 'changed') { 'payload.txt' } else { 'unique.txt' })
        if ($Change -eq 'missing') { [IO.File]::Delete((Join-Path $copy.Path 'payload.txt')) } else { [IO.File]::WriteAllText($file, 'unique-state') }
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Status | Should -Be Blocked
        $result.BlockedCopies.Count | Should -Be 1
        if ($Change -ne 'missing') { [IO.File]::ReadAllText($file) | Should -Be unique-state }
    }

    It 'compares old persist data to its scoped renamed active target' {
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'manifest.json'), '{"version":"1","persist":[["data","renamed"]]}')
        $null = New-Item -ItemType Directory -Path (Join-Path $app.VersionPath 'data')
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'data\state.txt'), 'state')
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Status | Should -Be Reclaimed
        $result.Removed.Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $env:SCOOP 'persist\demo\renamed\state.txt')) | Should -Be state
        Restore-SpxApp demo -Confirm:$false | Out-Null
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Removed.Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'data\state.txt')) | Should -Be state
    }

    It 'keeps old persist content after the active persist file changes' {
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'manifest.json'), '{"version":"1","persist":["state.ini"]}')
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'state.ini'), 'old')
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:SCOOP 'persist\demo\state.ini'), 'new')
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Status | Should -Be Blocked
        $backup = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies | Where-Object Role -EQ backup
        [IO.File]::ReadAllText((Join-Path $backup.Path 'state.ini')) | Should -Be old
    }

    It 'unlinks contained junctions without following or deleting their active targets' {
        $null = New-Item -ItemType Directory -Path (Join-Path $app.VersionPath 'real')
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'real\inside.txt'), 'inside')
        $null = New-Item -ItemType Junction -Path (Join-Path $app.VersionPath 'alias') -Target (Join-Path $app.VersionPath 'real')
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Reclaimed
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'alias\inside.txt')) | Should -Be inside
    }

    It 'refuses foreign reparse points and forged private paths' -ForEach @(@{ Change = 'link' }, @{ Change = 'path' }) {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        if ($Change -eq 'link') {
            $foreign = Join-Path $sb.Root 'foreign'; $null = New-Item -ItemType Directory -Path $foreign
            [IO.File]::WriteAllText((Join-Path $foreign 'precious.txt'), 'precious')
            $null = New-Item -ItemType Junction -Path (Join-Path $copy.Path 'escape') -Target $foreign
        }
        else {
            $config = Join-Path $env:SCOOP 'spx\links.json'
            $text = [IO.File]::ReadAllText($config).Replace('.spx-backup-', '.wrong-backup-')
            [IO.File]::WriteAllText($config, $text)
        }
        (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Blocked
        Test-Path -LiteralPath $copy.Path | Should -BeTrue
    }

    It 'resumes a partial deletion using its immutable inventory' -ForEach @(@{ AddFile = $false }, @{ AddFile = $true }) {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        & (Get-Module SPX) {
            $script:RealDelete = (Get-Command Remove-SpxReclaimEntry).ScriptBlock
            $script:DeleteCount = 0
            function script:Remove-SpxReclaimEntry {
                param ($Path, $Entry)
                & $script:RealDelete @PSBoundParameters
                if (++$script:DeleteCount -eq 1) { throw 'Interrupted after one deletion' }
            }
        }
        { Remove-SpxRetainedCopy demo -Confirm:$false } | Should -Throw
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        (Get-SpxStatus demo -Scope Local).Status | Should -Be NeedsRecovery
        $journal = Join-Path $env:SCOOP 'spx\operations\link\local-demo.json'
        $before = [IO.File]::ReadAllText($journal)
        $remaining = @(Get-ChildItem -LiteralPath $copy.Path -Recurse -Force).FullName
        Repair-SpxLinkedApp demo -WhatIf
        [IO.File]::ReadAllText($journal) | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $copy.Path -Recurse -Force).FullName | Should -Be $remaining
        if ($AddFile) {
            [IO.File]::WriteAllText((Join-Path $copy.Path 'new.txt'), 'new')
            { Repair-SpxLinkedApp demo -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryConflict*'
            [IO.File]::ReadAllText((Join-Path $copy.Path 'new.txt')) | Should -Be new
        }
        else {
            (Repair-SpxLinkedApp demo -Confirm:$false).Status | Should -Be Completed
            Test-Path -LiteralPath $copy.Path | Should -BeFalse
            @(Repair-SpxLinkedApp demo -Confirm:$false).Count | Should -Be 0
            (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Unchanged
        }
    }

    It 'selects only the requested copy identity across versions' {
        [IO.Directory]::Delete($app.CurrentPath, $false)
        New-SpxTestApp demo -Version 2 | Out-Null
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copies = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies
        (Remove-SpxRetainedCopy demo -CopyId $copies[0].Id -Confirm:$false).Removed.Count | Should -Be 1
        Test-Path -LiteralPath $copies[1].Path | Should -BeTrue
    }

    It 'allows a declared persist entry that has never existed' {
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'manifest.json'), '{"version":"1","persist":["future.ini"]}')
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Reclaimed
    }

    It 'blocks a copy still referenced by another scoped persist tree' {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        $null = New-Item -ItemType Junction -Path (Join-Path $env:SCOOP_GLOBAL 'persist\other') -Target $copy.Path
        (Remove-SpxRetainedCopy demo -Confirm:$false).Status | Should -Be Blocked
        Test-Path -LiteralPath $copy.Path | Should -BeTrue
    }

    It 'preserves named data streams absent from the ordinary file hash' -ForEach @(@{ Item = 'File' }, @{ Item = 'Root' }) {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        $path = if ($Item -eq 'Root') { $copy.Path } else { Join-Path $copy.Path 'payload.txt' }
        Set-Content -LiteralPath $path -Stream unique -Value 'unique-stream'
        $result = Remove-SpxRetainedCopy demo -Confirm:$false
        $result.Status | Should -Be Blocked
        $result.BlockedCopies[0].Reason | Should -Match 'Named data streams'
        (Get-Content -LiteralPath $path -Stream unique) | Should -Be unique-stream
    }

    It 'refuses to repair a different journal after acquiring the writer' {
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $copy = (Get-SpxLinkedApp demo -Scope Local).RetainedCopies[0]
        & (Get-Module SPX) {
            $script:Write = (Get-Command Write-SpxOperation).ScriptBlock
            function script:Write-SpxOperation {
                param ($Kind, $Key, $Value)
                & $script:Write @PSBoundParameters
                throw 'Stop after preparing reclamation'
            }
        }
        { Remove-SpxRetainedCopy demo -Confirm:$false } | Should -Throw
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        & (Get-Module SPX) {
            $script:Mutation = (Get-Command Invoke-SpxMutation).ScriptBlock
            function script:Invoke-SpxMutation {
                param ($MutationBody)
                $path = Join-Path (Get-SpxContext).Operations 'link\local-demo.json'
                $journal = Read-SpxJsonFile $path; $journal.id = [guid]::NewGuid().ToString('N')
                [IO.File]::WriteAllText($path, ($journal | ConvertTo-Json -Depth 30))
                & $script:Mutation @PSBoundParameters
            }
        }
        { Repair-SpxLinkedApp demo -Confirm:$false } | Should -Throw -ErrorId 'Spx.StateChanged*'
        [IO.File]::ReadAllText((Join-Path $copy.Path 'payload.txt')) | Should -Be payload-demo-1
    }
}
