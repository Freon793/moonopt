# Cross-checks the proven optima in bench/mip-report.md against MIPLIB's own optimum
# table.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench/check-mip-objectives.ps1
#
# A branch and bound that proves optimality is making a much stronger claim than a
# relaxation: not "the optimum is at least this good", but "this is the optimum". So
# the check here is equality, not an inequality - and every instance it applies to is
# one where an outside authority has published the answer.
#
# The table also lets the run be wrong in the useful direction: a proven objective
# *below* the published optimum would be a violation of the published value rather
# than of this code, and the script says so instead of passing it silently.

param(
  [string]$Report = (Join-Path $PSScriptRoot "mip-report.md"),
  [string]$SolutionFile = "https://miplib.zib.de/downloads/miplib2017-v26.solu",
  [double]$Tolerance = 1.0e-6
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

if (-not (Test-Path $Report)) {
  Write-Error "mip report not found: $Report (run bench/report-mip.ps1 first)"
  exit 2
}

$cache = Join-Path $env:TEMP "miplib-optima.solu"
$fresh = $false
try {
  Invoke-WebRequest -Uri $SolutionFile -UseBasicParsing -OutFile $cache -TimeoutSec 90
  $fresh = $true
} catch {
  if (Test-Path $cache) {
    Write-Host ("download failed ({0}); using the cached table" -f $_.Exception.Message)
  } else {
    Write-Error ("cannot download the optimum table and no cached copy exists: " + $_.Exception.Message)
    exit 2
  }
}
if ($fresh) {
  Write-Host "optimum table downloaded"
}

$optima = @{}
foreach ($line in ([IO.File]::ReadAllText($cache) -split "`n")) {
  $fields = ($line.Trim() -split '\s+')
  if ($fields.Count -ge 3 -and $fields[0] -eq '=opt=') {
    $optima[$fields[1]] = [double]$fields[2]
  }
}
Write-Host ("optimum table: {0} entries" -f $optima.Count)

$checked = 0
$violations = 0
$unknown = 0
$unverified = 0
foreach ($line in [IO.File]::ReadAllLines($Report)) {
  if ($line -notmatch '^\|\s*([A-Za-z0-9_.-]+)\s*\|.*\|\s*optimal\s*\|\s*(\S+)\s*\|.*\|\s*(\d+)\s*\|\s*(\d+)\s*\|') { continue }
  $name = $Matches[1]
  $objective = [double]$Matches[2]
  $nodes = [int]$Matches[3]
  $verified = [int]$Matches[4]
  if ($verified -ne $nodes) {
    $unverified++
    Write-Host ("UNVERIFIED {0}: {1} nodes, {2} verified" -f $name, $nodes, $verified)
  }
  if (-not $optima.ContainsKey($name)) {
    $unknown++
    continue
  }
  $checked++
  $best = $optima[$name]
  $within = [Math]::Abs($objective - $best) -le $Tolerance * (1.0 + [Math]::Abs($best))
  if (-not $within) {
    $violations++
    Write-Host ("VIOLATION {0}: proven {1} != optimum {2}" -f $name, $objective, $best)
  } else {
    Write-Host ("ok        {0}: proven {1} == optimum {2}" -f $name, $objective, $best)
  }
}
Write-Host ""
Write-Host ("checked {0}, violations {1}, not in the table {2}, unverified nodes {3}" -f $checked, $violations, $unknown, $unverified)
if ($violations -gt 0 -or $unverified -gt 0) {
  exit 1
}
