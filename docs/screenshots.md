# Screenshots

BeamNG-MCP has two screenshot tools, and the repository ships a desktop-capture script for cases
neither covers. They differ in what ends up in the image.

| | `screenshot` | `screenshot_native` | `scripts/capture-window.ps1` |
|---|---|---|---|
| Source | Engine capture of the scene render target | Steam overlay capture of the presented frame | Copy of the window's region of the desktop |
| 3D scene and CEF UI | Yes | Yes | Yes |
| ImGui overlays (mod gauges, minimaps, debug windows, the BeamMCP panel) | **No** | Yes | Yes |
| Format | PNG, inline | JPEG, inline | PNG file on disk |
| Needs | Nothing | Game launched through Steam, one-time junction setup | Windows, an unobstructed game window |
| Works while minimised | Untested | No | No (minimised windows are skipped) |
| Leaves files behind | No | Yes, in your Steam screenshot library | Yes, the PNG it writes |

## `screenshot`

Calls the engine's `createScreenshot2`, waits for the PNG (up to five seconds), returns it inline and
deletes the temporary file. No arguments, no setup.

The engine grabs the scene render target. Dear ImGui is drawn on top of the frame after that
target, so **ImGui overlays are absent from these images by design**. If a mod draws gauges or a
minimap with ImGui, an empty area where the widget should be is what a working widget looks like in
this capture. Use `screenshot_native` or the desktop-capture script to see them.

Requires BeamNG.drive 0.39 or later (older versions used a different capture function).

## `screenshot_native`

Asks Steam's overlay to take a screenshot. The overlay hooks the swapchain after ImGui has been
drawn, so its image is the full frame as presented on screen. The tool waits for Steam to write the
JPEG (up to about twelve seconds; usually under one), reads it and returns it inline.

Before triggering, the tool checks the preconditions and returns a specific error if one fails:

- The game's online service is Steam, the Steam API is initialised (the game was launched through
  Steam), and a Steam account is logged in.
- The `/steamshots` folder is reachable (see setup below).
- The game is presenting frames. A minimised window has no frames to capture; restore it. Focus is
  not required, so the game can sit behind other windows.

If Steam never writes the file, the error mentions BeamNG's `onlineFeatures` setting when it is not
enabled, since that may suppress the capture.

### One-time setup

Steam saves screenshots under its own `userdata` folder, outside the game's virtual file system, and
the game's Lua sandbox cannot read outside that file system. A directory junction from the BeamNG
user folder into Steam's screenshot folder gives the tool access. Create it once per machine:

```powershell
powershell -File scripts\link-steam-screenshots.ps1
```

This creates `<BeamNG user folder>\steamshots`, pointing at
`<Steam>\userdata\<account>\760\remote\284160\screenshots`, which the tool reads as `/steamshots`.
A junction needs no administrator rights or Developer Mode.

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-UserPath` | `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current` | BeamNG user folder to create the link in |
| `-AppId` | `284160` | Steam app id (BeamNG.drive) |
| `-AccountId` | auto-detected | 32-bit Steam account id (the `userdata` folder name). Needed when several accounts on the machine have BeamNG screenshots |
| `-Remove` | | Remove the junction only, leaving the screenshots in place |

Steam creates the screenshot folder lazily. If the script says it can't find it, take one
screenshot in game with F12 first, then run the script again. Running it again when the link exists
just verifies it.

> **Warning:** `steamshots` is a junction into your real Steam screenshot library. Deleting it
> recursively (`Remove-Item -Recurse`, `rm -rf`, a cleanup tool) deletes your screenshots, not just
> the link. Remove it with `link-steam-screenshots.ps1 -Remove` (or `cmd /c rmdir`), which refuses to
> touch anything that isn't a junction.

### Captures are kept, prune them with Steam closed

`screenshot_native` does not delete its captures. Steam records every screenshot in
`userdata\<account>\760\screenshots.vdf` when it is taken. Deleting only the `.jpg` leaves that
record behind, and Steam's screenshot manager then shows a broken "missing file" entry that Steam
never cleans up. Editing the `.vdf` while Steam runs doesn't help either, because Steam rewrites it
from memory on exit.

`scripts/prune-steam-screenshots.ps1` removes the image, its thumbnail and its `.vdf` entry
together. It refuses to run while Steam is running, and it is a dry run unless you add `-Apply`:

```powershell
# Close Steam fully first.
powershell -File scripts\prune-steam-screenshots.ps1 -OlderThanDays 7            # show what would go
powershell -File scripts\prune-steam-screenshots.ps1 -OlderThanDays 7 -Apply     # do it
powershell -File scripts\prune-steam-screenshots.ps1 -RepairOrphans -Apply       # fix entries whose file is already gone
powershell -File scripts\prune-steam-screenshots.ps1 -Names 20260101123456_1.jpg -Apply
```

| Parameter | Meaning |
|-----------|---------|
| `-OlderThanDays N` | Prune every BeamNG capture older than N days |
| `-Names a.jpg,b.jpg` | Prune these captures |
| `-RepairOrphans` | Drop `.vdf` entries whose image no longer exists (repairs an earlier file-only delete) |
| `-Apply` | Actually write. Without it, nothing changes |
| `-AppId`, `-AccountId` | As above; the account is auto-detected when only one has a `screenshots.vdf` |

Before writing, the script copies `screenshots.vdf` to `screenshots.vdf.bak-<timestamp>`. After
starting Steam again, check **View > Screenshots**; if anything looks wrong, restore the backup with
Steam closed.

Note that the pruning applies to all BeamNG screenshots in that account, including ones you took
yourself.

## `scripts/capture-window.ps1` (Windows, no Steam)

For a non-Steam install, or when the Steam overlay is unavailable, this script copies the game
window's area of the desktop to a PNG, so it contains exactly what is on screen, ImGui overlays
included. It runs outside the game, so it is not an MCP tool: run it yourself, or let an agent with
shell access (Claude Code, Codex) run it and then open the PNG.

```powershell
powershell -File scripts\capture-window.ps1                    # capture BeamNG, prints the PNG path
powershell -File scripts\capture-window.ps1 -List              # list matching windows, capture nothing
powershell -File scripts\capture-window.ps1 -OutFile shot.png -Focus
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-ProcessName` | `BeamNG` | Case-insensitive substring of the process name |
| `-OutFile` | timestamped file in `%TEMP%` | Where to write the PNG |
| `-List` | | List candidate windows and exit |
| `-Focus` | | Bring the window to the front and wait `-SettleMs` before capturing |
| `-SettleMs` | `400` | Settle delay after `-Focus` |
| `-AllowOccluded` | | Capture even if another window overlaps the game |

Things to know:

- It copies from the screen, so anything covering the window would be captured too. By default it
  refuses when another window overlaps the game window; `-AllowOccluded` overrides that.
- The window does not need focus, but an unfocused BeamNG lowers its frame rate, so the frame can be
  slightly old. Use `-Focus` for animated content.
- It is DPI-aware, so captures on scaled displays are not cropped.
- On Linux, use the compositor's own screenshot tool instead (for example `grim` or `spectacle`).
