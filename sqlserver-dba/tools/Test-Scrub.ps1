<#
.SYNOPSIS
    Fails if any organization-specific term appears in the plugin. Run before every commit and release.

.DESCRIPTION
    The deny-list is NOT kept in this repository, because the list itself names an organization's systems. It is read
    from (first found):
      -DenyList <file>
      $env:SQLSERVER_DBA_SITE\scrub-denylist.txt
      ~/.sqlserver-dba/scrub-denylist.txt
    One .NET regex per line, case-insensitive; start a line with (?-i) for a case-sensitive term; # starts a comment.

.EXAMPLE
    pwsh -File tools/Test-Scrub.ps1
#>
param(
    [string]$DenyList,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
if (-not $DenyList) {
    $candidates = @()
    if ($env:SQLSERVER_DBA_SITE) { $candidates += Join-Path $env:SQLSERVER_DBA_SITE 'scrub-denylist.txt' }
    $candidates += Join-Path $HOME '.sqlserver-dba/scrub-denylist.txt'
    $DenyList = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $DenyList -or -not (Test-Path $DenyList)) { throw 'No deny-list found. Pass -DenyList or set up a site folder (see core/site.md).' }

$patterns = Get-Content $DenyList | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object {
    [regex]::new($_.Trim(), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
$files = Get-ChildItem $Root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$hits = foreach ($f in $files) {
    $n = 0
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        $n++
        foreach ($p in $patterns) {
            $m = $p.Match($line)
            if ($m.Success) {
                [pscustomobject]@{ file = [IO.Path]::GetRelativePath($Root, $f.FullName); line = $n; term = $p.ToString(); text = $line.Trim().Substring(0, [math]::Min(140, $line.Trim().Length)) }
            }
        }
    }
}
if ($hits) {
    $hits | Format-Table -AutoSize -Wrap | Out-String -Width 250
    "{0} hit(s) in {1} file(s). Replace them with neutral names before committing." -f @($hits).Count, @($hits | Select-Object -Unique file).Count
    exit 1
}
"Clean: {0} files checked against {1} terms." -f $files.Count, $patterns.Count
