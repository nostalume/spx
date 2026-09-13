#Requires -Module Pester

Describe 'SPX native module contract' {
    BeforeAll {
        . "$PSScriptRoot/TestSupport.ps1"
        $manifest = Join-Path $PSScriptRoot '..\SPX.psd1'
        Import-Module $manifest -Force
        $expectedExports = @(
            'Move-SpxApp', 'Restore-SpxApp', 'Get-SpxLinkedApp', 'Sync-SpxLinkedApp', 'Repair-SpxLinkedApp', 'Remove-SpxStaleLink',
            'Export-SpxLinkConfiguration', 'Import-SpxLinkConfiguration', 'Get-SpxAppSource', 'Set-SpxAppSource', 'Test-SpxAppSource',
            'Compare-SpxAppSource', 'Find-SpxAppSource', 'Get-SpxBucketMirror', 'New-SpxBucketMirror', 'Set-SpxBucketMirror',
            'Remove-SpxBucketMirror', 'Repair-SpxBucketMirror'
        ) | Sort-Object
    }
    It 'exports exactly the approved commands' {
        @(Get-Command -Module SPX | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be $expectedExports
    }

    It 'uses native binding for option-first calls and arrays' {
        $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive 'binding')
        try {
            New-SpxTestApp -Name one | Out-Null
            New-SpxTestApp -Name two | Out-Null
            $result = @(Get-SpxAppSource -Scope Local -Name one, two)
            $result.Count | Should -Be 2
            $result[0].PSTypeNames[0] | Should -Be 'SPX.AppSource'
        }
        finally { Exit-SpxTestSandbox }
    }

    It 'does not mutate Scoop roots on import' {
        $root = Join-Path $TestDrive 'neutral'
        $old = $env:SCOOP; $env:SCOOP = $root
        try { Remove-Module SPX; Import-Module $manifest -Force; Test-Path -LiteralPath $root | Should -BeFalse }
        finally { $env:SCOOP = $old; Import-Module $manifest -Force }
    }

    It 'gives mutations ShouldProcess and keeps reads read-only' {
        $mutations = @('Move-SpxApp', 'Restore-SpxApp', 'Sync-SpxLinkedApp', 'Repair-SpxLinkedApp', 'Remove-SpxStaleLink', 'Export-SpxLinkConfiguration', 'Import-SpxLinkConfiguration', 'Set-SpxAppSource', 'New-SpxBucketMirror', 'Set-SpxBucketMirror', 'Remove-SpxBucketMirror', 'Repair-SpxBucketMirror')
        foreach ($name in $mutations) { (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue }
        foreach ($name in @('Get-SpxLinkedApp', 'Get-SpxAppSource', 'Test-SpxAppSource', 'Compare-SpxAppSource', 'Find-SpxAppSource', 'Get-SpxBucketMirror')) { (Get-Command $name).Parameters.ContainsKey('WhatIf') | Should -BeFalse }
    }

    It 'binds object properties from the pipeline' {
        $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive 'pipeline')
        try {
            New-SpxTestApp -Name piped -Version 1 | Out-Null
            $result = [pscustomobject]@{AppName = 'piped' } | Get-SpxAppSource -Scope Local
            $result.Name | Should -Be piped
        }
        finally { Exit-SpxTestSandbox }
    }
}
