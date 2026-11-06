# .SYNOPSIS
#     Sorts SQL Server deadlock graphs by pattern, tags each pattern's mechanism, and lists what is upstream of it:
#     the code on each side, the locks, the isolation and transaction shape, and the programs, hosts, logins and jobs
#     that send each side, with the timing. Local only: it reads files and never connects to a database instance.
#
# .DESCRIPTION
#     Input (-Path, wildcards and several paths allowed; the same deadlock read twice counts once):
#       - JSON written by 14_deadlock_graphs_file.sql or 15_deadlock_graphs_ring.sql (also the older {"deadlocks":[...]} shape);
#       - .xdl / .xml deadlock graphs saved from SSMS or exported by a monitoring product.
#
#     Output, in -OutDir (default: the folder of the first input):
#       graphs\dl_<utc>.xdl       one file per deadlock; opens as a picture in SSMS
#       deadlock_processes.csv    one row per process per deadlock
#       deadlock_patterns.csv     one row per pattern
#       deadlock_patterns.md      per-pattern detail: sides, locks, mechanism tags with catalog candidates, upstream
#                                 signals, timing, and the ready-made inputs for scripts 16, 17 and 18 and the
#                                 handoff to sql-query-tuning and sql-workload-hotspots
#
#     A pattern is the set of code on the sides (the innermost named procedure, function or trigger and its line, or
#     "adhoc" plus the query hash or the statement with literals removed) plus the locked objects and indexes.
#
#     Times: event times are UTC and are converted to -TimeZone (default: this machine's), daylight saving included.
#     Graphs from .xdl files carry no event time; their time is the latest "lastbatchstarted" in the graph, which is
#     the instance's local time, and is marked with "~".
#
#     Production guardrails scan scripts run with -File: keep this file free of SQL write keywords and of
#     assignments that look like a connection target (tools/Test-ReadOnlyScripts.ps1 checks it).
#
# .PARAMETER Compare
#     A deadlock_patterns.csv from an earlier run: patterns are marked new or continuing, and patterns that no longer
#     occur are listed as gone. Use it to verify a fix or to spot new patterns on a repeat run.
#
# .EXAMPLE
#     pwsh -NoProfile -File Analyze-Deadlocks.ps1 -Path 'C:\work\deadlocks\raw\graphs_*.json' -TimeZone 'Central Standard Time'
# .EXAMPLE
#     pwsh -NoProfile -File Analyze-Deadlocks.ps1 -Path .\after\*.json -Compare .\before\deadlock_patterns.csv
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string[]]$Path,
    [string]$TimeZone,
    [string]$OutDir,
    [string]$Compare,
    [int]$Detail = 15,
    [string]$MonitorApps    # a regex for the site's own monitoring or maintenance programs (from the site profile)
)
$ErrorActionPreference = 'Stop'
# -Path may also arrive as one ';'-separated string (pwsh -File called from another shell can't pass an array)
$Path = @($Path | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$utf8 = [Text.UTF8Encoding]::new($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
$tz = if ($TimeZone) { [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) } else { [TimeZoneInfo]::Local }

# ---------------------------------------------------------------------------------------------------------------- helpers
function Short([string]$s, [int]$n) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { $s.Substring(0, $n) + '…' } else { $s }
}
function Norm([string]$s, [int]$n = 90) {
    # statement shape: literals and numbers replaced, so literal ad hoc variants group together
    $s = $s -replace "N?'(?:[^']|'')*'", "'?'" -replace '\b0x[0-9A-Fa-f]+\b', '0x?' -replace '(?<![\w@#])\d+(\.\d+)?\b', '?'
    Short $s $n
}
function StripDb([string]$name) { $p = $name.Split('.'); if ($p.Count -ge 3) { ($p[($p.Count - 2)..($p.Count - 1)]) -join '.' } else { $name } }
# Temp tables carry a per-session suffix (#name____…0000003BF60B) and cached ones an internal name (#A0043D13):
# normalize both, or every deadlock on a temp table becomes a pattern of its own.
function TempName([string]$name) {
    $name -replace '#(.+?)_{3,}[0-9A-Fa-f]{6,}$', '#$1' -replace '#[0-9A-Fa-f]{8}$', '#(cached temp table)'
}
function DbOf([string]$name) { $p = $name.Split('.'); if ($p.Count -ge 3) { ($p[0..($p.Count - 3)]) -join '.' } else { '' } }   # a database name may itself contain dots
# The collectors write UTC without an offset. ConvertFrom-Json may already have made a DateTime of it (some PowerShell
# versions a local time or a DateTimeOffset), so normalize every shape to a UTC DateTime.
function AsUtc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [DateTimeOffset]) { return $v.UtcDateTime }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [DateTimeKind]::Local) { return $v.ToUniversalTime() }
        return [datetime]::SpecifyKind($v, [DateTimeKind]::Utc)
    }
    return [datetime]::Parse([string]$v, $inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}
function ParseTime([string]$s) {
    if (-not $s) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($s, $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d } else { return $null }
}
# A Query Store text match for an ad hoc statement (script 16 "text:"): the locked table names that occur in the
# statement, plus identifiers recognized by their shape (an underscore or digit, or a capital after the first letter,
# and not all capitals), in the order they occur. Shape, not a keyword list: keywords are one-case words, and the
# match text then never carries a word a production guardrail would block.
function TextTarget([string]$stmt, [string[]]$tables) {
    $found = [Collections.Generic.List[object]]::new()
    foreach ($t in @($tables | Where-Object { $_ } | Select-Object -Unique)) {
        $at = $stmt.IndexOf($t, [StringComparison]::OrdinalIgnoreCase)
        if ($at -ge 0) { $found.Add([pscustomobject]@{ at = $at; v = $t }) }
    }
    foreach ($m in [regex]::Matches($stmt, '(?<![@#\w])[A-Za-z_][A-Za-z0-9_]{2,}')) {
        $v = $m.Value
        $shaped = ($v -match '[_0-9]' -or $v.Substring(1) -cmatch '[A-Z]') -and ($v -cmatch '[a-z]')
        if ($shaped) { $found.Add([pscustomobject]@{ at = $m.Index; v = $v }) }
    }
    $seenTok = @{}
    $tokens = @($found | Sort-Object at | Where-Object { $k = $_.v.ToLowerInvariant(); if ($seenTok.ContainsKey($k)) { $false } else { $seenTok[$k] = 1; $true } } |
        Select-Object -First 3 | ForEach-Object v)
    if ($tokens.Count -lt 2 -and -not ($tokens.Count -eq 1 -and $tables -contains $tokens[0])) { return '' }
    'text:' + (($tokens | ForEach-Object { $_ -replace '\[', '[[]' -replace '_', '[_]' }) -join '%')
}
# Known monitoring and maintenance products, as whole names: a bare "monitor" or "quest" would also match application
# names such as OrderMonitorService or RequestRouter and hide real application deadlocks as tool noise. A site adds its
# own tools with -MonitorApps. A negative deadlock priority is tagged separately ('low-priority'), whatever the name.
$monitorApps = '\b(SQL ?Sentry|SolarWinds|Nagios|Redgate|SQL Monitor|Idera|Spotlight|Quest Software|Zabbix|Datadog|New ?Relic|Dynatrace|SCOM|System Center|PRTG|Paessler|dbatools|SQLWATCH|Telegraf|Prometheus|Site24x7|AppDynamics|sp_WhoIsActive|sp_Blitz\w*)\b'
if ($MonitorApps) { $monitorApps = "$monitorApps|($MonitorApps)" }
$catalog = [ordered]@{
    'cross-object' = 'D1 lock order across tables'
    'conversion' = 'D2 read, then write the same row'
    'same-code' = 'D3 the same routine twice on one key'
    'same-index' = 'D3 one key worked on by two sessions, rows locked in different orders (D2 if a waiter converts)'
    'two-indexes' = 'D4 two indexes of one table (lookup vs write)'
    'page' = 'D5 a scan under page locks'
    'heap' = 'D6 a heap used as a queue'
    'range' = 'D7 serializable range locks (the session runs at serializable)'
    'range-hint' = 'D7 range locks the code asks for (HOLDLOCK / SERIALIZABLE hint, an upsert with HOLDLOCK), a cascading foreign key or an indexed view'
    'table-lock' = 'D8 lock escalation or table locks'
    'schema' = 'D12 schema locks (DDL, temp tables, metadata queries)'
    'parallel' = 'D13 intra-query parallelism'
    'applock' = 'D14 application locks'
    'low-priority' = 'D15 a tool that volunteers to lose'
    'monitoring-tool' = 'D15 monitoring or maintenance tool'
    'client-tran' = 'D16 transaction held open by the client'
    'implicit-tran' = 'D16 implicit transactions (driver autocommit off)'
    'distributed' = 'D16 distributed transaction'
}

# ---------------------------------------------------------------------------------------------------------------- read
$files = @(foreach ($p in $Path) {
    $m = @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue)
    # a mistyped path would otherwise just vanish, and with -Compare its patterns would show as "gone"
    if (-not $m) { Write-Warning "No input file matches $p" }
    $m
})
if (-not $files) { throw "No input files match: $($Path -join ', ')" }
if (-not $OutDir) { $OutDir = Split-Path $files[0].FullName }
$gdir = Join-Path $OutDir 'graphs'
New-Item -ItemType Directory -Force -Path $gdir | Out-Null

$graphs = [Collections.Generic.List[object]]::new()
$seen = @{}
$sources = [Collections.Generic.List[object]]::new()
function AddDeadlock([Xml.XmlElement]$dl, $utc, [string]$from) {
    $text = $dl.OuterXml
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($text)))
    if ($script:seen.ContainsKey($key)) { return 0 }
    $script:seen[$key] = 1
    $script:graphs.Add([pscustomobject]@{ Utc = $utc; Xml = $dl; Key = $key; From = $from })
    return 1
}

foreach ($f in $files) {
    $raw = [IO.File]::ReadAllText($f.FullName, $utf8).TrimStart([char]0xFEFF)
    if ($f.Extension -in '.xdl', '.xml') {
        $x = [xml]$raw
        $added = 0; $found = 0
        foreach ($d in @($x.SelectNodes('//deadlock'))) { $found++; $added += (AddDeadlock $d $null $f.Name) }
        $sources.Add([pscustomobject]@{ file = $f.Name; instance = ''; session = '(xdl)'; graphs = $found; new = $added; oldest_utc = ''; read_utc = '' })
        continue
    }
    $lines = ($raw -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '^(Warning: |\(\d+ rows? affected\)|-+\s*$)' }
    $text = $lines -join ''
    $i = $text.IndexOf('{'); $j = $text.LastIndexOf('}')
    if ($i -lt 0 -or $j -le $i) { Write-Warning "$($f.Name): no JSON in it (a sqlcmd error?) - skipped"; continue }
    # a truncated file (a collector cancelled by its timeout) must not stop the whole run
    try { $root = $text.Substring($i, $j - $i + 1) | ConvertFrom-Json }
    catch { Write-Warning "$($f.Name): not valid JSON (truncated?) - skipped"; continue }
    $added = 0; $found = 0
    foreach ($e in @($root.deadlocks)) {
        if (-not $e -or -not $e.graph) { continue }
        $found++
        $utc = AsUtc $e.utc
        $gx = [xml][string]$e.graph
        $added += (AddDeadlock $gx.DocumentElement $utc $f.Name)
    }
    $oldest = if ($root.oldest_event_utc) { AsUtc $root.oldest_event_utc } elseif ($root.oldest_utc) { AsUtc $root.oldest_utc } else { $null }
    $sources.Add([pscustomobject]@{ file = $f.Name; instance = [string]$root.server_name; session = [string]$root.xe_session
            graphs = $found; new = $added; oldest_utc = $(if ($oldest) { $oldest.ToString('yyyy-MM-dd HH:mm', $inv) } else { '' }) })
}
if ($graphs.Count -eq 0) { Write-Warning 'No deadlock graphs in the input.'; $sources | Format-Table -AutoSize; return }

# ---------------------------------------------------------------------------------------------------------------- parse
$procRows = [Collections.Generic.List[object]]::new()
$dlRows = [Collections.Generic.List[object]]::new()
$kinds = @{ keylock = 'key'; pagelock = 'page'; ridlock = 'rid'; objectlock = 'object'; metadatalock = 'metadata'; applicationlock = 'applock'
    exchangeEvent = 'exchange'; threadpool = 'threadpool'; hobtlock = 'hobt'; databaselock = 'database'; filelock = 'file'; extentlock = 'extent'
    allocunitlock = 'allocunit'; resourceWait = 'resource' }

foreach ($g in $graphs) {
    $dl = $g.Xml
    $procs = @($dl.SelectNodes('process-list/process'))
    if (-not $procs) { continue }
    if ($g.Utc) { $lt = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::SpecifyKind($g.Utc, 'Utc'), $tz); $approx = '' }
    else {
        $lt = ($procs | ForEach-Object { ParseTime $_.GetAttribute('lastbatchstarted') } | Where-Object { $_ } | Measure-Object -Maximum).Maximum
        $approx = '~'
        if (-not $lt) { $lt = [datetime]::MinValue; $approx = '?' }   # a graph with no time at all: keep it, undated
    }
    $id = if ($g.Utc) { $g.Utc.ToString('yyyyMMdd_HHmmss_fff', $inv) } else { 'x' + $g.Key.Substring(0, 12).ToLowerInvariant() }
    $file = Join-Path $gdir "dl_$id.xdl"
    if (-not (Test-Path $file)) { [IO.File]::WriteAllText($file, '<deadlock-list>' + $dl.OuterXml + '</deadlock-list>', $utf8) }

    $victims = @($dl.SelectNodes('victim-list/victimProcess') | ForEach-Object { $_.GetAttribute('id') })
    if (-not $victims -and $dl.GetAttribute('victim')) { $victims = @($dl.GetAttribute('victim')) }

    # resources
    $res = [Collections.Generic.List[object]]::new()
    $rl = $dl.SelectSingleNode('resource-list')
    if ($rl) {
        foreach ($r in $rl.ChildNodes) {
            if ($r.NodeType -ne 'Element') { continue }
            $type = $r.LocalName
            $kind = if ($kinds.ContainsKey($type)) { $kinds[$type] } else { $type }
            $objFull = $r.GetAttribute('objectname'); $idx = $r.GetAttribute('indexname'); $hobt = $r.GetAttribute('hobtid')
            $objShort = if ($objFull) { TempName (StripDb $objFull) } else { '' }
            $label = if ($objFull) { $objShort + $(if ($idx) { '/' + $idx } elseif ($kind -eq 'rid') { '/(heap)' } else { '' }) }
                     elseif ($kind -eq 'exchange') { '(parallel exchange)' }
                     elseif ($kind -eq 'threadpool') { '(worker threads)' }
                     elseif ($kind -eq 'metadata') { '(metadata ' + $r.GetAttribute('subresource') + ' ' + $r.GetAttribute('classid') + ')' }
                     elseif ($hobt) { "(hobt $hobt)" } else { "($type)" }
            $owners = @($r.SelectNodes('owner-list/owner') | ForEach-Object { [pscustomobject]@{ id = $_.GetAttribute('id'); mode = $_.GetAttribute('mode') } })
            $waiters = @($r.SelectNodes('waiter-list/waiter') | ForEach-Object { [pscustomobject]@{ id = $_.GetAttribute('id'); mode = $_.GetAttribute('mode'); req = $_.GetAttribute('requestType') } })
            $res.Add([pscustomobject]@{ kind = $kind; label = $label; obj = $objShort; idx = $idx
                    db = $(if ($objFull) { DbOf $objFull } else { '' }); hobt = $hobt; mode = $r.GetAttribute('mode'); owners = $owners; waiters = $waiters })
        }
    }

    # processes
    $sideRows = [Collections.Generic.List[object]]::new()
    $spidCount = @{}
    foreach ($p in $procs) { $s = $p.GetAttribute('spid'); $spidCount[$s] = 1 + [int]$spidCount[$s] }
    foreach ($p in $procs) {
        $pid_ = $p.GetAttribute('id')
        $frames = @($p.SelectNodes('executionStack/frame'))
        $named = $null
        foreach ($fr in $frames) { $pn = $fr.GetAttribute('procname'); if ($pn -and $pn -notin @('adhoc', 'unknown')) { $named = $fr; break } }
        $inner = $frames | Select-Object -First 1
        $stmt = if ($inner) { [string]$inner.InnerText } else { '' }
        $stmt = $stmt.Trim()
        $ibNode = $p.SelectSingleNode('inputbuf')
        $inputbuf = if ($ibNode) { ([string]$ibNode.InnerText).Trim() } else { '' }
        if (-not $stmt -or $stmt -eq 'unknown') { $stmt = $inputbuf }
        $qh = ''
        foreach ($fr in $frames) { $h = $fr.GetAttribute('queryhash'); if ($h -and $h -notmatch '^0x0+$') { $qh = $h; break } }
        if ($named) {
            $pnFull = $named.GetAttribute('procname')
            $module = StripDb $pnFull
            $db = DbOf $pnFull
            $dyn = if (-not [object]::ReferenceEquals($named, $inner)) { ' (dynamic SQL)' } else { '' }
            $code = $module + ':' + $named.GetAttribute('line') + $dyn
            # The pattern key uses the module, not the line: a fix inside the module shifts line numbers, and a key
            # with lines would show the same deadlock as "gone" plus "new" in a -Compare run. Lines stay in "code".
            $sideKey = $module + $dyn
        } else {
            $module = ''
            $db = $p.GetAttribute('currentdbname')
            $code = 'adhoc: ' + (Norm $stmt 70)
            # without a query hash, the statement shape (literals removed) is the key: 200 characters, so two ORM
            # statements that share their first line but differ in the WHERE clause stay apart
            $sideKey = 'adhoc ' + $(if ($qh) { $qh } else { Norm $stmt 200 })
        }
        if (-not $db) { $db = ($res | Where-Object db | Select-Object -First 1).db }
        $isolation = ($p.GetAttribute('isolationlevel') -replace '\s*\(\d+\)\s*$', '')
        $tranStart = ParseTime $p.GetAttribute('lasttranstarted')
        $batchStart = ParseTime $p.GetAttribute('lastbatchstarted')
        $clientTran = ($tranStart -and $batchStart -and ($batchStart - $tranStart).TotalSeconds -gt 1)
        $app = $p.GetAttribute('clientapp')
        $job = if ($app -match 'Job (0x[0-9A-Fa-f]{32}) : Step (\d+)') { $Matches[1] + ' step ' + $Matches[2] } else { '' }
        $prio = 0; [void][int]::TryParse($p.GetAttribute('priority'), [ref]$prio)
        $holds = @(foreach ($r in $res) { foreach ($o in $r.owners) { if ($o.id -eq $pid_) { "$($r.label) $($o.mode)" } } }) -join '; '
        $wants = @(foreach ($r in $res) { foreach ($w in $r.waiters) { if ($w.id -eq $pid_) { "$($r.label) $($w.mode)$(if ($w.req -eq 'convert') { ' (convert)' })" } } }) -join '; '
        $row = [pscustomobject]@{
            pattern = ''; deadlock = $id; local = $lt.ToString('yyyy-MM-dd HH:mm:ss', $inv) + $approx; victim = [bool]($victims -contains $pid_)
            side = $sideKey; code = $code; module = $module; db = $db; spid = $p.GetAttribute('spid'); ecid = $p.GetAttribute('ecid')
            isolation = $isolation; tran_name = $p.GetAttribute('transactionname'); trancount = $p.GetAttribute('trancount')
            tran_open_before_batch = [bool]$clientTran; lock_mode = $p.GetAttribute('lockMode'); holds = $holds; waits_for = $wants
            waitresource = $p.GetAttribute('waitresource'); waittime_ms = $p.GetAttribute('waittime'); logused = $p.GetAttribute('logused')
            priority = $prio; app = $app; host = $p.GetAttribute('hostname'); login = $p.GetAttribute('loginname'); job = $job
            query_hash = $qh; frames = (@($frames | ForEach-Object { (StripDb $_.GetAttribute('procname')) + ':' + $_.GetAttribute('line') }) -join ' < ')
            statement = (Short $stmt 400); inputbuf = (Short $inputbuf 400)
        }
        $sideRows.Add($row); $procRows.Add($row)
    }

    # deadlock-level tags
    $tags = [Collections.Generic.HashSet[string]]::new()
    $modes = @($res | ForEach-Object { $_.mode; $_.owners.mode; $_.waiters.mode }) + @($sideRows.lock_mode) | Where-Object { $_ }
    $isParallel = ($res.kind -contains 'exchange') -or ($res.kind -contains 'threadpool') -or (@($spidCount.Values | Where-Object { $_ -gt 1 }).Count -gt 0)
    if ($isParallel) { [void]$tags.Add('parallel') }
    if (($res.kind -contains 'metadata') -or ($modes | Where-Object { $_ -like 'Sch-*' })) { [void]$tags.Add('schema') }
    # Range locks come from a serializable session, or, at any isolation level, from code that asks for them (HOLDLOCK
    # or SERIALIZABLE hints, an upsert statement with HOLDLOCK), a cascading foreign key or an indexed view. Only the first points at
    # the client; the second is the database code, including fixes that add UPDLOCK, HOLDLOCK.
    if ($sideRows.isolation | Where-Object { $_ -like 'serializable*' }) { [void]$tags.Add('range') }
    elseif ($modes | Where-Object { $_ -like 'Range*' }) { [void]$tags.Add('range-hint') }
    if ($res | Where-Object { $_.waiters.req -contains 'convert' }) { [void]$tags.Add('conversion') }
    $lockObjs = @($res | Where-Object { $_.kind -in 'key', 'page', 'rid', 'object', 'hobt' -and $_.obj } | Select-Object -ExpandProperty obj -Unique)
    $lockIdx = @($res | Where-Object { $_.kind -in 'key', 'page', 'rid' -and $_.obj } | ForEach-Object { $_.obj + '/' + $_.idx } | Select-Object -Unique)
    $realObjs = @($lockObjs | Where-Object { $_ -notmatch '(^|\.)#' })
    if ($realObjs.Count -gt 1) { [void]$tags.Add('cross-object') }
    elseif ($lockObjs.Count -eq 1 -and $lockIdx.Count -gt 1) { [void]$tags.Add('two-indexes') }
    elseif ($lockObjs.Count -eq 1 -and $res.kind -contains 'key') { [void]$tags.Add('same-index') }
    if ($res.kind -contains 'rid') { [void]$tags.Add('heap') }
    if ($res.kind -contains 'page') { [void]$tags.Add('page') }
    if ($res | Where-Object { $_.kind -eq 'object' -and (@($_.owners.mode) + @($_.waiters.mode) | Where-Object { $_ -and $_ -notlike 'Sch-*' }) }) { [void]$tags.Add('table-lock') }
    if ($res.kind -contains 'applock') { [void]$tags.Add('applock') }
    # One row per session. A parallel query shows up as several threads (ecid) of one spid; locks are often held or
    # waited on by threads other than the first, so combine them all (the first thread alone under-reports).
    $bySpid = @($sideRows | Group-Object spid | ForEach-Object {
        $grp = @($_.Group)
        $m = $grp[0].PSObject.Copy()
        if ($grp.Count -gt 1) {
            $m.holds = (@($grp.holds -split '; ' | Where-Object { $_ }) | Select-Object -Unique) -join '; '
            $m.waits_for = (@($grp.waits_for -split '; ' | Where-Object { $_ }) | Select-Object -Unique) -join '; '
            $m.victim = [bool](@($grp | Where-Object victim).Count)
        }
        $m
    })
    # same routine on every side, at the same or different lines
    if ($bySpid.Count -gt 1 -and @($bySpid | ForEach-Object { $_.side -replace ':\d*( \(dynamic SQL\))?$', '' } | Select-Object -Unique).Count -eq 1) { [void]$tags.Add('same-code') }
    if ($bySpid.Count -gt 2) { [void]$tags.Add('multi-party') }
    if ($sideRows | Where-Object { $_.priority -lt 0 }) { [void]$tags.Add('low-priority') }
    if ($sideRows | Where-Object { $_.app -match $monitorApps }) { [void]$tags.Add('monitoring-tool') }
    if ($sideRows | Where-Object { $_.tran_open_before_batch }) { [void]$tags.Add('client-tran') }
    if ($sideRows | Where-Object { $_.tran_name -eq 'implicit_transaction' }) { [void]$tags.Add('implicit-tran') }
    if ($sideRows | Where-Object { $_.tran_name -like 'DTC*' }) { [void]$tags.Add('distributed') }
    if ($sideRows | Where-Object { $_.job }) { [void]$tags.Add('agent-job') }

    $sides = (@($bySpid.side) | Sort-Object) -join '  x  '
    $objects = (@($res.label) | Sort-Object -Unique) -join ', '
    # Grouping key. A side that volunteers to lose (negative deadlock priority, typically a monitoring tool) defines
    # the pattern by itself: whatever it collides with is incidental. Deadlocks only on temp tables group as one.
    $lowSides = @($bySpid | Where-Object { $_.priority -lt 0 } | ForEach-Object side | Sort-Object -Unique)
    $keySides = if ($lowSides) { ($lowSides -join '  x  ') + '  x  (any)' } else { $sides }
    $keyObjects = if (@($res | Where-Object { $_.obj -and $_.obj -notmatch '(^|\.)#' }).Count -eq 0 -and @($res | Where-Object obj).Count -gt 0) { '(temp tables)' } else { $objects }
    $dlRows.Add([pscustomobject]@{
            id = $id; local = $lt; approx = $approx; key = "$keySides  |  $keyObjects"; sides = $keySides; objects = $keyObjects
            tags = @($tags); victim_sides = (@($sideRows | Where-Object victim | ForEach-Object side | Select-Object -Unique) -join ', ')
            nproc = $bySpid.Count; procs = $sideRows; sessions = $bySpid; res = $res })
}

# ---------------------------------------------------------------------------------------------------------------- patterns
$old = @{}
if ($Compare) { foreach ($r in (Import-Csv $Compare)) { $old[$r.key] = $r } }
$groups = @($dlRows | Group-Object key | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
$patterns = [Collections.Generic.List[object]]::new()
$n = 0
foreach ($grp in $groups) {
    $n++
    $label = "P$n"
    $dls = @($grp.Group | Sort-Object local)
    foreach ($d in $dls) { foreach ($pr in $d.procs) { $pr.pattern = $label } }
    $tagCount = @{}
    foreach ($d in $dls) { foreach ($t in $d.tags) { $tagCount[$t] = 1 + [int]$tagCount[$t] } }
    $times = @($dls.local)
    $close = 0
    for ($k = 1; $k -lt $times.Count; $k++) { if (($times[$k] - $times[$k - 1]).TotalSeconds -le 120) { $close++ } }
    $status = if ($Compare) { if ($old.ContainsKey($grp.Name)) { 'continuing' } else { 'new' } } else { '' }
    $patterns.Add([pscustomobject]@{
            pattern = $label; status = $status; count = $grp.Count
            first = $times[0].ToString('yyyy-MM-dd HH:mm', $inv) + $dls[0].approx; last = $times[-1].ToString('yyyy-MM-dd HH:mm', $inv) + $dls[-1].approx
            sides = $dls[0].sides; objects = $dls[0].objects
            tags = (($tagCount.GetEnumerator() | Sort-Object Name | ForEach-Object { if ($_.Value -eq $grp.Count) { $_.Name } else { "$($_.Name) ($($_.Value)/$($grp.Count))" } }) -join ', ')
            victims = ((@($dls.victim_sides) | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join '; ')
            within_2_min_of_previous = $close
            key = $grp.Name; _dls = $dls; _tags = $tagCount })
}
$gone = @()
if ($Compare) { $gone = @($old.Values | Where-Object { -not ($groups.Name -contains $_.key) }) }

# CSV cells that start with = + - @ are formulas to Excel; program and host names come from clients, so prefix them with
# a quote (the pattern key stays exact: -Compare matches on it).
function NoFormula($rows, [string[]]$keep = @()) {
    foreach ($r in $rows) {
        $o = $r.PSObject.Copy()
        foreach ($pp in $o.PSObject.Properties) {
            if ($pp.Name -notin $keep -and $pp.Value -is [string] -and $pp.Value -match '^[=+\-@\t\r]') { $pp.Value = "'" + $pp.Value }
        }
        $o
    }
}
NoFormula $procRows | Export-Csv (Join-Path $OutDir 'deadlock_processes.csv') -NoTypeInformation -Encoding utf8
NoFormula ($patterns | Select-Object pattern, status, count, first, last, sides, objects, tags, victims, within_2_min_of_previous, key) @('key') |
    Export-Csv (Join-Path $OutDir 'deadlock_patterns.csv') -NoTypeInformation -Encoding utf8

# ---------------------------------------------------------------------------------------------------------------- report
$sb = [Text.StringBuilder]::new()
function L([string]$s = '') { [void]$script:sb.AppendLine($s) }
# Text from the server (statements, program and host names) is shown, never rendered: HTML-encode it as well as
# escaping the table separator, so a report rendered with report_shell.html can't be made to run script.
function Esc([string]$s) { ([Net.WebUtility]::HtmlEncode($s) -replace '\|', '\|' -replace '\r?\n', ' ') }
function TopList($values, [int]$k = 3) {
    $vals = @($values | Where-Object { $_ -ne $null -and "$_" -ne '' })
    if (-not $vals) { return '' }
    (@($vals | Group-Object | Sort-Object Count -Descending | Select-Object -First $k | ForEach-Object { if ($_.Count -eq $vals.Count) { $_.Name } else { "$($_.Name) ($($_.Count))" } }) -join ', ')
}

$all = @($dlRows | Sort-Object local)
$span0 = $all[0].local; $span1 = $all[-1].local
L "# Deadlock patterns"
L
L ([string]::Format($inv, "{0} distinct deadlocks, {1:yyyy-MM-dd HH:mm} to {2:yyyy-MM-dd HH:mm} ({3}), {4} patterns. Generated {5:yyyy-MM-dd HH:mm} by Analyze-Deadlocks.ps1.", $all.Count, $span0, $span1, $tz.Id, $patterns.Count, (Get-Date)))
L
L "**Sources**"
L
L "| File | Instance | Session | Graphs | New | Oldest event in the session (UTC) |"
L "|---|---|---|---:|---:|---|"
foreach ($s in $sources) { L "| $($s.file) | $($s.instance) | $($s.session) | $($s.graphs) | $($s.new) | $($s.oldest_utc) |" }
L
L "Only what the session still held when it was read is here. For the long trend use script 16 with the History lines below."
L
L "## Summary"
L
L "| Pattern | Status | Deadlocks | First | Last | Sides | Locked | Tags | Lost |"
L "|---|---|---:|---|---|---|---|---|---|"
foreach ($p in $patterns) { L "| $($p.pattern) | $($p.status) | $($p.count) | $($p.first) | $($p.last) | $(Esc $p.sides) | $(Esc $p.objects) | $($p.tags) | $(Esc $p.victims) |" }
if ($gone) { L; L ("**Gone since the comparison run:** " + (($gone | ForEach-Object { "$($_.pattern) ($($_.count)x: $($_.sides))" }) -join '; ')) }
L
L ("**By day:** " + ((@($all | Group-Object { $_.local.ToString('yyyy-MM-dd ddd', $inv) } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ' · '))
L
L ("**By hour of day:** " + ((@($all | Group-Object { $_.local.Hour } | Sort-Object { [int]$_.Name } | ForEach-Object { '{0:00}h {1}' -f [int]$_.Name, $_.Count })) -join ' · '))
L
L ("**Victims by program:** " + (Esc (TopList ($procRows | Where-Object victim | ForEach-Object { if ($_.app) { $_.app } else { '(blank program name)' } }) 8)))
L

$detailN = [Math]::Min($Detail, $patterns.Count)
foreach ($p in ($patterns | Select-Object -First $detailN)) {
    $dls = $p._dls
    L "## $($p.pattern): $($p.count) deadlock$(if ($p.count -ne 1) {'s'}), $($p.first) to $($p.last)$(if ($p.status) { " ($($p.status))" })"
    L
    $cands = @($catalog.Keys | Where-Object { $p._tags.ContainsKey($_) } | ForEach-Object { $catalog[$_] } | Select-Object -Unique)
    L "**Mechanism tags:** $($p.tags)"
    L
    L ("**Catalog candidates** (references/deadlock-patterns.md): " + $(if ($cands) { $cands -join '; ' } else { 'none from the graph alone' }) + ". Not visible in a graph, so check them too: D9 mass rewrite, D10 plan flip or placeholder value, D11 unindexed foreign key, D17 trigger in the transaction.")
    L
    L "**Locked:** $(Esc $p.objects)"
    L
    L "| Side | Code (innermost < outer) | Statement | Holds | Waits for | Isolation / transaction | Program · host · login | Lost |"
    L "|---|---|---|---|---|---|---|---|"
    # one row per session (parallel threads merged), grouped by the code and line each side ran
    $sideGroups = @($dls | ForEach-Object { $_.sessions } | Group-Object code)
    $si = 0
    foreach ($sg in $sideGroups) {
        $si++
        $r = $sg.Group
        $first = $r[0]
        $lost = @($r | Where-Object victim).Count
        $iso = TopList $r.isolation
        $tran = TopList $r.tran_name
        $ct = @($r | Where-Object tran_open_before_batch).Count
        $isoText = "$iso; $tran" + $(if ($ct) { "; open before the batch $ct/$($r.Count)" } else { '' })
        $who = (TopList $r.app 2) + ' · ' + (TopList $r.host 2) + ' · ' + (TopList $r.login 2)
        $jobs = TopList $r.job 2
        if ($jobs) { $who += " · job $jobs" }
        $prio = @($r.priority | Where-Object { $_ -ne 0 } | Select-Object -Unique)
        if ($prio) { $who += " · deadlock priority $($prio -join ',')" }
        L "| $si | $(Esc $first.frames) | $(Esc (Short $first.statement 160)) | $(Esc (TopList $r.holds 1)) | $(Esc (TopList $r.waits_for 1)) | $(Esc $isoText) | $(Esc $who) | $lost/$($r.Count) |"
    }
    L
    # timing and upstream signals
    $times = @($dls.local)
    $hours = (@($dls | Group-Object { $_.local.Hour } | Sort-Object { [int]$_.Name } | ForEach-Object { '{0:00}h {1}' -f [int]$_.Name, $_.Count }) -join ' · ')
    $days = (@($dls | Group-Object { $_.local.ToString('MM-dd ddd', $inv) } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ' · ')
    L "**Timing:** by day $days. By hour $hours. $($p.within_2_min_of_previous) of $($p.count) came within 2 minutes of the previous one (bursts point at a batch, a retry loop or a burst of work on one key)."
    L
    $signals = [Collections.Generic.List[string]]::new()
    $allProcs = @($dls | ForEach-Object { $_.procs })
    if ($p._tags.ContainsKey('same-code')) { $signals.Add('Both sides run the same code: two sessions worked on the same key at the same moment. Find out why (two workers on one queue item, a client retry after a timeout, a double submission, message redelivery).') }
    if ($p._tags.ContainsKey('same-index') -and -not $p._tags.ContainsKey('same-code')) { $signals.Add('Two different routines take the same index''s rows for one key in different orders: the same business entity (document, order, message) was being processed twice at once. Find out why it reaches two sessions together.') }
    $sideHosts = @($dls | ForEach-Object { @($_.sessions.host) -join '|' } | Where-Object { ($_ -split '\|' | Select-Object -Unique).Count -gt 1 })
    if (($p._tags.ContainsKey('same-index') -or $p._tags.ContainsKey('same-code')) -and $sideHosts.Count) { $signals.Add("In $($sideHosts.Count) of $($p.count) deadlocks the sides came from different hosts: separate application servers or workers handle the same key at the same time, so the fix may belong in how work is shared out, not only in the database.") }
    if ($p._tags.ContainsKey('client-tran')) { $signals.Add('A side''s transaction started before its current batch: the client holds the transaction open across round trips (TransactionScope, an ORM unit of work, autocommit off). Every statement in that transaction keeps its locks until the client commits.') }
    if ($p._tags.ContainsKey('implicit-tran')) { $signals.Add('implicit_transaction: the driver runs with autocommit off (common with JDBC and ODBC defaults), so even reads keep their locks until the client commits.') }
    if ($p._tags.ContainsKey('distributed')) { $signals.Add('A distributed transaction (DTC): a client TransactionScope that spans two connections or resources; usually serializable by default.') }
    if ($p._tags.ContainsKey('range')) { $signals.Add('A side runs at serializable isolation, so its reads take range locks. Procedures rarely ask for this; the client usually does (TransactionScope defaults to serializable). Check the program in the side table.') }
    if ($p._tags.ContainsKey('range-hint')) { $signals.Add('Range locks at a normal isolation level: the code asks for them (a HOLDLOCK or SERIALIZABLE table hint, an upsert statement with HOLDLOCK), or a cascading foreign key or an indexed view takes them. Read the code at the line, and 17 section 5. This includes local fixes that added UPDLOCK, HOLDLOCK. Not a client setting.') }
    if ($p._tags.ContainsKey('low-priority') -or $p._tags.ContainsKey('monitoring-tool')) { $signals.Add('A monitoring or maintenance tool is a side (low deadlock priority or a known product name). It loses by design; count it apart from application deadlocks and fix the check, not the application.') }
    if ($p._tags.ContainsKey('agent-job')) { $signals.Add('A SQL Agent job is a side: name it and get its schedule with script 18 (ids: ' + ((@($allProcs.job | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique)) -join ', ') + ').') }
    if ($p._tags.ContainsKey('parallel')) { $signals.Add('Intra-query parallelism: one statement deadlocked with its own threads. The fix is that statement''s plan (sql-query-tuning), not concurrency.') }
    if (@($allProcs | Where-Object { -not $_.app }).Count) { $signals.Add('Blank program name on a side: the application does not set Application Name. Identify it by host and login (sql-workload-hotspots script 08) and ask the owner to set it.') }
    $avgLog = ($allProcs | Where-Object victim | ForEach-Object { [double]$_.logused } | Measure-Object -Average).Average
    if ($avgLog -gt 1048576) { $signals.Add(('The victim had written {0:N1} MB of log on average before it was chosen: long transactions, expensive to roll back.' -f ($avgLog / 1MB))) }
    if ($signals.Count) { L "**Upstream signals**"; L; foreach ($s in $signals) { L "- $s" }; L }

    # inputs for the next scripts
    $hist = [ordered]@{}
    $lockedTables = @($dls | ForEach-Object { $_.res } | Where-Object obj | ForEach-Object { ($_.obj -split '\.')[-1] } | Select-Object -Unique)
    foreach ($v in @($allProcs | Where-Object victim)) {
        $t = if ($v.query_hash) { $v.query_hash } elseif ($v.module) { $v.module } else { TextTarget $v.statement $lockedTables }
        if (-not $t) { continue }
        $dbk = if ($v.db) { $v.db } else { '(database?)' }
        if (-not $hist.Contains($dbk)) { $hist[$dbk] = [Collections.Generic.List[string]]::new() }
        if (-not $hist[$dbk].Contains("$($p.pattern)=$t")) { $hist[$dbk].Add("$($p.pattern)=$t") }
    }
    if ($hist.Count) {
        L ("**History (script 16), victim statements:** " + ((@($hist.Keys) | ForEach-Object { "in ``$_``: ``$($hist[$_] -join '; ')``" }) -join ' · '))
        L
    }
    $objs = @($dls | ForEach-Object { $_.res } | Where-Object { $_.obj -and $_.obj -notmatch '(^|\.)#' -and $_.kind -in 'key', 'page', 'rid', 'object', 'hobt' } | Group-Object db)
    $hobts = @($dls | ForEach-Object { $_.res } | Where-Object { -not $_.obj -and $_.hobt } | ForEach-Object hobt | Select-Object -Unique)
    if ($objs -or $hobts) {
        L ("**Objects (script 17):** " + ((@($objs | ForEach-Object { "in ``$(if ($_.Name) { $_.Name } else { '(database?)' })``: ``" + ((@($_.Group.obj | Select-Object -Unique)) -join '; ') + '`' })) -join ' · ') + $(if ($hobts) { " · unnamed hobt ids: ``$($hobts -join '; ')``" } else { '' }))
        L
    }
    # A pattern defined by a tool that volunteers to lose is fixed in the tool, so no tuning requests for the other sides.
    $toolPattern = $p.sides -like '*(any)'
    $hand = if ($toolPattern) { @() } else { @($sideGroups | ForEach-Object { $_.Group[0] } | Where-Object { $_.module -or $_.query_hash }) }
    if ($hand) {
        L "**Handoffs**"
        L
        foreach ($h in $hand) {
            $lostN = @($h | Where-Object victim).Count
            L ("- sql-query-tuning: read the plan of ``{0}``{1} in ``{2}``: it is a side of {3} ({4} deadlocks, {5} to {6}); it holds {7} and waits for {8}. Does it scan, and which predicate stops a seek?" -f $h.code, $(if ($h.query_hash) { " (query_hash $($h.query_hash))" } else { '' }), $h.db, $p.pattern, $p.count, $p.first, $p.last, $(if ($h.holds) { $h.holds } else { 'nothing named' }), $(if ($h.waits_for) { $h.waits_for } else { 'nothing named' }))
        }
        foreach ($h in @($sideGroups | ForEach-Object { $_.Group[0] } | Where-Object { $_.query_hash -or $_.module } | Select-Object -First 2)) {
            L ("- sql-workload-hotspots script 08: who sends ``{0}`` (@QueryHash = {1}, or @Object = N'{2}'), and when (section 5)." -f $h.code, $(if ($h.query_hash) { $h.query_hash } else { 'NULL' }), ($h.module -replace "'", "''"))
        }
        L
    }
    L ("Graphs: " + ((@($dls | Select-Object -First 5 | ForEach-Object { "graphs\dl_$($_.id).xdl" })) -join ', ') + $(if ($dls.Count -gt 5) { ' …' } else { '' }))
    L
}
if ($patterns.Count -gt $detailN) { L "$($patterns.Count - $detailN) smaller patterns are in deadlock_patterns.csv (raise -Detail to describe them here)." }
[IO.File]::WriteAllText((Join-Path $OutDir 'deadlock_patterns.md'), $sb.ToString(), $utf8)

# ---------------------------------------------------------------------------------------------------------------- console
Write-Output ([string]::Format($inv, "{0} distinct deadlocks from {1} file(s), {2:yyyy-MM-dd HH:mm} to {3:yyyy-MM-dd HH:mm} ({4}), {5} patterns", $all.Count, $files.Count, $span0, $span1, $tz.Id, $patterns.Count))
foreach ($p in ($patterns | Select-Object -First 10)) {
    Write-Output ("`n[{0}] {1}x {2} .. {3} {4}`n   sides:  {5}`n   locked: {6}`n   tags:   {7}`n   lost:   {8}" -f $p.pattern, $p.count, $p.first, $p.last, $p.status, $p.sides, $p.objects, $p.tags, $p.victims)
}
if ($gone) { Write-Output ("`nGone since the comparison run: " + (($gone | ForEach-Object { "$($_.pattern) ($($_.sides))" }) -join '; ')) }
Write-Output "`nWrote deadlock_patterns.md, deadlock_patterns.csv, deadlock_processes.csv and graphs\ in $OutDir"
