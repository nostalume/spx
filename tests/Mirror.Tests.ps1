#Requires -Module Pester

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
        Test-Path (Join-Path $env:SCOOP 'spx\spx.json') | Should -BeFalse
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
        Test-Path (Join-Path $env:SCOOP 'spx\spx.json') | Should -BeFalse
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

    It 'compensates Git and preserves recovery evidence when config is contended' {
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $config = Join-Path $env:SCOOP 'spx\spx.json'; $null = New-Item -ItemType Directory -Path (Split-Path $config -Parent) -Force
        $holder = [IO.File]::Open($config + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { New-SpxBucketMirror main 'https://mirror.example/main.git' -Confirm:$false } | Should -Throw }
        finally { $holder.Dispose() }
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://origin.example/main.git'
        (Get-SpxBucketMirror main).State | Should -Be PendingRecovery
        (Repair-SpxBucketMirror main -Confirm:$false).Status | Should -Be RolledBack
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
