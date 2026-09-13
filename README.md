# SPX — recoverable Scoop extensions

SPX is a Scoop-style `spx` command for relocating installed apps, inspecting or changing their
recorded bucket source, and switching bucket Git remotes. It is designed around refusal and
recovery: ambiguous destinations, malformed state, failed Git checks, and changed recovery data
are preserved instead of guessed away.

SPX supports Windows PowerShell 5.1 and PowerShell 7 on Windows.

## Install

```powershell
scoop bucket add spx https://github.com/nostalume/spx
scoop install spx
spx -Version
spx -Help
```

From a checkout, replace `spx` in the examples with `./spx.ps1`.

## Start safely

Preview mutations with PowerShell's native `-WhatIf` parameter:

```powershell
spx linked -Scope All
spx source get jq -Scope Local
spx link jq -Destination 'D:\Portable Apps' -Scope Local -WhatIf
spx mirror set main -Url 'https://mirror.example/main.git' -WhatIf
```

If the preview names the intended target, run the same command without `-WhatIf`. Native
parameters are single-hyphen and case-insensitive. Use `-Confirm:$false` only when a
non-interactive caller has already made the same safety decision.

```powershell
spx link jq -Destination 'D:\Portable Apps' -Confirm:$false
spx linked jq
spx unlink jq
```

The success check is `spx linked jq`: healthy relocated apps report `Healthy`. Commands return
ordinary PowerShell objects, so selection and formatting remain available:

```powershell
spx linked -Scope All | Select-Object Name, Scope, State, Destination
```

## Recovery

If an interrupted mutation leaves durable evidence, inspection reports `PendingRecovery` and new
mutations for that identity are refused. Keep the reported files and run the matching repair:

```powershell
spx repair jq -Scope Local -WhatIf
spx repair jq -Scope Local

spx mirror repair main -WhatIf
spx mirror repair main
```

Repair uses the recorded operation plus observed files or Git state. It rolls forward only when
the requested effect is proven; otherwise it restores the recorded pre-state. Do not manually
delete `$env:SCOOP\spx\operations` or `.spx-*` recovery paths.

## Learn more

- [CLI reference](docs/cli.md) — every command, default, effect, diagnostic, and 0.4 migration.
- [How SPX works](docs/how-it-works.md) — ownership, transaction edges, collisions, and recovery.
- [PowerShell module API](docs/api.md) — the retained secondary automation surface.
- [Design](docs/design.md) — maintainer boundaries, dependencies, and cost model.

For repository checks:

```powershell
./tools/Invoke-Quality.ps1
./tools/Invoke-Tests.ps1
```

Tests use disposable Scoop roots and local Git repositories; they do not touch the live Scoop
installation.

## License

Apache-2.0 OR MIT; see [LICENSE-Apache](LICENSE-Apache) and [LICENSE-MIT](LICENSE-MIT).
