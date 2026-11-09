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

$patterns = @(Get-Content $DenyList | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object {
    [regex]::new($_.Trim(), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
})
# A deny-list with no terms would report "clean" without checking anything
if ($patterns.Count -eq 0) { Write-Error "The deny-list $DenyList has no terms: nothing would be checked."; exit 1 }

# Files that are published: skip git's own folder, files git ignores (rendered PDFs, local output) and binary files,
# whose compressed bytes match short terms by chance.
$ignored = @{}
$gitIgnored = & git -C $Root ls-files --others --ignored --exclude-standard 2>$null
foreach ($p in @($gitIgnored)) { if ($p) { $ignored[(Join-Path $Root $p).Replace('/', '\')] = 1 } }
$binary = '\.(pdf|png|jpe?g|gif|ico|zip|7z|xlsx?|docx?|pptx?|sqlplan|bak|mdf|ldf)$'
$files = Get-ChildItem $Root -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Name -notmatch $binary -and -not $ignored.ContainsKey($_.FullName) }
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

# Git history is published with the repository: authors, committers and messages are checked too.
$commits = 0
$log = & git -C $Root log --all --format='%h%x09%an <%ae>%x09%cn <%ce>%x09%s %b%x1e' 2>$null
if ($LASTEXITCODE -eq 0 -and $log) {
    foreach ($c in (($log -join "`n") -split [char]0x1e)) {
        $c = $c.Trim()
        if (-not $c) { continue }
        $commits++
        foreach ($p in $patterns) {
            if ($p.IsMatch($c)) {
                [void]($hits = @($hits) + [pscustomobject]@{ file = 'git history ' + $c.Substring(0, 7); line = 0; term = $p.ToString(); text = ($c -replace '\s+', ' ').Substring(0, [math]::Min(140, ($c -replace '\s+', ' ').Length)) })
            }
        }
    }
}

if ($hits) {
    $hits | Format-Table -AutoSize -Wrap | Out-String -Width 250
    "{0} hit(s) in {1} file(s) or commits. Replace them with neutral names before publishing." -f @($hits).Count, @($hits | Select-Object -Unique file).Count
    exit 1
}
"Clean: {0} files and {1} commits checked against {2} terms." -f $files.Count, $commits, $patterns.Count
