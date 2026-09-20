# Runs the kernel over the instances in the manifest and writes
# bench/solve-report.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-solve.ps1
#
# Instances whose row count exceeds -MaxRows are reported as skipped rather than
# attempted: the kernel keeps a dense basis inverse, so a large model needs the
# sparse factorization that is the next milestone, and a ten minute hang would
# look like a defect instead of a boundary.
#
# The script refuses to write a report it cannot stand behind: a non-zero exit
# from the kernel, or a run that did not cover every manifest entry, is an error.
# A partial run presented as a whole one is worse than no report at all - a crash
# once produced a "successful" 22 of 33 instance report.
#
# The report records the toolchain version and the commit it came from, so every
# number in it can be traced back to the code that produced it.

param(
  [string]$Manifest = (Join-Path $PSScriptRoot "data/instances/manifest.txt"),
  [string]$Output = (Join-Path $PSScriptRoot "solve-report.md"),
  [int]$MaxRows = 200,
  [int]$MaxIterations = 20000,
  [switch]$Relax,
  [switch]$Presolve,
  [string]$Moon = "moon"
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Manifest)) {
  Write-Error "manifest not found: $Manifest (run bench/fetch-instances.ps1 first)"
  exit 2
}

$expected = @(
  Get-Content $Manifest |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
).Count
if ($expected -eq 0) {
  Write-Error "manifest is empty: $Manifest"
  exit 2
}

Push-Location $root
try {
  $version = (& $Moon version --all 2>&1 | Out-String).Trim()
  $commit = (& git rev-parse --short HEAD 2>&1 | Out-String).Trim()
  # Native release: the same solve takes about six times longer on the default
  # wasm backend, which is the difference between a report that finishes and one
  # that does not.
  $arguments = @(
    "run", "--target", "native", "--release", "cmd/parse", "--",
    "--manifest", $Manifest, "--solve", "--max-rows", "$MaxRows",
    "--max-iterations", "$MaxIterations"
  )
  if ($Relax) { $arguments += "--relax" }
  if ($Presolve) { $arguments += "--presolve" }
  $lines = & $Moon @arguments 2>&1 | ForEach-Object { $_.ToString() }
  $exitCode = $LASTEXITCODE
} finally {
  Pop-Location
}

# A crash or a refused file leaves the output incomplete. Writing it up anyway
# would publish numbers that describe a run that did not happen.
if ($exitCode -ne 0) {
  Write-Error ("the kernel run failed with exit code {0}; no report written" -f $exitCode)
  exit 3
}

$rows = @()
$checkFailures = @()
$current = $null
foreach ($line in $lines) {
  if ($line -match '^OK\s+(\S+)\s+format=(\S+)\s+vars=(\d+)\s+cons=(\d+)\s+nnz=(\d+)\s+int=(\d+)\s+sense=(\S+)\s+(\S+)') {
    $current = [pscustomobject]@{
      Instance   = Split-Path -Leaf $Matches[1]
      Vars       = [int]$Matches[3]
      Cons       = [int]$Matches[4]
      Nonzeros   = [int]$Matches[5]
      Integers   = [int]$Matches[6]
      Solve      = "-"
      Objective  = ""
      Iterations = ""
      Presolve   = ""
      Check      = ""
      Note       = ""
    }
    $rows += $current
    continue
  }
  if ($null -ne $current -and $line -match '^\s+presolve: (.*)$') {
    $current.Presolve = $Matches[1]
    continue
  }
  if ($null -ne $current -and $line -match '^\s+reconstructed: (.*)$') {
    $current.Check = $Matches[1]
    if ($Matches[1] -notmatch '\(feasible\)') {
      $checkFailures += $current.Instance
    }
    continue
  }
  if ($null -ne $current -and $line -match '^\s+solve=([^\s(]+)') {
    $current.Solve = $Matches[1]
    if ($line -match 'obj=(\S+)\s+iters=(\d+)') {
      $current.Objective = $Matches[1]
      $current.Iterations = $Matches[2]
    }
    if ($line -match '\((.+)\)\s*$') {
      # Greedy on purpose: a recovery message carries its own parentheses
      # ("... by restarting with Bland's rule (basis became numerically
      # singular)"), and a non-greedy pattern silently keeps only the inner one.
      $current.Note = $Matches[1]
    }
  }
}

# A reduction that produced an infeasible reconstruction, or a solution whose
# objective does not match the one recomputed from the original model, is a defect
# in the experiment rather than a result of it. The report is the place those get
# caught, so it refuses to be written.
if ($checkFailures.Count -gt 0) {
  Write-Error ("reconstruction checks failed for: {0}; no report written" -f ($checkFailures -join ", "))
  exit 5
}

if ($rows.Count -ne $expected) {
  Write-Error ("the run reported {0} of {1} manifest entries; no report written" -f $rows.Count, $expected)
  exit 4
}

$optimal = @($rows | Where-Object { $_.Solve -eq "optimal" })
$skipped = @($rows | Where-Object { $_.Solve -like "skipped*" })
$refused = @($rows | Where-Object { $_.Solve -eq "too-large" })
$recovered = @($rows | Where-Object { $_.Note -match 'recovered from a numerical failure' })
$reduced = @($rows | Where-Object { $_.Presolve -ne "" })
$checked = @($rows | Where-Object { $_.Check -ne "" })
$other = @($rows | Where-Object {
    $_.Solve -ne "-" -and $_.Solve -ne "optimal" -and $_.Solve -notlike "skipped*" -and $_.Solve -ne "too-large"
  })

$build = @()
$build += "# Kernel solve report"
$build += ""
$build += "Generated by ``bench/report-solve.ps1`` from commit ``$commit``."
$build += ""
$build += "- Toolchain: ``$($version -replace "`r?`n", " | ")``"
$build += "- Instances: MIPLIB 2017 (<https://miplib.zib.de>), fetched by ``bench/fetch-instances.ps1``."
$build += "- Mode: $(if ($Relax) { "LP relaxation (integer columns treated as continuous)" } else { "as-is (integer models are refused by the linear kernel)" }), row limit $MaxRows, pivot limit $MaxIterations, presolve $(if ($Presolve) { "on" } else { "off" }). An instance whose `pivots` column equals the pivot limit stopped there: the limit is part of the result, and two runs at different limits are not comparable."
$build += "- The script writes nothing unless the kernel exited zero, reported every manifest entry, and every reconstructed solution passed the row, bound and objective checks against the original model."
$build += ""
$build += "## Summary"
$build += ""
$build += "| metric | value |"
$build += "| --- | --- |"
$build += "| instances in manifest | $($rows.Count) |"
$build += "| solved to optimality | $($optimal.Count) |"
$build += "| skipped (row count over the limit) | $($skipped.Count) |"
$build += "| refused (kernel problem over the dense-inverse row limit) | $($refused.Count) |"
$build += "| other outcomes | $($other.Count) |"
if ($Presolve) {
  $build += "| solved instances run through the reduction | $($reduced.Count) |"
  $build += "| reconstructions verified against the original model | $($checked.Count) |"
  $build += "| runs that needed the Bland recovery | $($recovered.Count) |"
}
if ($optimal.Count -gt 0) {
  $build += "| pivot iterations (total) | $(($optimal | Measure-Object Iterations -Sum).Sum) |"
  $build += "| largest solved model (rows) | $(($optimal | Sort-Object Cons -Descending | Select-Object -First 1).Cons) |"
}
$build += ""
if ($other.Count -gt 0) {
  $build += "Outcomes other than optimal are listed verbatim below; a numerical failure is a"
  $build += "measured verdict from the kernel's own residual check, not a silent wrong answer."
  $build += ""
}
if ($refused.Count -gt 0) {
  $build += "A refusal is the kernel's row ceiling doing its job: every finite upper bound becomes"
  $build += "an explicit row, so these models reach the limit on kernel rows even though their"
  $build += "constraint counts look small. The run stops before allocating the basis inverse."
  $build += ""
}
if ($Presolve) {
  $build += "The ``presolve`` column is per instance: rows and variables before and after the"
  $build += "reduction, then the counters. The ``check`` column is the reconstructed solution"
  $build += "measured against the **original** model - worst row and bound violation, and the"
  $build += "objective recomputed from the original model's own cost vector. A run whose"
  $build += "reconstruction disagrees on the objective is not published at all."
  $build += ""
}
$build += "## Instances"
$build += ""
$build += "| instance | vars | cons | nonzeros | integer vars | solve | objective | pivots | presolve | check | note |"
$build += "| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- | --- | --- |"
foreach ($row in $rows) {
  $build += "| $($row.Instance) | $($row.Vars) | $($row.Cons) | $($row.Nonzeros) | $($row.Integers) | $($row.Solve) | $($row.Objective) | $($row.Iterations) | $($row.Presolve) | $($row.Check) | $($row.Note) |"
}
$build += ""
[IO.File]::WriteAllLines($Output, $build)
Write-Host ("wrote {0}: optimal={1} skipped={2} refused={3} other={4} reduced={5} checked={6} recovered={7}" -f $Output, $optimal.Count, $skipped.Count, $refused.Count, $other.Count, $reduced.Count, $checked.Count, $recovered.Count)
foreach ($row in $other) {
  Write-Host ("  {0}: {1} {2}" -f $row.Instance, $row.Solve, $row.Note)
}
foreach ($row in $refused) {
  Write-Host ("  {0}: too-large {1}" -f $row.Instance, $row.Note)
}
