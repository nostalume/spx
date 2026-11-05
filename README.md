# SPX

SPX relocates Scoop apps, shows where they are installed and which bucket/origin they use, and
recovers interrupted operations. Windows PowerShell 5.1 and PowerShell 7 on Windows are supported.

## Install and inspect

```powershell
scoop bucket add spx https://github.com/nostalume/spx
scoop install spx
spx -Help
spx linked
spx source jq
```

From a checkout, use `./spx.ps1` in place of `spx`.
Inspection returns objects with a summary, location/source, retained-copy count and next action.
`Ready` means the observed evidence agrees; `NeedsRecovery` names an unfinished operation;
`Conflict` or `Invalid` needs inspection. Expand `Issues`, `Source`, `PendingOperation` or
`RetainedCopies` for the evidence. Missing bucket information does not erase installation facts.

```powershell
spx linked jq | Select-Object Name,Scope,Status,ActivePath,Issues
```

## Relocate, restore, reclaim

```powershell
spx link jq -Destination 'D:\Apps' -Scope Local -WhatIf
spx link jq -Destination 'D:\Apps' -Scope Local
spx linked jq
spx unlink jq -WhatIf
```

`linked` lists managed apps, retained copies and pending operations; ordinary installed apps appear
under `source`. It shows the active path after a successful relocation. `sync jq` relocates later versions;
`unlink jq` restores them into Scoop. With no name, `sync` handles active destinations and imported
intent in Local scope; restored history alone is skipped. Both relocation and restore retain old copies, consuming
additional disk space. Retained copies are not unfinished recovery or an independent backup.

Stop applications, Scoop and other writers before reclaiming copies:

```powershell
spx cleanup jq -WhatIf | Select-Object Name,EligibleCopies,BlockedCopies
spx cleanup jq
```

The preview qualifies recorded copies without writing state. Execution checks again under the
writer. Changed/unique data, active references, unknown links, named data streams and insufficient
evidence stay blocked; expand `BlockedCopies` for each path and reason. There is no Force bypass.
`cleanup` also clears proven-stale ownership while retaining payload evidence. Repeating it is safe.

## One source relationship

An app records a bucket; that bucket has an actual Git origin. Select which relationship to change:

```powershell
spx source jq                       # app -> bucket -> origin
spx source jq -Bucket extras -WhatIf # only jq's recorded bucket
spx source -Buckets                 # bucket inventory
spx source -Bucket main             # one repository
spx source -Bucket main -Url https://mirror.example/main.git -WhatIf
spx source -Bucket main -Reset -WhatIf
```

Remove `-WhatIf` to apply a preview. An app-source change normally requires the target manifest's
version to match the installed version; `-Force` permits only that mismatch. A bucket URL change
affects every app using that bucket. Reset uses the saved original URL and refuses an unconfigured
bucket. Inspect `spx source -Bucket main` to verify the resulting origin.

`spx source -Help` also covers `-Find`, `-Compare <bucket>` and `-CheckVersion`. Version equality
does not prove software equivalence or source trust. Mutations default to Local; app inventory
defaults to All. Batch mutations stop at the first error; earlier commits remain committed.

## Recover

```powershell
spx repair jq -Scope Local -WhatIf
spx repair jq -Scope Local
spx repair -Bucket main -WhatIf
spx repair -Buckets -WhatIf
```

App repair with no name handles pending apps in Local scope. Bucket targets are explicit and
cannot be mixed with app names or Scope. Preserve operation journals and `.spx-*` paths until repair
resolves them. Reclamation repair resumes the explicit deletion; relocation repair retains copies.
Bucket repair never writes Git: a third-party origin value is a conflict and remains intact.

## Help, completion and automation

```powershell
spx source -Help
spx repair -Help
spx source jq -Bucket extras -Help # help for this mode; no source change
Import-Module SPX                  # from checkout: Import-Module ./SPX.psd1
Get-Help Remove-SpxRetainedCopy -Full
```

Module import enables completion for this session by wrapping `TabExpansion2` for `spx` only.
Other commands delegate to the previous implementation; `Remove-Module SPX` restores it if SPX
still owns the wrapper. Profiles are not modified. Completion uses the same command modes and
read-only observations; an unreadable target does not produce guessed names.

The PowerShell module retains its 20 automation functions, native parameters and structured results.
Configuration import/export remain module APIs: `Export-SpxLinkConfiguration` and
`Import-SpxLinkConfiguration`. Import records intent and cannot replace active ownership or recovery.

Old CLI syntax switches directly: `source get jq` becomes `source jq`; `source set jq -Bucket extras`
becomes `source jq -Bucket extras`; `mirror set main -Url ...` becomes `source -Bucket main -Url ...`;
`mirror remove main` becomes `source -Bucket main -Reset`. CLI `config` and `mirror` are removed.

See [maintaining SPX](docs/maintaining.md) for ownership, commit/recovery rules, proof limits and checks.

Apache-2.0 OR MIT: [Apache license](LICENSE-Apache), [MIT license](LICENSE-MIT).
