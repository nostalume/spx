# domain/Mirror.ps1 - recoverable bucket remote configuration

. "$PSScriptRoot/../lib/Config.ps1"

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

function Get-SpxMirrorConfig {
    $value = Get-SpxConfig -Key mirrors
    if ($null -eq $value) { return [ordered]@{} }
    if ($value -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new('Mirror config must contain a JSON object.') }
    foreach ($bucket in $value.Keys) {
        Assert-SpxName ([string]$bucket) 'mirror bucket name'
        $entry = $value[$bucket]
        if ($entry -isnot [Collections.IDictionary] -or -not $entry.Contains('original') -or -not $entry.Contains('mirror')) {
            throw [IO.InvalidDataException]::new("Invalid mirror config entry '$bucket'.")
        }
        Assert-SpxGitUrl ([string]$entry.original)
        Assert-SpxGitUrl ([string]$entry.mirror)
    }
    $value
}

function Set-SpxMirrorConfig {
    param ([Parameter(Mandatory)][Collections.IDictionary]$Value)
    Set-SpxConfig -Key mirrors -Value $Value
}

function Invoke-SpxMirrorLocks {
    param ([Parameter(Mandatory)][string]$Bucket, [Parameter(Mandatory)][scriptblock]$Script)
    Assert-SpxName $Bucket 'bucket name'
    Invoke-SpxOperationLock -Kind mirror -Key config -Script $Script
}

function Invoke-SpxMirrorChange {
    param ([string]$Bucket, [AllowNull()][string]$RequestedUrl, [ValidateSet('New', 'Set', 'Remove')][string]$Action)
    Assert-SpxName $Bucket 'bucket name'
    if (Read-SpxOperation -Kind mirror -Key $Bucket) { Stop-SpxError 'Spx.PendingRecovery' "Bucket '$Bucket' has pending recovery; run Repair-SpxBucketMirror before another mutation." $Bucket }
    if ($RequestedUrl) { Assert-SpxGitUrl $RequestedUrl }
    $path = Join-Path (Get-SpxContext).Buckets $Bucket
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { Stop-SpxError 'Spx.BucketNotGitRepository' "Bucket '$Bucket' is not a Git repository." $Bucket }
    $mirrors = Get-SpxMirrorConfig
    $existing = if ($mirrors.Contains($Bucket)) { $mirrors[$Bucket] } else { $null }
    if ($Action -eq 'New' -and $existing) { Stop-SpxError 'Spx.MirrorAlreadyExists' "Mirror for '$Bucket' already exists." $Bucket }
    if ($Action -eq 'Remove' -and -not $existing) { Stop-SpxError 'Spx.MirrorNotFound' "Mirror for '$Bucket' is not configured." $Bucket }
    $observed = Get-SpxBucketRemoteUrl $Bucket
    $original = if ($existing -and $existing.original) { [string]$existing.original } else { $observed }
    $desired = if ($Action -eq 'Remove') { $original } else { $RequestedUrl }
    $operation = [ordered]@{ schema = 1; id = [guid]::NewGuid().ToString('N'); kind = 'mirror'; bucket = $Bucket; action = $Action; phase = 'Prepared'; oldUrl = $observed; originalUrl = $original; requestedUrl = $desired; created = (Get-Date).ToUniversalTime().ToString('o') }
    $null = Write-SpxOperation -Kind mirror -Key $Bucket -Value $operation
    try {
        $null = Invoke-SpxGit -BucketPath $path -Arguments @('remote', 'set-url', 'origin', $desired)
        $operation.phase = 'GitChanged'; $null = Write-SpxOperation -Kind mirror -Key $Bucket -Value $operation
        $after = Get-SpxBucketRemoteUrl $Bucket
        if ($after -ne $desired) { Stop-SpxError 'Spx.GitVerificationFailed' "Git remote verification failed for '$Bucket'." $Bucket }
        if ($Action -eq 'Remove') { $null = $mirrors.Remove($Bucket) }
        else { $mirrors[$Bucket] = [ordered]@{ original = $original; mirror = $desired; updated = (Get-Date).ToUniversalTime().ToString('o') } }
        try { Set-SpxMirrorConfig $mirrors }
        catch {
            $primary = $_
            try {
                $null = Invoke-SpxGit -BucketPath $path -Arguments @('remote', 'set-url', 'origin', $observed)
                if ((Get-SpxBucketRemoteUrl $Bucket) -ne $observed) { throw "Rollback verification did not observe '$observed'." }
            }
            catch {
                Stop-SpxError 'Spx.MirrorCommitAndRollbackFailed' ("Mirror config commit failed: $($primary.Exception.Message) Rollback also failed: $($_.Exception.Message). Run Repair-SpxBucketMirror.") $Bucket
            }
            throw $primary
        }
        Remove-SpxOperation -Kind mirror -Key $Bucket
        Add-SpxTypeName ([pscustomobject]@{ Bucket = $Bucket; Status = $(if ($Action -eq 'Remove') { 'Restored' } else { 'Configured' }); Changed = $true; CurrentUrl = $desired; OriginalUrl = $original; MirrorUrl = $(if ($Action -eq 'Remove') { $null } else { $desired }); OperationId = $operation.id }) 'SPX.BucketMirrorResult'
    }
    catch { throw }
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
        $names = if ($Bucket) { @($Bucket) } elseif (Test-Path -LiteralPath $root) { @(Get-ChildItem -LiteralPath $root -Directory | Select-Object -ExpandProperty Name) } else { @() }
        $mirrors = Get-SpxMirrorConfig
        foreach ($name in $names) {
            Assert-SpxName $name 'bucket name'
            $path = Join-Path $root $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $entry = if ($mirrors.Contains($name)) { $mirrors[$name] } else { $null }
            $pending = Read-SpxOperation -Kind mirror -Key $name
            $current = $null; $gitError = $null
            try { $current = Get-SpxBucketRemoteUrl $name }catch { $gitError = $_.Exception.Message }
            Add-SpxTypeName ([pscustomobject]@{
                    Bucket=$name; State=$(if ($pending) { 'PendingRecovery' } elseif ($gitError) { 'GitError' } elseif ($entry -and $current -ne $entry.mirror) { 'Drifted' } elseif ($entry) { 'Mirrored' } else { 'Unmirrored' })
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
    if ($PSCmdlet.ShouldProcess($Bucket, "configure new mirror '$Url'")) { Invoke-SpxMirrorLocks -Bucket $Bucket -Script { Invoke-SpxMirrorChange -Bucket $Bucket -RequestedUrl $Url -Action New } }
}

function Set-SpxBucketMirror {
    <#
    .SYNOPSIS
    Changes a bucket mirror through checked Git and atomic SPX state commit.
    .DESCRIPTION
    Preserves the originally recorded remote, journals the new request, verifies the Git update,
    and atomically replaces committed mirror state.
    .PARAMETER Bucket
    Bucket with an existing mirror record.
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
    if ($PSCmdlet.ShouldProcess($Bucket, "set mirror '$Url'")) { Invoke-SpxMirrorLocks -Bucket $Bucket -Script { Invoke-SpxMirrorChange -Bucket $Bucket -RequestedUrl $Url -Action Set } }
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
    process { foreach ($name in $Bucket) { if ($PSCmdlet.ShouldProcess($name, 'restore original bucket remote')) { Invoke-SpxMirrorLocks -Bucket $name -Script { Invoke-SpxMirrorChange -Bucket $name -Action Remove } } } }
}

function Repair-SpxBucketMirror {
    <#
    .SYNOPSIS
    Completes or rolls back interrupted bucket mirror operations from durable evidence.
    .DESCRIPTION
    Completes configuration when Git already has the requested URL; otherwise restores the recorded
    old URL. The journal is cleared only after the selected recovery path succeeds.
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
            $operation = Read-SpxOperation -Kind mirror -Key $name
            if (-not $operation) { Stop-SpxError 'Spx.NoPendingRecovery' "Bucket '$name' has no pending mirror recovery." $name }
            if (-not $PSCmdlet.ShouldProcess($name, 'repair pending mirror operation')) { continue }
            Invoke-SpxMirrorLocks -Bucket $name -Script {
                $operation = Read-SpxOperation -Kind mirror -Key $name
                if (-not $operation) { return }
                $path = Join-Path (Get-SpxContext).Buckets $name
                $current = Get-SpxBucketRemoteUrl $name
                if ($current -eq $operation.requestedUrl) {
                    $mirrors = Get-SpxMirrorConfig
                    if ($operation.action -eq 'Remove') { $null = $mirrors.Remove($name) }
                    else { $mirrors[$name] = [ordered]@{ original = $operation.originalUrl; mirror = $operation.requestedUrl; updated = (Get-Date).ToUniversalTime().ToString('o') } }
                    Set-SpxMirrorConfig $mirrors
                    $status = 'Completed'
                }
                else {
                    $null = Invoke-SpxGit -BucketPath $path -Arguments @('remote', 'set-url', 'origin', [string]$operation.oldUrl)
                    if ((Get-SpxBucketRemoteUrl $name) -ne $operation.oldUrl) { Stop-SpxError 'Spx.RecoveryFailed' "Could not restore bucket '$name'." $name }
                    $status = 'RolledBack'
                }
                Remove-SpxOperation -Kind mirror -Key $name
                Add-SpxTypeName ([pscustomobject]@{ Bucket = $name; Status = $status; Changed = $true; CurrentUrl = (Get-SpxBucketRemoteUrl $name); OperationId = $operation.id }) 'SPX.BucketMirrorRepairResult'
            }
        }
    }
}
