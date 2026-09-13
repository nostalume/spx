#Requires -Module Pester

Describe 'SPX script CLI contract' {
    BeforeAll {
        . "$PSScriptRoot/TestSupport.ps1"
        $entry = Join-Path $PSScriptRoot '..\spx.ps1'
    }

    It 'shows root and leaf help without importing the module or creating state' {
        $root = Join-Path $TestDrive 'help-neutral'
        $old = $env:SCOOP
        $env:SCOOP = $root
        Remove-Module SPX -ErrorAction SilentlyContinue
        try {
            $rootHelp = & $entry -Help | Out-String
            $leafHelp = & $entry link -Help | Out-String
            $rootHelp | Should -Match 'spx <command>'
            $leafHelp | Should -Match 'spx link'
            Get-Module SPX | Should -BeNullOrEmpty
            Test-Path -LiteralPath $root | Should -BeFalse
        }
        finally {
            $env:SCOOP = $old
        }
    }

    It 'reports the package version without importing the module' {
        Remove-Module SPX -ErrorAction SilentlyContinue
        (& $entry -Version | Out-String).Trim() | Should -Be '0.5.0'
        Get-Module SPX | Should -BeNullOrEmpty
    }

    It 'renders every declared leaf from one specification without importing the module' {
        Remove-Module SPX -ErrorAction SilentlyContinue
        . (Join-Path $PSScriptRoot '..\lib\Cli.ps1')
        foreach ($key in (Get-SpxCliSpecification).Keys) {
            $parts = $key -split '/'
            $help = if ($parts.Count -eq 1) {
                & $entry $parts[0] -Help | Out-String
            }
            else {
                & $entry $parts[0] $parts[1] -Help | Out-String
            }
            $help | Should -Match ([regex]::Escape("spx $($key.Replace('/', ' '))"))
        }
        Get-Module SPX | Should -BeNullOrEmpty
    }

    It 'uses native case-insensitive parameter binding and emits module objects' {
        $sandbox = Enter-SpxTestSandbox -Root (Join-Path $TestDrive 'binding')
        try {
            New-SpxTestApp -Name jq | Out-Null
            $result = & $entry source get jq -sCoPe lOcAl
            $result.PSTypeNames[0] | Should -Be 'SPX.AppSource'
            $result.Name | Should -Be 'jq'
            $result.Scope | Should -Be 'Local'
        }
        finally {
            Exit-SpxTestSandbox
        }
    }

    It 'rejects parameters that do not belong to the selected leaf' {
        $caught = $null
        try {
            & $entry linked -Url 'https://example.test/repository.git'
        }
        catch {
            $caught = $_
        }
        $caught | Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId | Should -Match '^Spx\.CliUsage'
    }

    It 'rejects missing required leaf parameters before module import' {
        Remove-Module SPX -ErrorAction SilentlyContinue
        { & $entry link jq } | Should -Throw -ErrorId 'Spx.CliUsage'
        { & $entry mirror set main } | Should -Throw -ErrorId 'Spx.CliUsage'
        Get-Module SPX | Should -BeNullOrEmpty
    }

    It 'rejects irrelevant parameters on passive fast paths' {
        { & $entry -Version -Destination 'D:\invalid' } | Should -Throw -ErrorId 'Spx.CliUsage'
        { & $entry linked -Help -Url 'https://example.test/repository.git' } | Should -Throw -ErrorId 'Spx.CliUsage'
    }

    It 'propagates native WhatIf without mutating app or SPX state' {
        $sandbox = Enter-SpxTestSandbox -Root (Join-Path $TestDrive 'whatif')
        try {
            $app = New-SpxTestApp -Name jq
            $destination = Join-Path $TestDrive 'relocated'
            & $entry link jq -Destination $destination -Scope Local -WhatIf
            Test-Path -LiteralPath (Join-Path $app.VersionPath 'payload.txt') | Should -BeTrue
            Test-Path -LiteralPath $destination | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $env:SCOOP 'spx') | Should -BeFalse
        }
        finally {
            Exit-SpxTestSandbox
        }
    }

    It 'exposes one target module function for every command leaf' {
        . (Join-Path $PSScriptRoot '..\lib\Cli.ps1')
        $specification = Get-SpxCliSpecification
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\SPX.psd1')
        @($specification.Values.Function | Sort-Object -Unique) | Should -Be @($manifest.FunctionsToExport | Sort-Object)
    }
}
