#Requires -Module Pester

Describe 'SPX command modes' {
    BeforeAll {
        . "$PSScriptRoot/TestSupport.ps1"
        . (Join-Path $PSScriptRoot '..\src\Cli.ps1')
        $entry = Join-Path $PSScriptRoot '..\spx.ps1'
    }
    It 'admits <Key> without loading state' -ForEach @(
        @{Key = 'link'; Command = 'link'; Names = @('one'); Bound = @{Destination = 'D:\Apps' } }
        @{Key = 'unlink'; Command = 'unlink'; Names = @('one'); Bound = @{} }
        @{Key = 'linked'; Command = 'linked'; Names = @(); Bound = @{} }
        @{Key = 'sync'; Command = 'sync'; Names = @('one'); Bound = @{} }
        @{Key = 'repair'; Command = 'repair'; Names = @(); Bound = @{} }
        @{Key = 'repair.bucket'; Command = 'repair'; Names = @(); Bound = @{Bucket = 'main' } }
        @{Key = 'repair.buckets'; Command = 'repair'; Names = @(); Bound = @{Buckets = $true } }
        @{Key = 'cleanup'; Command = 'cleanup'; Names = @('one'); Bound = @{} }
        @{Key = 'source'; Command = 'source'; Names = @(); Bound = @{} }
        @{Key = 'source.set'; Command = 'source'; Names = @('one', 'two'); Bound = @{Bucket = 'extras' } }
        @{Key = 'source.buckets'; Command = 'source'; Names = @(); Bound = @{Buckets = $true } }
        @{Key = 'source.bucket'; Command = 'source'; Names = @(); Bound = @{Bucket = 'main' } }
        @{Key = 'source.url'; Command = 'source'; Names = @(); Bound = @{Bucket = 'main'; Url = 'https://example/main.git' } }
        @{Key = 'source.reset'; Command = 'source'; Names = @(); Bound = @{Bucket = 'main'; Reset = $true } }
        @{Key = 'source.find'; Command = 'source'; Names = @('one'); Bound = @{Find = $true } }
        @{Key = 'source.compare'; Command = 'source'; Names = @('one'); Bound = @{Compare = 'extras' } }
        @{Key = 'source.check'; Command = 'source'; Names = @('one'); Bound = @{CheckVersion = $true } }
    ) {
        (Resolve-SpxCliInvocation $Command $Names $Bound).Key | Should -Be $Key
    }
    It 'rejects <Label> before module import' -ForEach @(
        @{Label = 'app URL'; Command = 'source'; Names = @('one'); Bound = @{Bucket = 'main'; Url = 'https://example/main.git' } }
        @{Label = 'scope on buckets'; Command = 'source'; Names = @(); Bound = @{Buckets = $true; Scope = 'Local' } }
        @{Label = 'read preview'; Command = 'source'; Names = @('one'); Bound = @{WhatIf = $true } }
        @{Label = 'combined selectors'; Command = 'source'; Names = @('one'); Bound = @{Find = $true; Compare = 'main' } }
        @{Label = 'reset URL'; Command = 'source'; Names = @(); Bound = @{Bucket = 'main'; Reset = $true; Url = 'https://example/main.git' } }
        @{Label = 'all-scope write'; Command = 'source'; Names = @('one'); Bound = @{Bucket = 'main'; Scope = 'All' } }
        @{Label = 'ambiguous repair'; Command = 'repair'; Names = @('one'); Bound = @{Bucket = 'main' } }
        @{Label = 'implicit cleanup'; Command = 'cleanup'; Names = @(); Bound = @{} }
        @{Label = 'multi compare'; Command = 'source'; Names = @('one', 'two'); Bound = @{Compare = 'main' } }
        @{Label = 'missing destination'; Command = 'link'; Names = @('one'); Bound = @{} }
        @{Label = 'missing find target'; Command = 'source'; Names = @(); Bound = @{Find = $true } }
        @{Label = 'find scope'; Command = 'source'; Names = @('one'); Bound = @{Find = $true; Scope = 'All' } }
        @{Label = 'old source syntax'; Command = 'source'; Names = @('set', 'one'); Bound = @{Bucket = 'main' } }
        @{Label = 'old mirror'; Command = 'mirror'; Names = @('get'); Bound = @{} }
        @{Label = 'old config'; Command = 'config'; Names = @('export'); Bound = @{} }
    ) {
        Remove-Module SPX -ErrorAction SilentlyContinue
        { Resolve-SpxCliInvocation $Command $Names $Bound } | Should -Throw -ErrorId 'Spx.CliUsage'
        Get-Module SPX | Should -BeNullOrEmpty
    }
    It 'admits mode-specific help without execution prerequisites or state access' {
        $old = $env:SCOOP; $env:SCOOP = Join-Path $TestDrive 'help-only'
        Remove-Module SPX -ErrorAction SilentlyContinue
        try {
            $text = & $entry source demo -Bucket extras -Help | Out-String
            $text | Should -Match 'Change only an app'
            $text | Should -Not -Match 'Inspect all added'
            (& $entry source -Url https://example/main.git -Help | Out-String) | Should -Match 'preserving the original'
            (& $entry source -Find -Help | Out-String) | Should -Match 'Find candidates'
            (& $entry repair -Buckets -Help | Out-String) | Should -Match 'Recover all pending bucket'
            (& $entry link -Help | Out-String) | Should -Match 'Relocate an installed'
            { & $entry source demo -Bucket extras -Find -Help } | Should -Throw -ErrorId 'Spx.CliUsage'
            { & $entry source -Bucket main -Scope All -Help } | Should -Throw -ErrorId 'Spx.CliUsage'
            Get-Module SPX | Should -BeNullOrEmpty
            Test-Path $env:SCOOP | Should -BeFalse
        }
        finally { $env:SCOOP = $old }
    }

    It 'keeps help and version independent of Scoop and the module' {
        $old = $env:SCOOP; $env:SCOOP = Join-Path $TestDrive 'absent'
        Remove-Module SPX -ErrorAction SilentlyContinue
        try {
            (& $entry -Help | Out-String) | Should -Match 'spx <command>'
            foreach ($command in 'source', 'repair', 'cleanup', 'link', 'unlink', 'linked', 'sync') { (& $entry $command -Help | Out-String) | Should -Match "spx $command" }
            (& $entry help source | Out-String) | Should -Match 'CheckVersion'
            (& $entry -Version) | Should -Be '0.5.0'
            { & $entry -Version -Scope All } | Should -Throw -ErrorId 'Spx.CliUsage'
            Get-Module SPX | Should -BeNullOrEmpty
            Test-Path $env:SCOOP | Should -BeFalse
        }
        finally { $env:SCOOP = $old }
    }
}

Describe 'SPX CLI workflows and completion' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; $entry = Join-Path $PSScriptRoot '..\spx.ps1'; $module = Join-Path $PSScriptRoot '..\SPX.psd1' }
    BeforeEach { $sb = Enter-SpxTestSandbox (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); Import-Module $module -Force }
    AfterEach { Exit-SpxTestSandbox }

    It 'lists only managed placement while source inventories ordinary installations' {
        New-SpxTestApp managed -Version 1 | Out-Null
        New-SpxTestApp ordinary -Version 1 | Out-Null
        & $entry link managed -Destination (Join-Path $sb.Root 'dest') -Confirm:$false | Out-Null
        $linked = @(& $entry linked -Scope Local)
        $linked.Count | Should -Be 1
        $linked[0].Name | Should -Be managed
        $linked[0].PSTypeNames | Should -Contain 'SPX.Status'
        $linked[0].IsManaged | Should -BeTrue
        $linked[0].Location | Should -Be (Join-Path $sb.Root 'dest\managed\1')
        @(& $entry source -Scope Local).Count | Should -Be 2
        @(TabExpansion2 'spx linked o' 12).CompletionMatches.Count | Should -Be 0
        & $entry unlink managed -Confirm:$false | Out-Null
        @(& $entry linked -Scope Local).Count | Should -Be 1
        & $entry cleanup managed -Confirm:$false | Out-Null
        @(& $entry linked -Scope Local).Count | Should -Be 0
    }

    It 'keeps invalid-state evidence visible in linked through the unified query' {
        $path = Join-Path $env:SCOOP 'spx\links.json'; $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent)
        $raw = '{"schema":999,"local":{},"global":{}}'; [IO.File]::WriteAllText($path, $raw)
        $view = @(& $entry linked -Scope Local)
        $view.Count | Should -Be 1
        $view[0].Status | Should -Be Invalid
        $view[0].Issues.Code | Should -Contain InvalidState
        [IO.File]::ReadAllText($path) | Should -BeExactly $raw
    }

    It 'keeps pipeline objects and separates app and repository source effects' {
        New-SpxTestApp one -Version 1 | Out-Null
        New-SpxTestApp two -Version 1 | Out-Null
        $git = New-SpxTestGitBucket main 'https://origin.example/main.git'
        New-SpxTestBucket extras one -Version 1 | Out-Null
        $result = @('one', 'two') | & $entry source -Scope Local
        @($result).Count | Should -Be 2
        $result[0].PSTypeNames | Should -Contain 'SPX.Status'
        $result[0].Source.Bucket | Should -Be main
        (& $entry source one -Bucket extras -Confirm:$false).NewBucket | Should -Be extras
        (& git -C $git remote get-url origin) | Should -Be 'https://origin.example/main.git'
        & $entry source -Bucket main -Url 'https://mirror.example/main.git' -Confirm:$false | Out-Null
        (& $entry source two -Scope Local).Source.CurrentUrl | Should -Be 'https://mirror.example/main.git'
        (Get-SpxAppSource one -Scope Local).Bucket | Should -Be extras
        & $entry source -Bucket main -Reset -Confirm:$false | Out-Null
        (& $entry source one -CheckVersion).VersionMatches | Should -BeTrue
        (& $entry source one -Compare extras).VersionMatch | Should -BeTrue
        @(& $entry source one -Find).Count | Should -Be 1
    }
    It 'previews qualified cleanup, then reclaims copies and repeats unchanged' {
        $app = New-SpxTestApp one -Version 1
        & $entry link one -Destination (Join-Path $sb.Root 'dest') -Confirm:$false | Out-Null
        $state = Join-Path $env:SCOOP 'spx\links.json'; $before = [IO.File]::ReadAllText($state)
        $preview = & $entry cleanup one -WhatIf
        $preview.Status | Should -Be Preview
        $preview.EligibleCopies.Count | Should -Be 1
        [IO.File]::ReadAllText($state) | Should -BeExactly $before
        (& $entry cleanup one -Confirm:$false).Status | Should -Be Reclaimed
        (& $entry cleanup one -Confirm:$false).Status | Should -Be Unchanged
        Test-Path (Join-Path $app.VersionPath 'payload.txt') | Should -BeTrue
    }
    It 'stops a batch at the first error and preserves the earlier commit' {
        New-SpxTestApp one -Version 1 | Out-Null
        New-SpxTestApp two -Version 1 | Out-Null
        New-SpxTestBucket extras one -Version 1 | Out-Null
        { & $entry source one, missing, two -Bucket extras -Confirm:$false -ErrorAction Continue } | Should -Throw
        (Get-SpxAppSource one -Scope Local).Bucket | Should -Be extras
        (Get-SpxAppSource two -Scope Local).Bucket | Should -Be main
    }
    It 'filters actual parameter completions for <Tail>' -ForEach @(
        @{Tail = 'source one -Find -'; Present = @('-Help'); Absent = @('-Scope', '-Bucket', '-Url', '-WhatIf') }
        @{Tail = 'source one -Find -Verbose -'; Present = @('-Help'); Absent = @('-Scope', '-Bucket', '-Url', '-WhatIf') }
        @{Tail = 'source one -Find -ErrorAction Stop -'; Present = @('-Help'); Absent = @('-Scope', '-Bucket', '-Url', '-WhatIf') }
        @{Tail = 'source one -Compare extras -ea Stop -'; Present = @('-Scope'); Absent = @('-Bucket', '-Url', '-WhatIf') }
        @{Tail = 'source -Buckets -'; Present = @('-Help'); Absent = @('-Scope', '-Bucket', '-Url', '-WhatIf') }
        @{Tail = 'source one -Bucket extras -'; Present = @('-Scope', '-Force', '-WhatIf'); Absent = @('-Url', '-Reset', '-Find') }
        @{Tail = 'source -Bucket main -'; Present = @('-Url', '-Reset'); Absent = @('-Scope', '-Force', '-Find') }
        @{Tail = 'repair -Bucket main -'; Present = @('-WhatIf', '-Confirm'); Absent = @('-Scope', '-Buckets', '-Url') }
        @{Tail = 'link one -'; Present = @('-Destination', '-Scope', '-WhatIf'); Absent = @('-Bucket', '-Url', '-Find') }
    ) {
        $line = "& '$entry' $Tail"
        $matches = @((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText)
        foreach ($value in $Present) { $matches | Should -Contain $value }
        foreach ($value in $Absent) { $matches | Should -Not -Contain $value }
    }
    It 'completes scoped app and bucket values without creating state' {
        New-SpxTestApp localapp -Version 1 | Out-Null
        New-SpxTestApp globalapp -Version 1 -Global | Out-Null
        New-SpxTestBucket extras | Out-Null
        $line = "& '$entry' source -Scope Local loc"
        (TabExpansion2 $line $line.Length).CompletionMatches.CompletionText | Should -Contain localapp
        $line = "& '$entry' source -Bucket ex"
        (TabExpansion2 $line $line.Length).CompletionMatches.CompletionText | Should -Contain extras
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
    }
    It 'preserves other completions and restores the original function on unload' {
        Remove-Module SPX
        $original = (Get-Command TabExpansion2).ScriptBlock
        $line = 'Get-ChildItem -'
        $before = @((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText)
        Import-Module $module -Force
        Import-Module $module -Force
        @((TabExpansion2 $line $line.Length).CompletionMatches.CompletionText) | Should -Be $before
        Remove-Module SPX
        (Get-Command TabExpansion2).ScriptBlock | Should -Be $original
    }
}
Describe 'SPX CLI recovery and shell integration' {
    BeforeAll { . "$PSScriptRoot/TestSupport.ps1"; $entry = Join-Path $PSScriptRoot '..\spx.ps1'; $module = Join-Path $PSScriptRoot '..\SPX.psd1' }
    BeforeEach { $sb = Enter-SpxTestSandbox (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); Import-Module $module -Force }
    AfterEach { Exit-SpxTestSandbox }

    It 'binds option-first arrays and pipeline properties natively' {
        New-SpxTestApp one -Version 1 | Out-Null
        New-SpxTestApp two -Version 1 | Out-Null
        @([pscustomobject]@{ AppName = 'one' } | & $entry source -Scope Local)[0].Name | Should -Be one
        @(& $entry -Scope Local source one, two).Count | Should -Be 2
    }
    It 'supports the native AST/options completion parameter set' {
        $line = "& '$entry' source one -Find -"
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
        $matches = (TabExpansion2 -ast $ast -tokens $tokens -positionOfCursor $ast.Extent.EndScriptPosition -options @{RelativeFilePaths = $false }).CompletionMatches.CompletionText
        $matches | Should -Contain '-Help'
        $matches | Should -Not -Contain '-Scope'
    }
    It 'repairs selected and all pending bucket journals without changing Git' {
        foreach ($name in 'main', 'extras') {
            $bucket = New-SpxTestGitBucket $name ('https://origin.example/' + $name)
            & git -C $bucket remote set-url origin ('https://mirror.example/' + $name)
            $dir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $dir -Force
            @{schema = 1; id = ('pending-' + $name); kind = 'mirror'; bucket = $name; action = 'New'; phase = 'GitChanged'; oldUrl = ('https://origin.example/' + $name); originalUrl = ('https://origin.example/' + $name); requestedUrl = ('https://mirror.example/' + $name) } | ConvertTo-Json | Set-Content (Join-Path $dir ($name + '.json')) -Encoding UTF8
        }
        & $entry repair -Buckets -WhatIf
        Test-Path (Join-Path $dir 'main.json') | Should -BeTrue
        (& $entry repair -Bucket main -Confirm:$false).Status | Should -Be Completed
        @(& $entry repair -Buckets -Confirm:$false).Count | Should -Be 1
        @(& $entry repair -Buckets -Confirm:$false).Count | Should -Be 0
        (Get-SpxBucketMirror main).CurrentUrl | Should -Be 'https://mirror.example/main'
    }
    It 'does not silently omit invalid evidence during bucket batch repair' {
        $dir = Join-Path $env:SCOOP 'spx\operations\mirror'; $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir 'main.json'; [IO.File]::WriteAllText($path, '{broken')
        { & $entry repair -Buckets -Confirm:$false } | Should -Throw -ErrorId 'Spx.CliUsage'
        [IO.File]::ReadAllText($path) | Should -BeExactly '{broken'
    }
    It 'clears only stale ownership and repeats without error' {
        $portable = Join-Path $sb.Root 'intent.json'
        @{local = @{gone = @{Path = (Join-Path $sb.Root 'dest') } }; global = @{} } | ConvertTo-Json -Depth 5 | Set-Content $portable -Encoding UTF8
        Import-SpxLinkConfiguration $portable -Confirm:$false | Out-Null
        (& $entry cleanup gone -Confirm:$false).StaleRecordRemoved | Should -BeTrue
        (& $entry cleanup gone -Confirm:$false).Status | Should -Be Unchanged
    }

    It 'returns a failing process exit for invalid modes even with ErrorAction Continue' {
        $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + [IO.Path]::GetFullPath($entry) + '"'), 'source', '-Bucket', 'main', '-Scope', 'Local', '-ErrorAction', 'Continue')
        $process = Start-Process (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $sb.Root 'out.txt') -RedirectStandardError (Join-Path $sb.Root 'err.txt') -PassThru
        $null = $process.Handle
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'CLI process timed out.' }
        $process.WaitForExit()
        $process.Refresh()
        $process.ExitCode | Should -Be 1
        (Get-Content (Join-Path $sb.Root 'err.txt') -Raw) | Should -Match 'not valid'
        Test-Path (Join-Path $env:SCOOP 'spx') | Should -BeFalse
        $arguments = @('-NoLogo', '-NoProfile', '-File', ('"' + [IO.Path]::GetFullPath($entry) + '"'), '-Version')
        $process = Start-Process (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $sb.Root 'version.txt') -RedirectStandardError (Join-Path $sb.Root 'version.err') -PassThru
        $null = $process.Handle
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'CLI version process timed out.' }
        $process.WaitForExit(); $process.Refresh()
        $process.ExitCode | Should -Be 0
        (Get-Content (Join-Path $sb.Root 'version.txt') -Raw).Trim() | Should -Be '0.5.0'
    }

    It 'does not turn an empty object pipeline into scope-wide synchronization' {
        New-SpxTestApp one -Version 1 | Out-Null
        $destination = Join-Path $sb.Root 'dest'
        $portable = Join-Path $sb.Root 'intent.json'
        @{local = @{one = @{Path = $destination } }; global = @{} } | ConvertTo-Json -Depth 5 | Set-Content $portable -Encoding UTF8
        Import-SpxLinkConfiguration $portable -Confirm:$false | Out-Null
        @(@() | & $entry sync -Confirm:$false).Count | Should -Be 0
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
}
