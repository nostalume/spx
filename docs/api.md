# PowerShell module API

The `SPX` module is the secondary automation surface and the sole domain/transaction engine behind
the `spx` command. Importing `SPX.psd1` is effect-neutral. All mutations are advanced functions with
native `-WhatIf` and `-Confirm`; reads do not expose those parameters.

```powershell
Import-Module .\SPX.psd1
Get-Help Move-SpxApp -Full
```

`Name` arrays accept strings and `AppName` properties from the pipeline. `Bucket` arrays on list or
batch mirror commands accept strings and `BucketName` properties. Local mutations default to
`Local`; inventory commands that support both scopes default to `All`.

## Commands and results

| Command | Project parameters | Result |
|---|---|---|
| `Move-SpxApp` | `-Name`, `-Destination`, `-Scope` | `SPX.AppMoveResult` |
| `Restore-SpxApp` | `-Name`, `-Scope` | `SPX.AppRestoreResult` |
| `Get-SpxLinkedApp` | `-Name`, `-Scope` | `SPX.LinkedApp` |
| `Sync-SpxLinkedApp` | `-Name`, `-Scope` | `SPX.AppMoveResult` |
| `Repair-SpxLinkedApp` | `-Name`, `-Scope` | `SPX.LinkedAppRepairResult` |
| `Remove-SpxStaleLink` | `-Name`, `-Scope` | `SPX.StaleLinkRemovalResult` |
| `Export-SpxLinkConfiguration` | `-Path`, `-Force` | `SPX.LinkConfigurationExportResult` |
| `Import-SpxLinkConfiguration` | `-Path`, `-Merge` | `SPX.LinkConfigurationImportResult` |
| `Get-SpxAppSource` | `-Name`, `-Scope` | `SPX.AppSource` |
| `Set-SpxAppSource` | `-Name`, `-Bucket`, `-Scope`, `-Force` | `SPX.SourceChangeResult` |
| `Test-SpxAppSource` | `-Name`, `-Scope` | `System.Boolean` |
| `Compare-SpxAppSource` | `-Name`, `-Bucket`, `-Scope` | `SPX.AppSourceComparison` |
| `Find-SpxAppSource` | `-Name` | `SPX.AppSourceCandidate` |
| `Get-SpxBucketMirror` | `-Bucket` | `SPX.BucketMirror` |
| `New-SpxBucketMirror` | `-Bucket`, `-Url` | `SPX.BucketMirrorResult` |
| `Set-SpxBucketMirror` | `-Bucket`, `-Url` | `SPX.BucketMirrorResult` |
| `Remove-SpxBucketMirror` | `-Bucket` | `SPX.BucketMirrorResult` |
| `Repair-SpxBucketMirror` | `-Bucket` | `SPX.BucketMirrorRepairResult` |

The leading `PSTypeNames` and stable properties are suitable for PowerShell automation. Mutation
receipts include `Status` and `Changed`; relocation receipts additionally identify name, scope,
destination, versions, and operation. Inspection objects expose observed state and evidence.

```powershell
Move-SpxApp jq -Destination 'D:\Portable Apps' -WhatIf
Get-SpxLinkedApp jq | Where-Object State -ne Healthy

Get-SpxAppSource -Scope All | Select-Object Name,Scope,Bucket,Version
Set-SpxAppSource jq -Bucket extras -WhatIf

Get-SpxBucketMirror | Where-Object State -in Drifted,PendingRecovery
Repair-SpxBucketMirror main -Confirm:$false
```

Configuration import records validated intent only. Inspect with `Get-SpxLinkedApp`, then invoke
sync or repair explicitly as observed state requires.

## Stable error families

PowerShell may append the emitting command to `FullyQualifiedErrorId`; match the stable leading ID.

| Family | Meaning |
|---|---|
| `Spx.AppNotInstalled`, `Spx.LinkNotFound`, `Spx.LinkNotStale` | Requested app/link state does not admit the operation. |
| `Spx.DestinationCollision`, `Spx.AlreadyLinkedElsewhere` | Destination ownership is unsafe. |
| `Spx.PendingRecovery`, `Spx.NoPendingRecovery` | Repair is required, or the requested journal does not exist. |
| `Spx.RecoveryConflict`, `Spx.CommittedCleanupConflict`, `Spx.CommittedCleanupPending` | Evidence changed or cleanup could not be proven safe. |
| `Spx.RelocationAndRollbackFailed` | Primary relocation and automatic rollback both failed. |
| `Spx.VersionMismatch`, `Spx.ManifestNotFound` | Source metadata admission failed. |
| `Spx.BucketNotGitRepository`, `Spx.GitFailed`, `Spx.GitVerificationFailed` | Bucket Git effect or observation failed. |
| `Spx.MirrorAlreadyExists`, `Spx.MirrorNotFound` | Committed mirror state contradicts the request. |
| `Spx.MirrorCommitAndRollbackFailed`, `Spx.RecoveryFailed` | Mirror compensation/recovery could not prove completion. |
| `Spx.ExportExists`, `Spx.ImportNotFound` | Configuration path admission failed. |

`Get-Help <command> -Full` is the detailed authority for parameters, effects, examples, results, and
recovery notes. The manifest allow-list is checked against this table and the CLI dispatch map.
