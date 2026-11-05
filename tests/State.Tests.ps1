#Requires -Module Pester

Describe 'SPX observed state and durable ownership' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; Import-Module (Join-Path $PSScriptRoot '..\SPX.psd1') -Force }
    BeforeEach { $sb = Enter-SpxTestSandbox -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); $destination = Join-Path $sb.Root 'destination' }
    AfterEach { Exit-SpxTestSandbox }

    It 'uses one app identity through differently cased reads, restore and reclaim' {
        New-SpxTestApp demo -Version 1 | Out-Null
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        (Get-SpxLinkedApp DEMO -Scope Local).State | Should -Be Healthy
        @(Get-SpxStatus -Scope Local).Count | Should -Be 1
        (Restore-SpxApp DEMO -Confirm:$false).Status | Should -Be Restored
        (Remove-SpxRetainedCopy Demo -Confirm:$false).Status | Should -Be Reclaimed
        (Get-SpxAppSource demo -Scope Local).Version | Should -Be 1
        $cfg = Get-Content (Join-Path $env:SCOOP 'spx\links.json') -Raw | ConvertFrom-Json
        @($cfg.local.PSObject.Properties).Count | Should -Be 1
    }

    It 'refuses case-colliding app identities without writing' {
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'links.json'
        $raw = '{"schema":2,"local":{"demo":{"Active":null,"Intent":null,"Retained":[]},"DEMO":{"Active":null,"Intent":null,"Retained":[]}},"global":{}}'
        [IO.File]::WriteAllText($path, $raw)
        (Get-SpxStatus demo -Scope Local).Status | Should -Be Invalid
        { Sync-SpxLinkedApp -Confirm:$false } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
    }

    It 'matches portable intent to existing ownership irrespective of case' {
        New-SpxTestApp demo -Version 1 | Out-Null
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $path = Join-Path $sb.Root 'import.json'
        @{ local = @{ DEMO = @{ Path = $destination } }; global = @{} } | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
        Import-SpxLinkConfiguration $path -Confirm:$false | Out-Null
        @(Get-SpxLinkedApp -Scope Local).Count | Should -Be 1
        (Get-SpxLinkedApp demo).State | Should -Be Healthy
    }

    It 'refuses case-colliding portable identities before creating state' {
        $path = Join-Path $sb.Root 'import.json'
        $escaped = $destination.Replace('\', '\\')
        [IO.File]::WriteAllText($path, ('{"local":{"demo":{"Path":"' + $escaped + '"},"DEMO":{"Path":"' + $escaped + '"}},"global":{}}'))
        { Import-SpxLinkConfiguration $path -Confirm:$false } | Should -Throw
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
    }

    It 'ignores restored and reclaimed history in implicit sync' {
        New-SpxTestApp history -Version 1 | Out-Null
        Move-SpxApp history $destination -Confirm:$false | Out-Null
        Restore-SpxApp history -Confirm:$false | Out-Null
        New-SpxTestApp active -Version 1 | Out-Null
        Move-SpxApp active $destination -Confirm:$false | Out-Null
        $result = @(Sync-SpxLinkedApp -Confirm:$false)
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be active
        Remove-SpxRetainedCopy history -Confirm:$false | Out-Null
        @(Sync-SpxLinkedApp -Confirm:$false).Count | Should -Be 1
        { Sync-SpxLinkedApp history -Confirm:$false } | Should -Throw -ErrorId 'Spx.LinkNotFound*'
    }

    It 'reads schema one without migration and upgrades only on an authorized mutation' {
        New-SpxTestApp -Name demo -Version 1 | Out-Null
        $path = Join-Path $env:SCOOP 'spx\links.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        $raw = '{"schema":1,"generation":4,"local":{},"global":{},"extension":"preserve"}'
        [IO.File]::WriteAllText($path, $raw)
        (Get-SpxStatus demo -Scope Local).Placement | Should -Be Canonical
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
        Move-SpxApp demo $destination -WhatIf
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $cfg.schema | Should -Be 2
        $cfg.extension | Should -Be preserve
        $cfg.local.demo.Active.Path | Should -Be $destination
        $cfg.local.demo.Retained.Count | Should -Be 1
        [IO.File]::ReadAllText($path + '.previous') | Should -BeExactly $raw
    }

    It 'refuses unknown schemas and presents invalid state without following it' {
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'links.json'; [IO.File]::WriteAllText($path, '{"schema":999,"local":{},"global":{}}')
        (Get-SpxStatus demo -Scope Local).Status | Should -Be Invalid
        { Export-SpxLinkConfiguration (Join-Path $sb.Root 'export.json') -Confirm:$false } | Should -Throw
        Test-Path -LiteralPath (Join-Path $sb.Root 'export.json') | Should -BeFalse
        (Get-Content $path -Raw | ConvertFrom-Json).schema | Should -Be 999
    }

    It 'does not let portable intent erase active ownership' {
        New-SpxTestApp -Name demo -Version 1 | Out-Null
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $path = Join-Path $sb.Root 'import.json'; [IO.File]::WriteAllText($path, '{"local":{},"global":{}}')
        { Import-SpxLinkConfiguration $path -Confirm:$false } | Should -Throw -ErrorId 'Spx.AlreadyLinkedElsewhere*'
        (Get-SpxLinkedApp demo -Scope Local).State | Should -Be Healthy
        (Restore-SpxApp demo -Confirm:$false).Status | Should -Be Restored
        $cfg = Get-Content (Join-Path $env:SCOOP 'spx\links.json') -Raw | ConvertFrom-Json
        $cfg.local.demo.Active | Should -BeNullOrEmpty
        $cfg.local.demo.LastOperation.Action | Should -Be Restore
        $cfg.local.demo.LastOperation.Outcome | Should -Be Committed
        $cfg.local.demo.Retained.Count | Should -Be 2
        foreach ($copy in $cfg.local.demo.Retained) { Test-Path -LiteralPath $copy.Path | Should -BeTrue }
        (Get-SpxStatus demo -Scope Local).Placement | Should -Be Canonical
    }

    It 'treats imported paths as intent rather than proof of an external junction' {
        $app = New-SpxTestApp -Name demo -Version 1
        $external = Join-Path $sb.Root 'external'; $null = New-Item -ItemType Directory -Path (Join-Path $external 'demo') -Force
        Move-Item -LiteralPath $app.VersionPath -Destination (Join-Path $external 'demo\1')
        $null = New-Item -ItemType Junction -Path $app.VersionPath -Target (Join-Path $external 'demo\1')
        $path = Join-Path $sb.Root 'import.json'
        @{ local = @{ demo = @{ Path = $external } }; global = @{} } | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
        Import-SpxLinkConfiguration $path -Confirm:$false | Out-Null
        (Get-SpxStatus demo -Scope Local).Status | Should -Be Conflict
        { Sync-SpxLinkedApp demo -Confirm:$false } | Should -Throw -ErrorId 'Spx.LinkTargetMismatch*'
        Test-Path (Join-Path $external 'demo\1\payload.txt') | Should -BeTrue
    }

    It 'discovers and preserves a malformed orphan journal in the read-only view' {
        $dir = Join-Path $env:SCOOP 'spx\operations\link'; $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir 'local-orphan.json'; [IO.File]::WriteAllText($path, '{invalid')
        $view = Get-SpxStatus -Scope Local
        $view.Name | Should -Be orphan
        $view.Status | Should -Be Invalid
        (Get-SpxLinkedApp orphan -Scope Local).State | Should -Be Invalid
        [IO.File]::ReadAllText($path) | Should -BeExactly '{invalid'
    }

    It 'keeps reads and empty repair effect-neutral and reports missing targets' {
        $before = @(Get-ChildItem -LiteralPath $sb.Root -Recurse -Force).Count
        (Get-SpxStatus absent -Scope Local).Status | Should -Be Missing
        @(Repair-SpxLinkedApp absent -Confirm:$false).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $sb.Root -Recurse -Force).Count | Should -Be $before
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
    }

    It 'includes pending buckets even when their directory has disappeared' {
        $op = @{ schema = 1; id = 'pending'; kind = 'mirror'; bucket = 'gone'; action = 'Set'; phase = 'Prepared'; oldUrl = 'https://old.example'; originalUrl = 'https://old.example'; requestedUrl = 'https://new.example' }
        $dir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $dir -Force
        $op | ConvertTo-Json | Set-Content (Join-Path $dir 'gone.json') -Encoding UTF8
        $view = Get-SpxStatus -Buckets
        $view.Name | Should -Be gone
        $view.Status | Should -Be NeedsRecovery
        $view.PendingOperation.id | Should -Be pending
    }

    It 'serializes source mutations against another process without blocking reads' {
        New-SpxTestApp -Name demo -Version 1 | Out-Null
        New-SpxTestBucket -Name extras -AppName demo -Version 1 | Out-Null
        $holder = Join-Path $sb.Root 'holder.ps1'
        @'
param ($Repository, $Ready, $Release)
$ErrorActionPreference = 'Stop'
Import-Module "$Repository/SPX.psd1" -Force
& (Get-Module SPX) {
    param ($Ready, $Release)
    Invoke-SpxMutation {
        [IO.File]::WriteAllText($Ready, 'locked')
        $until = [DateTime]::UtcNow.AddSeconds(20)
        while (-not [IO.File]::Exists($Release) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
    }
} $Ready $Release
[IO.File]::WriteAllText($Ready, 'released')
'@ | Set-Content -LiteralPath $holder -Encoding UTF8
        $ready = Join-Path $sb.Root 'ready'; $release = Join-Path $sb.Root 'release'
        $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + $holder + '"'), '-Repository', ('"' + $repository + '"'), '-Ready', ('"' + $ready + '"'), '-Release', ('"' + $release + '"'))
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $sb.Root 'holder.out') -RedirectStandardError (Join-Path $sb.Root 'holder.err')
        try {
            $until = [DateTime]::UtcNow.AddSeconds(10)
            while (-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
            Test-Path -LiteralPath $ready | Should -BeTrue
            (Get-SpxStatus demo -Scope Local).Placement | Should -Be Canonical
            { Set-SpxAppSource demo -Bucket extras -Confirm:$false } | Should -Throw
            (Get-SpxAppSource demo -Scope Local).Bucket | Should -Be main
            Test-Path (Join-Path $env:SCOOP 'spx\operations') | Should -BeFalse
        }
        finally {
            [IO.File]::WriteAllText($release, 'release')
            if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Writer holder did not terminate.' }
        }
        [IO.File]::ReadAllText($ready) | Should -Be released
    }

    It 'rejects drive-relative intent without creating SPX state' {
        $path = Join-Path $sb.Root 'relative.json'
        [IO.File]::WriteAllText($path, '{"local":{"demo":{"Path":"C:relative"}},"global":{}}')
        { Import-SpxLinkConfiguration $path -Confirm:$false } | Should -Throw
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
    }

    It 'reports malformed bucket state without hiding the failure behind an empty list' {
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'spx.json'; [IO.File]::WriteAllText($path, '{"mirrors":[]}')
        (Get-SpxStatus -Buckets).Status | Should -Be Invalid
        (Get-SpxStatus -Bucket main).Status | Should -Be Invalid
        [IO.File]::ReadAllText($path) | Should -BeExactly '{"mirrors":[]}'
    }

    It 'reads the complete source relationship without creating a state root' {
        New-SpxTestApp -Name one -Version 1 | Out-Null
        New-SpxTestApp -Name two -Version 1 | Out-Null
        New-SpxTestGitBucket main 'https://origin.example/main.git' | Out-Null
        $views = @(Get-SpxStatus -Scope Local)
        $views.Count | Should -Be 2
        @($views.Status | Select-Object -Unique) | Should -Be @('Ready')
        @($views.Source.CurrentUrl | Select-Object -Unique) | Should -Be @('https://origin.example/main.git')
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
    }

    It 'rejects malformed object shape: <Case>' -ForEach @(
        @{ Case = 'array root'; Json = '[{"local":{},"global":{}}]' },
        @{ Case = 'null retained entry'; Json = '{"schema":2,"local":{"demo":{"Active":null,"Intent":null,"Retained":[null]}},"global":{}}' }
    ) {
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'links.json'; [IO.File]::WriteAllText($path, $Json)
        (Get-SpxStatus demo -Scope Local).Status | Should -Be Invalid
        [IO.File]::ReadAllText($path) | Should -BeExactly $Json
    }

    It 'does not list a settled receipt alone as a configured relocation' {
        New-SpxTestApp -Name demo -Version 1 | Out-Null
        $dir = Join-Path $env:SCOOP 'spx'; $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'links.json'
        $json = '{"schema":2,"local":{"demo":{"Active":null,"Intent":null,"Retained":[],"LastOperation":{"Id":"done","Action":"Move","Outcome":"RolledBack"}}},"global":{}}'
        [IO.File]::WriteAllText($path, $json)
        @(Get-SpxLinkedApp -Scope Local).Count | Should -Be 0
        (Get-SpxStatus demo -Scope Local).Placement | Should -Be Canonical
        [IO.File]::ReadAllText($path) | Should -BeExactly $json
    }

    It 'isolates invalid installed persist definitions from other observations' {
        $app = New-SpxTestApp -Name bad -Version 1
        New-SpxTestApp -Name good -Version 1 | Out-Null
        Move-SpxApp bad $destination -Confirm:$false | Out-Null
        [IO.File]::WriteAllText((Join-Path $app.VersionPath 'manifest.json'), '{"persist":["..\\escape"]}')
        $views = @(Get-SpxStatus -Scope Local)
        ($views | Where-Object Name -EQ bad).Status | Should -Be Invalid
        ($views | Where-Object Name -EQ good).Placement | Should -Be Canonical
        (Get-SpxLinkedApp bad -Scope Local).State | Should -Be Invalid
        Test-Path (Join-Path $app.VersionPath 'payload.txt') | Should -BeTrue
    }

    It 'refuses to export portable intent over its own durable state even with Force' {
        New-SpxTestApp -Name demo -Version 1 | Out-Null
        Move-SpxApp demo $destination -Confirm:$false | Out-Null
        $path = Join-Path $env:SCOOP 'spx\links.json'; $before = [IO.File]::ReadAllText($path)
        { Export-SpxLinkConfiguration $path -Force -Confirm:$false } | Should -Throw -ErrorId 'Spx.ExportStateConflict*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
        (Get-SpxLinkedApp demo -Scope Local).State | Should -Be Healthy
        (Get-SpxLinkedApp demo -Scope Local).RetainedCopies.Count | Should -Be 1
    }
}
