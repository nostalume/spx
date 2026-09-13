# lib/Config.ps1 - locked, atomic SPX configuration and operation journals

. "$PSScriptRoot/Context.ps1"
. "$PSScriptRoot/Core.ps1"

function Assert-SpxOperationRecord {
    param([string]$Kind, [string]$Key, $Value)
    if ($Value -isnot [Collections.IDictionary] -or [string]$Value.kind -ne $Kind -or [string]::IsNullOrWhiteSpace([string]$Value.id)) { throw [IO.InvalidDataException]::new("Invalid SPX $Kind operation record '$Key'.") }
    if ($Kind -eq 'mirror') {
        Assert-SpxName ([string]$Value.bucket) 'operation bucket'
        if ([string]$Value.bucket -ne $Key) { throw [IO.InvalidDataException]::new("Mirror operation identity mismatch for '$Key'.") }
        if ([string]$Value.action -notin 'New', 'Set', 'Remove' -or [string]$Value.phase -notin 'Prepared', 'GitChanged') {
            throw [IO.InvalidDataException]::new("Invalid mirror operation transition for '$Key'.")
        }
        foreach ($field in 'oldUrl', 'originalUrl', 'requestedUrl') {
            $url = [string]$Value[$field]
            $hasControl = @($url.ToCharArray() | Where-Object { [int]$_ -lt 32 }).Count -gt 0
            if (-not $Value.Contains($field) -or [string]::IsNullOrWhiteSpace($url) -or $hasControl -or $url.StartsWith('-')) {
                throw [IO.InvalidDataException]::new("Invalid mirror operation URL '$field' for '$Key'.")
            }
        }
        return
    }
    if ($Kind -ne 'link') { throw [IO.InvalidDataException]::new("Unknown SPX operation kind '$Kind'.") }
    $name = [string]$Value.name; $scope = [string]$Value.scope
    Assert-SpxName $name 'operation app'
    if ($scope -notin 'Local', 'Global' -or ($scope.ToLowerInvariant() + '-' + $name) -ne $Key) { throw [IO.InvalidDataException]::new("Link operation identity mismatch for '$Key'.") }
    if ([string]$Value.action -notin 'Move', 'Restore') { throw [IO.InvalidDataException]::new("Invalid link operation action '$($Value.action)'.") }
    if (-not [IO.Path]::IsPathRooted([string]$Value.destination)) { throw [IO.InvalidDataException]::new('Link operation destination is not absolute.') }
    $ctx = Get-SpxContext
    $appsRoot = if ($scope -eq 'Global') { $ctx.GlobalApps }else { $ctx.LocalApps }
    $persistRoot = if ($scope -eq 'Global') { $ctx.GlobalPersist }else { $ctx.LocalPersist }
    $appPath = Join-Path $appsRoot $name; $targetApp = Join-Path ([string]$Value.destination) $name
    foreach ($record in @($Value.versions)) {
        if ($record -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new('Invalid link operation version record.') }
        Assert-SpxName ([string]$record.name) 'operation version'
        $canonical = Join-Path $appPath ([string]$record.name); $target = Join-Path $targetApp ([string]$record.name)
        $canonicalValue = if ($Value.action -eq 'Move') { $record.source }else { $record.canonical }
        $targetValue = if ($Value.action -eq 'Move') { $record.target }else { $record.source }
        $stageRoot = if ($Value.action -eq 'Move') { $targetApp }else { $appPath }
        $canonicalMatch = [IO.Path]::GetFullPath([string]$canonicalValue).Equals([IO.Path]::GetFullPath($canonical), [StringComparison]::OrdinalIgnoreCase)
        $targetMatch = [IO.Path]::GetFullPath([string]$targetValue).Equals([IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase)
        if (-not $canonicalMatch -or -not $targetMatch -or -not(Test-SpxPathWithin ([string]$record.stage) $stageRoot)) { throw [IO.InvalidDataException]::new("Unsafe recovery paths for '$name/$($record.name)'.") }
        if ($Value.action -eq 'Move' -and -not(Test-SpxPathWithin ([string]$record.backup) $appPath)) { throw [IO.InvalidDataException]::new("Unsafe backup path for '$name/$($record.name)'.") }
    }
    $persistPath = Join-Path $persistRoot $name
    foreach ($copy in @(@($Value.persistCreated) + @($Value.conflictCopies) | Where-Object { $_ })) {
        if ($copy -isnot [Collections.IDictionary] -or -not(Test-SpxPathWithin ([string]$copy.source) $appPath) -or -not(Test-SpxPathWithin ([string]$copy.target) $persistPath)) { throw [IO.InvalidDataException]::new("Unsafe persist recovery paths for '$name'.") }
    }
}

function Invoke-SpxFileLock {
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Script, [int]$TimeoutMilliseconds = 5000)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $stream = $null
    do {
        try { $stream = New-Object IO.FileStream(($Path + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
    } until ($stream -or [DateTime]::UtcNow -ge $deadline)
    if (-not $stream) { throw [TimeoutException]::new("Timed out acquiring SPX lock for '$Path'.") }
    try { & $Script } finally { $stream.Dispose() }
}

function Invoke-SpxOperationLock {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][Alias('Key')][string]$OperationKey, [Parameter(Mandatory)][scriptblock]$Script)
    Assert-SpxName $Kind 'lock kind'; Assert-SpxName $OperationKey 'lock key'
    $path = Join-Path (Get-SpxContext).ConfigRoot (Join-Path 'locks' ($Kind + '-' + $OperationKey))
    Invoke-SpxFileLock -Path $path -Script $Script
}

function Read-SpxJsonFile {
    param ([Parameter(Mandatory)][string]$Path, $Default = $null)
    if (-not [IO.File]::Exists($Path)) { return $Default }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw [IO.InvalidDataException]::new("SPX state is empty: $Path") }
    $raw | ConvertFrom-JsonAsHashtable
}

function Write-SpxJsonFileAtomic {
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [switch]$RetainPrevious)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = if ($RetainPrevious) { $Path + '.previous' } else { Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.bak.tmp') }
    $json = $Value | ConvertTo-Json -Depth 30
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    try {
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, $backup, $true) }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        if (-not $RetainPrevious -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Get-SpxConfig {
    [CmdletBinding()]
    param ([string]$Name = 'spx.json', [string]$Key)
    $data = Read-SpxJsonFile -Path (Get-SpxConfigFile -Name $Name) -Default ([ordered]@{})
    if ($data -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("SPX config '$Name' must contain a JSON object.") }
    if ($Key) { if ($data.Contains($Key)) { return $data[$Key] }; return $null }
    $data
}

function Set-SpxConfig {
    [CmdletBinding()]
    param ([string]$Name = 'spx.json', [Parameter(Mandatory)][string]$Key, $Value)
    $file = Get-SpxConfigFile -Name $Name -CreateIfMissing
    Invoke-SpxFileLock $file {
        $data = Read-SpxJsonFile -Path $file -Default ([ordered]@{})
        $data[$Key] = $Value
        Write-SpxJsonFileAtomic -Path $file -Value $data -RetainPrevious
    }
}

function Get-LinksConfig {
    $file = Get-SpxConfigFile -Name 'links.json'
    $data = Read-SpxJsonFile -Path $file -Default ([ordered]@{ schema = 1; generation = 0; local = [ordered]@{}; global = [ordered]@{} })
    if ($data -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new('Links config must contain a JSON object.') }
    foreach ($scope in 'local', 'global') {
        if (-not $data.Contains($scope) -or $data[$scope] -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("Invalid links config scope '$scope'.") }
        foreach ($name in $data[$scope].Keys) {
            Assert-SpxName ([string]$name) 'link app name'
            $entry = $data[$scope][$name]
            if ($entry -isnot [Collections.IDictionary] -or -not $entry.Contains('Path') -or
                [string]::IsNullOrWhiteSpace([string]$entry.Path) -or -not [IO.Path]::IsPathRooted([string]$entry.Path)) {
                throw [IO.InvalidDataException]::new("Invalid links config entry '$scope/$name'.")
            }
        }
    }
    $data
}

function Update-LinkEntry {
    param ([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('Local', 'Global')][string]$Scope, $Entry, [switch]$Remove)
    $file = Get-SpxConfigFile -Name 'links.json' -CreateIfMissing
    Invoke-SpxFileLock $file {
        $cfg = Get-LinksConfig
        $key = $Scope.ToLowerInvariant()
        if ($Remove) { $null = $cfg[$key].Remove($Name) } else { $cfg[$key][$Name] = $Entry }
        $cfg.generation = [int64]$cfg.generation + 1
        Write-SpxJsonFileAtomic -Path $file -Value $cfg -RetainPrevious
    }
}

function Write-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Value)
    Assert-SpxName $Kind 'operation kind'; Assert-SpxName $Key 'operation key'; Assert-SpxOperationRecord -Kind $Kind -Key $Key -Value $Value
    $ctx = Get-SpxContext
    $dir = Join-Path $ctx.Operations $Kind
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $path = Join-Path $dir ($Key + '.json')
    Invoke-SpxFileLock $path { Write-SpxJsonFileAtomic -Path $path -Value $Value -RetainPrevious }
    $path
}

function Read-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key)
    $path = Join-Path (Join-Path (Get-SpxContext).Operations $Kind) ($Key + '.json')
    $value = Read-SpxJsonFile -Path $path -Default $null
    if ($null -ne $value) { Assert-SpxOperationRecord -Kind $Kind -Key $Key -Value $value }
    $value
}

function Remove-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key)
    $path = Join-Path (Join-Path (Get-SpxContext).Operations $Kind) ($Key + '.json')
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    if (Test-Path -LiteralPath ($path + '.previous')) { Remove-Item -LiteralPath ($path + '.previous') -Force }
}

function Export-LinksConfig { param([string]$Path); Write-SpxJsonFileAtomic -Path ([IO.Path]::GetFullPath($Path)) -Value (Get-LinksConfig) }
function Import-LinksConfig {
    param([string]$Path, [switch]$Merge)
    $imported = Read-SpxJsonFile -Path ([IO.Path]::GetFullPath($Path))
    foreach ($scope in 'local', 'global') { if (-not $imported.Contains($scope)) { throw "Imported links config lacks '$scope'." } }
    foreach ($scope in 'local', 'global') {
        if ($imported[$scope] -isnot [Collections.IDictionary]) { throw "Imported links config scope '$scope' is invalid." }
        foreach ($name in $imported[$scope].Keys) {
            Assert-SpxName ([string]$name) 'link app name'
            $entry = $imported[$scope][$name]
            if ($entry -isnot [Collections.IDictionary] -or -not $entry.Contains('Path') -or -not [IO.Path]::IsPathRooted([string]$entry.Path)) { throw "Imported link entry '$scope/$name' is invalid." }
            $entry['State'] = 'Imported'
            $entry['Updated'] = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    $file = Get-SpxConfigFile -Name 'links.json' -CreateIfMissing
    Invoke-SpxFileLock $file {
        $current = Get-LinksConfig
        $next = if ($Merge) {
            foreach ($scope in 'local', 'global') {
                foreach ($key in $imported[$scope].Keys) { $current[$scope][$key] = $imported[$scope][$key] }
            }
            $current
        }
        else { $imported }
        $next['schema'] = 1
        $next['generation'] = [int64]$current.generation + 1
        Write-SpxJsonFileAtomic -Path $file -Value $next -RetainPrevious
    }
}
