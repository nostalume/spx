# SPX - Scoop Power Extensions

## Project Overview

**SPX** (Scoop Power Extensions) is a PowerShell enhancement toolkit for Scoop.

### Design Philosophy

1. **Orthogonality** - Features complement Scoop without duplication
2. **Modularity** - Independent modules with clear boundaries
3. **Safety First** - Destructive ops require confirmation; reversible
4. **Transparency** - Clear logging and status reporting
5. **Stateless by Default** - Don't record state unless necessary

---

## Architecture

```
spx/
├── spx.ps1              # CLI entry point (thin router)
├── context.ps1          # Scoop path resolution (single source of truth)
├── lib/
│   ├── Core.ps1         # Shared utilities (JSON, admin, app helpers, file ops)
│   ├── Parse.ps1       # CLI argument parsing
│   └── Config.ps1      # Configuration I/O (spx.json, links.json)
├── modules/
│   ├── Link.ps1        # App relocation via symbolic links
│   ├── Mirror.ps1     # Bucket git remote mirror management
│   └── Source.ps1     # App bucket source management (stateless)
├── exec/
│   ├── link.ps1       # link command
│   ├── unlink.ps1     # unlink command
│   ├── linked.ps1     # linked command
│   ├── sync.ps1       # sync command
│   ├── cleanup.ps1    # cleanup command (remove stale link entries)
│   ├── source.ps1     # source command
│   └── mirror.ps1     # mirror command
└── tests/
    └── Sandbox.ps1    # Test helper for isolated testing
```

### Design Pattern

- **spx.ps1**: Thin router that dispatches to `exec/*.ps1` scripts
- **lib/**: Reusable libraries (Config, Core, Parse)
- **modules/**: Business logic modules with public APIs
- **exec/**: CLI command implementations that compose modules
- **context.ps1**: Single source of truth for Scoop paths

---

## Context - Scoop Path Resolution

[`context.ps1`](context.ps1:1) provides a single source of truth for all Scoop paths:

| Variable | Description |
|----------|-------------|
| `$Script:ScoopHome` | User's Scoop directory (from `$env:SCOOP` or `~/scoop`) |
| `$Script:ScoopGlobal` | Global Scoop directory (from `$env:SCOOP_GLOBAL` or `C:\ProgramData\scoop`) |
| `$Script:ScoopPaths` | Ordered hashtable of Scoop subdirectories (apps, buckets, persist, shims, cache, spx) |

---

## Library

### [`lib/Core.ps1`](lib/Core.ps1:1) - Shared Utilities

Pure functions only. No Write-Host. Outputs objects, not strings.

| Function | Description |
|----------|-------------|
| `ConvertFrom-JsonAsHashtable` | JSON to hashtable (PS5.1+ compatible) |
| `Test-IsAdmin` | Check if running as Administrator |
| `Get-AppBasePath` | Get app base directory |
| `Test-AppInstalled` | Check if app is installed |
| `Get-AppVersions` | Get all installed versions |
| `Get-AppCurrentVersion` | Get current (active) version |
| `Get-AppInstallManifest` | Read install.json |
| `Get-AppPersistPath` | Get persist directory path |
| `Resolve-VersionSymlink` | Resolve symlink target |
| `Invoke-RobocopyMove` | Move files via robocopy |
| `New-Symlink` | Create symbolic link |
| `Update-PersistLinks` | Sync persist directory symlinks |

### [`lib/Config.ps1`](lib/Config.ps1:1) - Configuration I/O

Thin read/write layer. No business logic.

| Config File | Location |
|-------------|----------|
| spx.json | `$env:SCOOP/spx/spx.json` |
| links.json | `$env:SCOOP/spx/links.json` |

| Function | Description |
|----------|-------------|
| `Get-SpxConfig` | Read from spx.json |
| `Set-SpxConfig` | Write to spx.json |
| `Get-LinksConfig` | Read links.json |
| `Set-LinksConfig` | Write links.json |
| `Get-LinkEntry` | Get single link entry |
| `Set-LinkEntry` | Create/update link entry |
| `Remove-LinkEntry` | Remove link entry |
| `Export-LinksConfig` | Export to file |
| `Import-LinksConfig` | Import from file |

### [`lib/Parse.ps1`](lib/Parse.ps1:1) - Argument Parsing

| Function | Description |
|----------|-------------|
| `Get-ParsedArgs` | Parse flat argument array into positional items and named options |
| `Test-HelpFlag` | Check for -h/--help flags |

---

## Modules

### LINK - App Relocation

Located in [`modules/Link.ps1`](modules/Link.ps1:1). Moves apps to custom paths via symbolic links.

| Command | Description |
|---------|-------------|
| `spx link <app> --path <dir>` | Move app to custom directory |
| `spx link --export <file>` | Export links.json to file |
| `spx link --import <file> [--merge]` | Import links.json from file |
| `spx unlink <app>` | Restore app to Scoop directory |
| `spx linked [--status]` | List linked apps |
| `spx sync [<app>]` | Sync version/persist state |
| `spx cleanup [--dry-run] [--force]` | Remove stale link entries |

| Function | Description |
|----------|-------------|
| `New-AppLink` | Move app to custom path, leave symlink |
| `Remove-AppLink` | Restore app to Scoop, remove symlink |
| `Get-AppLinkStatus` | Get link status (Linked/Stale) |
| `Sync-AppLinks` | Reconcile config with installed state |
| `Get-StaleLinkEntries` | Find entries with missing app dirs |
| `Remove-StaleLinkEntry` | Remove single stale entry |

---

### SOURCE - Bucket Source Management

Located in [`modules/Source.ps1`](modules/Source.ps1:1). **Stateless** - reads directly from Scoop's install.json.

| Command | Description |
|---------|-------------|
| `spx source list` | List all apps with bucket sources |
| `spx source show <app>` | Show app source details |
| `spx source change <app> <bucket>` | Change app's bucket |
| `spx source verify [<app>]` | Verify manifest matches bucket |
| `spx source diff <app> <bucket>` | Compare installed vs bucket manifest |
| `spx source find <app>` | Search all buckets for app |

| Function | Description |
|----------|-------------|
| `Get-AppSource` | Get source info for an app |
| `Get-AppSourceList` | List all apps with sources |
| `Move-AppSource` | Change app's bucket |
| `Test-AppSourceValid` | Verify app matches bucket |
| `Compare-AppManifest` | Compare installed vs bucket |
| `Find-AppBucket` | Search buckets for app |
| `Get-BucketList` | List added buckets |

---

### MIRROR - Bucket Mirror Management

Located in [`modules/Mirror.ps1`](modules/Mirror.ps1:1). Manages bucket git remote mirrors, preserving original URLs for reversibility.

| Command | Description |
|---------|-------------|
| `spx mirror list` | List buckets and mirror state |
| `spx mirror show <bucket>` | Show bucket mirror details |
| `spx mirror add <bucket> <url>` | Add mirror (fails if exists) |
| `spx mirror set <bucket> <url>` | Set/change mirror URL |
| `spx mirror remove <bucket>` | Restore original URL |

| Function | Description |
|----------|-------------|
| `Get-BucketMirror` | Get mirror info for bucket(s) |
| `Set-BucketMirror` | Set bucket remote to mirror URL |
| `Remove-BucketMirror` | Restore original remote URL |
| `Get-BucketRemoteUrl` | Get current git remote URL |
| `Set-BucketRemoteUrl` | Set git remote URL |

---

## Sandbox - Test Helper

Located in [`tests/Sandbox.ps1`](tests/Sandbox.ps1:1). Provides isolated test environment for Pester tests.

### Functions

| Function | Description |
|----------|-------------|
| `Enter-Sandbox` | Enter sandbox, inject test paths |
| `Exit-Sandbox` | Exit sandbox, restore original environment |
| `New-SandboxApp` | Create fake app with install.json |
| `New-SandboxBucketDir` | Create fake bucket directory |
| `New-SandboxBucketManifest` | Create bucket manifest file |
| `Write-SandboxLinkEntry` | Write link entry for testing |

### Environment Injection

| Variable | Original | Sandbox |
|----------|----------|---------|
| `$env:SCOOP` | User's scoop path | `TestDrive:\sandbox\scoop` |
| `$env:SCOOP_GLOBAL` | User's global scoop path | `TestDrive:\sandbox\scoop_global` |

---

## CLI

```
spx <command> [options]

Commands:
  link     <app> --path <dir>   Relocate app to a custom directory
  unlink   <app>                Restore app to Scoop directory
  linked   [--status]           List linked apps
  sync     [<app>]              Sync version/persist state for linked apps
  cleanup  [--dry-run]          Remove stale link entries
  source   <action> [...]       Manage app bucket sources
  mirror   <action> [...]       Manage bucket git remote mirrors

Flags (any command):
  --global, -g    Operate on the global Scoop install
  --whatif        Simulate without making changes
  -d, --debug     Verbose debug output
  -h, --help      Show help
```

---

## Function Naming

| Verb | Purpose |
|------|---------|
| `Get-` | Retrieve data |
| `Set-` | Modify config |
| `New-` | Create resource |
| `Remove-` | Delete resource |
| `Test-` | Validate |
| `Invoke-` | Execute operation |
| `Sync-` | Reconcile state |
| `Move-` | Change location |
| `Compare-` | Compare two sources |

---

## Error Handling

| Category | Behavior |
|----------|----------|
| Context | Terminate immediately |
| Validation | Return error, no action |
| Maybe | Return `$null` |
| Recoverable | Try/catch with rollback |

---

## Testing

Tests use [Pester](https://pester.dev/) and the Sandbox helper:

```powershell
# tests/Link.Tests.ps1

BeforeAll {
    . "$PSScriptRoot/Sandbox.ps1"
    . "$PSScriptRoot/../lib/Core.ps1"
    . "$PSScriptRoot/../modules/Link.ps1"
}

Describe "New-AppLink" {
    BeforeEach {
        $sb = Enter-Sandbox
        New-SandboxApp -AppName 'jq' -Version '1.7.1'
    }
    
    AfterEach {
        Exit-Sandbox
    }
    
    It "Moves app to custom path" {
        $result = New-AppLink -AppName 'jq' -Path 'D:\Apps' -Confirm:$false
        $result.AppName | Should -Be 'jq'
    }
}
```
