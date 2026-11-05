# SPX module: one composition root, no import-time filesystem effects.

function Add-SpxTypeName {
    param ([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$TypeName)
    $InputObject.PSObject.TypeNames.Insert(0, $TypeName)
    $InputObject
}

function Stop-SpxError {
    param ([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, [object]$TargetObject)
    $exception = New-Object InvalidOperationException($Message)
    $record = New-Object Management.Automation.ErrorRecord($exception, $Id, [Management.Automation.ErrorCategory]::InvalidOperation, $TargetObject)
    throw $record
}

foreach ($owner in 'Files', 'Store', 'Scoop', 'Link', 'Source') { . "$PSScriptRoot/src/$owner.ps1" }

function Get-SpxStatus {
    <#
    .SYNOPSIS
    Observes app placement, recovery evidence, retained copies, and source relationships.
    .DESCRIPTION
    Returns structured per-target observations without creating state or following unowned paths.
    One invalid app or bucket does not hide the remaining targets. No observation grants mutation authority.
    .PARAMETER Name
    Optional app names. Omission inventories installed apps, recorded intent, operations and retained copies.
    .PARAMETER Scope
    Local, Global or All; defaults to All. Applies to app targets only.
    .PARAMETER Bucket
    Explicit bucket names instead of app targets.
    .PARAMETER Buckets
    Inventories bucket directories, committed mirror records and pending bucket operations.
    .OUTPUTS
    SPX.Status objects with Status, Placement, Issues, Source, PendingOperation and RetainedCopies.
    .EXAMPLE
    Get-SpxStatus jq -Scope Local
    .EXAMPLE
    Get-SpxStatus -Bucket main
    #>
    [CmdletBinding(DefaultParameterSetName = 'App')]
    param (
        [Parameter(Position = 0, ParameterSetName = 'App', ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('AppName')][string[]]$Name,
        [Parameter(ParameterSetName = 'App')][ValidateSet('Local', 'Global', 'All')][string]$Scope = 'All',
        [Parameter(Mandatory, ParameterSetName = 'Bucket')][string[]]$Bucket,
        [Parameter(Mandatory, ParameterSetName = 'Buckets')][switch]$Buckets
    )
    process {
        if ($PSCmdlet.ParameterSetName -ne 'App') {
            $names = @($Bucket)
            if ($Buckets) {
                try { $names = @(Get-SpxSourceNames) }
                catch {
                    Add-SpxTypeName ([pscustomobject]@{ TargetKind = 'Bucket'; Name = '*'; Scope = $null; Status = 'Invalid'; Placement = $null; Issues = @([pscustomobject]@{ Code = 'InvalidState'; Message = $_.Exception.Message }); Source = $null; PendingOperation = $null; RetainedCopies = @(); NextActions = @('Inspect') }) 'SPX.Status'
                    return
                }

            }
            foreach ($target in @($names | Select-Object -Unique)) {
                Assert-SpxName $target 'bucket'
                $issues = @(); $view = $null; $pending = $null
                try { $pending = Read-SpxOperation mirror $target; $view = Get-SpxBucketMirror -Bucket $target }
                catch { $issues += [pscustomobject]@{ Code = 'InvalidState'; Message = $_.Exception.Message } }
                $status = if ($issues.Count) { 'Invalid' } elseif ($pending) { 'NeedsRecovery' } elseif (-not $view) { 'Missing' } elseif ($view.State -in 'GitError', 'Drifted' -or -not $view.IsGitRepository) { 'Conflict' } else { 'Ready' }
                if (-not $issues.Count -and $status -ne 'Ready') { $issues += [pscustomobject]@{ Code = $(if ($view) { $view.State } else { $status }); Message = $view.Evidence } }
                Add-SpxTypeName ([pscustomobject]@{ TargetKind = 'Bucket'; Name = $target; Scope = $null; Status = $status; Placement = $null; Issues = $issues; Source = $view; PendingOperation = $pending; RetainedCopies = @(); NextActions = @(if ($pending) { 'Repair' } elseif ($status -ne 'Ready') { 'Inspect' }) }) 'SPX.Status'
            }
            return
        }
        # A changed generation invalidates the whole collected projection; retry once.
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try { $cfg = Get-LinksConfig }
            catch {
                foreach ($target in $(if ($Name) { $Name } else { '*' })) {
                    Add-SpxTypeName ([pscustomobject]@{ TargetKind = 'App'; Name = $target; Scope = $Scope; Status = 'Invalid'; Placement = 'Unknown'; Issues = @([pscustomobject]@{ Code = 'InvalidState'; Message = $_.Exception.Message }); Source = $null; PendingOperation = $null; RetainedCopies = @(); NextActions = @('Inspect') }) 'SPX.Status'
                }
                return
            }
            $bucketViews = @{}
            $views = @(
                foreach ($currentScope in Resolve-SpxScopes $Scope) {
                    $names = if ($Name) { @($Name) } else { @(Get-SpxLinkNames $currentScope $cfg -Installed) }
                    foreach ($target in $names) {
                        Assert-SpxName $target 'app'
                        $view = Get-SpxLinkObservation $target $currentScope $cfg
                        $source = $null
                        if ($view.Snapshot) {
                            $recordedBucket = [string]$view.Snapshot.Install.bucket
                            $remote = $null
                            if ($recordedBucket) {
                                if (-not $bucketViews.ContainsKey($recordedBucket)) {
                                    try { $bucketViews[$recordedBucket] = Get-SpxBucketMirror -Bucket $recordedBucket }
                                    catch { $bucketViews[$recordedBucket] = [pscustomobject]@{ State = 'GitError'; IsGitRepository = $false; Evidence = $_.Exception.Message } }
                                }
                                $remote = $bucketViews[$recordedBucket]
                            }
                            if (-not $recordedBucket -or -not $remote -or -not $remote.IsGitRepository -or $remote.State -in 'GitError', 'Drifted') {
                                $view.Issues += [pscustomobject]@{ Code = 'SourceUnavailable'; Message = $(if ($remote.Evidence) { $remote.Evidence } else { "Inspect the recorded bucket '$recordedBucket'." }) }
                                if ($view.Status -eq 'Ready') { $view.Status = 'Conflict'; $view.NextActions = @('Inspect') }
                            }
                            if ($remote.PendingOperation) {
                                $view.Issues += [pscustomobject]@{ Code = 'BucketRecovery'; Message = "Bucket '$recordedBucket' has pending recovery." }
                                if ($view.Status -eq 'Ready') { $view.Status = 'NeedsRecovery'; $view.NextActions = @('InspectBucket') }
                            }
                            $source = [pscustomobject]@{ Bucket = $recordedBucket; Version = $view.Snapshot.CurrentVersion; CurrentUrl = $remote.CurrentUrl; RepositoryState = $remote.State; PendingOperation = $remote.PendingOperation }
                        }
                        Add-SpxTypeName ([pscustomobject]@{ TargetKind = 'App'; Name = $target; Scope = $currentScope; Status = $view.Status; Placement = $view.Placement; IsManaged = $view.IsManaged; ActivePath = $view.Snapshot.CurrentPath; Issues = $view.Issues; Source = $source; PendingOperation = $view.PendingOperation; RetainedCopies = $view.RetainedCopies; NextActions = $view.NextActions }) 'SPX.Status'
                    }
                }
            )
            try { $stable = (Get-LinksConfig).generation -eq $cfg.generation } catch { $stable = $false }
            if ($stable) { $views; return }
        }
        foreach ($view in $views) {
            $view.Status = 'Invalid'; $view.Placement = 'Unknown'
            $view.Issues += [pscustomobject]@{ Code = 'StateChanged'; Message = 'State changed during observation; retry.' }
            $view
        }
    }
}

# Public automation contract; CLI helpers remain private.
Export-ModuleMember -Function @(
    'Move-SpxApp', 'Restore-SpxApp', 'Get-SpxLinkedApp', 'Sync-SpxLinkedApp', 'Repair-SpxLinkedApp', 'Remove-SpxStaleLink', 'Remove-SpxRetainedCopy',
    'Export-SpxLinkConfiguration', 'Import-SpxLinkConfiguration', 'Get-SpxAppSource', 'Set-SpxAppSource', 'Test-SpxAppSource',
    'Compare-SpxAppSource', 'Find-SpxAppSource', 'Get-SpxBucketMirror', 'New-SpxBucketMirror', 'Set-SpxBucketMirror',
    'Remove-SpxBucketMirror', 'Repair-SpxBucketMirror', 'Get-SpxStatus'
)

. "$PSScriptRoot/src/Cli.ps1"
Register-SpxCliCompletion
