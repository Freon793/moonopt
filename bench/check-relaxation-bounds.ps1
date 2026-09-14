# Cross-checks the objectives in bench/solve-report.md against MIPLIB's own
# optimum table.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench/check-relaxation-bounds.ps1
#
# A relaxation of a minimisation model can only be at or below its optimum, and
# the same holds in the maximisation direction after the sign convention. So every
# solved instance gives a checkable inequality against an authority that is
# completely independent of this code: if a relaxation ever came out above the
# published optimum, the kernel would be wrong.
#
# The check is not a proof of correctness, but it is a cheap way to catch a whole
# class of errors, and it is recorded rather than assumed.

param(
  [string]$Report = (Join-Path $PSScriptRoot "solve-report.md"),
  [string]$SolutionFile = "https://miplib.zib.de/downloads/miplib2017-v26.solu",
  [double]$Tolerance = 1.0e-6
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

if (-not (Test-Path $Report)) {
  Write-Error "solve report not found: $Report (run bench/report-solve.ps1 first)"
  exit 2
}

$cache = Join-Path $env:TEMP "miplib-optima.solu"
try {
  Invoke-WebRequest -Uri $SolutionFile -UseBasicParsing -OutFile $cache -TimeoutSec 90
} catch {
  Write-Error ("cannot download the optimum table: " + $_.Exception.Message)
  exit 2
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
foreach ($line in [IO.File]::ReadAllLines($Report)) {
  if ($line -notmatch '^\|\s*([A-Za-z0-9_.-]+)\s*\|.*\|\s*optimal\s*\|\s*(\S+)\s*\|') { continue }
  $name = $Matches[1]
  $objective = [double]$Matches[2]
  if (-not $optima.ContainsKey($name)) {
    $unknown++
    continue
  }
  $checked++
  $best = $optima[$name]
  $within = $objective -le $best + $Tolerance * (1.0 + [Math]::Abs($best))
  if (-not $within) {
    $violations++
    Write-Host ("VIOLATION {0}: relaxation {1} > optimum {2}" -f $name, $objective, $best)
  } else {
    Write-Host ("ok        {0}: relaxation {1} <= optimum {2}" -f $name, $objective, $best)
  }
}
Write-Host ""
Write-Host ("checked {0}, violations {1}, not in the table {2}" -f $checked, $violations, $unknown)
if ($violations -gt 0) {
  exit 1
}
