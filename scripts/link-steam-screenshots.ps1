<#
.SYNOPSIS
  Junction Steam's BeamNG screenshot folder into the game userpath so the `screenshot_native` MCP tool
  can read and clean up its own captures. Run once per machine.

.WHY THIS IS NEEDED
  `screenshot_native` triggers Steam's overlay capture, which is the only route that sees ImGui
  overlays. Steam writes the file into its own userdata tree, which is OUTSIDE the BeamNG VFS,
  and the game's Lua sandbox has no way out of that VFS - all four routes are sealed:
  FS:mount returns -1 for OS directories, io.open/io.popen are VFS-redirected, os.execute is an inert
  stub, and ffi.cdef rejects every function type. A directory junction is therefore the only mechanism
  that lets in-game Lua read the capture back and delete it afterwards.

.HAZARD - READ BEFORE YOU AUTOMATE ANYTHING AGAINST THIS PATH
  The link is a JUNCTION INTO YOUR REAL STEAM SCREENSHOT LIBRARY. Deleting it recursively (Remove-Item
  -Recurse, rm -rf, a cleanup task) deletes YOUR SCREENSHOTS, not just the link. To remove it, delete
  the link itself - use -Remove below, or `cmd /c rmdir <link>`, never a recursive delete.

.NOTES
  ASCII ONLY, DELIBERATELY. PowerShell 5.1 decodes a BOM-less .ps1 as ANSI, so a stray em dash is a
  parse error rather than a cosmetic issue. Do not add non-ASCII characters to this file.

  A junction (mklink /J) is used rather than a symlink because it needs no elevation and no Developer
  Mode. It works only for local paths, which is what a Steam userdata folder always is.

.EXAMPLE
  ./link-steam-screenshots.ps1            # create (or verify) the junction
  ./link-steam-screenshots.ps1 -Remove    # remove ONLY the link, leaving the screenshots untouched
#>
[CmdletBinding()]
param(
  # BeamNG userpath. The junction is created directly inside it, as `steamshots`.
  [string] $UserPath = "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current",
  # Steam app id. BeamNG.drive is 284160.
  [string] $AppId = '284160',
  # Steam account id (32-bit, the userdata folder name). Auto-detected when omitted.
  [string] $AccountId,
  # Remove the junction instead of creating it.
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'

$link = Join-Path $UserPath 'steamshots'

if ($Remove) {
  if (-not (Test-Path $link)) { Write-Host "nothing to remove: $link does not exist"; exit 0 }
  $item = Get-Item $link -Force
  if ($item.LinkType -ne 'Junction') {
    # No ?? operator in PowerShell 5.1 - a real directory reports a null LinkType.
    $kind = if ($item.LinkType) { $item.LinkType } else { 'real directory' }
    throw "REFUSING to remove '$link': it is a $kind, not a junction. Delete it yourself if that is what you want."
  }
  # rmdir removes the link only. Remove-Item -Recurse would delete THROUGH it into the Steam library.
  cmd /c rmdir "$link" | Out-Null
  Write-Host "removed junction $link (Steam screenshots untouched)"
  exit 0
}

if (-not (Test-Path $UserPath)) {
  throw "BeamNG userpath not found: '$UserPath'. Pass -UserPath if your install uses a different location."
}

$steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $steamPath) { throw 'Steam is not installed for this user (no HKCU:\Software\Valve\Steam\SteamPath).' }

if (-not $AccountId) {
  # The currently logged-in account. Falls back to scanning userdata, because ActiveUser reads 0 when
  # Steam is not running - and this script is useful before launching the game.
  $active = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue).ActiveUser
  if ($active -and $active -ne 0 -and
      (Test-Path (Join-Path $steamPath "userdata\$active\760\remote\$AppId\screenshots"))) {
    $AccountId = "$active"
  } else {
    $found = @(Get-ChildItem (Join-Path $steamPath 'userdata') -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName "760\remote\$AppId\screenshots") })
    if ($found.Count -eq 0) {
      throw ("No Steam account has a screenshot folder for app $AppId. Take one screenshot in game with F12 " +
             "first (Steam creates the folder lazily), then re-run this script.")
    }
    if ($found.Count -gt 1) {
      $names = ($found | ForEach-Object { $_.Name }) -join ', '
      throw "Ambiguous: $($found.Count) Steam accounts have screenshots for app $AppId -> $names. Pass -AccountId."
    }
    $AccountId = $found[0].Name
  }
}

$target = Join-Path $steamPath "userdata\$AccountId\760\remote\$AppId\screenshots"
if (-not (Test-Path $target)) {
  throw ("Steam screenshot folder not found: '$target'. Take one screenshot in game with F12 first " +
         "(Steam creates the folder lazily), then re-run this script.")
}

if (Test-Path $link) {
  $item = Get-Item $link -Force
  if ($item.LinkType -ne 'Junction') {
    throw "'$link' already exists and is NOT a junction. Move it aside before running this script."
  }
  if ($item.Target -and ($item.Target -join '') -ieq $target) {
    Write-Host "already linked: $link -> $target"
    Write-Output $link
    exit 0
  }
  throw "'$link' is a junction pointing at '$($item.Target -join '')', not '$target'. Remove it with -Remove first."
}

cmd /c mklink /J "$link" "$target" | Out-Null
if (-not (Test-Path $link)) { throw "mklink reported success but '$link' does not exist." }

$count = @(Get-ChildItem $link -File -Filter *.jpg -ErrorAction SilentlyContinue).Count
Write-Host "linked $link -> $target ($count existing capture(s) visible)"
Write-Host "The MCP tool now reaches it as the VFS path /steamshots."
Write-Host "REMINDER: this is a junction into your real Steam library - remove it with -Remove, never a recursive delete."
Write-Output $link
