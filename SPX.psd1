@{
    RootModule = 'SPX.psm1'
    ModuleVersion = '0.5.0'
    GUID = 'cb81d0f7-9688-4f35-a387-2bdd7e252f2f'
    Author = 'SPX contributors'
    CompanyName = 'Community'
    Copyright = '(c) SPX contributors. Apache-2.0 OR MIT.'
    Description = 'Recoverable Scoop app relocation, source inspection, and bucket mirror management.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Move-SpxApp', 'Restore-SpxApp', 'Get-SpxLinkedApp', 'Sync-SpxLinkedApp', 'Repair-SpxLinkedApp', 'Remove-SpxStaleLink',
        'Export-SpxLinkConfiguration', 'Import-SpxLinkConfiguration', 'Get-SpxAppSource', 'Set-SpxAppSource', 'Test-SpxAppSource',
        'Compare-SpxAppSource', 'Find-SpxAppSource', 'Get-SpxBucketMirror', 'New-SpxBucketMirror', 'Set-SpxBucketMirror',
        'Remove-SpxBucketMirror', 'Repair-SpxBucketMirror'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Scoop', 'Windows', 'PowerShell')
            LicenseUri = 'https://github.com/nostalume/spx/blob/main/LICENSE-Apache'
            ProjectUri = 'https://github.com/nostalume/spx'
        }
    }
}
