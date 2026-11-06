<#
  Render a report_shell.html page (markdown + mermaid) to PDF, and optionally a PNG screenshot, with headless Edge or Chrome.
  Local only: it opens a file:// URL and needs internet access for the jsDelivr scripts. It touches no database.

  .\render_pdf.ps1 -Html C:\repo\docs\Report.html                  # writes Report.pdf next to it
  .\render_pdf.ps1 -Html C:\repo\docs\Report.html -Screenshot      # also Report.png (first screen) to check the layout
#>
param(
    [Parameter(Mandatory)] [string] $Html,
    [string] $Pdf,
    [switch] $Screenshot,
    [int] $BudgetMs = 10000
)
$ErrorActionPreference = 'Stop'
$Html = (Resolve-Path $Html).Path
if (-not $Pdf) { $Pdf = [IO.Path]::ChangeExtension($Html, '.pdf') }

$browser = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw 'Edge or Chrome not found' }

$url = 'file:///' + ($Html -replace '\\', '/')
$common = @('--headless=new', '--disable-gpu', "--virtual-time-budget=$BudgetMs")

Start-Process $browser -ArgumentList ($common + @('--no-pdf-header-footer', "--print-to-pdf=$Pdf", $url)) -Wait
"PDF: $Pdf ($([math]::Round((Get-Item $Pdf).Length / 1KB)) KB)"

if ($Screenshot) {
    $png = [IO.Path]::ChangeExtension($Html, '.png')
    Start-Process $browser -ArgumentList ($common + @('--window-size=1100,1800', "--screenshot=$png", $url)) -Wait
    "Screenshot: $png"
}
