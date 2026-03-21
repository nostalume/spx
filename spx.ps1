# spx.ps1 - SPX entry point
# Thin router. All logic lives in modules.

param (
    [Parameter(Position = 0)] [string]$Command,
    [Parameter(ValueFromRemainingArguments)] [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# Early debug flag
if ($Rest -contains '-d' -or $Rest -contains '--debug') {
    $DebugPreference = 'Continue'
    $Rest = @($Rest | Where-Object { $_ -notin '-d','--debug' })
}

. "$PSScriptRoot/context.ps1"
. "$PSScriptRoot/lib/Parse.ps1"

$HelpText = @{
    main = @'
SPX - Scoop Power Extensions  v2.0

Usage: spx <command> [options]

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

Run "spx <command> -h" for command-specific help.
'@
    link = @'
spx link <app> --path <dir>   Move app to a custom directory
spx link --export <file>      Export link config to a JSON file
spx link --import <file>      Import link config from a JSON file [--merge]

Options:
  --path, --to    Target directory (must be absolute, must not contain "scoop")
  --export        Write links.json to a file
  --import        Load links.json from a file
  --merge         Merge imported entries with existing config
  --global, -g    Operate on globally installed apps
  --whatif        Show what would happen without making changes
'@
    unlink = @'
spx unlink <app> [<app2> ...]   Restore apps to the Scoop directory
Options: --global/-g, --whatif
'@
    linked = @'
spx linked [--status] [--global]
  --status    Show Linked / Stale status for each entry
'@
    sync = @'
spx sync [<app>]   Sync version and persist links for linked apps
  Omit <app> to sync all linked apps.
Options: --global/-g, --whatif
'@
    cleanup = @'
spx cleanup [--dry-run] [--force]
  Removes links.json entries whose app directory is missing.
  --dry-run    Show what would be removed without acting
  --force      Skip confirmation prompt
'@
    source = @'
spx source list                    List all installed apps with their bucket
spx source show <app>              Show detailed source info
spx source change <app> <bucket>   Re-assign app to a different bucket
spx source verify [<app>]          Verify manifest matches registered bucket
spx source diff <app> <bucket>     Compare installed vs bucket manifest
spx source find <app>              Search all added buckets for the app
Options: --force (for change), -h/--help
'@
    mirror = @'
spx mirror list                  List buckets and their mirror state
spx mirror add <bucket> <url>    Add a mirror (fails if already mirrored)
spx mirror set <bucket> <url>    Set / change mirror URL
spx mirror remove <bucket>       Restore original URL and clear mirror
'@
}

function Show-Help { param ([string]$Ctx = 'main') Write-Host ($HelpText[$Ctx] ?? $HelpText['main']) }

$Commands = @{
    link    = 'link'
    unlink  = 'unlink'
    linked  = 'linked'
    sync    = 'sync'
    cleanup = 'cleanup'
    source  = 'source'
    mirror  = 'mirror'
}

# $parsed = Get-ParsedArgs @($Command) + $Rest   # used only for top-level help check

if (-not $Command -or $Command -in '-h','--help','/?','help') { Show-Help; return }

$normalized = $Commands[$Command.ToLower()]

if (-not $normalized) {
    # Pass through to Scoop for unknown commands
    & scoop $Command @Rest
    return
}

if (Test-HelpFlag (Get-ParsedArgs $Rest)) { Show-Help -Ctx $normalized; return }

$execScript = "$PSScriptRoot/exec/$normalized.ps1"
if (-not (Test-Path $execScript)) { throw "Executor not found: $execScript" }

Write-Debug "[spx] → $normalized  args: $($Rest -join ' ')"
& $execScript @Rest