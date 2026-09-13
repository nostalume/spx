# SPX command reference

`spx` is an advanced PowerShell script. PowerShell performs named/switch binding; SPX then checks
the selected command leaf before importing its transaction module. Parameter names, command names,
actions, and enum values are case-insensitive. Canonical syntax uses one hyphen (`-Scope`), not GNU
double-hyphen options.

Use `spx -Help`, `spx help <command> [<action>]`, or `spx <command> [<action>] -Help`. Help and
version do not import the module or create state.

## Command grammar

| Command | Purpose and defaults |
|---|---|
| `spx link <Name>... -Destination <Path> [-Scope Local\|Global] [-WhatIf] [-Confirm]` | Relocate all installed versions. Scope defaults to Local. |
| `spx unlink <Name>... [-Scope Local\|Global] [-WhatIf] [-Confirm]` | Restore managed versions to Scoop. Scope defaults to Local. |
| `spx linked [<Name>...] [-Scope Local\|Global\|All]` | Inspect committed intent and observed health. Scope defaults to All. |
| `spx sync [<Name>...] [-Scope Local\|Global] [-WhatIf] [-Confirm]` | Relocate newly installed versions of managed apps. Omitted names select all managed apps in the scope. |
| `spx repair [<Name>...] [-Scope Local\|Global] [-WhatIf] [-Confirm]` | Resolve pending relocation operations. Omitted names select all pending operations in the scope. |
| `spx cleanup <Name>... [-Scope Local\|Global] [-WhatIf] [-Confirm]` | Remove a link record only after the app is proven absent and no recovery is pending. |
| `spx config export -Path <File> [-Force] [-WhatIf] [-Confirm]` | Atomically export link intent; `-Force` permits replacing the file. |
| `spx config import -Path <File> [-Merge] [-WhatIf] [-Confirm]` | Validate then replace or merge link intent. Does not move files. |
| `spx source get [<Name>...] [-Scope Local\|Global\|All]` | Inspect installed source and manifest metadata. Scope defaults to All. |
| `spx source set <Name>... -Bucket <Bucket> [-Scope Local\|Global] [-Force] [-WhatIf] [-Confirm]` | Atomically change only `install.json` bucket metadata. `-Force` permits version mismatch only. |
| `spx source test <Name>... [-Scope Local\|Global]` | Return one Boolean per app for configured-bucket version identity. |
| `spx source compare <Name> -Bucket <Bucket> [-Scope Local\|Global]` | Compare version and selected installed/bucket manifest fields. |
| `spx source find <Name>...` | Find added buckets containing each requested manifest. |
| `spx mirror get [<Bucket>...]` | Inspect Git origin, committed mirror state, drift, and recovery. |
| `spx mirror add <Bucket> -Url <Url> [-WhatIf] [-Confirm]` | Record the original origin and configure the first mirror. |
| `spx mirror set <Bucket> -Url <Url> [-WhatIf] [-Confirm]` | Replace an existing mirror while preserving the original origin. |
| `spx mirror remove <Bucket>... [-WhatIf] [-Confirm]` | Restore each original origin and remove committed mirror state. |
| `spx mirror repair <Bucket>... [-WhatIf] [-Confirm]` | Complete or roll back pending mirror operations from durable evidence. |

`-Destination`, `-Path`, `-Bucket`, and `-Url` belong only to the leaves that show them. A parameter
valid for another leaf is rejected before module import. Identity order is preserved. In a batch,
each identity is its own transaction and processing stops on the first terminating failure; earlier
committed identities are not rolled back as a group.

## Examples

```powershell
spx link jq rg -Destination 'D:\Portable Apps' -WhatIf
spx unlink jq -Scope Local
spx linked jq -Scope All
spx sync jq -WhatIf
spx repair jq -Confirm:$false
spx cleanup removed-app -WhatIf

spx config export -Path .\spx-links.json
spx config import -Path .\spx-links.json -Merge -WhatIf

spx source get jq
spx source set jq -Bucket extras -Force -WhatIf
spx source test jq
spx source compare jq -Bucket main
spx source find jq rg

spx mirror get main
spx mirror add main -Url 'https://mirror.example/main.git' -WhatIf
spx mirror set main -Url 'https://mirror2.example/main.git' -Confirm:$false
spx mirror remove main -WhatIf
spx mirror repair main -WhatIf
```

## Output and status

Operational commands emit the module's typed PowerShell objects. Mutation objects include `Status`
and `Changed`; previewed mutations normally emit PowerShell's WhatIf message and no success receipt.
`source test` intentionally emits Booleans. Stdout formatting is for people and is not a stable
serialization schema; automation should use the [module API](api.md).

Help, version, successful work, no-op, and successful preview complete with process status zero.
Binding, leaf admission, or operation failure is nonzero. Native binding diagnostics remain native.
SPX leaf errors use `Spx.CliUsage`; domain errors retain stable leading `Spx.*` identifiers. No more
granular cross-runtime numeric status taxonomy is promised.

## Failure and recovery guide

| Symptom | Action |
|---|---|
| `Spx.AppNotInstalled`, `Spx.LinkNotFound`, `Spx.MirrorNotFound` | Recheck identity and scope; inspect before mutating. |
| `Spx.DestinationCollision` or `Spx.AlreadyLinkedElsewhere` | Choose an empty destination or restore the existing managed link first. SPX will not merge ownership. |
| `Spx.VersionMismatch` | Select the matching bucket; use `-Force` only after accepting that exact mismatch. |
| `Spx.PendingRecovery` | Preserve evidence and run `spx repair` or `spx mirror repair`. |
| `Spx.RecoveryConflict` or committed-cleanup error | Preserve the reported path, inspect changes, then retry repair; SPX refused destructive cleanup. |
| `Spx.GitFailed` or Git verification error | Fix repository/remote access, inspect `spx mirror get`, then repair if pending. |

## Migration from 0.4

The unreleased 0.5 command surface intentionally drops the manual GNU-style parser and per-command
executors. Use native PowerShell spelling:

| 0.4 form | 0.5 form |
|---|---|
| `--to D:\Apps` / `--path D:\Apps` | `-Destination 'D:\Apps'` |
| `--global` | `-Scope Global` |
| `--whatif` / `--dry-run` | `-WhatIf` |
| `--force` | `-Force` on the documented leaf |
| `--bucket extras` | `-Bucket extras` |
| `--url <remote>` | `-Url <remote>` |

There is no compatibility promise for GNU options, a bare `--` terminator, old aliases, short
forms, or PowerShell's incidental unambiguous parameter abbreviations.
