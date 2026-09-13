# How SPX works

Scoop remains authoritative for installed app versions, `current`, `install.json`, installed
`manifest.json`, persist roots, bucket repositories, and their Git remotes. SPX stores only the
intent and durable evidence needed to relocate apps and recover mirror changes.

SPX resolves roots at operation time. Local state comes from `$env:SCOOP`; global state comes from
`$env:SCOOP_GLOBAL` or Scoop configuration. The single layout adapter admits names as one path
segment, validates `current` containment, reads installed metadata, and corroborates relocated
targets with committed SPX ownership. Domain commands do not guess alternate layouts themselves.

## Relocating an app

For each app, SPX performs a bounded transaction:

1. Admit the app, scope, destination, version paths, manifest, and persisted paths.
2. Acquire the operation lock and write a journal naming every source, stage, target, and backup.
3. Copy non-persisted data to operation-owned staging and compare streaming fingerprints.
4. Publish the staged destination, move the canonical source to a backup, and create/verify a
   directory junction from Scoop's version path to the relocated target.
5. Recreate Scoop persist references. When source and configured persist data conflict, keep the
   configured value active and copy the source value to `.spx-conflict-<operation-id>`.
6. Atomically commit link ownership, verify source and target again, remove only the owned backup,
   and clear the journal.

No mirror/purge copy is used. Reparse points and persisted payloads are not recursively traversed.
An existing target is a neutral collision unless committed SPX state proves exact ownership.

Restore uses the inverse verified sequence: copy relocated data to an operation stage, remove only
the admitted junction, publish into Scoop, commit removal of SPX ownership, then remove only the
verified relocated source. `sync` applies relocation to versions Scoop installed later.

## Changing a mirror

SPX reads the current Git origin and writes a journal containing the old, original, and requested
URLs before calling Git. Git must return success and a post-read must equal the requested URL before
SPX atomically commits mirror configuration. If configuration commit fails, SPX restores and
verifies the previously observed URL. If both commit and compensation fail, it keeps the journal.

Removing a mirror follows the same protocol but requests the saved original URL and deletes the
committed mirror record only after verification.

## Configuration and recovery

SPX state lives under `$env:SCOOP\spx`:

- `links.json` contains versioned local/global relocation ownership.
- `spx.json` contains committed bucket mirror records.
- `operations\` contains incomplete link and mirror journals.

JSON configuration is written with a bounded lock and same-directory atomic replacement; a
`.previous` generation is retained. Empty or malformed JSON is treated as evidence of invalid
state, not silently as empty configuration.

Repair is explicit and idempotent. A relocation repair compares the journal, committed operation
identity, junction targets, and fingerprints. A mirror repair completes configuration only when Git
already shows the requested URL; otherwise it restores the recorded old URL. Ambiguous or modified
evidence produces a terminating `Spx.*` error and is preserved.

`-WhatIf` reaches the domain `ShouldProcess` boundary before mutation. Reads, help, version, and module import do
not create roots or state. For object types and stable error families, see [the module API](api.md).
