# lib/Core.ps1 - shared, non-exported primitives (PowerShell 5.1+)

. "$PSScriptRoot/Context.ps1"

function ConvertTo-SpxHashtable {
    param ([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $result[[string]$key] = ConvertTo-SpxHashtable $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-SpxHashtable $_ })
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
                return (ConvertFrom-Json -InputObject $Json -AsHashtable -Depth 30 -ErrorAction Stop)
            }
            ConvertTo-SpxHashtable (ConvertFrom-Json -InputObject $Json -ErrorAction Stop)
        }
        catch { throw [IO.InvalidDataException]::new(('Invalid JSON: ' + $_.Exception.Message), $_.Exception) }
    }
}

function Add-SpxTypeName {
    param ([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$TypeName)
    $InputObject.PSObject.TypeNames.Insert(0, $TypeName)
    $InputObject
}

function Stop-SpxError {
    param ([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Message, [object]$TargetObject)
    $exception = New-Object InvalidOperationException($Message)
    $record = New-Object Management.Automation.ErrorRecord($exception, $Id, [Management.Automation.ErrorCategory]::InvalidOperation, $TargetObject)
    throw $record
}

function Assert-SpxName {
    param ([Parameter(Mandatory)][string]$Name, [string]$Kind = 'name')
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in '.', '..' -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Name.Contains('/') -or $Name.Contains('\')) {
        throw [ArgumentException]::new("Invalid SPX $Kind '$Name'.")
    }
}

function Assert-SpxRelativePath {
    param ([Parameter(Mandatory)][string]$Path, [string]$Kind = 'relative path')
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { throw [ArgumentException]::new("Invalid SPX $Kind '$Path'.") }
    $root = 'C:\spx-contained-root'
    $combined = [IO.Path]::GetFullPath((Join-Path $root $Path.TrimEnd('/\')))
    if (-not(Test-SpxPathWithin $combined $root) -or $combined.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new("Invalid SPX $Kind '$Path'.")
    }
}

function Test-SpxPathWithin {
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SpxItemLinkTarget {
    param ([Parameter(Mandatory)]$Item)
    $item = $Item
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $target = @($item.Target)[0]
    if (-not $target) { return $null }
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $item.Parent.FullName $target }
    [IO.Path]::GetFullPath($target)
}

function Get-SpxLinkTarget {
    param ([Parameter(Mandatory)][string]$Path, [AllowNull()]$Item)
    $item = if ($null -ne $Item) { $Item } else { Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    if (-not $item) { return $null }
    Get-SpxItemLinkTarget $item
}

function New-SpxDirectoryJunction {
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $null = New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop
    $observed = Get-SpxLinkTarget $Path
    if (-not $observed -or -not $observed.Equals([IO.Path]::GetFullPath($Target), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Junction verification failed for '$Path'."
    }
}

function Remove-SpxOwnedTree {
    param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) }
        else { [IO.File]::Delete($item.FullName) }
        return
    }
    if (-not $item.PSIsContainer) {
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        [IO.File]::Delete($item.FullName)
        return
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { Remove-SpxOwnedTree $child.FullName }
    [IO.Directory]::Delete($item.FullName, $false)
}

function Get-SpxTreeEntries {
    param ([Parameter(Mandatory)][string]$Root, [string[]]$ExcludeRelative = @())
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
            $excluded = $false
            foreach ($prefix in $ExcludeRelative) {
                $p = $prefix.Trim('/\').Replace('\', '/')
                if ($relative -eq $p -or $relative.StartsWith($p + '/', [StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            $item
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($item.FullName) }
        }
    }
}

function Copy-SpxTree {
    param ([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [string[]]$ExcludeRelative = @())
    if (Test-Path -LiteralPath $Destination) { throw "Destination already exists: $Destination" }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $directories = New-Object Collections.ArrayList
    $links = New-Object Collections.ArrayList
    foreach ($item in Get-SpxTreeEntries -Root $sourceFull -ExcludeRelative $ExcludeRelative) {
        $relative = $item.FullName.Substring($sourceFull.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $sourceTarget = Get-SpxLinkTarget $item.FullName
            if (-not $sourceTarget -or -not (Test-SpxPathWithin $sourceTarget $sourceFull)) { throw "External or unreadable reparse point is not relocatable: $($item.FullName)" }
            $targetRelative = $sourceTarget.Substring($sourceFull.Length).TrimStart('\')
            $null = $links.Add([pscustomobject]@{Source = $item; Target = $target; TargetPath = (Join-Path $Destination $targetRelative) })
        }
        elseif ($item.PSIsContainer) { $null = New-Item -ItemType Directory -Path $target -Force; $null = $directories.Add([pscustomobject]@{Source = $item; Target = $target }) }
        else {
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
            [IO.File]::Copy($item.FullName, $target, $false)
            [IO.File]::SetCreationTimeUtc($target, $item.CreationTimeUtc)
            [IO.File]::SetLastAccessTimeUtc($target, $item.LastAccessTimeUtc)
            [IO.File]::SetLastWriteTimeUtc($target, $item.LastWriteTimeUtc)
            [IO.File]::SetAttributes($target, $item.Attributes)
        }
    }
    foreach ($link in $links) {
        $parent = Split-Path -Parent $link.Target
        if (-not(Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        if ($link.Source.LinkType -eq 'Junction') { New-SpxDirectoryJunction -Path $link.Target -Target $link.TargetPath }
        else { $null = New-Item -ItemType SymbolicLink -Path $link.Target -Target $link.TargetPath -ErrorAction Stop }
    }
    foreach ($directory in @($directories | Sort-Object { $_.Target.Length } -Descending)) {
        [IO.Directory]::SetCreationTimeUtc($directory.Target, $directory.Source.CreationTimeUtc)
        [IO.Directory]::SetLastAccessTimeUtc($directory.Target, $directory.Source.LastAccessTimeUtc)
        [IO.Directory]::SetLastWriteTimeUtc($directory.Target, $directory.Source.LastWriteTimeUtc)
        [IO.File]::SetAttributes($directory.Target, $directory.Source.Attributes)
    }
    $sourceRoot = Get-Item -LiteralPath $sourceFull -Force
    [IO.Directory]::SetCreationTimeUtc($Destination, $sourceRoot.CreationTimeUtc)
    [IO.Directory]::SetLastAccessTimeUtc($Destination, $sourceRoot.LastAccessTimeUtc)
    [IO.Directory]::SetLastWriteTimeUtc($Destination, $sourceRoot.LastWriteTimeUtc)
}

function Update-SpxMovedInternalLinks {
    param ([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$PreviousRoot)
    foreach ($item in @(Get-SpxTreeEntries -Root $Root | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        $oldTarget = Get-SpxLinkTarget $item.FullName
        if (Test-SpxPathWithin $oldTarget $Root) { continue }
        if (-not(Test-SpxPathWithin $oldTarget $PreviousRoot)) { throw "Moved reparse target is outside the admitted tree: $($item.FullName)" }
        $relative = $oldTarget.Substring([IO.Path]::GetFullPath($PreviousRoot).TrimEnd('\').Length).TrimStart('\')
        $newTarget = Join-Path $Root $relative
        $linkType = $item.LinkType; $linkPath = $item.FullName
        Remove-SpxOwnedTree $linkPath
        if ($linkType -eq 'Junction') { New-SpxDirectoryJunction -Path $linkPath -Target $newTarget }
        else { $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $newTarget -ErrorAction Stop }
    }
}

function Get-SpxTreeFingerprint {
    param ([Parameter(Mandatory)][string]$Root, [string[]]$ExcludeRelative = @())
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $rows = foreach ($item in Get-SpxTreeEntries -Root $rootFull -ExcludeRelative $ExcludeRelative) {
            $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $linkTarget = Get-SpxLinkTarget $item.FullName
                if (-not $linkTarget -or -not(Test-SpxPathWithin $linkTarget $rootFull)) { throw "External or unreadable reparse point cannot be fingerprinted: $($item.FullName)" }
                'L|' + $relative + '|' + $linkTarget.Substring($rootFull.Length).TrimStart('\').Replace('\', '/') + '|' + $item.LinkType
            }
            elseif ($item.PSIsContainer) { 'D|' + $relative }
            else {
                $fileHasher = [Security.Cryptography.SHA256]::Create()
                $fileStream = [IO.File]::OpenRead($item.FullName)
                try { $hash = [BitConverter]::ToString($fileHasher.ComputeHash($fileStream)).Replace('-', '') }
                finally { $fileStream.Dispose(); $fileHasher.Dispose() }
                'F|' + $relative + '|' + $item.Length + '|' + $hash
            }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes((@($rows | Sort-Object) -join "`n"))
        [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Get-SpxFileFingerprint {
    param ([Parameter(Mandatory)][string]$Path)
    $hasher = [Security.Cryptography.SHA256]::Create(); $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $hasher.Dispose() }
}

function Test-SpxContentEquivalent {
    param ([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) { return $false }
    $leftItem = Get-Item -LiteralPath $Left -Force; $rightItem = Get-Item -LiteralPath $Right -Force
    if ([bool]$leftItem.PSIsContainer -ne [bool]$rightItem.PSIsContainer) { return $false }
    if ($leftItem.PSIsContainer) { return (Get-SpxTreeFingerprint $Left) -eq (Get-SpxTreeFingerprint $Right) }
    (Get-SpxFileFingerprint $Left) -eq (Get-SpxFileFingerprint $Right)
}
