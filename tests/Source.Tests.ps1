#Requires -Module Pester

Describe 'SPX Scoop state and source operations' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    AfterEach { Exit-SpxTestSandbox }

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
