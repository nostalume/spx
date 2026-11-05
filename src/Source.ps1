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

                Invoke-SpxMutation {
                    if (Read-SpxOperation link ($Scope.ToLowerInvariant() + '-' + $appName)) { Stop-SpxError 'Spx.PendingRecovery' 'Resolve the app operation before changing source metadata.' $appName }
                    $fresh = Get-SpxAppSnapshot -Name $appName -Scope $Scope
                    if (-not $fresh -or $fresh.CurrentVersion -ne $snapshot.CurrentVersion -or $fresh.InstallPath -ne $snapshot.InstallPath) { Stop-SpxError 'Spx.StateChanged' 'Installed version changed before source modification.' $appName }
                    $target = Get-SpxBucketManifest $appName $Bucket
                    if (-not $target) { Stop-SpxError 'Spx.ManifestNotFound' 'Target manifest disappeared.' $Bucket }
                    if (-not $Force -and [string]$target.version -ne $fresh.CurrentVersion) { Stop-SpxError 'Spx.VersionMismatch' 'Target manifest version changed before the source commit.' $appName }
                    $install = $fresh.Install
                    $old = $install.bucket
                    $changed = $old -ne $Bucket
                    if ($changed) { $install['bucket'] = $Bucket; Write-SpxJsonFileAtomic $fresh.InstallPath $install }
                    Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Scope = $Scope; Status = $(if ($changed) { 'Changed' } else { 'Unchanged' }); Changed = $changed; OldBucket = $old; NewBucket = $Bucket; Version = $fresh.CurrentVersion }) 'SPX.SourceChangeResult'
                }
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
            foreach ($bucket in Get-SpxBucketNames) {
                $manifest = Get-SpxBucketManifest -Name $appName -Bucket $bucket
                if ($manifest) { Add-SpxTypeName ([pscustomobject]@{ Name = $appName; Bucket = $bucket; Version = $manifest.version; Url = $manifest.url; State = 'Available' }) 'SPX.AppSourceCandidate' }
            }
        }
    }
}



function Assert-SpxGitUrl {
    param ([Parameter(Mandatory)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -match '[\x00-\x1f]' -or $Url.StartsWith('-')) {
        throw [ArgumentException]::new("Invalid Git remote URL '$Url'.")
    }
}

function Invoke-SpxGit {
    param ([Parameter(Mandatory)][string]$BucketPath, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $BucketPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { Stop-SpxError 'Spx.GitFailed' ("git failed with exit code ${exitCode}: " + ($output -join [Environment]::NewLine)) $BucketPath }
    ($output -join [Environment]::NewLine).Trim()
}

function Get-SpxBucketRemoteUrl {
    param ([Parameter(Mandatory)][string]$Bucket)
    Assert-SpxName $Bucket 'bucket name'
    $path = Join-Path (Get-SpxContext).Buckets $Bucket
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { return $null }
    Invoke-SpxGit -BucketPath $path -Arguments @('remote', 'get-url', 'origin')
}

function Get-SpxMirrorState {
    param ([string]$Bucket, [switch]$NamesOnly)
    $state = Get-SpxConfig
    if ($state.Contains('schema') -and [string]$state.schema -notin '1', '2') { throw [IO.InvalidDataException]::new('Unsupported source state schema.') }
    if ($state.Contains('generation') -and [string]$state.generation -notmatch '^\d+$') { throw [IO.InvalidDataException]::new('Invalid source generation.') }
    if (-not $state.Contains('mirrors')) { $state['mirrors'] = [ordered]@{} }
    if (-not $state.Contains('mirrorReceipts')) { $state['mirrorReceipts'] = [ordered]@{} }
    if ($state.mirrors -isnot [Collections.IDictionary] -or $state.mirrorReceipts -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new('Invalid bucket source state.') }
    $state.mirrors = ConvertTo-SpxNameMap $state.mirrors
    $state.mirrorReceipts = ConvertTo-SpxNameMap $state.mirrorReceipts
    if ($NamesOnly) { return $state }
    foreach ($name in $state.mirrors.Keys) {
        if ($Bucket -and $name -ne $Bucket) { continue }
        Assert-SpxName ([string]$name) 'bucket'
        $entry = $state.mirrors[$name]
        if ($entry -isnot [Collections.IDictionary] -or -not $entry.original -or -not $entry.mirror) { throw [IO.InvalidDataException]::new("Invalid source entry '$name'.") }
        Assert-SpxGitUrl ([string]$entry.original); Assert-SpxGitUrl ([string]$entry.mirror)
    }
    foreach ($receiptName in $state.mirrorReceipts.Keys) {
        if ($Bucket -and $receiptName -ne $Bucket) { continue }
        $receipt = $state.mirrorReceipts[$receiptName]
        if ($receipt -isnot [Collections.IDictionary] -or -not $receipt.Id -or $receipt.Outcome -notin 'Committed', 'RolledBack') { throw [IO.InvalidDataException]::new('Invalid bucket operation receipt.') }
    }
    $state
}

function Get-SpxRepositoryIdentity {
    param ([string]$Bucket)
    Assert-SpxName $Bucket 'bucket'
    $path = Join-Path (Get-SpxContext).Buckets $Bucket
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { Stop-SpxError 'Spx.BucketNotGitRepository' "Bucket '$Bucket' is not a Git repository." $Bucket }
    $directory = Invoke-SpxGit $path @('rev-parse', '--absolute-git-dir')
    [ordered]@{ Path = [IO.Path]::GetFullPath($path); GitDirectory = [IO.Path]::GetFullPath($directory); CreatedTicks = [string](Get-Item -LiteralPath $directory -Force -ErrorAction Stop).CreationTimeUtc.Ticks }
}

function Save-SpxMirrorOutcome {
    param ($Operation, [bool]$Committed)
    $state = Get-SpxMirrorState
    $entry = if ($Committed) {
        if ($Operation.action -ne 'Remove') {
            $next = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            if ($Operation.before) { foreach ($key in $Operation.before.Keys) { $next[$key] = $Operation.before[$key] } }
            $next['original'] = $Operation.originalUrl; $next['mirror'] = $Operation.requestedUrl
            $next['updated'] = $Operation.created; $next['OperationId'] = $Operation.id
            $next
        }
    }
    else { $Operation.before }
    if ($null -eq $entry) { $null = $state.mirrors.Remove([string]$Operation.bucket) } else { $state.mirrors[$Operation.bucket] = $entry }
    $state.mirrorReceipts[$Operation.bucket] = [ordered]@{ Id = $Operation.id; Action = $Operation.action; Outcome = $(if ($Committed) { 'Committed' } else { 'RolledBack' }) }
    $state['schema'] = 2
    $state['generation'] = [int64]$state.generation + 1
    Write-SpxJsonFileAtomic (Get-SpxConfigFile) $state -RetainPrevious
}

function Invoke-SpxMirrorRecovery {
    param ($Operation)
    $identity = Get-SpxRepositoryIdentity $Operation.bucket
    if ($Operation.repository -and ($identity.Path -ne $Operation.repository.Path -or $identity.GitDirectory -ne $Operation.repository.GitDirectory -or $identity.CreatedTicks -ne $Operation.repository.CreatedTicks)) { Stop-SpxError 'Spx.RecoveryConflict' 'Bucket repository identity changed; preserved the journal.' $Operation.bucket }
    $current = Get-SpxBucketRemoteUrl $Operation.bucket
    $state = Get-SpxMirrorState
    if ([string]$Operation.schema -eq '1') { $Operation['before'] = $state.mirrors[$Operation.bucket] }
    $committed = $state.mirrorReceipts[$Operation.bucket].Id -eq $Operation.id -and $state.mirrorReceipts[$Operation.bucket].Outcome -eq 'Committed'
    if ($current -ceq $Operation.requestedUrl) {
        Save-SpxMirrorOutcome $Operation $true
        $result = 'Completed'
    }
    elseif ($current -ceq $Operation.oldUrl -and -not $committed) {
        Save-SpxMirrorOutcome $Operation $false
        $result = 'RolledBack'
    }
    else { Stop-SpxError 'Spx.RecoveryConflict' 'Origin differs from the recorded transition; no remote was overwritten.' $Operation.bucket }
    Remove-SpxOperation mirror $Operation.bucket
    $result
}

function Invoke-SpxMirrorChange {
    param ([string]$Bucket, [AllowNull()][string]$RequestedUrl, [ValidateSet('New', 'Set', 'Remove')][string]$Action)
    Assert-SpxName $Bucket 'bucket'
    if (Read-SpxOperation mirror $Bucket) { Stop-SpxError 'Spx.PendingRecovery' "Repair '$Bucket' before another source mutation." $Bucket }
    if ($RequestedUrl) { Assert-SpxGitUrl $RequestedUrl }
    $identity = Get-SpxRepositoryIdentity $Bucket
    $state = Get-SpxMirrorState
    $existing = $state.mirrors[$Bucket]
    if ($Action -eq 'New' -and $existing) { Stop-SpxError 'Spx.MirrorAlreadyExists' "Mirror for '$Bucket' already exists." $Bucket }
    if ($Action -eq 'Remove' -and -not $existing) { Stop-SpxError 'Spx.MirrorNotFound' "Mirror for '$Bucket' is not configured." $Bucket }
    $observed = Get-SpxBucketRemoteUrl $Bucket
    $original = if ($existing) { $existing.original } else { $observed }
    $desired = if ($Action -eq 'Remove') { $original } else { $RequestedUrl }
    if ($Action -eq 'Set' -and $existing -and $existing.mirror -ceq $desired -and $observed -ceq $desired) {
        return Add-SpxTypeName ([pscustomobject]@{ Bucket = $Bucket; Status = 'Unchanged'; Changed = $false; CurrentUrl = $observed; OriginalUrl = $original; MirrorUrl = $desired; OperationId = $existing.OperationId }) 'SPX.BucketMirrorResult'
    }
    $operation = [ordered]@{ schema = 2; id = [guid]::NewGuid().ToString('N'); kind = 'mirror'; bucket = $Bucket; action = $Action; phase = 'Prepared'; oldUrl = $observed; originalUrl = $original; requestedUrl = $desired; before = $existing; repository = $identity; created = (Get-Date).ToUniversalTime().ToString('o') }
    $null = Write-SpxOperation mirror $Bucket $operation
    try {
        $null = Invoke-SpxGit $identity.Path @('remote', 'set-url', 'origin', $desired)
        if ((Get-SpxBucketRemoteUrl $Bucket) -cne $desired) { Stop-SpxError 'Spx.GitVerificationFailed' 'Origin does not match the request.' $Bucket }
        $operation.phase = 'GitChanged'; $null = Write-SpxOperation mirror $Bucket $operation
        Save-SpxMirrorOutcome $operation $true
        Remove-SpxOperation mirror $Bucket
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'Spx.Git*') { throw }
        Stop-SpxError 'Spx.RecoveryFailed' ("Source transition requires inspection/repair: " + $_.Exception.Message) $Bucket
    }
    Add-SpxTypeName ([pscustomobject]@{ Bucket = $Bucket; Status = $(if ($Action -eq 'Remove') { 'Restored' } else { 'Configured' }); Changed = $true; CurrentUrl = $desired; OriginalUrl = $original; MirrorUrl = $(if ($Action -ne 'Remove') { $desired }); OperationId = $operation.id }) 'SPX.BucketMirrorResult'
}

function Get-SpxBucketMirror {
    <#
    .SYNOPSIS
    Reports observed Git remote, committed mirror state, and pending recovery.
    .DESCRIPTION
    Reads added bucket repositories, their origin remotes, committed SPX mirror records, and
    durable operation evidence without changing Git or configuration.
    .PARAMETER Bucket
    Optional bucket names. When omitted, inspects every added bucket directory.
    .OUTPUTS
    SPX.BucketMirror objects with observed state, URLs, evidence, and pending operation data.
    .EXAMPLE
    Get-SpxBucketMirror main
    #>
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('BucketName')][string[]]$Bucket)
    process {
        $root = (Get-SpxContext).Buckets
        $names = if ($Bucket) { @($Bucket) } elseif (Test-Path -LiteralPath $root) { @(Get-SpxBucketNames) } else { @() }
        if (-not $names.Count) { $null = Get-SpxMirrorState }
        foreach ($name in $names) {
            Assert-SpxName $name 'bucket name'
            $mirrors = (Get-SpxMirrorState -Bucket $name).mirrors
            $path = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $entry = if ($mirrors.Contains($name)) { $mirrors[$name] } else { $null }
            $pending = Read-SpxOperation -Kind mirror -Key $name
            $current = $null; $gitError = $null
            try { $current = Get-SpxBucketRemoteUrl $name }catch { $gitError = $_.Exception.Message }
            Add-SpxTypeName ([pscustomobject]@{
                    Bucket=$name; State=$(if ($pending) { 'PendingRecovery' } elseif ($gitError) { 'GitError' } elseif ($entry -and $current -cne $entry.mirror) { 'Drifted' } elseif ($entry) { 'Mirrored' } else { 'Unmirrored' })
                    CurrentUrl=$current; OriginalUrl=$(if ($entry) { $entry.original } else { $null }); MirrorUrl=$(if ($entry) { $entry.mirror } else { $null })
                    IsMirrored=[bool]$entry; IsGitRepository=(Test-Path -LiteralPath (Join-Path $path '.git')); Evidence=$gitError; PendingOperation=$pending
                }) 'SPX.BucketMirror'
        }
    }
}

function New-SpxBucketMirror {
    <#
    .SYNOPSIS
    Configures a new recoverable bucket mirror while preserving the original remote.
    .DESCRIPTION
    Records the intended transition, changes and verifies the Git origin, then atomically commits
    the original and mirror URLs. Existing mirror records are refused.
    .PARAMETER Bucket
    Added Scoop bucket backed by a Git repository.
    .PARAMETER Url
    New origin remote passed to Git as one argument after admission.
    .OUTPUTS
    SPX.BucketMirrorResult.
    .EXAMPLE
    New-SpxBucketMirror main -Url 'https://mirror.example/main.git' -WhatIf
    .NOTES
    Run Repair-SpxBucketMirror if a Spx.PendingRecovery or commit/rollback error is reported.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][string]$Bucket, [Parameter(Mandatory)][string]$Url)
    if ($PSCmdlet.ShouldProcess($Bucket, "configure new mirror '$Url'")) { Invoke-SpxMutation { Invoke-SpxMirrorChange -Bucket $Bucket -RequestedUrl $Url -Action New } }
}

function Set-SpxBucketMirror {
    <#
    .SYNOPSIS
    Changes a bucket mirror through checked Git and atomic SPX state commit.
    .DESCRIPTION
    Creates or updates a mirror record, preserving the originally recorded remote. Journals the
    request, verifies the Git update, and atomically replaces committed source state.
    .PARAMETER Bucket
    Added Git bucket. An existing record preserves its saved original remote.
    .PARAMETER Url
    Replacement mirror remote.
    .OUTPUTS
    SPX.BucketMirrorResult.
    .EXAMPLE
    Set-SpxBucketMirror main -Url 'https://mirror.example/main.git' -Confirm:$false
    .NOTES
    Run Repair-SpxBucketMirror when durable recovery is pending.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)][string]$Bucket, [Parameter(Mandatory)][string]$Url)
    if ($PSCmdlet.ShouldProcess($Bucket, "set mirror '$Url'")) { Invoke-SpxMutation { Invoke-SpxMirrorChange -Bucket $Bucket -RequestedUrl $Url -Action Set } }
}

function Remove-SpxBucketMirror {
    <#
    .SYNOPSIS
    Restores saved original remotes and removes committed mirror state.
    .DESCRIPTION
    For each bucket, journals the restore, changes and verifies Git origin, then atomically removes
    the SPX mirror record. Each bucket is a separate transaction.
    .PARAMETER Bucket
    One or more mirrored bucket names. Accepts strings and BucketName properties from the pipeline.
    .OUTPUTS
    SPX.BucketMirrorResult for restoring the original remote.
    .EXAMPLE
    Remove-SpxBucketMirror main -Confirm:$false
    .NOTES
    Run Repair-SpxBucketMirror if a batch stops with pending recovery.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('BucketName')][string[]]$Bucket)
    process { foreach ($name in $Bucket) { if ($PSCmdlet.ShouldProcess($name, 'restore original bucket remote')) { Invoke-SpxMutation { Invoke-SpxMirrorChange -Bucket $name -Action Remove } } } }
}

function Repair-SpxBucketMirror {
    <#
    .SYNOPSIS
    Completes or rolls back interrupted bucket mirror operations from durable evidence.
    .DESCRIPTION
    Completes configuration for the requested URL, or restores prior records when Git still has the
    old URL. A third remote value or replaced repository is preserved as a conflict; no remote is guessed back.
    .PARAMETER Bucket
    One or more buckets with pending mirror journals. Accepts BucketName pipeline properties.
    .OUTPUTS
    SPX.BucketMirrorRepairResult.
    .EXAMPLE
    Repair-SpxBucketMirror main -Confirm:$false
    .NOTES
    A Spx.RecoveryFailed error preserves evidence for inspection and another safe retry.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('BucketName')][string[]]$Bucket)

    process {
        foreach ($name in $Bucket) {
            $pending = Read-SpxOperation mirror $name
            if (-not $pending) { Stop-SpxError 'Spx.NoPendingRecovery' "Bucket '$name' has no pending recovery." $name }
            if ($PSCmdlet.ShouldProcess($name, 'recover the recorded bucket source transition')) {
                Invoke-SpxMutation {
                    $operation = Read-SpxOperation mirror $name
                    if (-not $operation) { return }
                    if ($operation.id -ne $pending.id) { Stop-SpxError 'Spx.StateChanged' 'Pending operation changed before repair; inspect and retry.' $name }
                    $status = Invoke-SpxMirrorRecovery $operation
                    Add-SpxTypeName ([pscustomobject]@{ Bucket = $name; Status = $status; Changed = $true; CurrentUrl = (Get-SpxBucketRemoteUrl $name); OperationId = $operation.id }) 'SPX.BucketMirrorRepairResult'
                }
            }
        }
    }
}

function Get-SpxSourceNames {
    $state = Get-SpxMirrorState -NamesOnly
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    @($state.mirrors.Keys) + @(Get-SpxBucketNames) + @(Get-SpxOperationKeys mirror) | Where-Object { $seen.Add([string]$_) }
}
