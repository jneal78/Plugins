<#
.SYNOPSIS
    Fails if any bundled read-only SQL script contains a statement that writes, or a write keyword a guardrail would block.

.DESCRIPTION
    Every .sql file under skills/ must be safe to run on production by Claude: no DML or DDL, no temp tables, no EXEC,
    and none of those words even in comments (production guardrails scan script text, not just statements).
    Templates in core/templates/patch/ are exempt: they are written for a DBA to run.

    Keywords are not the only way a script can do more than read, so it also fails on:
      - sqlcmd commands (:!! runs an operating-system command, :connect switches server, :r pulls in another file,
        :out redirects output, :setvar and the rest). One reviewed :r include is allowed, listed in $allowedInclude;
      - a batch whose first statement is a bare name: T-SQL runs that as a procedure call without EXEC;
      - for .sql files, a temp table.

    -Path checks other files or folders the same way, for example a site's dashboard groups file and business-metric
    SQL, which the dashboard runs on the server too. Build-Dashboard.ps1 calls it that way before every run.

    Local only: this reads files and touches no server.

.EXAMPLE
    pwsh -File tools/Test-ReadOnlyScripts.ps1
.EXAMPLE
    pwsh -File tools/Test-ReadOnlyScripts.ps1 -Path ~\.sqlserver-dba\groups_mysite.sql, ~\.sqlserver-dba\business_mysite.sql
#>
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Path
)
$ErrorActionPreference = 'Stop'

# Whole words, case-insensitive. This tool runs locally only; never run it in a command that names a server.
$words = @('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'TRUNCATE', 'DROP', 'CREATE', 'ALTER', 'EXEC', 'EXECUTE', 'INTO',
           'GRANT', 'REVOKE', 'DENY', 'BACKUP', 'RESTORE', 'SHUTDOWN', 'KILL', 'RECONFIGURE', 'DBCC', 'BULK',
           'OPENROWSET', 'OPENQUERY', 'OPENDATASOURCE', 'SP_CONFIGURE')
$rx = [regex]::new('\b(' + ($words -join '|') + ')\b', 'IgnoreCase')
$tempTable = [regex]::new('(^|[\s(,])#\w+', 'None')
# sqlcmd commands start a line with ':' (or '!!'); the include of the reviewed groups file is the one allowed
$sqlcmdCmd = [regex]::new('^\s*(:?!!|:(r|connect|out|error|perftrace|setvar|listvar|reset|ed|exit|quit|on\s+error|serverlist|xml|help)\b)', 'IgnoreCase')
$allowedInclude = @{ 'dash_workload.sql' = ':r $(GroupsFile)' }
# The first statement of a batch must start with one of these; anything else (a bare name) is an implicit procedure call.
# A batch may also start with '(' or ',' in a VALUES fragment that another file includes.
$batchStarts = [regex]::new('^\s*(;?WITH|SELECT|SET|DECLARE|IF|WHILE|BEGIN|PRINT|WAITFOR|RAISERROR|THROW|RETURN|USE|[(,])', 'IgnoreCase')

# pwsh -File passes a list as one string, so ';' and ',' separate paths too
$Path = @($Path | ForEach-Object { $_ -split '[;,]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Path) {
    $files = @(foreach ($p in $Path) {
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) { Get-ChildItem $item.FullName -Recurse -File -Include *.sql, *.ps1 } else { $item }
    })
} else {
    # PowerShell scripts under skills/ are checked too: guardrails scan a script run with -File the same way, and a
    # write keyword anywhere in it (a comment, a list of words) makes the guardrail treat the run as a write.
    $files = @(Get-ChildItem (Join-Path $Root 'skills') -Recurse -File -Include *.sql, *.ps1)
}

function Rel([string]$full) { if ($Path) { $full } else { [IO.Path]::GetRelativePath($Root, $full) } }

$hits = foreach ($f in $files) {
    $isSql = $f.Extension -eq '.sql'
    $rel = Rel $f.FullName
    $lines = [IO.File]::ReadAllLines($f.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($m in $rx.Matches($line)) { [pscustomobject]@{ file = $rel; line = $i + 1; word = $m.Value; text = $line.Trim() } }
        if ($isSql -and $tempTable.IsMatch($line) -and $line -notmatch '^\s*--') { [pscustomobject]@{ file = $rel; line = $i + 1; word = '#temp'; text = $line.Trim() } }
        if ($isSql -and $sqlcmdCmd.IsMatch($line)) {
            $ok = $allowedInclude.ContainsKey($f.Name) -and $line.Trim() -eq $allowedInclude[$f.Name]
            if (-not $ok) { [pscustomobject]@{ file = $rel; line = $i + 1; word = 'sqlcmd command'; text = $line.Trim() } }
        }
    }
    if ($isSql) {
        # First statement of each batch: blank out comments (keeping line numbers), then look after each GO
        $text = [IO.File]::ReadAllText($f.FullName)
        $text = [regex]::Replace($text, '(?s)/\*.*?\*/', { param($m) [regex]::Replace($m.Value, '[^\r\n]', ' ') })
        $text = [regex]::Replace($text, '--[^\r\n]*', '')
        $clean = $text -split '\r?\n'
        $atStart = $true
        for ($i = 0; $i -lt $clean.Count; $i++) {
            $l = $clean[$i]
            if ($l -match '^\s*GO\s*(\d+\s*)?$') { $atStart = $true; continue }
            if (-not $atStart -or $l -match '^\s*$' -or $sqlcmdCmd.IsMatch($l)) { continue }
            $atStart = $false
            if (-not $batchStarts.IsMatch($l)) { [pscustomobject]@{ file = $rel; line = $i + 1; word = 'batch starts with a bare name (an implicit procedure call?)'; text = $l.Trim() } }
        }
    }
}
if ($hits) {
    $hits | Format-Table -AutoSize -Wrap | Out-String -Width 250
    "{0} problem(s) in {1} file(s)." -f @($hits).Count, @($hits | Select-Object -Unique file).Count
    exit 1
}
"Read-only: {0} SQL and {1} PowerShell files checked." -f @($files | Where-Object Extension -eq '.sql').Count, @($files | Where-Object Extension -eq '.ps1').Count
