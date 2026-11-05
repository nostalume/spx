#Requires -Module Pester

Describe 'SPX Scoop state and source operations' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    AfterEach { Exit-SpxTestSandbox }

    It 'keeps bucket identity case-insensitive while preserving the first original URL' {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/Case.git'
        Set-SpxBucketMirror main 'https://mirror.example/one.git' -Confirm:$false | Out-Null
        Set-SpxBucketMirror MAIN 'https://mirror.example/two.git' -Confirm:$false | Out-Null
        (Get-SpxBucketMirror Main).OriginalUrl | Should -BeExactly 'https://origin.example/Case.git'
        @(Get-SpxStatus -Buckets).Count | Should -Be 1
        { New-SpxBucketMirror Main 'https://mirror.example/three.git' -Confirm:$false } | Should -Throw -ErrorId 'Spx.MirrorAlreadyExists*'
        Remove-SpxBucketMirror mAIN -Confirm:$false | Out-Null
        (& git -C $bucket remote get-url origin) | Should -BeExactly 'https://origin.example/Case.git'
    }

    It 'isolates a malformed bucket entry from other repository and app observations' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        New-SpxTestGitBucket bad 'https://origin.example/bad.git' | Out-Null
        New-SpxTestApp demo -Version 1 -Bucket main | Out-Null
        $path = Join-Path $env:SCOOP 'spx\spx.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        $raw = '{"schema":2,"mirrors":{"bad":{"original":"https://origin.example/bad.git"}}}'
        [IO.File]::WriteAllText($path, $raw)
        $all = @(Get-SpxStatus -Buckets)
        $all.Count | Should -Be 2
        ($all | Where-Object Name -EQ bad).Status | Should -Be Invalid
        ($all | Where-Object Name -EQ main).Status | Should -Be Ready
        (Get-SpxStatus demo -Scope Local).Source.CurrentUrl | Should -Be 'https://origin.example/main.git'
        { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
    }

    It 'refuses case-colliding bucket records without changing Git' {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/main.git'
        $path = Join-Path $env:SCOOP 'spx\spx.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        $raw = '{"mirrors":{"main":{"original":"https://origin.example/main.git","mirror":"https://mirror.example/main.git"},"MAIN":{"original":"https://other.example/main.git","mirror":"https://other.example/main.git"}}}'
        [IO.File]::WriteAllText($path, $raw)
        { Set-SpxBucketMirror main 'https://mirror.example/new.git' -Confirm:$false } | Should -Throw
        (& git -C $bucket remote get-url origin) | Should -BeExactly 'https://origin.example/main.git'
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
    }

    It 'separates install metadata, manifest, and directory version identity' {
        New-SpxTestApp -Name jq -Version 1.7.1 -Bucket main | Out-Null
        $source = Get-SpxAppSource -Name jq -Scope Local
        $source.Version | Should -Be '1.7.1'
        $source.Bucket | Should -Be 'main'
        $source.Manifest.description | Should -Be 'test jq'
    }

    It 'addresses duplicate local and global installations explicitly' {
        New-SpxTestApp -Name dual -Version 1 -Bucket local | Out-Null
        New-SpxTestApp -Name dual -Version 2 -Bucket global -Global | Out-Null
        $all = @(Get-SpxAppSource -Name dual -Scope All)
        $all.Count | Should -Be 2
        $all.Scope | Should -Contain Local
        $all.Scope | Should -Contain Global
    }

    It 'changes only bucket metadata and preserves installed manifest' {
        $app = New-SpxTestApp -Name bat -Version 1.0 -Bucket main
        New-SpxTestBucket -Name extras -AppName bat -Version 1.0 | Out-Null
        $before = [IO.File]::ReadAllText((Join-Path $app.VersionPath 'manifest.json'))
        $result = Set-SpxAppSource -Name bat -Bucket extras -Scope Local -Confirm:$false
        $result.Changed | Should -BeTrue
        (Get-SpxAppSource bat -Scope Local).Bucket | Should -Be extras
        [IO.File]::ReadAllText((Join-Path $app.VersionPath 'manifest.json')) | Should -Be $before
    }

    It 'rejects mismatched versions with a stable error identity' {
        New-SpxTestApp -Name fd -Version 1 -Bucket main | Out-Null
        New-SpxTestBucket -Name extras -AppName fd -Version 2 | Out-Null
        try { Set-SpxAppSource fd extras -Confirm:$false -ErrorAction Stop; throw 'expected failure' }
        catch { $_.FullyQualifiedErrorId | Should -Match '^Spx.VersionMismatch' }
    }

    It 'finds and compares bucket manifests' {
        New-SpxTestApp -Name rg -Version 1 -Bucket main | Out-Null
        New-SpxTestBucket -Name main -AppName rg -Version 1 | Out-Null
        New-SpxTestBucket -Name newer -AppName rg -Version 2 | Out-Null
        @(Find-SpxAppSource rg).Count | Should -Be 2
        (Compare-SpxAppSource rg newer).VersionMatch | Should -BeFalse
        Test-SpxAppSource rg | Should -BeTrue
    }

    It 'uses the sole installed version when current is absent and refuses ambiguity' {
        $app = New-SpxTestApp -Name fallback -Version 1
        [IO.Directory]::Delete($app.CurrentPath, $false)
        (Get-SpxAppSource fallback -Scope Local).Version | Should -Be 1
        $second = Join-Path $app.AppPath '2'; $null = New-Item -ItemType Directory -Path $second
        { Get-SpxAppSource fallback -Scope Local } | Should -Throw
    }
}


Describe 'SPX source transition admission and recovery' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
    BeforeEach {
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        $sb = Enter-SpxTestSandbox (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }
    AfterEach { Exit-SpxTestSandbox }

    It 'preserves source extensions, keeps Set as upsert, and makes identical Set a no-op' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        Set-SpxBucketMirror main 'https://mirror.example/one.git' -Confirm:$false | Out-Null
        $path = Join-Path $env:SCOOP 'spx\spx.json'
        & (Get-Module SPX) {
            $state = Get-SpxMirrorState; $state['custom'] = 'root'; $state.mirrors.main['custom'] = 'entry'
            $state['stamp'] = '2025-01-01T00:00:00-05:00'; $state.mirrors.main['stamp'] = '2025-01-01T00:00:00-05:00'
            Write-SpxJsonFileAtomic (Get-SpxConfigFile) $state
        }
        Set-SpxBucketMirror main 'https://mirror.example/two.git' -Confirm:$false | Out-Null
        $before = [IO.File]::ReadAllText($path)
        (Set-SpxBucketMirror main 'https://mirror.example/two.git' -Confirm:$false).Changed | Should -BeFalse
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
        $state = $before | ConvertFrom-Json
        $state.custom | Should -Be root
        $state.mirrors.main.custom | Should -Be entry
        [regex]::Matches($before, '"stamp":\s*"2025-01-01T00:00:00-05:00"').Count | Should -Be 2
        $state.mirrors.main.original | Should -Be 'https://origin.example/main.git'
        { New-SpxBucketMirror main 'https://other.example/main.git' -Confirm:$false } | Should -Throw -ErrorId 'Spx.MirrorAlreadyExists*'
    }

    It 'refuses a different journal installed before acquiring the repair writer' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        & (Get-Module SPX) { function script:Save-SpxMirrorOutcome { param ($Operation, $Committed); throw 'Commit failed' } }
        { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        & (Get-Module SPX) {
            $script:Mutation = (Get-Command Invoke-SpxMutation).ScriptBlock
            function script:Invoke-SpxMutation {
                param ($MutationBody)
                $op = Read-SpxOperation mirror main; $op.id = 'replacement'
                $path = Join-Path (Get-SpxContext).Operations 'mirror\main.json'
                Write-SpxJsonFileAtomic $path $op
                & $script:Mutation $MutationBody
            }
        }
        { Repair-SpxBucketMirror main -Confirm:$false } | Should -Throw -ErrorId 'Spx.StateChanged*'
        (Get-SpxBucketMirror main).PendingOperation.id | Should -Be replacement
    }

    It 'retains a failed transition and refuses to overwrite a third origin value' -ForEach @(@{ Committed = $false; CaseOnly = $false }, @{ Committed = $true; CaseOnly = $false }, @{ Committed = $false; CaseOnly = $true }) {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/main.git'
        & (Get-Module SPX) {
            param ($Committed)
            if ($Committed) { function script:Remove-SpxOperation { param ($Kind, $Key); throw 'Journal clear failed' } }
            else { function script:Save-SpxMirrorOutcome { param ($Operation, $Committed); throw 'State commit failed' } }
        } $Committed
        { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryFailed*'
        $third = if ($CaseOnly) { 'https://mirror.example/MAIN.git' } else { 'https://third.example/main.git' }
        & git -C $bucket remote set-url origin $third
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        { Repair-SpxBucketMirror main -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryConflict*'
        (Get-SpxBucketMirror main).CurrentUrl | Should -BeExactly $third
        Test-Path (Join-Path $env:SCOOP 'spx\operations\mirror\main.json') | Should -BeTrue
    }

    It 'restores the exact previous entry when Git remains at the old value' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        Set-SpxBucketMirror main 'https://mirror.example/one.git' -Confirm:$false | Out-Null
        $path = Join-Path $env:SCOOP 'spx\spx.json'
        $before = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).mirrors.main | ConvertTo-Json -Compress
        & (Get-Module SPX) {
            $script:Git = (Get-Command Invoke-SpxGit).ScriptBlock
            function script:Invoke-SpxGit {
                param ($BucketPath, $Arguments)
                if ($Arguments[0] -eq 'remote' -and $Arguments[1] -eq 'set-url') { Stop-SpxError 'Spx.GitFailed' 'Git refused the effect' $BucketPath }
                & $script:Git @PSBoundParameters
            }
        }
        { Set-SpxBucketMirror main 'https://mirror.example/two.git' -Confirm:$false } | Should -Throw -ErrorId 'Spx.GitFailed*'
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        (Repair-SpxBucketMirror main -Confirm:$false).Status | Should -Be RolledBack
        (([IO.File]::ReadAllText($path) | ConvertFrom-Json).mirrors.main | ConvertTo-Json -Compress) | Should -BeExactly $before
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://mirror.example/one.git'
    }

    It 'detects a replaced Git directory and leaves its origin untouched' {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/main.git'
        & (Get-Module SPX) { function script:Save-SpxMirrorOutcome { param ($Operation, $Committed); throw 'Commit failed' } }
        { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw
        $gitDirectory = Join-Path $bucket '.git'
        [IO.Directory]::SetCreationTimeUtc($gitDirectory, [DateTime]::UtcNow.AddDays(-1))
        Import-Module (Join-Path $repository 'SPX.psd1') -Force
        { Repair-SpxBucketMirror main -Confirm:$false } | Should -Throw -ErrorId 'Spx.RecoveryConflict*'
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://mirror.example/main.git'
    }

    It 'reads legacy source state without upgrading and refuses unknown schemas' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $path = Join-Path $env:SCOOP 'spx\spx.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        $legacy = '{"mirrors":{},"custom":42}'
        [IO.File]::WriteAllText($path, $legacy)
        Get-SpxBucketMirror main | Out-Null
        [IO.File]::ReadAllText($path) | Should -BeExactly $legacy
        [IO.File]::WriteAllText($path, '{"schema":99,"mirrors":{}}')
        { Set-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly '{"schema":99,"mirrors":{}}'
        (& git -C (Join-Path $env:SCOOP 'buckets\main') remote get-url origin) | Should -Be 'https://origin.example/main.git'
    }

    It 're-admits the target version and fresh install metadata inside the writer' -ForEach @(@{ Change = 'version' }, @{ Change = 'metadata' }) {
        $app = New-SpxTestApp demo -Version 1
        New-SpxTestBucket extras demo -Version 1 | Out-Null
        & (Get-Module SPX) {
            param ($Change, $Install)
            $script:Mutation = (Get-Command Invoke-SpxMutation).ScriptBlock
            $script:Change = $Change; $script:Install = $Install
            function script:Invoke-SpxMutation {
                param ($MutationBody)
                if ($script:Change -eq 'version') {
                    [IO.File]::WriteAllText((Join-Path (Get-SpxContext).Buckets 'extras\bucket\demo.json'), '{"version":"2"}')
                }
                else { [IO.File]::WriteAllText($script:Install, '{"bucket":"fresh","architecture":"arm64","unknown":{"keep":true,"stamp":"2025-01-01T00:00:00-05:00"}}') }
                & $script:Mutation @PSBoundParameters
            }
        } $Change (Join-Path $app.VersionPath 'install.json')
        if ($Change -eq 'version') {
            { Set-SpxAppSource demo extras -Confirm:$false } | Should -Throw -ErrorId 'Spx.VersionMismatch*'
            (Get-SpxAppSource demo -Scope Local).Bucket | Should -Be main
        }
        else {
            (Set-SpxAppSource demo extras -Confirm:$false).OldBucket | Should -Be fresh
            $install = Get-Content -LiteralPath (Join-Path $app.VersionPath 'install.json') -Raw | ConvertFrom-Json
            $install.architecture | Should -Be arm64
            $install.unknown.keep | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $app.VersionPath 'install.json') -Raw) | Should -Match '"stamp":\s*"2025-01-01T00:00:00-05:00"'
        }
        Test-Path (Join-Path $env:SCOOP 'spx\operations') | Should -BeFalse
    }

    It 'preserves the old install file when its atomic commit fails' {
        $app = New-SpxTestApp demo -Version 1
        New-SpxTestBucket extras demo -Version 1 | Out-Null
        $path = Join-Path $app.VersionPath 'install.json'; $before = [IO.File]::ReadAllText($path)
        $holder = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { { Set-SpxAppSource demo extras -Confirm:$false } | Should -Throw }
        finally { $holder.Dispose() }
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
}



Describe 'SPX recoverable bucket mirrors' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    AfterEach { Exit-SpxTestSandbox }

    It 'checks Git, commits observed mirror state, and restores the original' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $set = New-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false
        $set.Status | Should -Be Configured
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://mirror.example/main.git'
        $remove = Remove-SpxBucketMirror main -Confirm:$false
        $remove.Status | Should -Be Restored
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://origin.example/main.git'
    }

    It 'does not mutate Git or config under WhatIf' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        New-SpxBucketMirror main 'https://mirror.example/main.git' -WhatIf
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://origin.example/main.git'
        Test-Path (Join-Path $env:SCOOP 'spx\writer') | Should -BeFalse
    }

    It 'refuses malformed config rather than normalizing it' {
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir -Force
        [IO.File]::WriteAllText((Join-Path $dir 'spx.json'), '{broken')
        { Get-SpxBucketMirror } | Should -Throw
        [IO.File]::ReadAllText((Join-Path $dir 'spx.json')) | Should -Be '{broken'
    }

    It 'rejects non-Git buckets without writing committed state' {
        New-SpxTestBucket -Name plain | Out-Null
        { New-SpxBucketMirror plain 'https://mirror.example/plain.git' -Confirm:$false } | Should -Throw
        Test-Path (Join-Path $env:SCOOP 'spx\writer') | Should -BeFalse
    }

    It 'preserves existing extension fields when completing a legacy journal' {
        $bucket = New-SpxTestGitBucket main 'https://mirror.example/one.git'
        $path = Join-Path $env:SCOOP 'spx\spx.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        [IO.File]::WriteAllText($path, '{"mirrors":{"main":{"original":"https://origin.example/main.git","mirror":"https://mirror.example/one.git","custom":"keep"}}}')
        $operation = [ordered]@{schema = 1; id = 'legacy'; kind = 'mirror'; bucket = 'main'; action = 'Set'; phase = 'GitChanged'; oldUrl = 'https://mirror.example/one.git'; originalUrl = 'https://origin.example/main.git'; requestedUrl = 'https://mirror.example/two.git' }
        & git -C $bucket remote set-url origin $operation.requestedUrl
        $opDir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json | Set-Content (Join-Path $opDir 'main.json') -Encoding UTF8
        (Repair-SpxBucketMirror MAIN -Confirm:$false).Status | Should -Be Completed
        (Get-Content $path -Raw | ConvertFrom-Json).mirrors.main.custom | Should -BeExactly keep
    }

    It 'reports and rolls forward an interrupted observed Git change' {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/main.git'
        & git -C $bucket remote set-url origin 'https://mirror.example/main.git'
        $operation = [ordered]@{schema = 1; id = 'mirror-op'; kind = 'mirror'; bucket = 'main'; action = 'New'; phase = 'GitChanged'; oldUrl = 'https://origin.example/main.git'; originalUrl = 'https://origin.example/main.git'; requestedUrl = 'https://mirror.example/main.git' }
        $opDir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json | Set-Content (Join-Path $opDir 'main.json') -Encoding UTF8
        (Get-SpxBucketMirror main).State | Should -Be PendingRecovery
        (Repair-SpxBucketMirror main -Confirm:$false).Status | Should -Be Completed
        (Get-SpxBucketMirror main).IsMirrored | Should -BeTrue
        Test-Path (Join-Path $opDir 'main.json') | Should -BeFalse
    }

    It 'rolls back a prepared mirror whose Git effect was not observed' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $operation = [ordered]@{schema = 1; id = 'mirror-op'; kind = 'mirror'; bucket = 'main'; action = 'New'; phase = 'Prepared'; oldUrl = 'https://origin.example/main.git'; originalUrl = 'https://origin.example/main.git'; requestedUrl = 'https://mirror.example/main.git' }
        $opDir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $opDir -Force
        $operation | ConvertTo-Json | Set-Content (Join-Path $opDir 'main.json') -Encoding UTF8
        { New-SpxBucketMirror main 'https://replacement.example/main.git' -Confirm:$false } | Should -Throw -ErrorId 'Spx.PendingRecovery*'
        (Get-Content (Join-Path $opDir 'main.json') -Raw | ConvertFrom-Json).id | Should -Be mirror-op
        (Repair-SpxBucketMirror main -Confirm:$false).Status | Should -Be RolledBack
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://origin.example/main.git'
    }

    It 'refuses a busy writer before changing Git or creating recovery evidence' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $config = Join-Path $env:SCOOP 'spx\writer'; $null = New-Item -ItemType Directory -Path (Split-Path $config -Parent) -Force
        $holder = [IO.File]::Open($config + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { New-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw }
        finally { $holder.Dispose() }
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://origin.example/main.git'
        (Get-SpxBucketMirror main).State | Should -Be Unmirrored
    }

    It 'reports observed remote drift without mutating it' {
        $bucket = New-SpxTestGitBucket main 'https://origin.example/main.git'
        New-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false | Out-Null
        & git -C $bucket remote set-url origin 'https://other.example/main.git'
        $status = Get-SpxBucketMirror main
        $status.State | Should -Be Drifted
        $status.CurrentUrl | Should -Be 'https://other.example/main.git'
    }
}
