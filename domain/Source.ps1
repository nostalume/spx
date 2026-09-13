# domain/Source.ps1 - installed app source metadata over admitted Scoop state

. "$PSScriptRoot/../lib/ScoopState.ps1"

function Get-SpxBucketManifest {
    param ([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Bucket)
    Assert-SpxName $Bucket 'bucket name'
    $root = Join-Path (Get-SpxContext).Buckets $Bucket
    foreach ($path in @((Join-Path $root "bucket\$Name.json"), (Join-Path $root "$Name.json"))) {
        if (Test-Path -LiteralPath $path) { return Read-SpxJsonFile $path }
    }
    $null
}

function ConvertTo-SpxComparableJson {
    param([AllowNull()]$Value)
    function Normalize-SpxValue {
        param([AllowNull()]$InputValue)
        if ($null -eq $InputValue) { return $null }
        if ($InputValue -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($InputValue.Keys | Sort-Object)) { $ordered[[string]$key] = Normalize-SpxValue $InputValue[$key] }
            return $ordered
        }
        if ($InputValue -is [Collections.IEnumerable] -and $InputValue -isnot [string]) { return @($InputValue | ForEach-Object { Normalize-SpxValue $_ }) }
        $InputValue
    }
    if ($null -eq $Value) { return '<null>' }
    Normalize-SpxValue $Value | ConvertTo-Json -Compress -Depth 20
}

function Get-SpxAppSource {
    <#
    .SYNOPSIS
    Reads installed Scoop source metadata and the separate installed manifest.
    .DESCRIPTION
    Inspects current installed versions through admitted Scoop layout and returns source metadata
    without modifying Scoop or SPX state.
    .PARAMETER Name
    Optional app names. When omitted, returns all installed apps in the selected scope.
    .PARAMETER Scope
    Local, Global, or All. Defaults to All.
    .OUTPUTS
    SPX.AppSource objects containing bucket, version, install path, manifest path, and manifest.
    .EXAMPLE
    Get-SpxAppSource jq -Scope Local
    #>
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [ValidateSet('Local', 'Global', 'All')][string]$Scope = 'All'
    )
    process {
        foreach ($snapshot in Find-SpxAppSnapshots -Name $Name -Scope $Scope -CurrentOnly) {
            Add-SpxTypeName ([pscustomobject]@{
                    Name = $snapshot.Name; Scope = $snapshot.Scope; State = 'Installed'
                    Bucket = $snapshot.Install.bucket; Version = $snapshot.CurrentVersion
                    InstallPath = $snapshot.CurrentPath; ManifestPath = $snapshot.ManifestPath
                    Manifest = $snapshot.Manifest
                }) 'SPX.AppSource'
        }
    }
}

function Set-SpxAppSource {
    <#
    .SYNOPSIS
    Changes only an installed app's bucket metadata after manifest/version admission.
    .DESCRIPTION
    Confirms that the target bucket contains the app and normally the installed version, then
    atomically changes only the bucket field in install.json.
    .PARAMETER Name
    One or more installed app names. Accepts strings and AppName properties from the pipeline.
    .PARAMETER Bucket
    Added Scoop bucket that should become the recorded source.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .PARAMETER Force
    Permits a version mismatch; it does not bypass path, name, JSON, or manifest validation.
    .OUTPUTS
    SPX.SourceChangeResult objects, including unchanged receipts.
    .EXAMPLE
    Set-SpxAppSource jq -Bucket extras -Scope Local -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [Parameter(Mandatory)][string]$Bucket,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local',
        [switch]$Force
    )
    process {
        Assert-SpxName $Bucket 'bucket name'
        foreach ($appName in $Name) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot) { Stop-SpxError 'Spx.AppNotInstalled' "App '$appName' is not installed in $Scope scope." $appName }
            $target = Get-SpxBucketManifest -Name $appName -Bucket $Bucket
            if (-not $target) { Stop-SpxError 'Spx.ManifestNotFound' "App '$appName' was not found in bucket '$Bucket'." $Bucket }
            if (-not $Force -and [string]$target.version -ne $snapshot.CurrentVersion) {
                Stop-SpxError 'Spx.VersionMismatch' "Installed version '$($snapshot.CurrentVersion)' differs from bucket version '$($target.version)'." $appName
            }
            $old = $snapshot.Install.bucket
            if ($old -eq $Bucket) {
                Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Scope = $Scope; Status = 'Unchanged'; Changed = $false; OldBucket = $old; NewBucket = $Bucket; Version = $snapshot.CurrentVersion }) 'SPX.SourceChangeResult'
                continue
            }
            if ($PSCmdlet.ShouldProcess("$Scope app '$appName'", "change source from '$old' to '$Bucket'")) {
                Invoke-SpxFileLock -Path $snapshot.InstallPath -Script {
                    $install = Read-SpxJsonFile $snapshot.InstallPath
                    $install['bucket'] = $Bucket
                    Write-SpxJsonFileAtomic -Path $snapshot.InstallPath -Value $install
                }
                Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Scope = $Scope; Status = 'Changed'; Changed = $true; OldBucket = $old; NewBucket = $Bucket; Version = $snapshot.CurrentVersion }) 'SPX.SourceChangeResult'
            }
        }
    }
}

function Test-SpxAppSource {
    <#
    .SYNOPSIS
    Tests whether installed version identity matches its configured bucket manifest.
    .DESCRIPTION
    Returns false when the app, recorded bucket, manifest, or matching version is absent. It does
    not mutate a mismatch and does not modify state.
    .PARAMETER Name
    One or more installed app names. Accepts strings and AppName properties from the pipeline.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .OUTPUTS
    System.Boolean for each requested app.
    .EXAMPLE
    Test-SpxAppSource jq -Scope Local
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local'
    )
    process {
        foreach ($appName in $Name) {
            $snapshot = Get-SpxAppSnapshot -Name $appName -Scope $Scope
            if (-not $snapshot -or -not $snapshot.Install.bucket) { $false; continue }
            $manifest = Get-SpxBucketManifest -Name $appName -Bucket $snapshot.Install.bucket
            [bool]($manifest -and [string]$manifest.version -eq $snapshot.CurrentVersion)
        }
    }
}

function Compare-SpxAppSource {
    <#
    .SYNOPSIS
    Compares the installed manifest with a named bucket manifest.
    .DESCRIPTION
    Compares version identity and selected package fields after admitting both manifests. The
    operation is read-only and retains structured values in its Differences collection.
    .PARAMETER Name
    Installed app name.
    .PARAMETER Bucket
    Added Scoop bucket whose manifest is compared.
    .PARAMETER Scope
    Local or Global. Defaults to Local.
    .OUTPUTS
    SPX.AppSourceComparison.
    .EXAMPLE
    Compare-SpxAppSource jq -Bucket main -Scope Local
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Bucket,
        [ValidateSet('Local', 'Global')][string]$Scope = 'Local'
    )
    $snapshot = Get-SpxAppSnapshot -Name $Name -Scope $Scope
    if (-not $snapshot) { Stop-SpxError 'Spx.AppNotInstalled' "App '$Name' is not installed in $Scope scope." $Name }
    $target = Get-SpxBucketManifest -Name $Name -Bucket $Bucket
    if (-not $target) { Stop-SpxError 'Spx.ManifestNotFound' "App '$Name' was not found in bucket '$Bucket'." $Bucket }
    $fields = @('description', 'homepage', 'license', 'url', 'architecture', 'bin', 'shortcuts', 'persist')
    $differences = foreach ($field in $fields) {
        $left = ConvertTo-SpxComparableJson $snapshot.Manifest[$field]
        $right = ConvertTo-SpxComparableJson $target[$field]
        if ($left -ne $right) { [pscustomobject]@{ Field = $field; Installed = $snapshot.Manifest[$field]; Bucket = $target[$field] } }
    }
    Add-SpxTypeName ([pscustomobject]@{
            Name=$Name; Scope=$Scope; State='Compared'; CurrentBucket=$snapshot.Install.bucket; CompareBucket=$Bucket
            InstalledVersion=$snapshot.CurrentVersion; BucketVersion=$target.version
            VersionMatch=([string]$target.version -eq $snapshot.CurrentVersion); Differences=@($differences)
        }) 'SPX.AppSourceComparison'
}

function Find-SpxAppSource {
    <#
    .SYNOPSIS
    Finds added buckets containing manifests for the requested app names.
    .DESCRIPTION
    Searches the supported root and bucket subdirectory manifest layouts under already-added Scoop
    buckets. Missing buckets or manifests produce no object and no mutation.
    .PARAMETER Name
    One or more app names. Accepts strings and AppName properties from the pipeline.
    .OUTPUTS
    SPX.AppSourceCandidate for each bucket containing a requested app manifest.
    .EXAMPLE
    Find-SpxAppSource jq,rg
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name)
    process {
        foreach ($appName in $Name) {
            Assert-SpxName $appName 'app name'
            $root = (Get-SpxContext).Buckets
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($bucket in Get-ChildItem -LiteralPath $root -Directory) {
                $manifest = Get-SpxBucketManifest -Name $appName -Bucket $bucket.Name
                if ($manifest) { Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Bucket = $bucket.Name; Version = $manifest.version; Url = $manifest.url; State = 'Available' }) 'SPX.AppSourceCandidate' }
            }
        }
    }
}
