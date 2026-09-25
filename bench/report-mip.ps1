# Runs the branch and bound over the instances in the manifest and writes
# bench/mip-report.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench/report-mip.ps1
#
# Instances whose row count exceeds -MaxRows are reported as skipped rather than
# attempted, exactly as the linear report does. Every other instance is solved with
# a node budget: a run that reaches it reports the incumbent it has and the bound
# still open, which is the point of the budget - an unfinished integer problem has
# no answer, only a range.
#
# The script refuses to write a report it cannot stand behind:
#   - a non-zero exit from the kernel (a crash, or an unreadable file);
#   - a run that did not cover every manifest entry;
#   - a refused certificate (the branch and bound stops rather than branch on an
#     answer the independent verifier could not confirm);
#   - a reported point that failed the row, bound or integrality check.
# A partial run presented as a whole one is worse than no report at all, and a
# report is the only durable evidence a run happened.
#
# The report records the toolchain version and the commit it came from, so every
# number in it can be traced back to the code that produced it.

param(
  [string]$Manifest = (Join-Path $PSScriptRoot "data/instances/manifest.txt"),
  [string]$Output = (Join-Path $PSScriptRoot "mip-report.md"),
  [int]$MaxRows = 1000,
  [int]$MaxNodes = 1000,
  [int]$MaxIterations = 20000,
  [int]$CutRounds = -1,
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
  $arguments = @(
    "run", "--target", "native", "--release", "cmd/parse", "--",
    "--manifest", $Manifest, "--mip", "--max-rows", "$MaxRows",
    "--max-nodes", "$MaxNodes", "--max-iterations", "$MaxIterations"
  )
  if ($CutRounds -ge 0) {
    $arguments += @("--cut-rounds", "$CutRounds")
  }
  $lines = & $Moon @arguments 2>&1 | ForEach-Object { $_.ToString() }
  $exitCode = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($exitCode -ne 0) {
  # A refused certificate makes the CLI exit non-zero by design, and the parse below is
  # what tells that case apart from a crash: so this check waits until the output has
  # been read, at the end of the block below.
  $runFailed = $true
} else {
  $runFailed = $false
}

$rows = @()
$pointFailures = @()
$refused = @()
$current = $null
foreach ($line in $lines) {
  if ($line -match '^OK\s+(\S+)\s+format=(\S+)\s+vars=(\d+)\s+cons=(\d+)\s+nnz=(\d+)\s+int=(\d+)\s+sense=(\S+)\s+(\S+)') {
    $current = [pscustomobject]@{
      Instance   = Split-Path -Leaf $Matches[1]
      Vars       = [int]$Matches[3]
      Cons       = [int]$Matches[4]
      Nonzeros   = [int]$Matches[5]
      Integers   = [int]$Matches[6]
      Status     = "-"
      Objective  = ""
      Nodes      = ""
      Verified   = ""
      Cuts       = ""
      Bound      = ""
      Gap        = ""
      Check      = ""
      Note       = ""
    }
    $rows += $current
    continue
  }
  if ($null -ne $current -and $line -match '^\s+point: (.*)$') {
    $current.Check = $Matches[1]
    if ($Matches[1] -notmatch '\(feasible and whole\)') {
      $pointFailures += $current.Instance
    }
    continue
  }
  if ($null -ne $current -and $line -match '^\s+mip=([^\s(]+)') {
    $current.Status = $Matches[1]
    if ($line -match 'nodes=(\d+)\s+verified=(\d+)') {
      $current.Nodes = $Matches[1]
      $current.Verified = $Matches[2]
    }
    if ($line -match 'cuts=(\d+)') { $current.Cuts = $Matches[1] }
    if ($line -match 'obj=(\S+)') { $current.Objective = $Matches[1] }
    if ($line -match 'bound=(\S+)') { $current.Bound = $Matches[1] }
    if ($line -match 'gap=(\S+)') { $current.Gap = $Matches[1] }
    # Greedy on purpose: a message carries its own parentheses.
    if ($line -match '\((.+)\)\s*$') { $current.Note = $Matches[1] }
    if ($current.Status -eq "unverified") { $refused += $current.Instance }
  }
}

if ($rows.Count -ne $expected) {
  Write-Error ("the run reported {0} of {1} manifest entries; no report written" -f $rows.Count, $expected)
  exit 4
}
if ($refused.Count -gt 0) {
  foreach ($name in $refused) {
    $row = $rows | Where-Object { $_.Instance -eq $name }
    Write-Host ("  refused {0}: {1}" -f $name, $row.Note)
  }
  Write-Error ("a certificate was refused for: {0}; no report written" -f ($refused -join ", "))
  exit 5
}
if ($runFailed) {
  Write-Error ("the run failed with exit code {0}; no report written" -f $exitCode)
  exit 3
}
if ($pointFailures.Count -gt 0) {
  Write-Error ("point checks failed for: {0}; no report written" -f ($pointFailures -join ", "))
  exit 6
}

$optimal = @($rows | Where-Object { $_.Status -eq "optimal" })
$limit = @($rows | Where-Object { $_.Status -eq "node-limit" })
$skipped = @($rows | Where-Object { $_.Status -like "skipped*" })
$other = @($rows | Where-Object {
    $_.Status -ne "-" -and $_.Status -ne "optimal" -and $_.Status -ne "node-limit" -and $_.Status -notlike "skipped*"
  })
$attempted = @($rows | Where-Object { $_.Status -ne "-" -and $_.Status -notlike "skipped*" })
$checked = @($rows | Where-Object { $_.Check -ne "" })

$verifiedTotal = 0
$cutsTotal = 0
foreach ($row in $rows) {
  if ($row.Verified -ne "") { $verifiedTotal += [int]$row.Verified }
  if ($row.Cuts -ne "") { $cutsTotal += [int]$row.Cuts }
}

$build = @()
$CutRoundText = if ($CutRounds -ge 0) {
  "limited to $CutRounds round(s)"
} else {
  "at the library default"
}
$build += "# Branch and bound report (M5)"
$build += ""
$build += "Generated by ``bench/report-mip.ps1`` from commit ``$commit``."
$build += ""
$build += "- Toolchain: ``$($version -replace "`r?`n", " | ")``"
$build += "- Instances: MIPLIB 2017 (<https://miplib.zib.de>), fetched by ``bench/fetch-instances.ps1``; the list is ``$Manifest``."
$build += "- Mode: integer models solved by branch and bound, row limit $MaxRows, node budget $MaxNodes, relaxation iteration cap $MaxIterations, every relaxation verified, root cuts $CutRoundText."
$acceptance = "every reported point passed the row, bound and integrality checks against the model."
$build += "- The script writes nothing unless the run exited zero, covered every manifest entry, had no refused certificate, and $acceptance"
$build += ""
$build += "## Summary"
$build += ""
$build += "| metric | value |"
$build += "| --- | --- |"
$build += "| instances in manifest | $($rows.Count) |"
$build += "| proven optimal (tree exhausted or every open bound closed) | $($optimal.Count) |"
$build += "| stopped at the node budget | $($limit.Count) |"
$build += "| skipped (row count over the limit) | $($skipped.Count) |"
$build += "| other outcomes | $($other.Count) |"
$build += "| relaxations verified by ``verify`` | $verifiedTotal |"
$build += "| cuts added and verified by ``verify_cut`` | $cutsTotal |"
$build += "| reported points checked against the model | $($checked.Count) |"
$build += ""
$build += "Only ``optimal`` claims an answer. A run that stopped at the budget reports the"
$build += "incumbent it found together with the bound still open - the two numbers a caller"
$build += "needs to decide whether to keep going - and a run whose relaxation came back"
$build += "unbounded says so rather than calling the integer model unbounded, because an"
$build += "improving ray of the relaxation carries no integrality of its own."
$build += ""
$build += "The ``verify`` column is the number of node relaxations the independent checker"
$build += "accepted; with verification on it equals the node count unless a relaxation reached"
$build += "no verdict, which is exactly the work the budget left undone. That happens two ways:"
$build += "the iteration cap, and a relaxation whose optimal basis cannot be written down as a"
$build += "certificate at all. The second is a category rather than one measurement: before it"
$build += "emits a certificate the kernel checks the multiplier sign convention the checker reads"
$build += "it in and the duality gap those multipliers prove against the objective the point has,"
$build += "and a basis it cannot state a proof for is reported as a numerical failure. Both are"
$build += "open work rather than a refused claim: a run with no"
$build += "proof to offer has not made a claim the checker could refuse, and the tree is not"
$build += "exhausted, so the run ends at a limit instead of stopping the search."
$build += ""
$build += "The deficit has two sources and the ``note`` column names the first: a node popped"
$build += "from the queue whose relaxation reaches no verdict. Its region is still unexplored,"
$build += "so the bound the run reports is taken over the queue *and* over the keys of those"
$build += "nodes - a key is the parent's relaxation objective, which bounds every point below"
$build += "it, and a run that counted only the queue would report a bound it had not"
$build += "established. The second source leaves nothing open: a step of the primal heuristic"
$build += "that reaches no verdict spends a relaxation without finding a point, and the node"
$build += "it walked from had answered, so the children it branches into still carry that"
$build += "answer."
$build += ""
$build += "The node count is every relaxation the run solved, which includes the ones the"
$build += "primal heuristic spends walking a fractional node down to a whole point and the ones"
$build += "spent re-solving the root after a round of cuts: they are relaxations of restricted"
$build += "models, solved and verified by the same path a node's is, and they come out of the"
$build += "same budget. An empty ``objective`` column means the run never stood on a whole point,"
$build += "which the ``note`` column says in words."
$build += ""
$build += "The ``cuts`` column counts inequalities added to the model the tree is built on. Each"
$build += "one was rounded from a row of the root's tableau and then re-derived from the witness"
$build += "that row is by ``verify_cut``, which refuses a cut whose derivation does not reproduce"
$build += "it; a refusal stops the run rather than being skipped, because an invalid cut removes"
$build += "integer points from every node below it and no other check in the project can see"
$build += "that. A round of cuts is kept only when the root's re-solve returns a verdict and does"
$build += "not come back worse, so a round that costs more pivots than it saves is discarded"
$build += ""
$build += "## Instances"
$build += ""
$build += "| instance | vars | cons | integer vars | result | objective | bound | gap | nodes | verified | cuts | point check | note |"
$build += "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |"
foreach ($row in $rows) {
  $build += "| $($row.Instance) | $($row.Vars) | $($row.Cons) | $($row.Integers) | $($row.Status) | $($row.Objective) | $($row.Bound) | $($row.Gap) | $($row.Nodes) | $($row.Verified) | $($row.Cuts) | $($row.Check) | $($row.Note) |"
}
$build += ""
[IO.File]::WriteAllLines($Output, $build)
Write-Host ("wrote {0}: optimal={1} node-limit={2} skipped={3} other={4} verified={5} checked={6}" -f $Output, $optimal.Count, $limit.Count, $skipped.Count, $other.Count, $verifiedTotal, $checked.Count)
foreach ($row in ($limit + $other)) {
  Write-Host ("  {0}: {1} {2}" -f $row.Instance, $row.Status, $row.Note)
}
