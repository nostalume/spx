# Maintaining SPX

Public command usage belongs to `spx -Help` and command help; module parameter/result reference
belongs to `Get-Help <SpxFunction> -Full`. README provides complete user tasks. Change those alongside
the behavior they describe; do not maintain a second hand-written parameter catalogue.

## Owners and changes

`SPX.psm1` assembles private definitions once and exposes the explicit manifest allow-list. Internal
files do not load each other. `spx.ps1` binds a bounded set of native parameters and loads only Cli
for help/version; actual invocations use the module APIs.
Entry initialization runs once in begin; process handles bound object records. Independent -File
calls with inherited empty stdin still execute once; an explicit empty object pipeline stays empty.

| Owner | Change here |
|---|---|
| `src/Cli.ps1` | Command modes, admission, help/examples, projections and session completion. |
| `src/Scoop.ps1` | Runtime roots, installed versions, manifests, persist layout and app/bucket directory names. |
| `src/Store.ps1` | JSON/schema admission, writer lifetime, atomic generations and journals. |
| `src/Files.ps1` | Checked paths, streamed hashes/copies, links, renames and stream inspection. |
| `src/Link.ps1` | Relocate/restore/recover/reclaim, ownership/intent, portable import/export. |
| `src/Source.ps1` | App -> bucket and bucket -> origin; distinct commit rules in one owner. |

Layout knowledge stays with Scoop. Storage uses runtime root bindings and delegates operation-specific
admission to the relevant domain; storage alone is not deletion authority. Files does not infer
ownership. CLI orchestrates public operations without reading Scoop directories or writing state.
Store enumerates journal keys; Source combines bucket names and recorded identities. The shared
query facade composes these observations, including invalid or journal-only identities. Invalid
bucket entries are isolated in reads; a mutation still requires valid source state. `linked` filters
the unified query by its observed IsManaged fact and retains invalid-state evidence; it does not
derive ownership from display strings or use a second query contract.

The CLI mode table drives admission, help and completion candidates. Test a new mode through the
actual script, including invalid combinations before module import. The completion wrapper preserves
both native TabExpansion2 parameter sets, delegates other commands and owns only its session lifetime.
Raw script argument parsing and profile changes are not required.

## Facts, ownership and commit

App and bucket names are case-insensitive identities. Identity maps admit one spelling per name;
case-colliding records are refused without writing. This does not change arbitrary JSON keys or URL
case rules. Installation identity is `(Scope, Name)`; versions have their own installed manifest and persist
definitions. Scoop owns installed layout and Git owns actual origin. SPX separates `Active`, imported
`Intent`, `Retained` copies and `LastOperation` receipts. Intent cannot authorize an existing junction
or deletion. A phase label alone cannot establish commit.

One state-root writer covers mutations, including source changes, import/export and repair. Its
bounded wait is five seconds; reads do not acquire it. It coordinates only processes sharing that
SPX state root, including for Global apps. Other users, Scoop and applications remain external writers.

| Operation | Commit | Recovery |
|---|---|---|
| Move / restore | Verified layout/persist references followed by atomic ownership and operation receipt. | Receipt plus paths/hashes determine completion or safe pre-state restoration; retain other payloads. |
| Reclaim | Root deletion followed by removal of retained identities and a receipt. | Resume only unchanged entries from the immutable deletion inventory; clear journal last. |
| App source | Same-directory atomic install.json replacement after fresh version/manifest/metadata admission. | The document is a complete old or new value; no extra journal. Only bucket changes. |
| Bucket source | Checked Git effect followed by atomic source record and receipt. | Same repository + requested URL: complete record. Old URL + no committed receipt: restore exact previous record. Third URL, changed/unreadable repository, or old URL after commit: refuse and preserve. |

Bucket repair performs no Git write. Compare URLs case-sensitively. Preserve unknown JSON fields
and string values, including date-like strings; JSON parsing must not silently reinterpret them as
timestamps. Schema 1 is read in memory; an authorized write upgrades the relevant file atomically.
Unknown schemas, empty/corrupt documents and ambiguous journals are refused, not replaced with empty
state. `.previous` files preserve the preceding generation; they are not automatic rollback commands.

Portable configuration exports carry intent, not retained-copy deletion authority. Import cannot
erase active ownership, pending recovery or retained evidence. `Remove-SpxStaleLink` remains metadata
cleanup; the CLI combines it with explicit retained-copy reclamation through the public APIs.

## Reclamation argument and limits

Reclamation needs exact recorded ownership, an installed equivalent alternative, no known managed
references into the candidate, and unchanged content/link evidence. Persist data is compared against
its scoped active target. Conflict copies, unknown reparse points and named data streams stay blocked.
The read-only qualification used by WhatIf and the locked execution share one implementation;
the latter re-admits everything. Qualification is not a reservation against later writes.

Let M be the immutable inventory and R the remaining entries. Each original entry has an active
equivalent. Recovery requires R to be a subset of M with the same kind/hash/target and rechecks the
alternative. Each step deletes a verified entry or an empty directory, without following links.
Under stable trees, induction preserves an active value for every deleted logical item. Interruption
only reduces R; added/changed entries stop deletion and preserve evidence. Retained ownership remains
until root deletion, so losing an acknowledgement cannot erase recovery authority.

This conditional argument assumes stable trees during compare/delete, trusted admitted evidence and
the supported Windows filesystem primitives. It does not prove arbitrary concurrent-writer isolation,
power-loss durability or resistance to malicious state editing. Repository replacement evidence is
path/Git-directory/creation-time evidence. Managed-reference scans do not enumerate arbitrary links
outside managed roots. Reclamation uses memory proportional to inventory size; ordinary inspection
does not hash old copies. Retained data is not an independent backup service.

## Verification and regression triggers

Install pinned Pester 5.7.1 and PSScriptAnalyzer 1.25.0, then run in both Windows PowerShell 5.1 and
PowerShell 7:

```powershell
./tools/Invoke-Quality.ps1
./tools/Invoke-Tests.ps1
```

Use `Invoke-Quality.ps1 -Mode Format` to apply canonical formatting. Quality checks parsing,
format/analyzer rules, package/manifest parity, explicit exports, mode mappings, module help and
Markdown links. Pester exercises mode behavior/examples, actual completion and module contracts;
the canonical test command also runs the isolated packaged-entry smoke. Tests use disposable roots
and local Git repositories. The standalone metadata benchmark is diagnostic; allocation measures
that need PowerShell 7 are not a 5.1 acceptance requirement.

For layout or persist changes, add multi-version/scope/link fixtures. For filesystem or journal
changes, preserve actual process-termination recovery cases and verify bytes, topology and remaining
copies. For source changes, test exact field locality, version races, Git failure, URL drift and
repository evidence changes. For CLI changes, test legal modes, illegal mixes, ordering, pipelines,
WhatIf identity, actual TabExpansion2 (including AST/options), and non-SPX delegation/unload.
Changing a documented guarantee requires updating its counterexample and explanation together.

Preserve the 20 exported API names, parameter sets and stable error/result fields. CLI grammar is a
separate user contract; it need not mirror the API. Publication, version selection and live Scoop
installation acceptance are separate from local source verification.
