<#
.SYNOPSIS
    Local only: compares module definitions before and after a release and says which objects really changed.

.DESCRIPTION
    -After is a snapshot taken with 21_release_definitions.sql. -Before is either an earlier snapshot from the same
    script (best: exact text, with hashes) or a folder of .sql files (a source-control or nightly sync copy), one
    object per file, named <name>.sql or <schema>.<name>.sql.

    For every object it reports:
      same          the stored text is identical
      same-norm     identical once line endings, trailing spaces, blank lines, the SSMS script preamble and the
                    module header's first keyword are ignored (a re-apply, not a change)
      CHANGED       the code differs: lines added / removed, version note before -> after, your marker before -> after
      NEW           only after the release
      GONE          only before (snapshot to snapshot; with a folder as -Before this is listed as "only in folder")
      encrypted     no text on one side; judge it from Query Store (19) instead
    A marker present before and missing after is flagged MARKER LOST: the release overwrote a local change.

    Every snapshot block is checked against the SHA-256 the server computed, so a capture damaged by an editor,
    line-ending conversion or truncation is reported instead of producing false differences.

    Writes to -OutDir: definition_changes.md (the table), and for each changed object before\<name>.sql,
    after\<name>.sql and diff\<name>.diff (a unified diff of the normalized text, made with git if it is on PATH).
    Touches no server.

.EXAMPLE
    pwsh -NoProfile -File Compare-Definitions.ps1 -Before defs_20260105_0800.txt -After defs_20260106_0900.txt -OutDir release_0105 -Marker 'MyCo 20'
.EXAMPLE
    pwsh -NoProfile -File Compare-Definitions.ps1 -Before C:\src\db\StoredProcedures -After defs_after.txt -OutDir release_0105 -Name 'app.*'
.NOTES
    A value with a space (a marker such as 'MyCo 2026') can arrive split in two, depending on the calling shell.
    Parameters are named-only, so a split value stops the script with an error instead of landing in another one;
    if that happens, run it as pwsh -NoProfile -Command "& '<path>\Compare-Definitions.ps1' -Marker 'MyCo 2026' ...".
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Marker,
    [string]$VersionTag = 'VERSION:',
    [string]$Name = '*'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-Text([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return $utf8.GetString($bytes, 3, $bytes.Length - 3) }
    return $utf8.GetString($bytes)
}

function Get-Sha([string]$text) {
    # The server hashes nvarchar text, i.e. UTF-16LE bytes
    $sha = [Security.Cryptography.SHA256Managed]::new()
    try { '0x' + (($sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($text)) | ForEach-Object { $_.ToString('X2') }) -join '') }
    finally { $sha.Dispose() }
}

# Snapshot from 21_release_definitions.sql: name -> object
function Read-Snapshot([string]$path) {
    $text = Read-Text $path
    $rx = [regex]'(?m)^@@@@ (?<name>[^|\r\n]+?) \| (?<type>\w+) \| (?<hash>\S+) \| (?<mod>[^\r\n]*)\r?\n'
    $ms = $rx.Matches($text)
    $map = [ordered]@{}
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $m = $ms[$i]
        $start = $m.Index + $m.Length
        $end = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $text.Length }
        $body = $text.Substring($start, $end - $start)
        # sqlcmd ends each row with CRLF; the last row may be followed by blank lines
        $hash = $m.Groups['hash'].Value
        $ok = $null
        if ($hash -ne 'encrypted') {
            $cands = @($body, ($body -replace '\r\n$', ''), ($body -replace '(\r?\n)+$', ''))
            foreach ($c in $cands) { if ((Get-Sha $c) -eq $hash) { $body = $c; $ok = $true; break } }
            if (-not $ok) { $ok = $false; $body = $body -replace '(\r?\n)+$', '' }
        }
        $map[$m.Groups['name'].Value.Trim()] = [pscustomobject]@{
            type = $m.Groups['type'].Value; hash = $hash; modified = $m.Groups['mod'].Value.Trim()
            text = if ($hash -eq 'encrypted') { $null } else { $body }; capture_ok = $ok
        }
    }
    if ($map.Count -eq 0) { throw "No '@@@@' blocks in $path. Was it written by 21_release_definitions.sql with -y 0 -f 65001?" }
    return $map
}

function Read-Folder([string]$dir) {
    $map = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Filter *.sql) {
        $map[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = [pscustomobject]@{
            type = ''; hash = ''; modified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); text = (Read-Text $f.FullName); capture_ok = $null
        }
    }
    return $map
}

function Normalize([string]$s) {
    if ($null -eq $s) { return $null }
    $lines = ($s -replace "`r", '') -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object {
        $_.Trim() -ne '' -and
        $_ -notmatch '^\s*GO\s*$' -and
        $_ -notmatch '^\s*SET\s+(ANSI_NULLS|QUOTED_IDENTIFIER)\s+(ON|OFF)\s*;?\s*$' -and
        $_ -notmatch '^\s*USE\s+\[?[^\]]+\]?\s*;?\s*$' -and
        $_ -notmatch '^\s*/\*{6} Object:.*\*{6}/\s*$'
    }
    $t = $lines -join "`n"
    # The module header's first keyword differs between a script file and stored text (and between deploy styles);
    # replace only that first keyword, and treat PROC and PROCEDURE alike.
    $hdr = [regex]'(?im)^(\s*)\w+(\s+OR\s+\w+)?\s+(PROC|PROCEDURE|FUNCTION|TRIGGER|VIEW)\b'
    return $hdr.Replace($t, { param($m) $m.Groups[1].Value + 'MODULE ' + ($(if ($m.Groups[3].Value -match '^PROC') { 'PROCEDURE' } else { $m.Groups[3].Value.ToUpper() })) }, 1)
}

function Get-Version([string]$s) {
    if (-not $s -or -not $VersionTag) { return '' }
    $i = $s.IndexOf($VersionTag, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return '' }
    return (($s.Substring($i, [Math]::Min(40, $s.Length - $i)) -replace '\s+', ' ').Trim())
}

function Short([string]$n) { if ($n -match '\.') { $n.Substring($n.LastIndexOf('.') + 1) } else { $n } }
function Safe([string]$n) { $n -replace '[\\/:*?"<>|]', '_' }

$snapAfter = Read-Snapshot $After
$beforeIsFolder = Test-Path -LiteralPath $Before -PathType Container
$snapBefore = if ($beforeIsFolder) { Read-Folder $Before } else { Read-Snapshot $Before }

# Folder files may be named without the schema: match those on the object name
$beforeKey = @{}
foreach ($k in $snapBefore.Keys) { $beforeKey[$k.ToLower()] = $k; if ($beforeIsFolder) { $beforeKey['~' + (Short $k).ToLower()] = $k } }
function Find-Before([string]$n) {
    if ($beforeKey.ContainsKey($n.ToLower())) { return $beforeKey[$n.ToLower()] }
    if ($beforeIsFolder -and $beforeKey.ContainsKey('~' + (Short $n).ToLower())) { return $beforeKey['~' + (Short $n).ToLower()] }
    return $null
}

foreach ($d in 'before', 'after', 'diff') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $OutDir $d) }
$git = Get-Command git -ErrorAction SilentlyContinue
$matched = @{}

$rows = foreach ($n in $snapAfter.Keys) {
    if ($n -notlike $Name) { continue }
    $a = $snapAfter[$n]
    $bk = Find-Before $n
    if ($bk) { $matched[$bk] = $true }
    $b = if ($bk) { $snapBefore[$bk] } else { $null }
    $status = ''; $plus = ''; $minus = ''
    if (-not $b) { $status = $(if ($beforeIsFolder) { 'not in folder' } else { 'NEW' }) }
    elseif ($null -eq $a.text -or $null -eq $b.text) { $status = 'encrypted' }
    elseif ($a.text -ceq $b.text) { $status = 'same' }
    else {
        $na = Normalize $a.text; $nb = Normalize $b.text
        if ($na -ceq $nb) { $status = 'same-norm' }
        else {
            $status = 'CHANGED'
            # multiset line difference: how many lines were added and removed
            # (an ordinal dictionary: a PowerShell hashtable would treat lines differing only in case as equal)
            $count = New-Object 'System.Collections.Generic.Dictionary[string,int]'
            foreach ($l in ($nb -split "`n")) { if ($count.ContainsKey($l)) { $count[$l]++ } else { $count[$l] = 1 } }
            $added = 0
            foreach ($l in ($na -split "`n")) { if ($count.ContainsKey($l) -and $count[$l] -gt 0) { $count[$l]-- } else { $added++ } }
            $removed = 0; foreach ($v in $count.Values) { $removed += $v }
            $plus = "+$added"; $minus = "-$removed"
            $file = Safe $n
            [IO.File]::WriteAllText((Join-Path $OutDir "before\$file.sql"), $b.text, $utf8)
            [IO.File]::WriteAllText((Join-Path $OutDir "after\$file.sql"), $a.text, $utf8)
            if ($git) {
                $tb = Join-Path $OutDir "diff\$file.before.norm"; $ta = Join-Path $OutDir "diff\$file.after.norm"
                [IO.File]::WriteAllText($tb, $nb + "`n", $utf8); [IO.File]::WriteAllText($ta, $na + "`n", $utf8)
                $diff = & $git.Source diff --no-index --no-color -U3 -- $tb $ta 2>$null
                [IO.File]::WriteAllText((Join-Path $OutDir "diff\$file.diff"), (($diff | Out-String) -replace "`r", ''), $utf8)
                Remove-Item -LiteralPath $tb, $ta
            }
        }
    }
    $mb = if ($Marker -and $b -and $b.text) { $b.text.Contains($Marker) } else { $false }
    $ma = if ($Marker -and $a.text) { $a.text.Contains($Marker) } else { $false }
    [pscustomobject]@{
        object     = $n
        type       = $a.type
        status     = $status
        lines      = if ($plus) { "$plus / $minus" } else { '' }
        version    = $(if ($b) { $vb = Get-Version $b.text; $va = Get-Version $a.text; if ($vb -ne $va) { "$vb -> $va" } else { $va } } else { Get-Version $a.text })
        marker     = $(if (-not $Marker) { '' } elseif ($mb -and -not $ma) { 'MARKER LOST' } elseif ($ma -and -not $mb) { 'marker added' } elseif ($ma) { 'kept' } else { '' })
        modified   = $a.modified
        capture    = $(if ($a.capture_ok -eq $false -or ($b -and $b.capture_ok -eq $false)) { 'HASH MISMATCH' } else { '' })
    }
}
$gone = foreach ($k in $snapBefore.Keys) {
    if ($matched.ContainsKey($k)) { continue }
    if ($k -notlike $Name -and (Short $k) -notlike $Name) { continue }
    [pscustomobject]@{ object = $k; type = $snapBefore[$k].type; status = $(if ($beforeIsFolder) { 'only in folder' } else { 'GONE' }); lines = ''; version = (Get-Version $snapBefore[$k].text); marker = ''; modified = $snapBefore[$k].modified; capture = '' }
}
$all = @($rows) + @($gone)
$rank = { param($r) if ($r.marker -eq 'MARKER LOST') { 0 } elseif ($r.status -eq 'CHANGED') { 1 } elseif ($r.status -in 'NEW', 'GONE') { 2 } elseif ($r.status -eq 'encrypted') { 3 } elseif ($r.status -in 'only in folder', 'not in folder') { 5 } else { 4 } }
$all = $all | Sort-Object @{ Expression = { & $rank $_ } }, object

$summary = $all | Group-Object status | Sort-Object Name | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
$bad = @($all | Where-Object capture -eq 'HASH MISMATCH').Count

$md = New-Object Text.StringBuilder
[void]$md.AppendLine('# Definition changes')
[void]$md.AppendLine()
[void]$md.AppendLine("- Before: ``$Before``" + $(if ($beforeIsFolder) { ' (folder of scripts: no hashes, and it may lag production)' } else { ' (snapshot)' }))
[void]$md.AppendLine("- After: ``$After``")
[void]$md.AppendLine("- Objects compared: $(@($rows).Count). " + ($summary -join '; ') + '.')
if ($bad) { [void]$md.AppendLine("- **$bad block(s) failed the hash check**: the snapshot file was altered after capture (editor, line endings). Take it again before trusting those rows.") }
[void]$md.AppendLine("- 'same-norm' objects were re-applied with no code change. Diffs of CHANGED objects are in ``diff\``.")
[void]$md.AppendLine()
[void]$md.AppendLine('| Object | Type | Status | Lines | Version | Marker | Modified | Capture |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|')
$listed = { param($r) $r.status -notin 'same', 'same-norm', 'only in folder' -or $r.marker -in 'MARKER LOST', 'marker added' -or $r.capture }
foreach ($r in $all | Where-Object { & $listed $_ }) {
    [void]$md.AppendLine("| ``$($r.object)`` | $($r.type) | $($r.status) | $($r.lines) | $($r.version) | $($r.marker) | $($r.modified) | $($r.capture) |")
}
$unchanged = @($all | Where-Object { -not (& $listed $_) }).Count
$kept = @($all | Where-Object marker -eq 'kept').Count
[void]$md.AppendLine()
[void]$md.AppendLine("$unchanged object(s) unchanged (same, same-norm, or only in the folder) are not listed." + $(if ($Marker) { " $kept object(s) kept the marker." } else { '' }))
[IO.File]::WriteAllText((Join-Path $OutDir 'definition_changes.md'), $md.ToString(), $utf8)

$all | Where-Object { & $listed $_ } |
    Format-Table object, type, status, lines, version, marker, capture -AutoSize | Out-String -Width 220
($summary -join '  ') + "  ->  " + (Join-Path $OutDir 'definition_changes.md')
