# Downloads the benchmark instances used by the parse and solve reports.
#
# Source: MIPLIB 2017 (https://miplib.zib.de), which publishes plain MPS files
# gzipped one per instance. The data is NOT redistributed by this repository: it
# lands in bench/data/instances, which is gitignored, together with a manifest
# that `moon run cmd/parse -- --manifest ...` consumes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench/fetch-instances.ps1
#
# Why not the Netlib LP test set: netlib's lp/data files are stored in its own
# legacy compressed container (NAME line, dimension header, then encoded
# records), not as MPS, so they cannot be read without a decompressor for that
# container. MIPLIB publishes the same kind of real-world models as plain MPS.
#
# Missing instances are reported and skipped instead of aborting the run: one
# unavailable instance must not hide the result of the others.

param(
  [string[]]$Instances = @(
    "flugpl", "bell3a", "bell5", "blend2", "cap6000", "danoint", "dcmulti",
    "dsbmip", "egout", "enigma", "fiber", "fixnet6", "gesa2", "gesa2_o",
    "gesa3", "gesa3_o", "gt2", "harp2", "khb05250", "l152lav", "lseu",
    "markshare1", "markshare2", "misc03", "misc06", "misc07", "mitre",
    "mod008", "mod010", "mod011", "noswot", "p0033", "p0201", "p0282",
    "p0548", "p2756", "pk1", "pp08a", "pp08aCUTS", "qiu", "rgn", "rout",
    "set1ch", "stein27", "stein45", "vpm1", "vpm2", "22433", "30n20b8",
    "50v-10", "aflow40b", "2club200v15p5scn", "bc1", "bienst1", "bienst2",
    "blp-ar98", "core2536-691", "dano3_3", "fast0507"
  ),
  [string]$Source = "https://miplib.zib.de/WebData/instances/",
  [string]$Target = (Join-Path $PSScriptRoot "data/instances")
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
New-Item -ItemType Directory -Path $Target -Force | Out-Null

function Expand-Gzip([string]$archive, [string]$destination) {
  $input = [IO.File]::OpenRead($archive)
  try {
    $output = [IO.File]::Create($destination)
    try {
      $stream = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
      try { $stream.CopyTo($output) } finally { $stream.Dispose() }
    } finally { $output.Dispose() }
  } finally { $input.Dispose() }
}

$downloaded = @()
$missing = @()
# Deduplicated on purpose: the manifest is written from `$downloaded`, one line per entry of
# this list, so a name listed twice becomes a line twice - and every report that reads the
# manifest then processes that instance twice, doubling its contribution to the totals. That
# is not hypothetical: `danoint` was listed twice, and the parse report of the time read
# `instances attempted 33` with totals 521 variables above the 32-instance ones, 521 being
# exactly that instance's variable count. The list is deduplicated here so a typo cannot
# reach a report again.
foreach ($name in ($Instances | Select-Object -Unique)) {
  $destination = Join-Path $Target $name
  if (Test-Path $destination) {
    Write-Host "cached  $name"
    $downloaded += $name
    continue
  }
  $archive = "$destination.mps.gz"
  try {
    Invoke-WebRequest -Uri ($Source + $name + ".mps.gz") -UseBasicParsing -OutFile $archive -TimeoutSec 120
    Expand-Gzip $archive $destination
    Remove-Item $archive -Force
    Write-Host ("ok      {0} ({1} bytes)" -f $name, (Get-Item $destination).Length)
    $downloaded += $name
  } catch {
    if (Test-Path $archive) { Remove-Item $archive -Force }
    Write-Host ("miss    {0}" -f $name)
    $missing += $name
  }
}

$manifest = Join-Path $Target "manifest.txt"
$lines = @("# MIPLIB 2017 instances, one path per line, resolved relative to this file.")
$lines += $downloaded
[IO.File]::WriteAllLines($manifest, $lines)
Write-Host ""
Write-Host ("downloaded {0}, missing {1}" -f $downloaded.Count, $missing.Count)
if ($missing.Count -gt 0) {
  Write-Host ("missing: " + ($missing -join ", "))
}
Write-Host ("manifest: " + $manifest)
