#Requires -Version 5.1

<#
.SYNOPSIS
Runs the canonical isolated SPX tests and packaged-entry compatibility smoke.
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$requiredPester = [version]'5.7.1'
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -eq $requiredPester } |
    Select-Object -First 1
if (-not $pester) {
    throw "Pester $requiredPester is required. Install-Module Pester -RequiredVersion $requiredPester -Scope CurrentUser"
}
Import-Module $pester.Path -Force -ErrorAction Stop

$result = Invoke-Pester -Path (Join-Path $repository 'tests') -Output Detailed -PassThru
if ($result.FailedCount -or $result.FailedBlocksCount -or $result.FailedContainersCount) {
    throw "Pester failed: $($result.FailedCount) test(s), $($result.FailedBlocksCount) block(s), $($result.FailedContainersCount) container(s)."
}

$smoke = & (Join-Path $repository 'tests\Compatibility.Smoke.ps1')
if (-not $smoke -or -not $smoke.Cli -or -not $smoke.Relocation -or -not $smoke.Mirror) {
    throw 'Packaged-entry compatibility smoke did not report all required checks.'
}
$smoke
