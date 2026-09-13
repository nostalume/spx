# SPX design

## Product boundary

SPX extends Scoop; it does not become another package manager. The primary surface is the packaged
`spx.ps1` command. `SPX.psd1` retains an 18-function module for automation and is the only domain
engine. The CLI owns grammar and admission, never Scoop layout, transaction policy, Git/filesystem
effects, or recovery decisions.

```text
Scoop shim -> spx.ps1 (native binder/process entry)
  -> lib/Cli.ps1 (leaf specification, validation, help, one dispatch)
    -> SPX.psm1 (effect-neutral facade and exact export allow-list)
      -> domain/Link.ps1   -> lib/ScoopState.ps1
      -> domain/Source.ps1 -> lib/ScoopState.ps1
      -> domain/Mirror.ps1 -> lib/Config.ps1
        -> lib/Context.ps1 + lib/Core.ps1
```

PowerShell binds declared parameters once. The CLI validates the selected leaf once and calls one
exported function once. There is no raw argv parser, per-command executor layer, or alternate
domain API. Operational output remains the module's PowerShell objects rather than a second schema.

## Owners

- `spx.ps1`: bounded native parameters, help/version fast paths, and process entry.
- `lib/Cli.ps1`: immutable command grammar, leaf-specific admission, help, and dispatch mapping.
- `lib/Context.ps1`: runtime Scoop/SPX root resolution; no import-time directory creation.
- `lib/ScoopState.ps1`: sole adapter for installed app layout, scope, current version, manifests,
  and persist roots.
- `lib/Config.ps1`: schema admission, bounded locking, atomic JSON generations, and journals.
- `lib/Core.ps1`: contained paths, checked links/copies/fingerprints, Git-neutral primitives, and
  typed/error helpers.
- `domain/`: relocation, source, and mirror policies plus their effect sequences.

An owner is split only when a genuinely independent consumer or change lifecycle appears. Domain
code may not independently infer a new Scoop layout; extend the adapter and its fixtures first.

## Safety invariants

- User-controlled names are one contained segment; traversal and separator forms are rejected.
- `current` and relocated targets must remain inside their admitted owners.
- Destination storage cannot overlap Scoop apps, persist roots, or SPX state.
- Unowned existing paths are collisions, not merge targets.
- Every mutation re-admits state under a bounded lock before its first effect.
- Durable evidence precedes non-atomic external effects; config commit follows verification.
- Cleanup removes only operation-owned paths whose identity/content is still proven.
- Repair refuses ambiguity and retains evidence.
- Each batch identity is an independent transaction; there is no implied aggregate rollback.

See [how SPX works](how-it-works.md) for operator-level transaction sequences.

## Compatibility and quality

The supported runtimes are Windows PowerShell 5.1 and PowerShell 7. `tools/Invoke-Quality.ps1` owns
parse, manifest, CLI/API parity, help, documentation-link, analyzer, and formatter checks.
`tools/Invoke-Tests.ps1` owns the controlled Pester suite plus direct packaged-entry smoke. CI only
installs pinned tools and invokes these repository commands.

Tests use isolated Scoop roots and local Git repositories. Release authority is a separate job with
job-scoped write permission and depends on unprivileged verification of the tagged checkout.

## Cost model

Layout traversal is iterative, skips reparse points and excluded persisted subtrees, and hashes
files as streams. Source inventory parses context/config once per invocation and uses a current-only
fast path. The deterministic 120-app test retains a 15-second and 128 MiB managed-allocation guard;
the 1,000-app benchmark is diagnostic because storage/security scanning makes wall time noisy.

Help and version must finish before module import or Scoop-state access. CLI admission is linear in
the small declared parameter set and keeps no process-global cache. A speed claim requires fresh
runtime/host workload, repetitions, median/p95 or allocation, variance, and semantic equivalence.

Reopen architecture only if the Scoop shim cannot invoke the advanced script, a command cannot map
to one module operation without semantic loss, the Scoop layout adapter cannot express a supported
layout, or a new output consumer requires a separately versioned serialization contract.
