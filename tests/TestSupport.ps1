$script:OriginalScoop = $null
$script:OriginalScoopGlobal = $null

function Enter-SpxTestSandbox {
    param ([Parameter(Mandatory)][string]$Root)
    $script:OriginalScoop = $env:SCOOP
    $script:OriginalScoopGlobal = $env:SCOOP_GLOBAL
    $env:SCOOP = Join-Path $Root 'scoop'
    $env:SCOOP_GLOBAL = Join-Path $Root 'global'
    foreach ($path in @(
            (Join-Path $env:SCOOP 'apps'), (Join-Path $env:SCOOP 'buckets'), (Join-Path $env:SCOOP 'persist'),
            (Join-Path $env:SCOOP_GLOBAL 'apps'), (Join-Path $env:SCOOP_GLOBAL 'persist')
        )) { $null = New-Item -ItemType Directory -Path $path -Force }
    [pscustomobject]@{ Root = $Root; LocalApps = (Join-Path $env:SCOOP 'apps'); GlobalApps = (Join-Path $env:SCOOP_GLOBAL 'apps') }
}

function Exit-SpxTestSandbox {
    $env:SCOOP = $script:OriginalScoop
    $env:SCOOP_GLOBAL = $script:OriginalScoopGlobal
}

function New-SpxTestApp {
    param ([string]$Name, [string]$Version = '1.0.0', [string]$Bucket = 'main', [switch]$Global, [object[]]$Persist = @())
    $apps = if ($Global) { Join-Path $env:SCOOP_GLOBAL 'apps' } else { Join-Path $env:SCOOP 'apps' }
    $app = Join-Path $apps $Name
    $versionPath = Join-Path $app $Version
    $null = New-Item -ItemType Directory -Path $versionPath -Force
    [IO.File]::WriteAllText((Join-Path $versionPath 'payload.txt'), "payload-$Name-$Version", (New-Object Text.UTF8Encoding($false)))
    @{ bucket = $Bucket; architecture = '64bit' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $versionPath 'install.json') -Encoding UTF8
    $manifest = [ordered]@{ version = $Version; description = "test $Name"; homepage = 'https://example.test'; url = 'https://example.test/app.zip' }
    if ($Persist.Count) { $manifest.persist = $Persist }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $versionPath 'manifest.json') -Encoding UTF8
    $null = New-Item -ItemType Junction -Path (Join-Path $app 'current') -Target $versionPath
    [pscustomobject]@{ Name = $Name; AppPath = $app; VersionPath = $versionPath; CurrentPath = (Join-Path $app 'current') }
}

function New-SpxTestBucket {
    param ([string]$Name, [string]$AppName, [string]$Version = '1.0.0')
    $path = Join-Path (Join-Path $env:SCOOP 'buckets') $Name
    $bucket = Join-Path $path 'bucket'
    $null = New-Item -ItemType Directory -Path $bucket -Force
    if ($AppName) { [ordered]@{version = $Version; description = "test $AppName"; homepage = 'https://example.test'; url = 'https://example.test/app.zip' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $bucket ($AppName + '.json')) -Encoding UTF8 }
    $path
}

function New-SpxTestGitBucket {
    param ([string]$Name, [string]$Origin)
    $path = New-SpxTestBucket -Name $Name
    & git -C $path init --quiet
    & git -C $path remote add origin $Origin
    if ($LASTEXITCODE -ne 0) { throw 'Could not create test Git bucket.' }
    $path
}
