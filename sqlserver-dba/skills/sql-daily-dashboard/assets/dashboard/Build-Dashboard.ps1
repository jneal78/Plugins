<#
.SYNOPSIS
    Builds the daily SQL Server workload dashboard: runs the read-only collectors with sqlcmd, joins their JSON with
    the site's findings ledger, and renders one self-contained HTML page (plus the data as JSON).

.DESCRIPTION
    Every SQL file it runs is SELECT-only (dash_server.sql, dash_workload.sql, and any "extra" files in the config).
    Nothing is changed on the server. The page has no server connection: it is a snapshot you can open, mail or archive.

    Output (in the config's outDir):
        Dashboard_<yyyy-MM-dd_HHmm>.html   this run's page (each run keeps its own; same minute replaces)
        Dashboard_latest.html              the newest page under a fixed name, for a bookmark
        data\dashboard_<yyyy-MM-dd_HHmm>.json

.PARAMETER Config
    Path to the dashboard config (JSON). Relative paths inside it are resolved from the config's folder.
    See dashboard.config.example.json.

.PARAMETER FromJson
    Skip the server and render from a saved data file (for template work or re-rendering an old day).

.PARAMETER Template
    HTML template to use instead of the config's (or the default dashboard.html next to this script).

.PARAMETER Open
    Open the page in the default browser when done.

.EXAMPLE
    .\Build-Dashboard.ps1 -Config C:\dba\dashboard\mysite.config.json -Open
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Config,
    [string]$FromJson,
    [string]$Template,
    [switch]$Open
)
$ErrorActionPreference = 'Stop'

$cfgPath = (Resolve-Path $Config).Path
$cfgDir  = Split-Path $cfgPath
$cfg     = Get-Content $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json

function Resolve-CfgPath([string]$p) {
    if (-not $p) { return $null }
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $cfgDir $p)
}

$outDir  = Resolve-CfgPath $(if ($cfg.outDir) { $cfg.outDir } else { 'out' })
$dataDir = Join-Path $outDir 'data'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-SqlJson([string]$Database, [string]$SqlFile, [hashtable]$Vars) {
    # Runs one collector and returns one JSON object. Each top-level FOR JSON result in the file is one object with
    # its own keys. With -y 0 sqlcmd prints no header, splits long results across lines of ~2,000 characters and
    # mixes in "Warning: Null value is eliminated..." lines. Join the data lines, cut the stream back to objects
    # by brace depth (outside strings), then combine the objects.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dash_" + [guid]::NewGuid().ToString('N') + ".json")
    $argv = @('-S', $cfg.server, '-d', $Database, '-E', '-I', '-b', '-y', '0', '-f', '65001', '-i', $SqlFile, '-o', $tmp)
    if ($Vars) { foreach ($k in $Vars.Keys) { $argv += @('-v', "$k=$($Vars[$k])") } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & sqlcmd @argv
    $code = $LASTEXITCODE
    $text = if (Test-Path $tmp) { [IO.File]::ReadAllText($tmp, $utf8) } else { '' }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "sqlcmd failed ($code) for $(Split-Path $SqlFile -Leaf) on $Database`n$text" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in ($text.TrimStart([char]0xFEFF) -split "`r?`n")) {
        if ($line -match '^Warning: Null value is eliminated' -or $line -eq '') { continue }
        [void]$sb.Append($line)
    }
    $stream = $sb.ToString()
    $inner = @(); $depth = 0; $inStr = $false; $esc = $false; $start = -1
    for ($i = 0; $i -lt $stream.Length; $i++) {
        $ch = $stream[$i]
        if ($inStr) {
            if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $obj = $stream.Substring($start + 1, $i - $start - 1)
                if ($obj) { $inner += $obj }
                $start = -1
            }
        }
    }
    $text = '{' + ($inner -join ',') + '}'
    $null = $text | ConvertFrom-Json        # throws if the output is not valid JSON
    Write-Host ("  {0,-24} {1,-12} {2,6:N1} s  {3,8:N0} chars" -f (Split-Path $SqlFile -Leaf), $Database, $sw.Elapsed.TotalSeconds, $text.Length)
    return $text
}

function Get-Candidates([string]$Path) {
    # Reads the findings ledger (a markdown file): '## Done', '## Ready', '## Open' sections holding tables whose first
    # column is 'Item'. Object names in `backticks` and 0x query hashes in a row become its match keys.
    $list = @()
    if (-not $Path -or -not (Test-Path $Path)) { return $list }
    $status = $null; $header = $null
    foreach ($line in (Get-Content $Path -Encoding utf8)) {
        if ($line -match '^##\s+(.+)$') {
            $h = $Matches[1]
            $status = if ($h -match '^Done') { 'done' } elseif ($h -match '^Ready') { 'ready' } elseif ($h -match '^Open') { 'open' } else { $null }
            $header = $null
            continue
        }
        if (-not $status -or $line -notmatch '^\s*\|' -or $line -match '^\s*\|\s*:?-') { continue }
        $cells = @(($line.Trim() -replace '^\||\|$', '') -split '\s\|\s' | ForEach-Object { $_.Trim() })
        if ($cells[0] -eq 'Item') { $header = $cells; continue }
        $keys = @([regex]::Matches($cells[0], '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
        $keys += @([regex]::Matches($line, '0x[0-9A-Fa-f]{16}') | ForEach-Object { $_.Value.ToUpper() -replace '^0X', '0x' })
        $fields = @()
        for ($i = 1; $i -lt $cells.Count; $i++) {
            $name = if ($header -and $i -lt $header.Count) { $header[$i] } else { "col$i" }
            $fields += [ordered]@{ name = $name; value = $cells[$i] }
        }
        $list += [ordered]@{ status = $status; item = $cells[0]; keys = @($keys | Select-Object -Unique); fields = $fields }
    }
    return $list
}

# Date and time of the run, so several runs a day (or a run past midnight) each keep their own page
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
if ($FromJson) {
    $json = [IO.File]::ReadAllText((Resolve-Path $FromJson).Path, $utf8)
    $null = $json | ConvertFrom-Json
    # Re-render under the data file's own stamp: dashboard_<yyyy-MM-dd>[_HHmm].json
    $stamp = ([IO.Path]::GetFileNameWithoutExtension($FromJson) -replace '^.*?_(\d{4}-\d{2}-\d{2}(_\d{4})?)$', '$1')
    if ($stamp -notmatch '^\d{4}-\d{2}-\d{2}(_\d{4})?$') { $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm' }
} else {
    $here = $PSScriptRoot
    Write-Host "Collecting from $($cfg.server) (read-only)"
    $main = @($cfg.databases | Where-Object { $_.main })[0]
    if (-not $main) { $main = @($cfg.databases)[0] }
    $serverJson = Get-SqlJson $main.name (Join-Path $here 'dash_server.sql') $null

    $dbJson = @()
    foreach ($db in $cfg.databases) {
        $groups = Resolve-CfgPath $db.groups
        if (-not $groups) { $groups = Join-Path $here 'groups_default.sql' }
        # sqlcmd won't take a drive path in -v, so :r gets the bare file name and runs from the file's folder
        $vars = @{ BaselineDate = $cfg.baselineDate; TopN = $(if ($cfg.topN) { $cfg.topN } else { 30 }); GroupsFile = (Split-Path $groups -Leaf) }
        Push-Location (Split-Path (Resolve-Path $groups).Path)
        try { $dbJson += Get-SqlJson $db.name (Join-Path $here 'dash_workload.sql') $vars } finally { Pop-Location }
    }

    $extra = @()
    foreach ($e in @($cfg.extra)) {
        if (-not $e) { continue }
        $text = Get-SqlJson $e.database (Resolve-CfgPath $e.sql) $null
        $extra += ('"' + $e.key + '":' + $text)
    }

    $cands = Get-Candidates (Resolve-CfgPath $cfg.candidates)
    $meta = [ordered]@{
        generated    = (Get-Date -Format 's')
        title        = $cfg.title
        server       = $cfg.server
        environment  = $cfg.environment
        baselineDate = $cfg.baselineDate
        baselineNote = $cfg.baselineNote
        topN         = $cfg.topN
        drill        = $cfg.drill
        thresholds   = $cfg.thresholds
    }
    $json = '{"meta":' + ($meta | ConvertTo-Json -Compress -Depth 8) +
            ',"server":' + $serverJson +
            ',"databases":[' + ($dbJson -join ',') + ']' +
            ',"extra":{' + ($extra -join ',') + '}' +
            ',"candidates":' + (ConvertTo-Json -InputObject @($cands) -Compress -Depth 8) + '}'
    $null = $json | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $dataDir "dashboard_$stamp.json"), $json, $utf8)
}

# Render: the template holds the placeholder /*__DASHBOARD_DATA__*/null; "</" is escaped so text from the
# server can never close the script element. The template's development lines are resolved here:
#   <script src="...data.js"></script><!--DEV-->      removed (the data is embedded instead)
#   <script src="...model.js"></script><!--MODEL-->   replaced with model.js (next to this script), inline
$tpl = if ($Template) { $Template } elseif ($cfg.template) { Resolve-CfgPath $cfg.template } else { Join-Path $PSScriptRoot 'dashboard.html' }
$html = [IO.File]::ReadAllText((Resolve-Path $tpl).Path, $utf8)
if ($html -notmatch [regex]::Escape('/*__DASHBOARD_DATA__*/null')) { throw "Template $tpl has no /*__DASHBOARD_DATA__*/null placeholder" }
$html = [regex]::Replace($html, '(?m)^.*<!--DEV-->.*\r?\n?', '')
$modelJs = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'model.js'), $utf8)
$html = [regex]::Replace($html, '<script src="[^"]*model\.js"></script><!--MODEL-->', { param($m) "<script>`n" + $modelJs + "`n</script>" })
$html = $html.Replace('/*__DASHBOARD_DATA__*/null', $json.Replace('</', '<\/'))
$page = Join-Path $outDir "Dashboard_$stamp.html"
[IO.File]::WriteAllText($page, $html, $utf8)
[IO.File]::WriteAllText((Join-Path $outDir 'Dashboard_latest.html'), $html, $utf8)
Write-Host "Dashboard: $page"
if ($Open) { Start-Process $page }
