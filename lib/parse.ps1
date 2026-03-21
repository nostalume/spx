# lib/Parse.ps1 - CLI argument parsing
# Keeps exec scripts free of parsing boilerplate.

function Get-ParsedArgs {
    <#
    .SYNOPSIS
        Parses a flat argument array into positional items and named options.

    .DESCRIPTION
        --flag            → Options['flag'] = $true
        --flag value      → Options['flag'] = 'value'
        --flag a b        → Options['flag'] = @('a','b')  (up to next --)
        bare words        → Positional list

    .EXAMPLE
        Get-ParsedArgs 'jq' '--path' 'D:\Apps' '--global'
        # Positional = ['jq']  Options = { path='D:\Apps'; global=$true }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(ValueFromRemainingArguments)] [string[]]$Inputs)

    $result = [ordered]@{ Positional = [System.Collections.Generic.List[string]]::new(); Options = @{} }
    if (-not $Inputs) { return $result }

    $i = 0
    while ($i -lt $Inputs.Count) {
        $a = $Inputs[$i]
        if ($a -match '^--?(.+)') {
            $key    = $Matches[1].ToLower().TrimStart('-')
            $values = [System.Collections.Generic.List[string]]::new()
            $i++
            while ($i -lt $Inputs.Count -and $Inputs[$i] -notmatch '^-') {
                $values.Add($Inputs[$i]); $i++
            }
            $result.Options[$key] = switch ($values.Count) { 0 { $true } 1 { $values[0] } default { $values.ToArray() } }
        } else {
            $result.Positional.Add($a); $i++
        }
    }
    $result
}

function Test-HelpFlag {
    param ([hashtable]$Parsed)
    $Parsed.Options.ContainsKey('h') -or $Parsed.Options.ContainsKey('help')
}