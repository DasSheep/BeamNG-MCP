<#
.SYNOPSIS
  Remove Steam screenshots CONSISTENTLY - the .jpg, its thumbnail AND its screenshots.vdf entry - and
  repair entries whose file has already been deleted.

.WHY THIS EXISTS, AND WHY THE MCP TOOL DOES NOT DO IT
  Steam records every capture in <Steam>/userdata/<acct>/760/screenshots.vdf at capture time. Deleting
  just the .jpg leaves that entry behind and Steam's own screenshot manager then shows a broken
  "missing file" row. Steam does NOT prune those: orphaned entries (including ones for other games)
  survive Steam restarts indefinitely.

  Editing the .vdf while Steam is RUNNING does not work either: Steam owns that file in memory and
  rewrites it from its own state on exit, discarding whatever you wrote. That is why this script
  refuses to run while Steam is up, and why `screenshot_native` never deletes its own captures.

.MODES
  -RepairOrphans   Drop entries whose .jpg is missing (the fix for a previous file-only delete).
  -Names a,b       Prune these captures completely: file + thumbnail + entry.
  -OlderThanDays N Prune every capture for the app older than N days, completely.

  All three default to a DRY RUN. Add -Apply to actually write.

.NOTES
  ASCII ONLY, DELIBERATELY. PowerShell 5.1 decodes a BOM-less .ps1 as ANSI, so a stray em dash is a
  parse error rather than a cosmetic issue. Do not add non-ASCII characters to this file.

  The .vdf is Valve KeyValues: "screenshots" { "<appid>" { "<index>" { fields } } }. Entries are
  renumbered from 0 after removal, because the index keys are positional.

.EXAMPLE
  ./prune-steam-screenshots.ps1 -RepairOrphans              # show what would be repaired
  ./prune-steam-screenshots.ps1 -RepairOrphans -Apply       # repair for real (Steam must be closed)
  ./prune-steam-screenshots.ps1 -OlderThanDays 7 -Apply
#>
[CmdletBinding()]
param(
  [string]   $AppId = '284160',
  [string]   $AccountId,
  [switch]   $RepairOrphans,
  [string[]] $Names,
  [int]      $OlderThanDays = 0,
  [switch]   $Apply,
  # TEST SEAM: point at a synthetic `760` directory (containing screenshots.vdf + remote/<appid>/...)
  # instead of resolving the real one from the registry. Skips the Steam-running guard, because a
  # fixture is not the player's library. Never pass this against a real userdata path while Steam runs.
  [string]   $Root
)

$ErrorActionPreference = 'Stop'

if (-not $RepairOrphans -and -not $Names -and $OlderThanDays -le 0) {
  throw 'Nothing to do. Pass -RepairOrphans, -Names <file.jpg,...> or -OlderThanDays <n>.'
}

if ($Root) {
  $root = $Root
} else {
  # Steam rewrites screenshots.vdf from memory when it exits, so any edit made while it is running is
  # silently thrown away. Refuse rather than appear to work.
  if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
    throw 'Steam is RUNNING. It rewrites screenshots.vdf from memory on exit, so edits made now would be discarded. Close Steam fully, then re-run.'
  }

  $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
  if (-not $steamPath) { throw 'Steam is not installed for this user.' }

  if (-not $AccountId) {
    $found = @(Get-ChildItem (Join-Path $steamPath 'userdata') -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName '760\screenshots.vdf') })
    if ($found.Count -ne 1) { throw "Could not pick a Steam account automatically ($($found.Count) candidates). Pass -AccountId." }
    $AccountId = $found[0].Name
  }
  $root = Join-Path $steamPath "userdata\$AccountId\760"
}
$vdf   = Join-Path $root 'screenshots.vdf'
$shots = Join-Path $root "remote\$AppId\screenshots"
if (-not (Test-Path $vdf)) { throw "No screenshots.vdf at '$vdf'." }

$raw = [System.IO.File]::ReadAllText($vdf, [Text.Encoding]::UTF8)
$nl  = if ($raw -match "`r`n") { "`r`n" } else { "`n" }

# --- locate the app's section and split it into entry blocks -------------------------------------
$secRx = [regex]::new('(?m)^\t"' + [regex]::Escape($AppId) + '"\s*\r?\n\t\{')
$secM  = $secRx.Match($raw)
if (-not $secM.Success) { throw "No section for app $AppId in the .vdf." }

# Walk braces from the section's opening { to its matching }.
$open = $raw.IndexOf('{', $secM.Index)
$i = $open; $depth = 0; $close = -1
while ($i -lt $raw.Length) {
  if ($raw[$i] -eq '{') { $depth++ }
  elseif ($raw[$i] -eq '}') { $depth--; if ($depth -eq 0) { $close = $i; break } }
  $i++
}
if ($close -lt 0) { throw 'Unbalanced braces in the .vdf; refusing to edit.' }

$body = $raw.Substring($open + 1, $close - $open - 1)

# Each child: "N" { ... }
$entries = @()
$erx = [regex]::new('"(\d+)"\s*\r?\n\s*\{')
$m = $erx.Match($body)
while ($m.Success) {
  $bOpen = $body.IndexOf('{', $m.Index)
  $j = $bOpen; $d = 0; $bClose = -1
  while ($j -lt $body.Length) {
    if ($body[$j] -eq '{') { $d++ }
    elseif ($body[$j] -eq '}') { $d--; if ($d -eq 0) { $bClose = $j; break } }
    $j++
  }
  if ($bClose -lt 0) { throw 'Unbalanced entry braces in the .vdf; refusing to edit.' }
  $inner = $body.Substring($bOpen + 1, $bClose - $bOpen - 1)
  $fn = ([regex]::Match($inner, '"filename"\s*"([^"]+)"')).Groups[1].Value
  $entries += [pscustomobject]@{
    Inner    = $inner
    FileName = if ($fn) { Split-Path $fn -Leaf } else { '' }
  }
  $m = $erx.Match($body, $bClose)
}

if ($entries.Count -eq 0) { Write-Host "No entries for app $AppId."; exit 0 }

# --- decide what goes ------------------------------------------------------------------------------
$cutoff = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }
$drop = @()
foreach ($e in $entries) {
  if (-not $e.FileName) { continue }
  $path = Join-Path $shots $e.FileName
  $exists = Test-Path $path
  if ($RepairOrphans -and -not $exists) { $drop += $e; continue }
  if ($Names -and ($Names -contains $e.FileName)) { $drop += $e; continue }
  if ($cutoff -and $exists -and (Get-Item $path).LastWriteTime -lt $cutoff) { $drop += $e; continue }
}

if ($drop.Count -eq 0) { Write-Host "Nothing matched. $($entries.Count) entries left as they are."; exit 0 }

Write-Host "app $AppId : $($entries.Count) entries, $($drop.Count) to remove"
foreach ($e in $drop) {
  $path = Join-Path $shots $e.FileName
  $state = if (Test-Path $path) { 'file + entry' } else { 'entry only (orphan)' }
  Write-Host ("  {0,-28} {1}" -f $e.FileName, $state)
}
if (-not $Apply) { Write-Host "`nDRY RUN - nothing written. Re-run with -Apply."; exit 0 }

# --- apply -----------------------------------------------------------------------------------------
$backup = "$vdf.bak-$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $vdf $backup
Write-Host "backed up -> $backup"

foreach ($e in $drop) {
  foreach ($p in @((Join-Path $shots $e.FileName), (Join-Path $shots "thumbnails\$($e.FileName)"))) {
    if (Test-Path $p) { Remove-Item $p -Force }
  }
}

# Rebuild the section, renumbering from 0 - the index keys are positional.
$keep = @($entries | Where-Object { $drop -notcontains $_ })
$sb = New-Object System.Text.StringBuilder
for ($k = 0; $k -lt $keep.Count; $k++) {
  [void]$sb.Append("$nl`t`t`"$k`"$nl`t`t{")
  [void]$sb.Append($keep[$k].Inner)
  [void]$sb.Append('}')
}
[void]$sb.Append($nl + "`t")

$updated = $raw.Substring(0, $open + 1) + $sb.ToString() + $raw.Substring($close)
# BOM-less UTF-8: Valve writes it that way and Set-Content would default to ANSI on PS 5.1.
[System.IO.File]::WriteAllText($vdf, $updated, (New-Object Text.UTF8Encoding($false)))

Write-Host "removed $($drop.Count) entr(y/ies); $($keep.Count) remain."
Write-Host 'Start Steam and check View > Screenshots. If anything looks wrong, restore the .bak above.'
