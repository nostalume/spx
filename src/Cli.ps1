# Command modes, admission, help and user-facing projections; effects stay in the module API.

function Stop-SpxCliUsage {
    param ([string]$Message, $TargetObject)
    throw [Management.Automation.ErrorRecord]::new([ArgumentException]::new($Message), 'Spx.CliUsage', [Management.Automation.ErrorCategory]::InvalidArgument, $TargetObject)
}

function Get-SpxCliSpecification {
    # Each row: command, API, allowed/required parameters, min/max names (-1 = unlimited), scope, summary, example.
    $rows = [ordered]@{
        link = @('link', 'Move-SpxApp', 'Destination Scope WhatIf Confirm', 'Destination', 1, -1, 'Local', 'Relocate an installed app; retain the old copy.', "spx link jq -Destination 'D:\Apps' -WhatIf")
        unlink = @('unlink', 'Restore-SpxApp', 'Scope WhatIf Confirm', '', 1, -1, 'Local', 'Restore an app into Scoop; retain the external copy.', 'spx unlink jq -WhatIf')
        linked = @('linked', 'Get-SpxStatus', 'Scope', '', 0, -1, 'All', 'Inspect managed apps, retained copies and recovery.', 'spx linked')
        sync = @('sync', 'Sync-SpxLinkedApp', 'Scope WhatIf Confirm', '', 0, -1, 'Local', 'Relocate newly installed versions of managed apps.', 'spx sync jq -WhatIf')
        repair = @('repair', 'Repair-SpxLinkedApp', 'Scope WhatIf Confirm', '', 0, -1, 'Local', 'Recover selected or pending app operations.', 'spx repair jq -WhatIf')
        'repair.bucket' = @('repair', 'Repair-SpxBucketMirror', 'Bucket WhatIf Confirm', 'Bucket', 0, 0, '', 'Recover a bucket source operation.', 'spx repair -Bucket main -WhatIf')
        'repair.buckets' = @('repair', 'Repair-SpxBucketMirror', 'Buckets WhatIf Confirm', 'Buckets', 0, 0, '', 'Recover all pending bucket source operations.', 'spx repair -Buckets -WhatIf')
        cleanup = @('cleanup', 'Remove-SpxRetainedCopy', 'Scope WhatIf Confirm', '', 1, -1, 'Local', 'Reclaim verified inactive copies and clear stale ownership.', 'spx cleanup jq -WhatIf')
        source = @('source', 'Get-SpxStatus', 'Scope', '', 0, -1, 'All', 'Inspect app -> recorded bucket -> observed origin.', 'spx source jq')
        'source.set' = @('source', 'Set-SpxAppSource', 'Bucket Scope Force WhatIf Confirm', 'Bucket', 1, -1, 'Local', 'Change only an app installation''s recorded bucket.', 'spx source jq -Bucket extras -WhatIf')
        'source.buckets' = @('source', 'Get-SpxStatus', 'Buckets', 'Buckets', 0, 0, '', 'Inspect all added or recorded bucket sources.', 'spx source -Buckets')
        'source.bucket' = @('source', 'Get-SpxStatus', 'Bucket', 'Bucket', 0, 0, '', 'Inspect one bucket source.', 'spx source -Bucket main')
        'source.url' = @('source', 'Set-SpxBucketMirror', 'Bucket Url WhatIf Confirm', 'Bucket Url', 0, 0, '', 'Set a bucket origin, preserving the original URL.', 'spx source -Bucket main -Url https://mirror.example/main.git -WhatIf')
        'source.reset' = @('source', 'Remove-SpxBucketMirror', 'Bucket Reset WhatIf Confirm', 'Bucket Reset', 0, 0, '', 'Restore the saved original bucket origin.', 'spx source -Bucket main -Reset -WhatIf')
        'source.find' = @('source', 'Find-SpxAppSource', 'Find', 'Find', 1, -1, '', 'Find candidates in already added buckets.', 'spx source jq -Find')
        'source.compare' = @('source', 'Compare-SpxAppSource', 'Compare Scope', 'Compare', 1, 1, 'Local', 'Compare installed and bucket manifests.', 'spx source jq -Compare extras')
        'source.check' = @('source', 'Test-SpxAppSource', 'CheckVersion Scope', 'CheckVersion', 1, -1, 'Local', 'Check installed version identity against its recorded bucket.', 'spx source jq -CheckVersion')
    }
    $spec = [ordered]@{}
    foreach ($key in $rows.Keys) {
        $r = $rows[$key]
        $spec[$key] = [pscustomobject]@{ Command = $r[0]; Function = $r[1]; Parameters = @($r[2] -split ' ' | Where-Object { $_ }); Required = @($r[3] -split ' ' | Where-Object { $_ }); Minimum = $r[4]; Maximum = $r[5]; Scope = $r[6]; Summary = $r[7]; Example = $r[8] }
    }
    $spec
}

function Resolve-SpxCliInvocation {
    param ([string]$Command, [string[]]$Names, [Collections.IDictionary]$BoundParameters, [switch]$ForHelp)
    $commandKey = $Command.ToLowerInvariant(); $key = $commandKey
    if ($commandKey -in 'mirror', 'config' -or ($commandKey -eq 'source' -and $Names.Count -gt 1 -and $Names[0] -in 'get', 'set', 'test', 'find', 'compare')) {
        Stop-SpxCliUsage "The old syntax has been removed. Use 'spx source <Name>', 'spx source <Name> -Bucket <Bucket>', or 'spx source -Bucket <Bucket> -Url <Url>'. Import/export remain module APIs. Run 'spx source -Help'." $Command
    }
    if ($commandKey -eq 'source') {
        if (($BoundParameters.Keys -contains 'Buckets')) { $key = 'source.buckets' }
        elseif (($BoundParameters.Keys -contains 'Find')) { $key = 'source.find' }
        elseif (($BoundParameters.Keys -contains 'Compare')) { $key = 'source.compare' }
        elseif (($BoundParameters.Keys -contains 'CheckVersion')) { $key = 'source.check' }
        elseif (($BoundParameters.Keys -contains 'Reset')) { $key = 'source.reset' }
        elseif (($BoundParameters.Keys -contains 'Url')) { $key = 'source.url' }
        elseif (($BoundParameters.Keys -contains 'Bucket')) { $key = if ($Names.Count) { 'source.set' } else { 'source.bucket' } }
    }
    elseif ($commandKey -eq 'repair') {
        if (($BoundParameters.Keys -contains 'Buckets')) { $key = 'repair.buckets' }
        elseif (($BoundParameters.Keys -contains 'Bucket')) { $key = 'repair.bucket' }
    }
    $spec = Get-SpxCliSpecification
    if (-not $spec.Contains($key)) { Stop-SpxCliUsage "Unknown command '$Command'. Run 'spx -Help'." $Command }
    $mode = $spec[$key]
    if (@($Names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { Stop-SpxCliUsage 'App targets cannot be empty.' $Names }
    $common = @([Management.Automation.Cmdlet]::CommonParameters)
    foreach ($name in $BoundParameters.Keys) {
        if ($name -in @('Command', 'Arguments', 'Help') + $common) { continue }
        if ($name -notin $mode.Parameters) { Stop-SpxCliUsage "Parameter '-$name' is not valid in this mode. Example: $($mode.Example)" $name }
        if ($BoundParameters[$name] -is [Management.Automation.SwitchParameter] -and -not $BoundParameters[$name] -and $name -notin 'WhatIf', 'Confirm', 'Force') { Stop-SpxCliUsage "Omit '-$name' instead of selecting it with false." $name }
        if ($BoundParameters[$name] -is [string] -and [string]::IsNullOrWhiteSpace($BoundParameters[$name])) { Stop-SpxCliUsage "Parameter '-$name' cannot be empty." $name }
    }
    if ((-not $ForHelp -and $Names.Count -lt $mode.Minimum) -or ($mode.Maximum -ge 0 -and $Names.Count -gt $mode.Maximum)) { Stop-SpxCliUsage "Invalid app targets. Example: $($mode.Example)" $Names }
    foreach ($required in $(if (-not $ForHelp) { $mode.Required })) { if (-not ($BoundParameters.Keys -contains $required)) { Stop-SpxCliUsage "Missing '-$required'. Example: $($mode.Example)" $required } }
    if (($BoundParameters.Keys -contains 'Scope') -and $BoundParameters.Scope -eq 'All' -and $mode.Scope -ne 'All') { Stop-SpxCliUsage "This mode requires Local or Global scope. Example: $($mode.Example)" 'All' }
    $parameters = @{}
    foreach ($name in $mode.Parameters + $common) { if (($BoundParameters.Keys -contains $name) -and $name -notin 'Find', 'Compare', 'CheckVersion', 'Reset') { $parameters[$name] = $BoundParameters[$name] } }
    if ($mode.Scope -and -not $parameters.ContainsKey('Scope')) { $parameters.Scope = $mode.Scope }
    if ($Names.Count) { $parameters.Name = if ($key -eq 'source.compare') { $Names[0] } else { @($Names) } }
    if ($key -eq 'source.compare') { $parameters.Bucket = $BoundParameters.Compare }
    [pscustomobject]@{ Key = $key; Mode = $mode; Parameters = $parameters; Names = @($Names) }
}

function Get-SpxCliHelp {
    param ([string]$Command, [string]$ModeKey)
    $spec = Get-SpxCliSpecification
    if (-not $Command) {
        return @'
SPX - relocate Scoop apps and inspect their sources
Usage: spx <command> [<Name>...] [parameters]

Placement:  spx link jq -Destination 'D:\Apps' -WhatIf
            spx unlink jq       spx linked       spx sync jq
Sources:    spx source jq
            spx source jq -Bucket extras
            spx source -Bucket main -Url https://mirror.example/main.git
Recovery:   spx repair jq       spx repair -Bucket main
Reclaim:    spx cleanup jq -WhatIf

Run 'spx source -Help' or 'spx repair -Help' for modes, defaults and examples.
Import-Module SPX registers context completion for this session only.
'@
    }
    $modes = @(if ($ModeKey) { $spec[$ModeKey] } else { $spec.Values | Where-Object Command -EQ $Command })
    if (-not $modes.Count) { Stop-SpxCliUsage "Unknown command '$Command'. Run 'spx -Help'." $Command }
    $lines = @("spx $Command", '')
    foreach ($mode in $modes) {
        $lines += $mode.Summary
        $lines += '  ' + $mode.Example
        $lines += '  Parameters: ' + (@($mode.Parameters | ForEach-Object { '-' + $_ }) -join ', ') + $(if ($mode.Scope) { '; Scope: ' + $(if ($mode.Scope -eq 'All') { 'Local|Global|All' } else { 'Local|Global' }) + '; default ' + $mode.Scope } else { '' })
    }
    if ($Command -eq 'source' -and -not $ModeKey) { $lines += 'Reads reject WhatIf/Confirm. URL and Reset require an explicit bucket target and cannot modify an app source. App writes require a matching version; Force permits only version mismatch. Find searches added buckets without Scope. Compare checks selected manifest fields; CheckVersion does not establish source trust.' }
    if ($Command -eq 'cleanup') { $lines += 'Stop external writers during reclamation. Changed, unique or unowned copies remain blocked. Inspect BlockedCopies; there is no Force bypass.' }
    $lines += 'Batch mutations stop at the first terminating error; already committed targets remain committed.'
    $lines -join [Environment]::NewLine
}

function ConvertTo-SpxCliView {
    param ([Parameter(ValueFromPipeline)]$Value, [switch]$SourceView)
    process {
        if ($null -eq $Value) { return }
        if ($Value -isnot [psobject] -or $Value -is [bool]) { return $Value }
        $target = if ($Value.Name) { $Value.Name } else { $Value.Bucket }
        $location = if ($Value.Location) { $Value.Location } elseif ($SourceView -and $Value.Source) { $Value.Source.Bucket + ' -> ' + $Value.Source.CurrentUrl } elseif ($SourceView -and $Value.Bucket) { $Value.Bucket } elseif ($Value.ActivePath) { $Value.ActivePath } elseif ($Value.CurrentUrl) { $Value.CurrentUrl } elseif ($Value.NewBucket) { $Value.NewBucket } else { $Value.Destination }
        $next = if ($Value.NextActions) { $Value.NextActions -join ', ' } elseif ($Value.BlockedCopies.Count) { 'Inspect BlockedCopies' } else { '' }
        $Value | Add-Member NoteProperty Target $target -Force
        $Value | Add-Member NoteProperty Location $location -Force
        $Value | Add-Member NoteProperty Retained @($Value.RetainedCopies | Where-Object { $_ }).Count -Force
        $Value | Add-Member NoteProperty Next $next -Force
        if (-not $Value.PSObject.Properties['Status']) { $Value | Add-Member NoteProperty Status $(if ($Value.State) { $Value.State } elseif ($Value.PSObject.Properties['VersionMatch']) { if ($Value.VersionMatch) { 'VersionMatches' } else { 'VersionMismatch' } } else { 'Observed' }) }
        $display = [Management.Automation.PSPropertySet]::new('DefaultDisplayPropertySet', [string[]]@('Target', 'Scope', 'Status', 'Location', 'Retained', 'Next'))
        $Value.PSObject.Members.Add([Management.Automation.PSMemberSet]::new('PSStandardMembers', [Management.Automation.PSMemberInfo[]]@($display)))
        $Value
    }
}

function Invoke-SpxCli {
    param ([string]$RepositoryRoot, $Invocation)
    Import-Module (Join-Path $RepositoryRoot 'SPX.psd1') -Force -ErrorAction Stop
    $parameters = $Invocation.Parameters
    switch ($Invocation.Key) {
        'repair.buckets' {
            $null = $parameters.Remove('Buckets')
            foreach ($bucket in @(Get-SpxStatus -Buckets | Where-Object { $_.PendingOperation -or $_.Status -eq 'Invalid' })) {
                if ($bucket.Status -eq 'Invalid') { Stop-SpxCliUsage "Inspect invalid bucket evidence for '$($bucket.Name)' before batch repair." $bucket }
                $parameters.Bucket = $bucket.Name
                Repair-SpxBucketMirror @parameters | ConvertTo-SpxCliView
            }
        }
        'cleanup' {
            $null = $parameters.Remove('Name')
            foreach ($name in $Invocation.Names) {
                $view = Get-SpxLinkedApp -Name $name -Scope $parameters.Scope
                $stale = $null
                if ($view.State -eq 'Stale') { $stale = Remove-SpxStaleLink -Name $name @parameters }
                $reclaim = @{}; foreach ($key in $parameters.Keys) { if ($key -ne 'InformationVariable') { $reclaim[$key] = $parameters[$key] } }
                $spxPreview = @()
                $result = Remove-SpxRetainedCopy -Name $name @reclaim -InformationVariable spxPreview
                foreach ($information in $spxPreview) {
                    if ($information.MessageData.PSObject.TypeNames -contains 'SPX.RetainedCopyPreview') {
                        $preview = $information.MessageData
                        $preview | Add-Member NoteProperty Location (@($preview.EligibleCopies.Path) -join ', ')
                        $preview | Add-Member NoteProperty RetainedCopies @(@($preview.EligibleCopies) + @($preview.BlockedCopies))
                        $preview | ConvertTo-SpxCliView
                    }
                }
                if ($result) {
                    if ($stale) { $result.Changed = $true; if ($result.Status -eq 'Unchanged') { $result.Status = 'Cleaned' } }
                    $result | Add-Member NoteProperty StaleRecordRemoved ([bool]$stale)
                    $result | ConvertTo-SpxCliView
                }
            }
        }
        'source.check' {
            $null = $parameters.Remove('Name')
            foreach ($name in $Invocation.Names) {
                $match = Test-SpxAppSource -Name $name @parameters
                [pscustomobject]@{ Name = $name; Scope = $parameters.Scope; Status = $(if ($match) { 'VersionMatches' } else { 'VersionMismatch' }); VersionMatches = $match } | ConvertTo-SpxCliView
            }
        }
        default { & ('SPX\' + $Invocation.Mode.Function) @parameters | Where-Object { $Invocation.Key -ne 'linked' -or $_.IsManaged -or $_.Status -eq 'Invalid' } | ConvertTo-SpxCliView -SourceView:($Invocation.Key -like 'source*') }
    }
}

function Complete-SpxCli {
    param ([string]$Text, [int]$Cursor, $Native)
    $tokens = $null; $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $commands = @($tree.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.StartOffset -le $Cursor }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending)
    if (-not $commands.Count) { return $null }
    $command = $commands[0]
    if ($command.Extent.EndOffset -lt $Cursor -and $Text.Substring($command.Extent.EndOffset, $Cursor - $command.Extent.EndOffset).Trim()) { return $null }
    $leaf = [IO.Path]::GetFileName($command.GetCommandName())
    if ($leaf -notin 'spx', 'spx.ps1') { return $null }
    $elements = @($command.CommandElements)
    $word = $Text.Substring($Native.ReplacementIndex, $Cursor - $Native.ReplacementIndex).Trim("'" + '"')
    $spec = Get-SpxCliSpecification
    $values = @(); $bound = @{}; $names = @(); $valueParameter = $null
    $rootWord = $elements.Count -lt 2 -or ($elements[1].Extent.StartOffset -ge $Native.ReplacementIndex -and -not $Text.Substring($elements[1].Extent.EndOffset, [Math]::Max(0, $Cursor - $elements[1].Extent.EndOffset)).Trim())
    if ($rootWord) { $values = @($spec.Values.Command | Select-Object -Unique) + @('help', '-Help', '-Version') }
    else {
        $verb = $elements[1].Extent.Text.Trim("'" + '"').ToLowerInvariant()
        $common = @([Management.Automation.Cmdlet]::CommonParameters)
        $commonMetadata = (Get-Command Get-Command).Parameters
        $all = @($spec.Values.Parameters | Select-Object -Unique) + @('Help', 'Version') + $common
        for ($i = 2; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element.Extent.StartOffset -ge $Native.ReplacementIndex -and $word.StartsWith('-')) { break }
            if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                if ($element.Extent.StartOffset -ge $Native.ReplacementIndex -and $word.StartsWith('-')) { break }
                $matches = @($all | Where-Object { $_ -eq $element.ParameterName })
                if (-not $matches.Count) { $matches = @($all | Where-Object { $_.StartsWith($element.ParameterName, [StringComparison]::OrdinalIgnoreCase) }) }
                if (-not $matches.Count) { $matches = @($common | Where-Object { $commonMetadata[$_].Aliases -contains $element.ParameterName }) }
                if ($matches.Count -ne 1) { continue }
                $name = $matches[0]
                if ($name -in $common) {
                    if ($name -notin 'Verbose', 'Debug' -and -not $element.Argument) {
                        if ($i + 1 -ge $elements.Count) { return $Native }
                        $i++
                        if ($elements[$i].Extent.StartOffset -ge $Native.ReplacementIndex) { return $Native }
                    }
                    continue
                }
                $bound[$name] = $true
                if ($name -in 'Bucket', 'Compare', 'Scope', 'Destination', 'Url') {
                    if ($i + 1 -lt $elements.Count -and $elements[$i + 1] -isnot [Management.Automation.Language.CommandParameterAst]) {
                        $i++; $argument = $elements[$i]
                        if ($argument -is [Management.Automation.Language.StringConstantExpressionAst]) { $bound[$name] = $argument.Value } else { $bound[$name] = $null }
                        if ($argument.Extent.StartOffset -ge $Native.ReplacementIndex) { $valueParameter = $name }
                    }
                    else { $valueParameter = $name }
                }
            }
            elseif ($element -is [Management.Automation.Language.StringConstantExpressionAst]) { $names += $element.Value }
            elseif ($element -is [Management.Automation.Language.ArrayLiteralAst]) { try { $names += @($element.SafeGetValue()) } catch { return [Management.Automation.CommandCompletion]::new([Collections.ObjectModel.Collection[Management.Automation.CompletionResult]]::new(), -1, $Native.ReplacementIndex, $Native.ReplacementLength) } }
        }
        $modes = @($spec.Values | Where-Object {
                $mode = $_
                $mode.Command -eq $verb -and -not @($bound.Keys | Where-Object { $_ -notin $mode.Parameters }).Count -and
                -not ($mode.Maximum -ge 0 -and $names.Count -gt $mode.Maximum)
            })
        if ($verb -eq 'source' -and -not $bound.Find -and -not $bound.Compare -and -not $bound.CheckVersion) {
            if ($names.Count) { $modes = @($modes | Where-Object { $_.Maximum -ne 0 }) }
            elseif ($bound.Bucket) { $modes = @($modes | Where-Object { $_.Maximum -eq 0 }) }
            else { $modes = @($modes | Where-Object { 'Url' -notin $_.Parameters -and 'Reset' -notin $_.Parameters -and 'Force' -notin $_.Parameters }) }
        }
        if ($word.StartsWith('-') -and -not $valueParameter) {
            $values = @($modes.Parameters | Select-Object -Unique | Where-Object { -not $bound.ContainsKey($_) } | ForEach-Object { '-' + $_ })
            $values += '-Help'
        }
        elseif ($valueParameter -eq 'Scope' -and $modes.Count) {
            $values = @('Local', 'Global') + @(if ($modes.Scope -contains 'All') { 'All' })
        }
        elseif ($valueParameter -eq 'Destination') { return $Native }
        elseif ($valueParameter -in 'Bucket', 'Compare' -and $modes.Count) {
            try { $values = @(Get-SpxStatus -Buckets | Where-Object { $_.Status -ne 'Invalid' } | Select-Object -ExpandProperty Name) } catch { $values = @() }
        }
        elseif (-not $valueParameter -and $modes.Count) {
            $scope = if ($bound.ContainsKey('Scope')) { $bound.Scope } elseif ($modes.Scope -contains 'All') { 'All' } else { 'Local' }
            if ($scope -in 'Local', 'Global', 'All') {
                try { $values = @(Get-SpxStatus -Scope $scope | Where-Object { $_.Status -ne 'Invalid' -and ($verb -ne 'linked' -or $_.IsManaged) } | Select-Object -ExpandProperty Name) } catch { $values = @() }
            }
        }
    }
    $results = [Collections.ObjectModel.Collection[Management.Automation.CompletionResult]]::new()
    foreach ($value in @($values | Sort-Object -Unique)) {
        if (-not $value.StartsWith($word, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $insert = if ($value -match '^[\w.-]+$') { $value } else { "'" + $value.Replace("'", "''") + "'" }
        $kind = if ($value.StartsWith('-')) { 'ParameterName' } else { 'ParameterValue' }
        $results.Add([Management.Automation.CompletionResult]::new($insert, $value, $kind, $value))
    }
    [Management.Automation.CommandCompletion]::new($results, -1, $Native.ReplacementIndex, $Native.ReplacementLength)
}

function Register-SpxCliCompletion {
    $state = @{ Original = (Get-Command TabExpansion2).ScriptBlock; Complete = (Get-Command Complete-SpxCli).ScriptBlock }
    $wrapper = {
        [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
        [OutputType([Management.Automation.CommandCompletion])]
        param (
            [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory, Position = 0)][AllowEmptyString()][string]$inputScript,
            [Parameter(ParameterSetName = 'ScriptInputSet', Position = 1)][int]$cursorColumn = $inputScript.Length,
            [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 0)][Management.Automation.Language.Ast]$ast,
            [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 1)][Management.Automation.Language.Token[]]$tokens,
            [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 2)][Management.Automation.Language.IScriptPosition]$positionOfCursor,
            [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)][Parameter(ParameterSetName = 'AstInputSet', Position = 3)][hashtable]$options = $null
        )
        $native = & $state.Original @PSBoundParameters
        $text = if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') { (' ' * $ast.Extent.StartOffset) + $ast.Extent.Text } else { $inputScript }
        $cursor = if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') { $positionOfCursor.Offset } else { $cursorColumn }
        if ($text.Length -lt $cursor) { $text = $text.PadRight($cursor) }
        $result = & $state.Complete $text $cursor $native
        if ($null -eq $result) { $native } else { $result }
    }.GetNewClosure()
    $state.Wrapper = $wrapper
    Set-Item Function:\global:TabExpansion2 $wrapper
    $ExecutionContext.SessionState.Module.OnRemove = {
        if ((Get-Command TabExpansion2).ScriptBlock -eq $state.Wrapper) { Set-Item Function:\global:TabExpansion2 $state.Original }
    }.GetNewClosure()
}
