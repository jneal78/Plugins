<#
.SYNOPSIS
    Fails if any bundled read-only SQL script contains a statement that writes, or a write keyword a guardrail would block.

.DESCRIPTION
    Every .sql file under skills/ must be safe to run on production by Claude: no DML or DDL, no temp tables, no EXEC,
    and none of those words even in comments (production guardrails scan script text, not just statements).
    Templates in core/templates/patch/ are exempt: they are written for a DBA to run.
    Local only: this reads files and touches no server.

.EXAMPLE
    pwsh -File tools/Test-ReadOnlyScripts.ps1
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'

# Whole words, case-insensitive. This tool runs locally only; never run it in a command that names a server.
$words = @('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'TRUNCATE', 'DROP', 'CREATE', 'ALTER', 'EXEC', 'EXECUTE', 'INTO',
           'GRANT', 'REVOKE', 'DENY', 'BACKUP', 'RESTORE', 'SHUTDOWN', 'KILL', 'RECONFIGURE', 'DBCC', 'BULK',
           'OPENROWSET', 'SP_CONFIGURE')
$rx = [regex]::new('\b(' + ($words -join '|') + ')\b', 'IgnoreCase')
$tempTable = [regex]::new('(^|[\s(,])#\w+', 'None')

$files = Get-ChildItem (Join-Path $Root 'skills') -Recurse -File -Filter *.sql
$hits = foreach ($f in $files) {
    $n = 0
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        $n++
        foreach ($m in $rx.Matches($line)) { [pscustomobject]@{ file = [IO.Path]::GetRelativePath($Root, $f.FullName); line = $n; word = $m.Value; text = $line.Trim() } }
        if ($tempTable.IsMatch($line) -and $line -notmatch '^\s*--') { [pscustomobject]@{ file = [IO.Path]::GetRelativePath($Root, $f.FullName); line = $n; word = '#temp'; text = $line.Trim() } }
    }
}
if ($hits) {
    $hits | Format-Table -AutoSize -Wrap | Out-String -Width 250
    "{0} problem(s) in {1} file(s)." -f @($hits).Count, @($hits | Select-Object -Unique file).Count
    exit 1
}
"Read-only: {0} SQL files checked." -f $files.Count
