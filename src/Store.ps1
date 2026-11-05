# JSON records, writer scope and atomic persistence.

function ConvertTo-SpxHashtable {
    param ([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject.GetType().FullName -eq 'Newtonsoft.Json.Linq.JValue') { return $InputObject.Value }
    if ($InputObject.GetType().FullName -eq 'Newtonsoft.Json.Linq.JObject') {
        $result = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($property in $InputObject.Properties()) { $result[$property.Name] = ConvertTo-SpxHashtable $property.Value }
        return $result
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $result[[string]$key] = ConvertTo-SpxHashtable $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = New-Object Collections.ArrayList
        foreach ($item in $InputObject) { $null = $items.Add((ConvertTo-SpxHashtable $item)) }
        return , $items.ToArray()
    }
    if ($InputObject -is [Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-SpxHashtable $property.Value }
        return $result
    }
    $InputObject
}

function ConvertFrom-JsonAsHashtable {
    [CmdletBinding()]
    param ([Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string]$Json)
    process {
        if ([string]::IsNullOrWhiteSpace($Json)) { throw [IO.InvalidDataException]::new('JSON content is empty.') }
        try {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                # JSON dates are strings. Preserve their spelling when changing an unrelated field.
                $inputReader = New-Object IO.StringReader($Json)
                $jsonReader = New-Object Newtonsoft.Json.JsonTextReader($inputReader)
                $jsonReader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
                $jsonReader.MaxDepth = 30
                try {
                    $value = [Newtonsoft.Json.Linq.JToken]::ReadFrom($jsonReader)
                    while ($jsonReader.Read()) { if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::Comment) { throw 'Unexpected content after JSON value.' } }
                    return (ConvertTo-SpxHashtable $value)
                }
                finally { $jsonReader.Close(); $inputReader.Dispose() }
            }
            ConvertTo-SpxHashtable (ConvertFrom-Json -InputObject $Json -ErrorAction Stop)
        }
        catch { throw [IO.InvalidDataException]::new(('Invalid JSON: ' + $_.Exception.Message), $_.Exception) }
    }
}

function Get-SpxConfigFile {
    param ([string]$Name = 'spx.json')
    $root = (Get-SpxContext).ConfigRoot
    Join-Path $root $Name
}




function Assert-SpxOperationRecord {
    param([string]$Kind, [string]$Key, $Value)
    if ($Value -isnot [Collections.IDictionary] -or [string]$Value.kind -ne $Kind -or [string]::IsNullOrWhiteSpace([string]$Value.id)) { throw [IO.InvalidDataException]::new("Invalid SPX $Kind operation record '$Key'.") }
    if ($Kind -eq 'mirror') {
        if ([string]$Value.schema -notin '1', '2') { throw [IO.InvalidDataException]::new('Unsupported mirror journal schema.') }
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

        if ([string]$Value.schema -eq '2') {
            if (-not $Value.Contains('before') -or $Value.repository -isnot [Collections.IDictionary] -or -not(Test-SpxAbsolutePath $Value.repository.Path) -or -not(Test-SpxAbsolutePath $Value.repository.GitDirectory) -or [string]$Value.repository.CreatedTicks -notmatch '^\d+$') { throw [IO.InvalidDataException]::new('Invalid bucket repository evidence.') }
            $expected = Join-Path (Get-SpxContext).Buckets ([string]$Value.bucket)
            if ([IO.Path]::GetFullPath([string]$Value.repository.Path) -ne [IO.Path]::GetFullPath($expected)) { throw [IO.InvalidDataException]::new('Bucket repository path mismatch.') }
            if ($Value.before) { Assert-SpxGitUrl ([string]$Value.before.original); Assert-SpxGitUrl ([string]$Value.before.mirror) }
        }
        return
    }
    if ($Kind -ne 'link') { throw [IO.InvalidDataException]::new("Unknown SPX operation kind '$Kind'.") }

    if ([string]$Value.schema -notin '1', '2') { throw [IO.InvalidDataException]::new('Unsupported link journal schema.') }
    $name = [string]$Value.name; $scope = [string]$Value.scope
    Assert-SpxName $name 'operation app'; Assert-SpxName ([string]$Value.id) 'operation id'
    if ($scope -notin 'Local', 'Global' -or ($scope.ToLowerInvariant() + '-' + $name) -ne $Key) { throw [IO.InvalidDataException]::new('Link operation identity mismatch.') }
    if ($Value.action -eq 'Reclaim') { Assert-SpxReclaimOperation $Value; return }
    if ($Value.action -notin 'Move', 'Restore' -or $Value.phase -notin 'Prepared', 'Linked', 'Restored', 'Committed') { throw [IO.InvalidDataException]::new('Invalid link operation transition.') }
    if (-not (Test-SpxAbsolutePath $Value.destination)) { throw [IO.InvalidDataException]::new('Link destination is not absolute.') }
    $ctx = Get-SpxContext
    $appPath = Join-Path $(if ($scope -eq 'Global') { $ctx.GlobalApps } else { $ctx.LocalApps }) $name
    $targetApp = Join-Path ([string]$Value.destination) $name
    $seen = @{}
    foreach ($record in @($Value.versions)) {
        Assert-SpxName ([string]$record.name) 'operation version'
        if ($seen.ContainsKey([string]$record.name) -or -not $record.fingerprint) { throw [IO.InvalidDataException]::new('Missing fingerprint or repeated version.') }
        $seen[[string]$record.name] = $true
        $canonical = Join-Path $appPath ([string]$record.name); $target = Join-Path $targetApp ([string]$record.name)
        if ([string]$Value.schema -eq '1') {
            $actualCanonical = if ($Value.action -eq 'Move') { $record.source } else { $record.canonical }
            $actualTarget = if ($Value.action -eq 'Move') { $record.target } else { $record.source }
        }
        else { $actualCanonical = $record.canonical; $actualTarget = $record.target }
        if ([IO.Path]::GetFullPath([string]$actualCanonical) -ne [IO.Path]::GetFullPath($canonical) -or [IO.Path]::GetFullPath([string]$actualTarget) -ne [IO.Path]::GetFullPath($target)) { throw [IO.InvalidDataException]::new('Unsafe recovery identity.') }
        $stageRoot = if ($Value.action -eq 'Move') { $targetApp } else { $appPath }
        foreach ($field in @('stage') + @(if ($Value.action -eq 'Move' -or [string]$Value.schema -eq '2') { 'backup' })) {
            $owner = if ($field -eq 'backup') { $appPath } else { $stageRoot }
            $path = [IO.Path]::GetFullPath([string]$record[$field])
            $prefix = if ($field -eq 'backup') { '.spx-backup-' } elseif ($Value.action -eq 'Move') { '.spx-staging-' } else { '.spx-restore-' }
            if ([IO.Path]::GetDirectoryName($path) -ne [IO.Path]::GetFullPath($owner) -or -not [IO.Path]::GetFileName($path).StartsWith('.spx-', [StringComparison]::OrdinalIgnoreCase)) { throw [IO.InvalidDataException]::new('Unsafe recovery private path.') }
            if ([string]$Value.schema -eq '2' -and [IO.Path]::GetFileName($path) -ne ($prefix + $Value.id + '-' + $record.name)) { throw [IO.InvalidDataException]::new('Recovery path does not match operation id.') }
        }
        foreach ($relative in @($record.exclude | Where-Object { $_ })) { Assert-SpxRelativePath $relative 'journal persist path' }
    }
    if (-not $seen.Count) { throw [IO.InvalidDataException]::new('An operation must name at least one version.') }
    foreach ($relative in @($Value.exclude | Where-Object { $_ })) { Assert-SpxRelativePath $relative 'journal persist path' }
    if ([string]$Value.schema -eq '2') {
        foreach ($field in 'beforeActive', 'beforeIntent', 'entry') {
            if (-not $Value.Contains($field)) { throw [IO.InvalidDataException]::new("Missing journal field '$field'.") }
            $entry = $Value[$field]
            if ($null -ne $entry -and ($entry -isnot [Collections.IDictionary] -or -not(Test-SpxAbsolutePath ([string]$entry.Path)))) { throw [IO.InvalidDataException]::new('Invalid operation ownership.') }
        }
        if ($Value.entry.OperationId -ne $Value.id -or [IO.Path]::GetFullPath([string]$Value.entry.Path) -ne [IO.Path]::GetFullPath([string]$Value.destination)) { throw [IO.InvalidDataException]::new('Operation receipt identity mismatch.') }
    }
    $persistPath = Join-Path $(if ($scope -eq 'Global') { $ctx.GlobalPersist } else { $ctx.LocalPersist }) $name
    foreach ($copy in @(@($Value.persistCreated) + @($Value.conflictCopies) | Where-Object { $_ })) {
        if ($copy -isnot [Collections.IDictionary] -or -not(Test-SpxPathWithin ([string]$copy.source) $appPath) -or -not(Test-SpxPathWithin ([string]$copy.target) $persistPath)) { throw [IO.InvalidDataException]::new('Unsafe persist recovery paths.') }
    }
}


function Invoke-SpxMutation {
    param ([Parameter(Mandatory)][scriptblock]$MutationBody)
    $writerPath = Join-Path (Get-SpxContext).ConfigRoot 'writer'
    if ($script:SpxWriter) {
        if ($script:SpxWriter -ne $writerPath) { throw 'Cannot change SPX roots inside a mutation.' }
        & $MutationBody
        return
    }
    $writerParent = Split-Path $writerPath -Parent
    if (-not (Test-Path -LiteralPath $writerParent)) { $null = New-Item -ItemType Directory -Path $writerParent -Force }
    $writerDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $writerStream = $null
    do {
        try { $writerStream = New-Object IO.FileStream(($writerPath + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
    } until ($writerStream -or [DateTime]::UtcNow -ge $writerDeadline)
    if (-not $writerStream) { throw [TimeoutException]::new("Timed out acquiring SPX writer for '$writerPath'.") }
    $script:SpxWriter = $writerPath
    try { & $MutationBody } finally { $script:SpxWriter = $null; $writerStream.Dispose() }
}

function Read-SpxJsonFile {
    param ([Parameter(Mandatory)][string]$Path, $Default = $null)
    if (-not [IO.File]::Exists($Path)) { return $Default }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw [IO.InvalidDataException]::new("SPX state is empty: $Path") }
    if (-not $raw.TrimStart().StartsWith('{')) { throw [IO.InvalidDataException]::new("SPX JSON must contain an object: $Path") }
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
    param ([string]$Name = 'spx.json')
    $data = Read-SpxJsonFile -Path (Get-SpxConfigFile -Name $Name) -Default ([ordered]@{})
    if ($data -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("SPX config '$Name' must contain a JSON object.") }
    $data
}

function ConvertTo-SpxNameMap {
    param ([Collections.IDictionary]$Value)
    $names = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Value.Keys) {
        Assert-SpxName ([string]$key) 'state identity'
        if ($names.Contains([string]$key)) { throw [IO.InvalidDataException]::new("Repeated case-insensitive identity '$key'.") }
        $names[[string]$key] = $Value[$key]
    }
    $names
}

function Get-SpxOperationKeys {
    param ([ValidateSet('link', 'mirror')][string]$Kind)
    $directory = Join-Path (Get-SpxContext).Operations $Kind
    if (Test-Path -LiteralPath $directory) { Get-ChildItem -LiteralPath $directory -File -Filter '*.json' | Select-Object -ExpandProperty BaseName }
}

function Get-LinksConfig {
    $data = Read-SpxJsonFile (Get-SpxConfigFile 'links.json') ([ordered]@{ schema = 2; generation = 0; local = [ordered]@{}; global = [ordered]@{} })
    if ($data -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new('Links config must contain an object.') }
    $schema = if ($data.Contains('schema')) { [string]$data.schema } else { '1' }
    if ($schema -notin '1', '2') { throw [IO.InvalidDataException]::new("Unsupported links schema '$schema'.") }
    if ($data.Contains('generation') -and ([string]$data.generation -notmatch '^\d+$')) { throw [IO.InvalidDataException]::new('Invalid links generation.') }
    foreach ($scope in 'local', 'global') {
        if ($data[$scope] -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("Invalid links scope '$scope'.") }
        $data[$scope] = ConvertTo-SpxNameMap $data[$scope]
        foreach ($name in @($data[$scope].Keys)) {
            Assert-SpxName ([string]$name) 'app name'
            $record = $data[$scope][$name]
            if ($record -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("Invalid link '$scope/$name'.") }
            if ($schema -eq '1') {
                $record = [ordered]@{ Active = $(if ($record.State -ne 'Imported') { $record }); Intent = $(if ($record.State -eq 'Imported') { $record }); Retained = @(); LastOperation = $null }
                $data[$scope][$name] = $record
            }
            foreach ($field in 'Active', 'Intent') {
                $entry = $record[$field]
                if ($null -ne $entry -and ($entry -isnot [Collections.IDictionary] -or -not $entry.Path -or -not (Test-SpxAbsolutePath $entry.Path))) {
                    throw [IO.InvalidDataException]::new("Invalid $field for '$scope/$name'.")
                }
            }
            if (-not $record.Contains('Active') -or -not $record.Contains('Intent') -or $record.Retained -isnot [Collections.IList]) { throw [IO.InvalidDataException]::new("Incomplete link record '$scope/$name'.") }
            $copyIds = @{}
            foreach ($copy in $record.Retained) {
                if ($copy -isnot [Collections.IDictionary] -or -not $copy.Id -or -not $copy.Path -or -not (Test-SpxAbsolutePath $copy.Path)) { throw [IO.InvalidDataException]::new("Invalid retained copy for '$name'.") }
                if ($copyIds.ContainsKey([string]$copy.Id)) { throw [IO.InvalidDataException]::new("Repeated retained identity for '$name'.") }
                $copyIds[[string]$copy.Id] = $true
            }
            if ($record.LastOperation -and ($record.LastOperation -isnot [Collections.IDictionary] -or -not $record.LastOperation.Id -or $record.LastOperation.Outcome -notin 'Committed', 'RolledBack')) { throw [IO.InvalidDataException]::new("Invalid receipt for '$name'.") }
        }
    }
    $data['schema'] = 2
    if (-not $data.Contains('generation')) { $data['generation'] = 0 }
    $data
}

function Get-SpxLinkRecord {
    param ([string]$Name, [string]$Scope, $Config)
    $cfg = if ($null -ne $Config) { $Config } else { Get-LinksConfig }
    if ($cfg[$Scope.ToLowerInvariant()].Contains($Name)) { return $cfg[$Scope.ToLowerInvariant()][$Name] }
    [ordered]@{ Active = $null; Intent = $null; Retained = @(); LastOperation = $null }
}

function Update-LinkEntry {
    param ([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet('Local', 'Global')][string]$Scope,
        $Entry, [switch]$Remove, [object[]]$Retained = @(), $Intent = $null, [string]$OperationId, [string]$Action, [string]$Outcome, [string[]]$RemoveRetained = @())
    Invoke-SpxMutation {
        $cfg = Get-LinksConfig
        $key = $Scope.ToLowerInvariant()
        $record = Get-SpxLinkRecord $Name $Scope $cfg
        $before = $record | ConvertTo-Json -Depth 30 -Compress
        $record.Active = if ($Remove) { $null } else { $Entry }
        $record.Intent = $Intent
        $copies = [ordered]@{}
        foreach ($copy in @($record.Retained) + @($Retained)) { if ($copy -and $copy.Id -notin $RemoveRetained) { $copies[[string]$copy.Id] = $copy } }
        $record.Retained = @($copies.Values)
        if ($OperationId) { $record.LastOperation = [ordered]@{ Id = $OperationId; Action = $Action; Outcome = $Outcome } }
        if ($before -ceq ($record | ConvertTo-Json -Depth 30 -Compress)) { return }
        if (-not $record.Active -and -not $record.Intent -and -not $record.Retained.Count -and -not $record.LastOperation) { $null = $cfg[$key].Remove($Name) }
        else { $cfg[$key][$Name] = $record }
        $cfg.generation = [int64]$cfg.generation + 1
        Write-SpxJsonFileAtomic (Get-SpxConfigFile 'links.json') $cfg -RetainPrevious
    }
}

function Write-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Value)
    Assert-SpxName $Kind 'operation kind'; Assert-SpxName $Key 'operation key'; Assert-SpxOperationRecord -Kind $Kind -Key $Key -Value $Value
    $ctx = Get-SpxContext
    $dir = Join-Path $ctx.Operations $Kind
    $path = Join-Path $dir ($Key + '.json')
    Invoke-SpxMutation { Write-SpxJsonFileAtomic -Path $path -Value $Value -RetainPrevious }
    $path
}

function Read-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key)
    Assert-SpxName $Kind 'operation kind'; Assert-SpxName $Key 'operation key'
    $path = Join-Path (Join-Path (Get-SpxContext).Operations $Kind) ($Key + '.json')
    $value = Read-SpxJsonFile -Path $path -Default $null
    if ($null -ne $value) { Assert-SpxOperationRecord -Kind $Kind -Key $Key -Value $value }
    $value
}

function Remove-SpxOperation {
    param ([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Key)
    Assert-SpxName $Kind 'operation kind'; Assert-SpxName $Key 'operation key'
    Invoke-SpxMutation {
        $path = Join-Path (Join-Path (Get-SpxContext).Operations $Kind) ($Key + '.json')
        foreach ($candidate in @($path, ($path + '.previous'))) { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force -ErrorAction Stop } }
    }
}
