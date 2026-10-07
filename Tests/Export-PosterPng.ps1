# Exports IntuneRemediations-Poster.pptx to IntuneRemediations-Poster.png (A1, 200 dpi).
# Requires PowerPoint (Office 16+). Run from anywhere:
#   powershell -File Tests\Export-PosterPng.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pptx = Join-Path $root 'IntuneRemediations-Poster.pptx'
$png  = Join-Path $root 'IntuneRemediations-Poster.png'
if (-not (Test-Path -LiteralPath $pptx)) { throw "Missing $pptx - run Tests\Build-Poster.py first" }

$pp = New-Object -ComObject PowerPoint.Application
try {
    $pres = $pp.Presentations.Open($pptx, $true, $false, $false)
    # A1 landscape = 33.11 x 23.39 in -> 200 dpi = 6622 x 4678 px
    $pres.Slides.Item(1).Export($png, 'PNG', 6622, 4678)
    $pres.Close()
} finally {
    $pp.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($pp) | Out-Null
}
Write-Output "Exported: $png"
