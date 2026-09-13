# Native PowerShell CLI admission and dispatch over the SPX module.

function Stop-SpxCliUsage {
    param (
        [Parameter(Mandatory)][string]$Message,
        [object]$TargetObject
    )

    $exception = New-Object System.ArgumentException $Message
    $record = New-Object System.Management.Automation.ErrorRecord $exception, 'Spx.CliUsage', ([System.Management.Automation.ErrorCategory]::InvalidArgument), $TargetObject
    throw $record
}

function New-SpxCliLeaf {
    param (
        [Parameter(Mandatory)][string]$Usage,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter(Mandatory)][string]$Function,
        [int]$Minimum = 0,
        [int]$Maximum = 0,
        [string]$IdentityParameter,
        [switch]$IdentityArray,
        [string[]]$Parameters = @(),
        [string[]]$RequiredParameters = @(),
        [string[]]$Scopes = @(),
        [string]$DefaultScope
    )

    [pscustomobject]@{
        Usage = $Usage
        Summary = $Summary
        Function = $Function
        Minimum = $Minimum
        Maximum = $Maximum
        IdentityParameter = $IdentityParameter
        IdentityArray = $IdentityArray.IsPresent
        Parameters = @($Parameters)
        RequiredParameters = @($RequiredParameters)
        Scopes = @($Scopes)
        DefaultScope = $DefaultScope
    }
}

function Get-SpxCliSpecification {
    [ordered]@{
        'link' = New-SpxCliLeaf 'spx link <Name>... -Destination <Path> [-Scope Local|Global] [-WhatIf] [-Confirm]' 'Relocate installed app versions to external storage.' 'Move-SpxApp' 1 ([int]::MaxValue) Name -IdentityArray -Parameters Destination, Scope, WhatIf, Confirm -RequiredParameters Destination -Scopes Local, Global -DefaultScope Local
        'unlink' = New-SpxCliLeaf 'spx unlink <Name>... [-Scope Local|Global] [-WhatIf] [-Confirm]' 'Restore relocated apps to their Scoop apps directory.' 'Restore-SpxApp' 1 ([int]::MaxValue) Name -IdentityArray -Parameters Scope, WhatIf, Confirm -Scopes Local, Global -DefaultScope Local
        'linked' = New-SpxCliLeaf 'spx linked [<Name>...] [-Scope Local|Global|All]' 'Inspect configured relocations and observed health.' 'Get-SpxLinkedApp' 0 ([int]::MaxValue) Name -IdentityArray -Parameters Scope -Scopes Local, Global, All -DefaultScope All
        'sync' = New-SpxCliLeaf 'spx sync [<Name>...] [-Scope Local|Global] [-WhatIf] [-Confirm]' 'Relocate newly installed versions for managed apps.' 'Sync-SpxLinkedApp' 0 ([int]::MaxValue) Name -IdentityArray -Parameters Scope, WhatIf, Confirm -Scopes Local, Global -DefaultScope Local
        'repair' = New-SpxCliLeaf 'spx repair [<Name>...] [-Scope Local|Global] [-WhatIf] [-Confirm]' 'Resolve interrupted relocation operations.' 'Repair-SpxLinkedApp' 0 ([int]::MaxValue) Name -IdentityArray -Parameters Scope, WhatIf, Confirm -Scopes Local, Global -DefaultScope Local
        'cleanup' = New-SpxCliLeaf 'spx cleanup <Name>... [-Scope Local|Global] [-WhatIf] [-Confirm]' 'Remove proven-stale relocation records.' 'Remove-SpxStaleLink' 1 ([int]::MaxValue) Name -IdentityArray -Parameters Scope, WhatIf, Confirm -Scopes Local, Global -DefaultScope Local
        'config/export' = New-SpxCliLeaf 'spx config export -Path <File> [-Force] [-WhatIf] [-Confirm]' 'Export the link configuration atomically.' 'Export-SpxLinkConfiguration' 0 0 -Parameters Path, Force, WhatIf, Confirm -RequiredParameters Path
        'config/import' = New-SpxCliLeaf 'spx config import -Path <File> [-Merge] [-WhatIf] [-Confirm]' 'Import or merge a validated link configuration.' 'Import-SpxLinkConfiguration' 0 0 -Parameters Path, Merge, WhatIf, Confirm -RequiredParameters Path
        'source/get' = New-SpxCliLeaf 'spx source get [<Name>...] [-Scope Local|Global|All]' 'Inspect installed app source metadata.' 'Get-SpxAppSource' 0 ([int]::MaxValue) Name -IdentityArray -Parameters Scope -Scopes Local, Global, All -DefaultScope All
        'source/set' = New-SpxCliLeaf 'spx source set <Name>... -Bucket <Bucket> [-Scope Local|Global] [-Force] [-WhatIf] [-Confirm]' 'Change installed app bucket metadata after admission.' 'Set-SpxAppSource' 1 ([int]::MaxValue) Name -IdentityArray -Parameters Bucket, Scope, Force, WhatIf, Confirm -RequiredParameters Bucket -Scopes Local, Global -DefaultScope Local
        'source/test' = New-SpxCliLeaf 'spx source test <Name>... [-Scope Local|Global]' 'Test installed version identity against its bucket manifest.' 'Test-SpxAppSource' 1 ([int]::MaxValue) Name -IdentityArray -Parameters Scope -Scopes Local, Global -DefaultScope Local
        'source/compare' = New-SpxCliLeaf 'spx source compare <Name> -Bucket <Bucket> [-Scope Local|Global]' 'Compare the installed and selected bucket manifests.' 'Compare-SpxAppSource' 1 1 Name -Parameters Bucket, Scope -RequiredParameters Bucket -Scopes Local, Global -DefaultScope Local
        'source/find' = New-SpxCliLeaf 'spx source find <Name>...' 'Find added buckets containing app manifests.' 'Find-SpxAppSource' 1 ([int]::MaxValue) Name -IdentityArray
        'mirror/get' = New-SpxCliLeaf 'spx mirror get [<Bucket>...]' 'Inspect bucket remotes, mirror state, and recovery.' 'Get-SpxBucketMirror' 0 ([int]::MaxValue) Bucket -IdentityArray
        'mirror/add' = New-SpxCliLeaf 'spx mirror add <Bucket> -Url <Url> [-WhatIf] [-Confirm]' 'Configure a new recoverable bucket mirror.' 'New-SpxBucketMirror' 1 1 Bucket -Parameters Url, WhatIf, Confirm -RequiredParameters Url
        'mirror/set' = New-SpxCliLeaf 'spx mirror set <Bucket> -Url <Url> [-WhatIf] [-Confirm]' 'Change a recoverable bucket mirror.' 'Set-SpxBucketMirror' 1 1 Bucket -Parameters Url, WhatIf, Confirm -RequiredParameters Url
        'mirror/remove' = New-SpxCliLeaf 'spx mirror remove <Bucket>... [-WhatIf] [-Confirm]' 'Restore original remotes and remove mirror state.' 'Remove-SpxBucketMirror' 1 ([int]::MaxValue) Bucket -IdentityArray -Parameters WhatIf, Confirm
        'mirror/repair' = New-SpxCliLeaf 'spx mirror repair <Bucket>... [-WhatIf] [-Confirm]' 'Resolve interrupted mirror operations.' 'Repair-SpxBucketMirror' 1 ([int]::MaxValue) Bucket -IdentityArray -Parameters WhatIf, Confirm
    }
}

function Resolve-SpxCliLeaf {
    param (
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @()
    )

    $specification = Get-SpxCliSpecification
    $commandKey = $Command.ToLowerInvariant()
    $operands = @($Arguments)
    $key = $commandKey

    if ($commandKey -in @('config', 'source', 'mirror')) {
        if ($operands.Count -eq 0) {
            Stop-SpxCliUsage "Command '$Command' requires an action." $Command
        }
        $key = $commandKey + '/' + $operands[0].ToLowerInvariant()
        $operands = @($operands | Select-Object -Skip 1)
    }

    if (-not $specification.Contains($key)) {
        Stop-SpxCliUsage "Unknown SPX command or action '$($key.Replace('/', ' '))'. Run 'spx -Help'." $key
    }

    [pscustomobject]@{
        Key = $key
        Leaf = $specification[$key]
        Operands = $operands
    }
}

function Get-SpxCliParameterHelp {
    param ([Parameter(Mandatory)][string]$Name)

    $help = @{
        Destination = 'Destination root for relocated app directories.'
        Scope = 'Scoop scope: Local, Global, or All where shown.'
        Path = 'Configuration file path.'
        Bucket = 'Scoop bucket identity.'
        Url = 'Git remote URL.'
        Force = 'Permit the documented command-specific override.'
        Merge = 'Merge imported entries instead of replacing configuration.'
        WhatIf = 'Preview the operation without changing filesystem, Git, or SPX state.'
        Confirm = 'Request confirmation; use -Confirm:$false to suppress native confirmation.'
    }
    $help[$Name]
}

function Get-SpxCliHelp {
    param (
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $specification = Get-SpxCliSpecification
    if (-not $Command) {
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add('SPX - recoverable Scoop extensions')
        $lines.Add('')
        $lines.Add('Usage: spx <command> [arguments] [parameters]')
        $lines.Add('')
        $lines.Add('Commands:')
        foreach ($item in $specification.GetEnumerator()) {
            $lines.Add(('  {0,-18} {1}' -f $item.Key.Replace('/', ' '), $item.Value.Summary))
        }
        $lines.Add('')
        $lines.Add("Run 'spx <command> -Help' or 'spx help <command>' for details.")
        return $lines -join [Environment]::NewLine
    }

    $resolved = Resolve-SpxCliLeaf -Command $Command -Arguments $Arguments
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($resolved.Leaf.Usage)
    $lines.Add('')
    $lines.Add($resolved.Leaf.Summary)
    if ($resolved.Leaf.Parameters.Count) {
        $lines.Add('')
        $lines.Add('Parameters:')
        foreach ($name in $resolved.Leaf.Parameters) {
            $lines.Add(('  -{0,-12} {1}' -f $name, (Get-SpxCliParameterHelp $name)))
        }
    }
    $lines -join [Environment]::NewLine
}

function Resolve-SpxCliInvocation {
    param (
        [Parameter(Mandatory)]$Resolved,
        [Parameter(Mandatory)][Collections.IDictionary]$BoundParameters
    )

    $leaf = $Resolved.Leaf
    $count = $Resolved.Operands.Count
    if ($count -lt $leaf.Minimum -or $count -gt $leaf.Maximum) {
        Stop-SpxCliUsage "Invalid operand count for '$($Resolved.Key.Replace('/', ' '))'. Usage: $($leaf.Usage)" $Resolved.Operands
    }

    $scriptParameters = @('Command', 'Arguments', 'Help', 'Version')
    $passThroughCommon = @(
        'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'ProgressAction'
    )
    foreach ($name in $BoundParameters.Keys) {
        if ($name -in $scriptParameters -or $name -in $passThroughCommon) {
            continue
        }
        if ($name -notin $leaf.Parameters) {
            Stop-SpxCliUsage "Parameter '-$name' is not valid for '$($Resolved.Key.Replace('/', ' '))'. Usage: $($leaf.Usage)" $name
        }
    }

    foreach ($name in $leaf.RequiredParameters) {
        if ($BoundParameters.Keys -notcontains $name) {
            Stop-SpxCliUsage "Parameter '-$name' is required for '$($Resolved.Key.Replace('/', ' '))'. Usage: $($leaf.Usage)" $name
        }
    }

    if ($BoundParameters.Keys -contains 'Scope' -and $leaf.Scopes.Count -and $BoundParameters['Scope'] -notin $leaf.Scopes) {
        Stop-SpxCliUsage "Scope '$($BoundParameters['Scope'])' is not valid for '$($Resolved.Key.Replace('/', ' '))'." $BoundParameters['Scope']
    }

    $parameters = @{}
    if ($leaf.IdentityParameter -and $count) {
        $parameters[$leaf.IdentityParameter] = if ($leaf.IdentityArray) {
            @($Resolved.Operands)
        }
        else {
            $Resolved.Operands[0]
        }
    }
    foreach ($name in @($leaf.Parameters + $passThroughCommon)) {
        if ($BoundParameters.Keys -contains $name) {
            $parameters[$name] = $BoundParameters[$name]
        }
    }
    if ($leaf.DefaultScope -and -not $parameters.ContainsKey('Scope')) {
        $parameters['Scope'] = $leaf.DefaultScope
    }

    [pscustomobject]@{
        Function = $leaf.Function
        Parameters = $parameters
    }
}

function Invoke-SpxCli {
    param (
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)]$Resolved,
        [Parameter(Mandatory)][Collections.IDictionary]$BoundParameters
    )

    $invocation = Resolve-SpxCliInvocation -Resolved $Resolved -BoundParameters $BoundParameters
    Import-Module (Join-Path $RepositoryRoot 'SPX.psd1') -Force -ErrorAction Stop
    $parameters = $invocation.Parameters
    & $invocation.Function @parameters
}
