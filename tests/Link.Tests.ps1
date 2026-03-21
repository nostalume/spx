#Requires -Module Pester
# tests/Config.Tests.ps1 - Integration tests for Config read/write layer

BeforeAll {
    . "$PSScriptRoot/Sandbox.ps1"
    . "$PSScriptRoot/../lib/Core.ps1"
    . "$PSScriptRoot/../lib/Config.ps1"
}

Describe 'Get-LinksConfig: empty-file and missing-file behaviour' {
    BeforeAll { $sb = Enter-Sandbox }
    AfterAll  { Exit-Sandbox }

    It 'returns a default structure when no links.json exists' {
        $cfg = Get-LinksConfig
        $cfg        | Should -Not -BeNullOrEmpty
        $cfg['local']  | Should -BeOfType [hashtable]
        $cfg['global'] | Should -BeOfType [hashtable]
        $cfg['local'].Count  | Should -Be 0
        $cfg['global'].Count | Should -Be 0
    }

    It 'round-trips a written config through file I/O' {
        Set-LinkEntry -AppName 'ripgrep' -Path 'D:\Tools' -Version '14.0.0'
        Set-LinkEntry -AppName 'fd'      -Path 'D:\Tools' -Version '10.2.0'
        $cfg = Get-LinksConfig
        $cfg['local']['ripgrep'].Path    | Should -Be 'D:\Tools'
        $cfg['local']['ripgrep'].Version | Should -Be '14.0.0'
        $cfg['local']['fd'].Version      | Should -Be '10.2.0'
    }
}

Describe 'Get-SpxConfig / Set-SpxConfig: generic key-value store' {
    BeforeAll { $sb = Enter-Sandbox }
    AfterAll  { Exit-Sandbox }

    It 'returns null for a missing key' {
        Get-SpxConfig -Key 'nonexistent' | Should -BeNullOrEmpty
    }

    It 'writes and reads back a string value' {
        Set-SpxConfig -Key 'testKey' -Value 'hello'
        Get-SpxConfig -Key 'testKey' | Should -Be 'hello'
    }

    It 'writes and reads back a nested hashtable' {
        Set-SpxConfig -Key 'nested' -Value @{ a = 1; b = 'two' }
        $val = Get-SpxConfig -Key 'nested'
        $val['a'] | Should -Be 1
        $val['b'] | Should -Be 'two'
    }

    It 'overwrites an existing key without disturbing other keys' {
        Set-SpxConfig -Key 'key1' -Value 'original'
        Set-SpxConfig -Key 'key2' -Value 'other'
        Set-SpxConfig -Key 'key1' -Value 'updated'
        Get-SpxConfig -Key 'key1' | Should -Be 'updated'
        Get-SpxConfig -Key 'key2' | Should -Be 'other'
    }
}