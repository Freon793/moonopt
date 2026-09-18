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

# The columns are read by name, from the table's own header. Reading them by position is
# how this script came to compare a `cuts` count against a `verified` count: the `cuts`
# column was inserted between them and every position after it moved, so the check reported
# "UNVERIFIED 22433: 33 nodes, 20 verified" for a run whose 33 relaxations were all
# verified. A checker that reads the report by position is a checker that has to be edited
# whenever the report grows a column, and the failure mode of forgetting is a false alarm.
$lines = [IO.File]::ReadAllLines($Report)
$header = $null
foreach ($line in $lines) {
  if ($line -match '^\|\s*instance\s*\|') {
    $header = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
    break
  }
}
if ($null -eq $header) {
  Write-Error "no instance table found in $Report"
  exit 2
}
$column = @{}
for ($k = 0; $k -lt $header.Count; $k++) {
  $column[$header[$k]] = $k
}
foreach ($needed in @('instance', 'result', 'objective', 'nodes', 'verified')) {
  if (-not $column.ContainsKey($needed)) {
    Write-Error ("the report table has no '{0}' column; columns are: {1}" -f $needed, ($header -join ', '))
    exit 2
  }
}

foreach ($line in $lines) {
  if ($line -notmatch '^\|') { continue }
  $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
  if ($cells.Count -ne $header.Count) { continue }
  if ($cells[$column['result']] -ne 'optimal') { continue }
  $name = $cells[$column['instance']]
  if (-not ($cells[$column['objective']] -as [double])) { continue }
  $objective = [double]$cells[$column['objective']]
  $nodes = [int]$cells[$column['nodes']]
  $verified = [int]$cells[$column['verified']]
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
