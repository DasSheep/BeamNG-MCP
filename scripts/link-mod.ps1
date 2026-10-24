<#
.SYNOPSIS
  Set up the live BeamNG dev mod as a ZERO-DRIFT junction to this repo (default), or build a
  distributable release .zip (-Zip).

.DESCRIPTION
  The mod is pure Lua (no build step), so the live mod can be a true mirror of the repo:

    repo/dist/beammcp/
      lua                         -> junction -> repo/lua          (live mirror, zero drift)
      scripts/beammcp/modScript.lua  (copy of the 5-line auto-loader)
    <UserPath>/mods/unpacked/beammcp -> junction -> repo/dist/beammcp

  Edit anything under repo/lua and it is live the instant you reload in-game (Ctrl+L / restart) -
  no re-staging, ever. This eliminates the "forgot to mirror a tool file" drift class of bug.

  -Zip instead assembles a clean COPY (lua/ + scripts/beammcp/modScript.lua) and zips it to
  dist/beammcp.zip for distribution (a zip must contain real files, not junctions).

  Junctions need no admin rights. Deletion is junction-safe: reparse points are removed with
  `rmdir` (unlinks the link, never follows it into the target), so repo/lua can never be touched.

.PARAMETER UserPath
  BeamNG user directory (the one containing mods/). Default: the local AppData install.

.PARAMETER Zip
  Build dist/beammcp.zip for release instead of setting up the dev junction.

.EXAMPLE
  pwsh -File scripts/link-mod.ps1
  pwsh -File scripts/link-mod.ps1 -Zip
#>
param(
  [string] $UserPath = "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current",
  [switch] $Zip
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$repo      = Split-Path $PSScriptRoot -Parent
$luaSrc    = Join-Path $repo "lua"
$modScript = Join-Path $repo "scripts\beammcp\modScript.lua"
$distRoot  = Join-Path $repo "dist"
$modDist   = Join-Path $distRoot "beammcp"     # the clean mod root

function Test-Reparse([string] $p) {
  return (Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
}

# Remove a junction by unlinking it (rmdir on a reparse point removes the LINK, never its target).
function Remove-Junction([string] $p) {
  & cmd /c rmdir "$p" | Out-Null
}

# Safely remove a path that MAY be a junction or MAY be a real dir containing an inner `lua` junction.
# Never lets Remove-Item recurse through a junction into its target.
function Remove-PathSafe([string] $p) {
  if (-not (Test-Path -LiteralPath $p)) { return }
  if (Test-Reparse $p) { Remove-Junction $p; return }           # it's a junction -> just unlink
  # real directory: unlink any inner `lua` junction first, then delete the (now junction-free) tree
  $innerLua = Join-Path $p "lua"
  if ((Test-Path -LiteralPath $innerLua) -and (Test-Reparse $innerLua)) { Remove-Junction $innerLua }
  Remove-Item -LiteralPath $p -Recurse -Force
}

function New-Junction([string] $link, [string] $target) {
  $parent = Split-Path $link -Parent
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}

# Sanity: this must be run from the repo.
if (-not (Test-Path -LiteralPath $luaSrc) -or -not (Test-Path -LiteralPath $modScript)) {
  Write-Error "Run from the BeamNG-MCP repo: missing $luaSrc or $modScript"
  exit 1
}

if ($Zip) {
  # ---- release packaging: a clean real-file copy zipped for distribution -------------------
  $pkg = Join-Path $distRoot ".pkg"
  $zipOut = Join-Path $distRoot "beammcp.zip"
  Remove-PathSafe $pkg
  New-Item -ItemType Directory -Force -Path (Join-Path $pkg "scripts\beammcp") | Out-Null
  Copy-Item -Recurse -Force -LiteralPath $luaSrc -Destination (Join-Path $pkg "lua")
  Copy-Item -Force -LiteralPath $modScript -Destination (Join-Path $pkg "scripts\beammcp\modScript.lua")
  & (Join-Path $PSScriptRoot 'build-manifest.ps1') -RepoRoot $repo -OutputPath (Join-Path $pkg 'scripts/beammcp/build.json')
  foreach ($f in @("LICENSE", "README.md")) {
    $src = Join-Path $repo $f
    if (Test-Path -LiteralPath $src) { Copy-Item -Force -LiteralPath $src -Destination (Join-Path $pkg $f) }
  }
  if (Test-Path -LiteralPath $zipOut) { Remove-Item -LiteralPath $zipOut -Force }
  # Build the archive with explicit FORWARD-SLASH entry names. Windows PowerShell 5.1's Compress-Archive
  # (and .NET Framework's CreateFromDirectory) emit backslash separators, which BeamNG's mod loader does
  # not recognize -> the mod fails to mount. Add each file by hand with '/' to produce a valid mod zip.
  Add-Type -AssemblyName System.IO.Compression | Out-Null            # ZipArchive / ZipArchiveMode
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null # ZipFile / ZipFileExtensions
  $archive = [System.IO.Compression.ZipFile]::Open($zipOut, [System.IO.Compression.ZipArchiveMode]::Create)
  $n = 0
  try {
    $base = (Resolve-Path -LiteralPath $pkg).Path.TrimEnd('\') + '\'
    foreach ($file in Get-ChildItem -LiteralPath $pkg -Recurse -File) {
      $rel = $file.FullName.Substring($base.Length).Replace('\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $rel) | Out-Null
      $n++
    }
  } finally {
    $archive.Dispose()
  }
  Remove-Item -LiteralPath $pkg -Recurse -Force
  Write-Output "Packaged release: $zipOut ($n files, forward-slash entries)"
  exit 0
}

# ---- dev link: zero-drift junctions --------------------------------------------------------
# 1) (re)build the clean mod root dist/beammcp with lua -> junction -> repo/lua
Remove-PathSafe $modDist
New-Item -ItemType Directory -Force -Path (Join-Path $modDist "scripts\beammcp") | Out-Null
New-Junction (Join-Path $modDist "lua") $luaSrc
Copy-Item -Force -LiteralPath $modScript -Destination (Join-Path $modDist "scripts\beammcp\modScript.lua")
& (Join-Path $PSScriptRoot 'build-manifest.ps1') -RepoRoot $repo -OutputPath (Join-Path $modDist 'scripts/beammcp/build.json')

# 2) point the live unpacked mod at dist/beammcp (replacing any existing copy/junction)
$modsUnpacked = Join-Path $UserPath "mods\unpacked"
if (-not (Test-Path -LiteralPath $modsUnpacked)) {
  Write-Warning "BeamNG mods\unpacked not found at: $modsUnpacked"
  Write-Warning "Pass -UserPath '<BeamNG user dir>' (the folder containing mods\). dist/beammcp is built; junction skipped."
  Write-Output "Built mod root: $modDist (lua -> $luaSrc)"
  exit 0
}
$liveLink = Join-Path $modsUnpacked "beammcp"
Remove-PathSafe $liveLink
New-Junction $liveLink $modDist

Write-Output "Linked dev mod (zero-drift):"
Write-Output "  $liveLink"
Write-Output "    -> $modDist"
Write-Output "       lua -> $luaSrc   (edits live on reload)"
Write-Output ""
Write-Output "Reload in BeamNG (GE Lua console: extensions.load(`"beammcp`") / Ctrl+L / restart) to pick it up."
