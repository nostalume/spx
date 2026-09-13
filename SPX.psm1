# SPX module root - import is deliberately effect-neutral.

. "$PSScriptRoot/lib/Context.ps1"
. "$PSScriptRoot/lib/Core.ps1"
. "$PSScriptRoot/lib/Config.ps1"
. "$PSScriptRoot/lib/ScoopState.ps1"
. "$PSScriptRoot/domain/Link.ps1"
. "$PSScriptRoot/domain/Source.ps1"
. "$PSScriptRoot/domain/Mirror.ps1"

function Export-SpxLinkConfiguration {
    <#
    .SYNOPSIS
    Atomically exports the complete SPX link configuration.
    .DESCRIPTION
    Validates current link configuration and writes it through a same-directory atomic replacement.
    .PARAMETER Path
    Destination file path.
    .PARAMETER Force
    Allows replacement when the destination already exists.
    .OUTPUTS
    SPX.LinkConfigurationExportResult.
    .EXAMPLE
    Export-SpxLinkConfiguration -Path '.\spx-links.json' -Force -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][string]$Path, [switch]$Force)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) { Stop-SpxError 'Spx.ExportExists' "Export path already exists: $fullPath" $fullPath }
    if ($PSCmdlet.ShouldProcess($fullPath, 'export SPX link configuration')) {
        Export-LinksConfig -Path $fullPath
        Add-SpxTypeName ([pscustomobject]@{ Path = $fullPath; Status = 'Exported'; Changed = $true }) 'SPX.LinkConfigurationExportResult'
    }
}

function Import-SpxLinkConfiguration {
    <#
    .SYNOPSIS
    Atomically replaces or merges a validated SPX link configuration.
    .DESCRIPTION
    Reads and validates an exported configuration, then atomically replaces current link intent or
    merges its entries. It records intent only and does not relocate app files.
    .PARAMETER Path
    Existing configuration export to import.
    .PARAMETER Merge
    Merges entries instead of replacing the complete link configuration.
    .OUTPUTS
    SPX.LinkConfigurationImportResult.
    .EXAMPLE
    Import-SpxLinkConfiguration -Path '.\spx-links.json' -Merge -WhatIf
    .NOTES
    Inspect with Get-SpxLinkedApp, then use Sync-SpxLinkedApp or Repair-SpxLinkedApp as indicated.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory)][string]$Path, [switch]$Merge)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { Stop-SpxError 'Spx.ImportNotFound' "Import path was not found: $fullPath" $fullPath }
    if ($PSCmdlet.ShouldProcess($fullPath, $(if ($Merge) { 'merge SPX link configuration' } else { 'replace SPX link configuration' }))) {
        Import-LinksConfig -Path $fullPath -Merge:$Merge
        Add-SpxTypeName ([pscustomobject]@{ Path = $fullPath; Status = $(if ($Merge) { 'Merged' } else { 'Imported' }); Changed = $true }) 'SPX.LinkConfigurationImportResult'
    }
}

# Wrappers are defined after composing private owners, so re-assert the allow-list.
Export-ModuleMember -Function @(
    'Move-SpxApp', 'Restore-SpxApp', 'Get-SpxLinkedApp', 'Sync-SpxLinkedApp', 'Repair-SpxLinkedApp', 'Remove-SpxStaleLink',
    'Export-SpxLinkConfiguration', 'Import-SpxLinkConfiguration', 'Get-SpxAppSource', 'Set-SpxAppSource', 'Test-SpxAppSource',
    'Compare-SpxAppSource', 'Find-SpxAppSource', 'Get-SpxBucketMirror', 'New-SpxBucketMirror', 'Set-SpxBucketMirror',
    'Remove-SpxBucketMirror', 'Repair-SpxBucketMirror'
)
