#Requires -Module Pester

Describe 'SPX configuration durability and metadata cost' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    AfterEach { Exit-SpxTestSandbox }

    It 'atomically exports and imports valid link generations without lock residue' {
        $app = New-SpxTestApp -Name portable -Version 1
        $destination = Join-Path $sb.Root 'destination'
        Move-SpxApp portable $destination -Confirm:$false | Out-Null
        $export = Join-Path $sb.Root 'backup\links.json'
        Export-SpxLinkConfiguration $export -Confirm:$false | Out-Null
        Restore-SpxApp portable -Confirm:$false | Out-Null
        Import-SpxLinkConfiguration $export -Confirm:$false | Out-Null
        (Get-SpxLinkedApp portable).Destination | Should -Be $destination
        (Get-SpxLinkedApp portable).State | Should -Be ImportedIntent
        @(Get-ChildItem (Join-Path $env:SCOOP 'spx') -Recurse -Filter '*.lock' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path (Join-Path $env:SCOOP 'spx\links.json.previous') | Should -BeTrue
    }

    It 'enumerates a representative metadata-heavy layout within a bounded budget' {
        1..120 | ForEach-Object { New-SpxTestApp -Name ('app' + $_) -Version '1.0' | Out-Null }
        [GC]::Collect(); $memoryBefore = [GC]::GetTotalMemory($true)
        $watch = [Diagnostics.Stopwatch]::StartNew(); $items = @(Get-SpxAppSource -Scope Local); $watch.Stop()
        $memoryAfter = [GC]::GetTotalMemory($false)
        $items.Count | Should -Be 120
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
        ($memoryAfter - $memoryBefore) | Should -BeLessThan 134217728
    }
}
