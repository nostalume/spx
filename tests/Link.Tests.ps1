#Requires -Module Pester

Describe 'SPX recoverable app relocation' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); $destination = Join-Path $sb.Root 'relocated' }
    AfterEach { Exit-SpxTestSandbox }

    It 'moves through a verified copy, leaves a junction, and restores bytes' {
        $app = New-SpxTestApp -Name rg -Version 14
        $move = Move-SpxApp rg $destination -Confirm:$false
        $move.Status | Should -Be Moved
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'payload.txt')) | Should -Be 'payload-rg-14'
        (Get-SpxLinkedApp rg).State | Should -Be Healthy
        $restore = Restore-SpxApp rg -Confirm:$false
        $restore.Status | Should -Be Restored
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'payload.txt')) | Should -Be 'payload-rg-14'
    }

    It 'preserves persist data and creates a directory junction' {
        $app = New-SpxTestApp -Name tool -Version 1 -Persist @('data')
        $data = Join-Path $app.VersionPath 'data'; $null = New-Item -ItemType Directory -Path $data
        [IO.File]::WriteAllText((Join-Path $data 'state.txt'), 'unique-state')
        Move-SpxApp tool $destination -Confirm:$false | Out-Null
        $persist = Join-Path $env:SCOOP 'persist\tool\data'
        [IO.File]::ReadAllText((Join-Path $persist 'state.txt')) | Should -Be unique-state
        (Get-Item -LiteralPath (Join-Path $app.VersionPath 'data') -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        Restore-SpxApp tool -Confirm:$false | Out-Null
        (Get-Item -LiteralPath (Join-Path $app.VersionPath 'data') -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'data\state.txt')) | Should -Be unique-state
    }

    It 'refuses an unowned destination collision without changing source' {
        $app = New-SpxTestApp -Name fd -Version 1
        $collision = Join-Path $destination 'fd'; $null = New-Item -ItemType Directory -Path $collision -Force
        [IO.File]::WriteAllText((Join-Path $collision 'foreign.txt'), 'foreign')
        { Move-SpxApp fd $destination -Confirm:$false } | Should -Throw
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $collision 'foreign.txt')) | Should -Be foreign
    }

    It 'leaves filesystem and config unchanged under WhatIf' {
        $app = New-SpxTestApp -Name jq -Version 1
        Move-SpxApp jq $destination -WhatIf
        Test-Path -LiteralPath $destination | Should -BeFalse
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        Test-Path (Join-Path $env:SCOOP 'spx\links.json') | Should -BeFalse
    }

    It 'synchronizes a newly installed version into the owned destination' {
        $app = New-SpxTestApp -Name syncer -Version 1
        Move-SpxApp syncer $destination -Confirm:$false | Out-Null
        $version2 = Join-Path $app.AppPath '2'; $null = New-Item -ItemType Directory -Path $version2
        [IO.File]::WriteAllText((Join-Path $version2 'payload.txt'), 'version-two')
        @{bucket = 'main' } | ConvertTo-Json | Set-Content (Join-Path $version2 'install.json') -Encoding UTF8
        @{version = '2' } | ConvertTo-Json | Set-Content (Join-Path $version2 'manifest.json') -Encoding UTF8
        [IO.Directory]::Delete($app.CurrentPath, $false)
        $null = New-Item -ItemType Junction -Path $app.CurrentPath -Target $version2
        (Get-SpxLinkedApp syncer).State | Should -Be VersionDrift
        $result = Sync-SpxLinkedApp syncer -Confirm:$false
        $result.Status | Should -Be Moved
        (Get-SpxLinkedApp syncer).State | Should -Be Healthy
        [IO.File]::ReadAllText((Join-Path $destination 'syncer\2\payload.txt')) | Should -Be version-two
    }

    It 'preserves conflicting persist data in an explicit recovery copy' {
        $app = New-SpxTestApp -Name conflict -Version 1 -Persist @('data')
        $sourceData = Join-Path $app.VersionPath 'data'; $null = New-Item -ItemType Directory -Path $sourceData
        [IO.File]::WriteAllText((Join-Path $sourceData 'value.txt'), 'source-value')
        $persist = Join-Path $env:SCOOP 'persist\conflict\data'; $null = New-Item -ItemType Directory -Path $persist -Force
        [IO.File]::WriteAllText((Join-Path $persist 'value.txt'), 'persist-value')
        $result = Move-SpxApp conflict $destination -Confirm:$false
        [IO.File]::ReadAllText((Join-Path $persist 'value.txt')) | Should -Be persist-value
        $result.Conflicts.Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $result.Conflicts[0] 'value.txt')) | Should -Be source-value
    }

    It 'rolls back a prepared interrupted move from its durable journal' {
        $app = New-SpxTestApp -Name crash -Version 1
        $target = Join-Path $destination 'crash\1'; $stage = Join-Path $destination 'crash\.spx-staging-op-1'
        $fingerprint = & (Get-Module SPX) { param($path) Get-SpxTreeFingerprint $path } $app.VersionPath
        & (Get-Module SPX) { param($source, $target) Copy-SpxTree $source $target } $app.VersionPath $target
        $null = New-Item -ItemType Directory -Path $stage -Force
        $operation = [ordered]@{schema = 1; id = 'op'; kind = 'link'; action = 'Move'; phase = 'Prepared'; name = 'crash'; scope = 'Local'; destination = $destination; exclude = @(); versions = @([ordered]@{name = '1'; source = $app.VersionPath; target = $target; stage = $stage; backup = (Join-Path $app.AppPath '.spx-backup-op-1'); linked = $false; fingerprint = $fingerprint }); persistCreated = @(); conflictCopies = @() }
        $opDir = Join-Path $env:SCOOP 'spx\operations\link'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $opDir 'local-crash.json') -Encoding UTF8
        { Move-SpxApp crash $destination -Confirm:$false } | Should -Throw -ErrorId 'Spx.PendingRecovery*'
        (Get-Content (Join-Path $opDir 'local-crash.json') -Raw | ConvertFrom-Json).id | Should -Be op
        $repair = Repair-SpxLinkedApp crash -Confirm:$false
        $repair.Status | Should -Be RolledBack
        Test-Path $app.VersionPath | Should -BeTrue
        Test-Path $target | Should -BeFalse
        Test-Path $stage | Should -BeFalse
        Test-Path (Join-Path $opDir 'local-crash.json') | Should -BeFalse
    }

    It 'recreates contained junction topology without traversing it' {
        $app = New-SpxTestApp -Name linked-content -Version 1
        $real = Join-Path $app.VersionPath 'real'; $null = New-Item -ItemType Directory -Path $real
        [IO.File]::WriteAllText((Join-Path $real 'inside.txt'), 'inside')
        $alias = Join-Path $app.VersionPath 'alias'; $null = New-Item -ItemType Junction -Path $alias -Target $real
        Move-SpxApp linked-content $destination -Confirm:$false | Out-Null
        $movedAlias = Join-Path $destination 'linked-content\1\alias'
        (Get-Item -LiteralPath $movedAlias -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $movedAlias 'inside.txt')) | Should -Be inside
    }

    It 'refuses external reparse targets without changing the source' {
        $app = New-SpxTestApp -Name external-link -Version 1
        $external = Join-Path $sb.Root 'external'; $null = New-Item -ItemType Directory -Path $external
        $null = New-Item -ItemType Junction -Path (Join-Path $app.VersionPath 'outside') -Target $external
        { Move-SpxApp external-link $destination -Confirm:$false } | Should -Throw
        Test-Path (Join-Path $app.VersionPath 'payload.txt') | Should -BeTrue
        (Get-Item -LiteralPath $app.VersionPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        Test-Path $destination | Should -BeFalse
        Test-Path (Join-Path $env:SCOOP 'spx\operations\link\local-external-link.json') | Should -BeFalse
    }

    It 'rejects persist paths that escape the admitted app and persist roots' {
        $app = New-SpxTestApp -Name traversal -Version 1 -Persist @('..\outside')
        { Move-SpxApp traversal $destination -Confirm:$false } | Should -Throw
        Test-Path (Join-Path $app.VersionPath 'payload.txt') | Should -BeTrue
        Test-Path $destination | Should -BeFalse
    }

    It 'refuses a tampered recovery journal before touching its paths' {
        $victim = Join-Path $sb.Root 'victim'; $null = New-Item -ItemType Directory -Path $victim
        [IO.File]::WriteAllText((Join-Path $victim 'keep.txt'), 'keep')
        $operation = [ordered]@{schema = 1; id = 'tampered'; kind = 'link'; action = 'Move'; phase = 'Prepared'; name = 'evil'; scope = 'Local'; destination = $destination; versions = @([ordered]@{name = '1'; source = $victim; target = (Join-Path $destination 'evil\1'); stage = (Join-Path $destination 'evil\.spx-stage'); backup = (Join-Path $sb.LocalApps 'evil\.spx-backup') }) }
        $opDir = Join-Path $env:SCOOP 'spx\operations\link'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $opDir 'local-evil.json') -Encoding UTF8
        { Repair-SpxLinkedApp evil -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText((Join-Path $victim 'keep.txt')) | Should -Be keep
    }

    It 'preserves changed canonical data instead of forcing a restore rollback' {
        $app = New-SpxTestApp -Name guarded-restore -Version 1
        Move-SpxApp guarded-restore $destination -Confirm:$false | Out-Null
        $source = Join-Path $destination 'guarded-restore\1'
        $fingerprint = & (Get-Module SPX) { param($path) Get-SpxTreeFingerprint $path } $source
        [IO.Directory]::Delete($app.VersionPath, $false)
        & (Get-Module SPX) { param($from, $to) Copy-SpxTree $from $to } $source $app.VersionPath
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'new-data.txt'), 'preserve-me')
        $operation = [ordered]@{
            schema=1; id='guarded-restore-op'; kind='link'; action='Restore'; phase='Restored'
            name='guarded-restore'; scope='Local'; destination=$destination; exclude=@()
            versions=@([ordered]@{
                    name='1'; source=$source; canonical=$app.VersionPath
                    stage=(Join-Path $app.AppPath '.spx-restore-guarded-1')
                    restored=$true; fingerprint=$fingerprint
                })
        }
        $opDir = Join-Path $env:SCOOP 'spx\operations\link'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $opDir 'local-guarded-restore.json') -Encoding UTF8
        { Repair-SpxLinkedApp guarded-restore -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryConflict*'
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'new-data.txt')) | Should -Be preserve-me
        Test-Path (Join-Path $source 'payload.txt') | Should -BeTrue
        Test-Path (Join-Path $opDir 'local-guarded-restore.json') | Should -BeTrue
    }

    It 'distinguishes missing targets and mismatched link targets' {
        $missing = New-SpxTestApp -Name missing-target -Version 1
        Move-SpxApp missing-target $destination -Confirm:$false | Out-Null
        $target = Join-Path $destination 'missing-target\1'; Move-Item -LiteralPath $target -Destination ($target + '.away')
        (Get-SpxLinkedApp missing-target).State | Should -Be TargetMissing

        $mismatch = New-SpxTestApp -Name mismatch -Version 1
        Move-SpxApp mismatch $destination -Confirm:$false | Out-Null
        [IO.Directory]::Delete($mismatch.VersionPath, $false)
        $other = Join-Path $sb.Root 'other'; $null = New-Item -ItemType Directory -Path $other
        $null = New-Item -ItemType Junction -Path $mismatch.VersionPath -Target $other
        (Get-SpxLinkedApp mismatch).State | Should -Be LinkTargetMismatch
    }

    It 'reports persist-link drift separately from version drift' {
        $app = New-SpxTestApp -Name persist-drift -Version 1 -Persist @('data')
        $data = Join-Path $app.VersionPath 'data'; $null = New-Item -ItemType Directory -Path $data
        Move-SpxApp persist-drift $destination -Confirm:$false | Out-Null
        [IO.Directory]::Delete((Join-Path $destination 'persist-drift\1\data'), $false)
        (Get-SpxLinkedApp persist-drift).State | Should -Be PersistDrift
    }

    It 'removes only an existing proven-stale record and honors WhatIf' {
        $import = Join-Path $sb.Root 'stale.json'
        [ordered]@{local = [ordered]@{gone = [ordered]@{Path = $destination; Version = '1' } }; global = [ordered]@{} } | ConvertTo-Json -Depth 10 | Set-Content $import -Encoding UTF8
        Import-SpxLinkConfiguration $import -Confirm:$false | Out-Null
        (Get-SpxLinkedApp gone -Scope Local).State | Should -Be Stale
        Remove-SpxStaleLink gone -WhatIf
        (Get-SpxLinkedApp gone -Scope Local).State | Should -Be Stale
        (Remove-SpxStaleLink gone -Confirm:$false).Changed | Should -BeTrue
        @(Get-SpxLinkedApp gone -Scope Local).Count | Should -Be 0
        { Remove-SpxStaleLink gone -Confirm:$false } | Should -Throw
    }
}
