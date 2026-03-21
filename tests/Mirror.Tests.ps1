#Requires -Module Pester
# tests/Mirror.Tests.ps1 - Integration tests for Mirror module
# git operations are mocked; config read/write is tested against a real sandbox.

BeforeAll {
    . "$PSScriptRoot/Sandbox.ps1"
    . "$PSScriptRoot/../lib/Core.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
    . "$PSScriptRoot/../modules/Mirror.ps1"

    # Mock git so tests run without a real git repo
    Mock Get-BucketRemoteUrl { return 'https://github.com/ScoopInstaller/Main' }
    Mock Set-BucketRemoteUrl {}
}

Describe 'Set-BucketMirror: add semantics' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketDir -Name 'main'
    }
    AfterAll { Exit-Sandbox }

    It 'saves original and mirror URLs in spx.json' {
        $r = Set-BucketMirror -BucketName 'main' -Url 'https://mirror.example.com/main' -Add
        $r.MirrorURL   | Should -Be 'https://mirror.example.com/main'
        $r.OriginalURL | Should -Be 'https://github.com/ScoopInstaller/Main'

        $saved = Get-SpxConfig -Key 'mirrors'
        $saved            | Should -Not -BeNullOrEmpty
        $saved['main']    | Should -Not -BeNullOrEmpty
        $saved['main']['mirror']   | Should -Be 'https://mirror.example.com/main'
        $saved['main']['original'] | Should -Be 'https://github.com/ScoopInstaller/Main'
    }

    It 'throws on -Add when a mirror already exists' {
        { Set-BucketMirror -BucketName 'main' -Url 'https://other.mirror.com' -Add } | Should -Throw
    }
}

Describe 'Set-BucketMirror: set semantics (overwrite)' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketDir -Name 'extras'
        # Seed an existing mirror entry
        Set-SpxConfig -Key 'mirrors' -Value @{
            extras = @{ original = 'https://github.com/ScoopInstaller/Extras'; mirror = 'https://old.mirror.com' }
        }
    }
    AfterAll { Exit-Sandbox }

    It 'updates mirror URL but preserves the original' {
        $r = Set-BucketMirror -BucketName 'extras' -Url 'https://new.mirror.com'
        $r.MirrorURL   | Should -Be 'https://new.mirror.com'
        $r.OriginalURL | Should -Be 'https://github.com/ScoopInstaller/Extras'

        $saved = (Get-SpxConfig -Key 'mirrors')['extras']
        $saved['mirror']   | Should -Be 'https://new.mirror.com'
        $saved['original'] | Should -Be 'https://github.com/ScoopInstaller/Extras'
    }
}

Describe 'Remove-BucketMirror: restores original URL' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketDir -Name 'versions'
        Set-SpxConfig -Key 'mirrors' -Value @{
            versions = @{ original = 'https://github.com/ScoopInstaller/Versions'; mirror = 'https://fast.mirror.com' }
        }
    }
    AfterAll { Exit-Sandbox }

    It 'calls Set-BucketRemoteUrl with the original URL' {
        Remove-BucketMirror -BucketName 'versions' -Confirm:$false
        Assert-MockCalled Set-BucketRemoteUrl -Times 1 -ParameterFilter {
            $Url -eq 'https://github.com/ScoopInstaller/Versions'
        }
    }

    It 'removes the bucket entry from spx.json' {
        $saved = Get-SpxConfig -Key 'mirrors'
        $saved.ContainsKey('versions') | Should -BeFalse
    }

    It 'throws when no mirror is configured for the bucket' {
        { Remove-BucketMirror -BucketName 'versions' -Confirm:$false } | Should -Throw
    }
}

Describe 'Get-BucketMirror: listing' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketDir -Name 'main'
        New-SandboxBucketDir -Name 'extras'
        Set-SpxConfig -Key 'mirrors' -Value @{
            main = @{ original = 'https://github.com/ScoopInstaller/Main'; mirror = 'https://cn.mirror.com/main' }
        }
    }
    AfterAll { Exit-Sandbox }

    It 'returns one result per bucket' {
        $results = @(Get-BucketMirror)
        $results.Count | Should -Be 2
    }

    It 'marks mirrored bucket correctly' {
        $main = @(Get-BucketMirror) | Where-Object { $_.Bucket -eq 'main' }
        $main.IsMirrored | Should -BeTrue
        $main.MirrorURL  | Should -Be 'https://cn.mirror.com/main'
    }

    It 'marks un-mirrored bucket correctly' {
        $extras = @(Get-BucketMirror) | Where-Object { $_.Bucket -eq 'extras' }
        $extras.IsMirrored | Should -BeFalse
        $extras.MirrorURL  | Should -BeNullOrEmpty
    }

    It 'returns a single bucket when BucketName is specified' {
        $result = @(Get-BucketMirror -BucketName 'main')
        $result.Count    | Should -Be 1
        $result[0].Bucket | Should -Be 'main'
    }

    It 'warns and returns nothing for an unknown bucket' {
        $result = Get-BucketMirror -BucketName 'no-such-bucket' -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Mirror config survives multiple write cycles' {
    BeforeAll {
        $sb = Enter-Sandbox
        New-SandboxBucketDir -Name 'main'
        New-SandboxBucketDir -Name 'extras'
    }
    AfterAll { Exit-Sandbox }

    It 'retains independent entries for two buckets' {
        Set-BucketMirror -BucketName 'main'   -Url 'https://m1.example.com'
        Set-BucketMirror -BucketName 'extras' -Url 'https://m2.example.com'

        $cfg = Get-SpxConfig -Key 'mirrors'
        $cfg['main']['mirror']   | Should -Be 'https://m1.example.com'
        $cfg['extras']['mirror'] | Should -Be 'https://m2.example.com'
    }

    It 'removing one does not affect the other' {
        Remove-BucketMirror -BucketName 'main' -Confirm:$false
        $cfg = Get-SpxConfig -Key 'mirrors'
        $cfg.ContainsKey('main')   | Should -BeFalse
        $cfg.ContainsKey('extras') | Should -BeTrue
    }
}