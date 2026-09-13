[CmdletBinding()]
param(
    [ValidateRange(1, 10000)][int]$AppCount = 1000,
    [ValidateRange(1, 20)][int]$Repetitions = 5
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/TestSupport.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('spx-benchmark-' + [guid]::NewGuid().ToString('N'))

try {
    $null = Enter-SpxTestSandbox -Root $root
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Import-Module (Join-Path $repository 'SPX.psd1') -Force
    foreach ($number in 1..$AppCount) {
        $null = New-SpxTestApp -Name ('app' + $number) -Version '1.0'
    }
    $null = @(Get-SpxAppSource -Scope Local)
    foreach ($run in 1..$Repetitions) {
        [GC]::Collect()
        $before = [GC]::GetTotalAllocatedBytes($true)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $items = @(Get-SpxAppSource -Scope Local)
        $watch.Stop()
        $after = [GC]::GetTotalAllocatedBytes($true)
        [pscustomobject]@{
            PowerShell = $PSVersionTable.PSVersion.ToString()
            OS = [Environment]::OSVersion.VersionString
            Apps = $AppCount
            Run = $run
            Count = $items.Count
            Milliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            AllocatedMiB = [math]::Round(($after - $before) / 1MB, 2)
        }
    }
}
finally {
    Exit-SpxTestSandbox
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd($separators)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($separators)
    if (-not ([IO.Path]::GetDirectoryName($fullRoot).Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase)) -or
        -not ([IO.Path]::GetFileName($fullRoot).StartsWith('spx-benchmark-', [StringComparison]::Ordinal))) {
        throw "Refusing to clean an unexpected benchmark path: $fullRoot"
    }
    if (Test-Path -LiteralPath $fullRoot) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
}
