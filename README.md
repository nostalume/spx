# SPX — Scoop Power Extensions

**SPX** is a PowerShell toolkit that extends [Scoop](https://scoop.sh/) with capabilities its core deliberately omits. Each module is independent, reversible, and non-duplicative.

## Why SPX?

| Pain point | SPX solution |
|---|---|
| Apps locked inside `~/scoop/apps` | `link` — relocate to any drive/path via symlinks |
| App points to wrong bucket after manual moves | `source change` — rewrites `install.json` in-place |
| Slow downloads, need a CDN mirror | `mirror set` — swaps git remote URL, saves the original |
| links.json out of sync after upgrades | `sync` — reconciles version and persist state |

## Design principles

1. **Orthogonality** — complements Scoop; never reimplements what Scoop already does.
2. **Modularity** — `lib/`, `modules/`, `exec/` have strict one-way dependency flow.
3. **Safety first** — destructive operations use `SupportsShouldProcess`; use `--whatif` to preview.
4. **Transparency** — operations emit structured objects, not raw strings.
5. **Stateless by default** — state is recorded only when necessary (`links.json`, mirror entry in `spx.json`), and always reversible.

## Installation

### Via Scoop (recommended)

```powershell
scoop bucket add spx https://github.com/lvyuemeng/spx
scoop install spx
```

### Manual

```powershell
git clone https://github.com/lvyuemeng/spx.git C:\Tools\spx
# Then add C:\Tools\spx to $env:PATH, or alias:
Set-Alias spx C:\Tools\spx\spx.ps1
```

**Requirements:** PowerShell 5.1+, Scoop installed.

---

## Commands

### Global flags (available on every command)

| Flag | Effect |
|---|---|
| `--global`, `-g` | Operate on the global Scoop install (requires admin) |
| `--whatif` | Preview changes without applying them |
| `-d`, `--debug` | Print internal debug trace |
| `-h`, `--help` | Show help for the current command |

---

### `link` — Relocate an app to a custom path

Moves an installed app's files to a custom directory and leaves a symlink in the original Scoop location. Scoop continues to see the app as installed; the files live elsewhere.

```powershell
# Move jq to D:\Portables
spx link jq --path D:\Portables

# Preview without changing anything
spx link jq --path D:\Portables --whatif

# Operate on a globally installed app (requires admin)
spx link 7zip --path D:\Portables --global

# Export your link config for backup or migration
spx link --export D:\Backup\links.json

# Import on a new machine
spx link --import D:\Backup\links.json

# Merge imported entries with existing config
spx link --import D:\Backup\links.json --merge
```

**Constraints:** `--path` must be an absolute path and must not contain the word `scoop`.

---

### `unlink` — Restore an app to the Scoop directory

Moves the app's files back from the custom path into the standard Scoop location and removes the symlink. Accepts multiple app names.

```powershell
spx unlink jq
spx unlink jq ripgrep fd       # restore several at once
spx unlink 7zip --global
```

---

### `linked` — List linked apps

```powershell
spx linked                     # local linked apps
spx linked --global            # global linked apps
spx linked --status            # show Linked / Stale status per entry
```

---

### `sync` — Reconcile link state after upgrades

When Scoop upgrades a linked app, the new version directory appears in Scoop's folder but has not been moved to the custom path. `sync` detects this, moves the new version, re-creates the symlink, and updates `links.json`. It also fixes persist symlinks.

```powershell
spx sync                       # sync all linked apps
spx sync jq                    # sync a specific app
spx sync --global              # sync global linked apps
spx sync --whatif              # preview what would change
```

---

### `cleanup` — Remove stale link entries

Scans `links.json` for entries whose app directory no longer exists (e.g. after `scoop uninstall`) and removes them.

```powershell
spx cleanup                    # interactive prompt before removal
spx cleanup --dry-run          # list stale entries, change nothing
spx cleanup --force            # remove without prompting
```

---

### `source` — Manage app bucket sources

SPX reads and rewrites Scoop's own `install.json`; no separate state file is maintained.

```powershell
# List all installed apps with their bucket
spx source list

# Show full source detail for one app
spx source show 7zip

# Re-assign an app to a different bucket
spx source change 7zip extras

# Force even if the bucket version differs
spx source change 7zip extras --force

# Verify that an app's install.json matches its registered bucket
spx source verify 7zip
spx source verify              # verify all installed apps

# Compare installed manifest fields against another bucket's manifest
spx source diff 7zip main

# Search all added buckets to find which ones contain an app
spx source find 7zip
```

---

### `mirror` — Manage bucket git remote mirrors

Changes a bucket's git remote URL to a mirror (useful for faster downloads in regions with poor GitHub connectivity). The original URL is saved and restored on `remove`.

```powershell
# List all buckets and their mirror state
spx mirror list

# Show detail for one bucket
spx mirror show main

# Add a mirror (fails if one already exists)
spx mirror add main https://mirror.example.com/main

# Set or change a mirror URL
spx mirror set main https://new-mirror.example.com/main

# Restore original URL and remove mirror config
spx mirror remove main
```

---

## Configuration files

All configuration lives under `$env:SCOOP\spx\`.

| File | Purpose |
|---|---|
| `links.json` | Records app → custom path mappings (local and global scopes) |
| `spx.json` | General SPX settings; mirror entries stored under `mirrors` key |

---

## Running tests

```powershell
# Requires Pester 5+
Install-Module Pester -Force
Invoke-Pester ./tests -Output Detailed
```

---

## License

Licensed under either of:

- [Apache License 2.0](LICENSE-Apache)
- [MIT License](LICENSE-MIT)