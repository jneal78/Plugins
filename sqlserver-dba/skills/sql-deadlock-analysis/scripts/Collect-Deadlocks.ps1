# .SYNOPSIS
#     Keeps deadlock graphs that an Extended Events session would otherwise roll away. Read-only on the instance.
#
# .DESCRIPTION
#     Reruns 14_deadlock_graphs_file.sql (or 15 for a ring buffer) every -EveryHours for -Runs runs and saves each
#     result as <OutDir>\graphs_<yyyyMMdd_HHmm>.json. Analyze-Deadlocks.ps1 combines them and counts a deadlock seen
#     by two runs once. Bounded by design: it stops after -Runs runs.
#
#     Use it when the event files hold only a few hours and no dedicated deadlock session exists yet
#     (core/templates/deadlock_xe_session_TEMPLATE.sql, for the DBA). Each run costs what one run of 14 costs
#     (typically 5-30 s of one core), so keep -EveryHours at about half of the files' reach (14's oldest_event_utc).
#
#     A guardrail that resolves the target of every sqlcmd call may not accept the instance name passed as a
#     parameter. If it blocks this script, have the DBA run it (or a scheduled task), rather than rewording it.
#
# .EXAMPLE
#     pwsh -NoProfile -File Collect-Deadlocks.ps1 -Server SQLPROD01 -EveryHours 2 -Runs 12 -OutDir C:\work\deadlocks\raw
param(
    [Parameter(Mandatory)][string]$Server,
    [double]$EveryHours = 2,
    [ValidateRange(1, 200)][int]$Runs = 12,
    [string]$OutDir = (Join-Path (Get-Location) 'deadlock_raw'),
    [string]$Script = (Join-Path $PSScriptRoot '14_deadlock_graphs_file.sql'),
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$prefix = if ((Split-Path $Script -Leaf) -like '15*') { 'graphs_ring_' } else { 'graphs_file_' }

for ($i = 1; $i -le $Runs; $i++) {
    $out = Join-Path $OutDir ($prefix + (Get-Date).ToString('yyyyMMdd_HHmm', [Globalization.CultureInfo]::InvariantCulture) + '.json')
    & sqlcmd -S $Server -d master -E -I -X -y 0 -f 65001 -t $TimeoutSeconds -i $Script -o $out
    $code = $LASTEXITCODE
    $n = if (Test-Path $out) { ([regex]::Matches([IO.File]::ReadAllText($out), '"graph"')).Count } else { 0 }
    Write-Output ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:yyyy-MM-dd HH:mm} run {1}/{2}: exit {3}, {4} graphs held by the session', (Get-Date), $i, $Runs, $code, $n))
    if ($i -lt $Runs) { Start-Sleep -Seconds ([int]($EveryHours * 3600)) }
}
