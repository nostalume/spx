param ()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/TestSupport.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('spx-compat-' + [guid]::NewGuid().ToString('N'))
$oldScoop = $env:SCOOP
$oldGlobal = $env:SCOOP_GLOBAL
try {
    $sandbox = Enter-SpxTestSandbox -Root $root
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $parseFailures = @()
    foreach ($file in @((Get-ChildItem -LiteralPath $repository -File), (Get-ChildItem -LiteralPath (Join-Path $repository 'src') -File)) | ForEach-Object { $_ }) {
        if ($file.Extension -notin '.ps1', '.psm1', '.psd1') { continue }
        $tokens = $null
        $fileFailures = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$fileFailures)
        $parseFailures += $fileFailures
    }
    if ($parseFailures.Count) { throw ('PowerShell parse failures: ' + (($parseFailures | ForEach-Object Message) -join '; ')) }
    Import-Module (Join-Path $repository 'SPX.psd1') -Force
    $exports = @(Get-Command -Module SPX | Select-Object -ExpandProperty Name | Sort-Object)
    $expected = @((Import-PowerShellDataFile (Join-Path $repository 'SPX.psd1')).FunctionsToExport | Sort-Object)
    if (Compare-Object $exports $expected) { throw 'Module exports differ from the explicit manifest allow-list.' }
    $entry = Join-Path $repository 'spx.ps1'
    if ((& $entry -Version | Out-String).Trim() -ne '0.5.0') { throw 'CLI version failed.' }
    if ((& $entry -Help | Out-String) -notmatch 'spx <command>') { throw 'CLI help failed.' }

    $app = New-SpxTestApp -Name smoke -Version 1 -Bucket main
    New-SpxTestBucket -Name main -AppName smoke -Version 1 | Out-Null
    if ((& $entry source smoke -Scope Local).Source.Version -ne '1') { throw 'CLI source admission failed.' }

    $destination = Join-Path $root 'destination'
    $move = & $entry link smoke -Scope Local -Destination $destination -Confirm:$false
    if (-not $move.Changed -or -not ((Get-Item -LiteralPath $app.VersionPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Relocation failed.' }
    $restore = & $entry unlink smoke -Scope Local -Confirm:$false
    if (-not $restore.Changed -or ((Get-Item -LiteralPath $app.VersionPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Restore failed.' }
    $reclaim = Remove-SpxRetainedCopy smoke -Scope Local -Confirm:$false
    if ($reclaim.Status -ne 'Reclaimed' -or $reclaim.Removed.Count -ne 2) { throw 'Explicit retained-copy reclamation failed.' }

    New-SpxTestGitBucket -Name main -Origin 'https://origin.example/main.git' | Out-Null
    & $entry source -Bucket main -Url 'https://mirror.example/main.git' -Confirm:$false | Out-Null
    if ((& $entry source -Bucket main).Source.CurrentUrl -ne 'https://mirror.example/main.git') { throw 'Mirror set failed.' }
    & $entry source -Bucket main -Reset -Confirm:$false | Out-Null
    if ((& $entry source -Bucket main).Source.CurrentUrl -ne 'https://origin.example/main.git') { throw 'Mirror restore failed.' }

    [pscustomobject]@{ PowerShell = $PSVersionTable.PSVersion.ToString(); Exports = $exports.Count; Cli = $true; Source = $true; Relocation = $true; Reclamation = $true; Mirror = $true }
}
finally {
    Exit-SpxTestSandbox
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd($separators)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($separators)
    if (-not ([IO.Path]::GetDirectoryName($fullRoot).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase)) -or
        -not ([IO.Path]::GetFileName($fullRoot).StartsWith('spx-compat-', [StringComparison]::Ordinal))) {
        throw "Refusing to clean an unexpected compatibility path: $fullRoot"
    }
    if (Test-Path -LiteralPath $fullRoot) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
    $env:SCOOP = $oldScoop
    $env:SCOOP_GLOBAL = $oldGlobal
}
