#Requires -Module Pester
# tests/Source.Tests.ps1 - Integration tests for Source module

BeforeAll {
    . "$PSScriptRoot/Sandbox.ps1"
    . "$PSScriptRoot/../lib/Core.ps1"
    . "$PSScriptRoot/../modules/Source.ps1"
}

Describe 'Get-AppSource: reads install.json correctly' {
    BeforeAll {
        $sb  = Enter-Sandbox
        New-SandboxApp -AppName '7zip' -Version '24.8.0' -Bucket 'main'
    }
    AfterAll { Exit-Sandbox }

    It 'returns the correct bucket and version' {
        $src = Get-AppSource -AppName '7zip'
        $src              | Should -Not -BeNullOrEmpty
        $src.AppName      | Should -Be '7zip'
        $src.Bucket       | Should -Be 'main'
        $src.Version      | Should -Be '24.8.0'
        $src.Global       | Should -BeFalse
        $src.InstallPath  | Should -Match 'current'
    }

    It 'returns null and warns for an uninstalled app' {
        $result = Get-AppSource -AppName 'nonexistent' -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Move-AppSource: rewrites install.json' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxApp -AppName 'jq' -Version '1.7.1' -Bucket 'main'
        New-SandboxBucketManifest -BucketName 'extras' -AppName 'jq' -Version '1.7.1'
    }
    AfterAll { Exit-Sandbox }

    It 'changes the bucket field in install.json' {
        Move-AppSource -AppName 'jq' -Bucket 'extras' -Confirm:$false
        $src = Get-AppSource -AppName 'jq'
        $src.Bucket | Should -Be 'extras'
    }

    It 'is idempotent — warns if already in target bucket' {
        { Move-AppSource -AppName 'jq' -Bucket 'extras' -Confirm:$false -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It 'throws when the target bucket does not exist' {
        { Move-AppSource -AppName 'jq' -Bucket 'nonexistent-bucket' -Confirm:$false } | Should -Throw
    }

    It 'blocks a version mismatch without -Force' {
        # Bucket manifest has different version
        New-SandboxBucketManifest -BucketName 'nightly' -AppName 'jq' -Version '99.0.0'
        $result = Move-AppSource -AppName 'jq' -Bucket 'nightly' -Confirm:$false -WarningAction SilentlyContinue
        # Should warn and return nothing (not throw)
        $result | Should -BeNullOrEmpty
        (Get-AppSource 'jq').Bucket | Should -Be 'extras'   # unchanged
    }

    It 'proceeds past a version mismatch with -Force' {
        Move-AppSource -AppName 'jq' -Bucket 'nightly' -Force -Confirm:$false
        (Get-AppSource 'jq').Bucket | Should -Be 'nightly'
    }
}

Describe 'Find-AppBucket: searches all buckets' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketManifest -BucketName 'main'   -AppName 'curl' -Version '8.10.0'
        New-SandboxBucketManifest -BucketName 'extras' -AppName 'curl' -Version '8.10.0'
        New-SandboxBucketManifest -BucketName 'games'  -AppName 'other-app' -Version '1.0.0'
    }
    AfterAll { Exit-Sandbox }

    It 'finds app in multiple buckets' {
        $hits = @(Find-AppBucket -AppName 'curl')
        $hits.Count          | Should -Be 2
        $hits.Bucket         | Should -Contain 'main'
        $hits.Bucket         | Should -Contain 'extras'
    }

    It 'returns nothing for an app in no bucket' {
        @(Find-AppBucket -AppName 'no-such-app') | Should -HaveCount 0
    }
}

Describe 'Compare-AppManifest: version and field comparison' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxApp -AppName 'bat' -Version '0.24.0' -Bucket 'main'
        New-SandboxBucketManifest -BucketName 'main'   -AppName 'bat' -Version '0.24.0'
        New-SandboxBucketManifest -BucketName 'extras' -AppName 'bat' -Version '0.25.0'
    }
    AfterAll { Exit-Sandbox }

    It 'reports VersionMatch=true when versions align' {
        $cmp = Compare-AppManifest -AppName 'bat' -Bucket 'main'
        $cmp.VersionMatch | Should -BeTrue
    }

    It 'reports VersionMatch=false when bucket has a newer version' {
        $cmp = Compare-AppManifest -AppName 'bat' -Bucket 'extras'
        $cmp.VersionMatch     | Should -BeFalse
        $cmp.InstalledVersion | Should -Be '0.24.0'
        $cmp.BucketVersion    | Should -Be '0.25.0'
    }
}

Describe 'Test-AppSourceValid' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxApp -AppName 'fzf' -Version '0.55.0' -Bucket 'main'
        New-SandboxBucketManifest -BucketName 'main' -AppName 'fzf' -Version '0.55.0'
    }
    AfterAll { Exit-Sandbox }

    It 'returns true when app, bucket, and version all match' {
        Test-AppSourceValid -AppName 'fzf' | Should -BeTrue
    }

    It 'returns false when the bucket does not exist' {
        # Remove bucket dir
        Remove-Item (Join-Path $env:SCOOP 'buckets\main') -Recurse -Force
        Test-AppSourceValid -AppName 'fzf' -WarningAction SilentlyContinue | Should -BeFalse
    }
}