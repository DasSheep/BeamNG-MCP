<#
.SYNOPSIS
  Capture a window's on-screen pixels to a PNG, including layers the engine's own screenshot cannot see.

.DESCRIPTION
  BeamNG's createScreenshot2 (used by the `screenshot` MCP tool) grabs the SCENE RENDER TARGET only:
  bufferType accepts "color" / "normals" / "depth". Dear ImGui composites downstream of that target,
  so ImGui overlays (a mod's gauges, minimap, HUD panels) are absent from those images on both the
  D3D12 and Vulkan backends. A blank widget box in such a capture is the expected look of a working
  gauge.

  The MCP server runs inside the game's Lua sandbox, which has no host-OS reach (io.popen is nil,
  ffi.load is denied, os.execute is an inert stub), so it cannot grab the desktop itself. This script
  does it from outside the game: it copies the window's region of the composited desktop, so the
  image contains exactly what is on screen, ImGui overlays included.

  When to use which:
    - `screenshot`        - scene only (3D world + CEF UI), cross-platform, no setup.
    - `screenshot_native` - full presented frame via Steam's overlay capture. Prefer it on a Steam
                            install: it works while the window is in the background (not while
                            minimised). Its captures land in the Steam screenshot library; see
                            link-steam-screenshots.ps1 / prune-steam-screenshots.ps1.
    - this script         - full presented frame on a non-Steam install, or when Steam's overlay is
                            unavailable.

  LIMITATION: WINDOWS ONLY. On Linux the equivalent is a compositor grab (grim / spectacle / `import`).

.PARAMETER ProcessName
  Substring matched against the process name (case-insensitive). Default 'BeamNG'.

.PARAMETER OutFile
  PNG path to write. Default: a timestamped file under %TEMP%.

.PARAMETER List
  List matching windows and exit without capturing.

.PARAMETER Focus
  Raise the window and wait -SettleMs before capturing (use for animated content; an unfocused
  BeamNG throttles its render rate, so the frame can be stale).

.PARAMETER AllowOccluded
  Capture even when another window overlaps the target (off by default).

.PARAMETER SettleMs
  Settle delay after raising the window. Default 400.

.NOTES
  ASCII ONLY, DELIBERATELY. PowerShell 5.1 decodes a BOM-less .ps1 as ANSI, so a stray em dash is a
  parse error rather than a cosmetic issue. Do not add non-ASCII characters to this file.

  DPI: the process is marked DPI-aware before any rect is read, so window rects come back in PHYSICAL
  pixels. Without that, a scaled display yields a logical-pixel rect and the capture is silently
  cropped.

  Occlusion: this copies from the SCREEN, so anything covering the window is captured too. That is a
  deliberate trade. PrintWindow can grab an occluded window but returns black for many
  GPU-composited surfaces, which is precisely the plausible-but-wrong output that motivated this
  script. A visibly-wrong capture beats a silently-empty one.

  FOREGROUND IS NOT THE REQUIREMENT - OCCLUSION IS. A capture of a backgrounded BeamNG window
  carries the same content as a focused one, so the script does NOT demand focus. It refuses only
  when another visible window actually OVERLAPS the target rect, which is the condition that
  corrupts the image. One caveat focus does own: an unfocused BeamNG throttles its render rate, so
  the captured frame can be STALE (old, not wrong). That matters for anything animated - see -Focus.

.EXAMPLE
  ./capture-window.ps1                  # capture BeamNG, print the PNG path
  ./capture-window.ps1 -List            # list candidate windows and exit
  ./capture-window.ps1 -OutFile shot.png
#>
[CmdletBinding()]
param(
  # Substring matched against the process name (case-insensitive). BeamNG ships as BeamNG.drive.x64.
  [string] $ProcessName = 'BeamNG',
  # Where to write the PNG. Defaults to a timestamped file under the user's TEMP.
  [string] $OutFile,
  # List matching windows and exit without capturing.
  [switch] $List,
  # Raise the target window and wait for it to settle before capturing. Use for animated content:
  # an unfocused BeamNG throttles its render rate, so the frame can be stale.
  [switch] $Focus,
  # Capture even when another window overlaps the target. Off by default: an occluded capture is
  # silently wrong, which is the exact failure class this script exists to avoid.
  [switch] $AllowOccluded,
  # Settle delay after raising the window, so the game presents a fresh frame.
  [int] $SettleMs = 400
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

if (-not ('Win32CaptureNative' -as [type])) {
  # NOTE: -MemberDefinition already emits `using System.Runtime.InteropServices;`. Adding it via
  # -UsingNamespace duplicates the directive, and Add-Type compiles warnings-as-errors, so it fails.
  Add-Type -Namespace '' -Name 'Win32CaptureNative' -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int max);

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

    // DWM bounds exclude the invisible resize border that Windows 10+ reports via GetWindowRect.
    // DWMWA_CLOAKED (14) identifies UWP "ghost" windows that are visible per IsWindowVisible but
    // are not actually composited - without this they show up as phantom occluders.
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(
        IntPtr hWnd, int attr, out RECT value, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(
        IntPtr hWnd, int attr, out int value, int size);
'@
}

# Top-level visible windows sitting ABOVE $target in Z-order whose rect overlaps $rect.
# EnumWindows yields windows in Z-order (topmost first), so everything before the target is above it.
function Get-Occluders {
  param([IntPtr] $Target, [object] $Rect)
  $above = New-Object System.Collections.ArrayList
  $reached = $false
  $cb = [Win32CaptureNative+EnumProc] {
    param($h, $l)
    if ($h -eq $Target) { $script:reachedTarget = $true; return $false }  # stop: rest are below
    [void]$above.Add($h)
    return $true
  }
  $script:reachedTarget = $false
  [void][Win32CaptureNative]::EnumWindows($cb, [IntPtr]::Zero)
  if (-not $script:reachedTarget) { return @() }   # target not enumerated; do not guess

  $hits = @()
  foreach ($h in $above) {
    if (-not [Win32CaptureNative]::IsWindowVisible($h)) { continue }
    if ([Win32CaptureNative]::IsIconic($h)) { continue }
    $cloaked = 0
    if ([Win32CaptureNative]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4) -eq 0 -and $cloaked -ne 0) { continue }
    $r = New-Object Win32CaptureNative+RECT
    if ([Win32CaptureNative]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) {
      if (-not [Win32CaptureNative]::GetWindowRect($h, [ref]$r)) { continue }
    }
    $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { continue }
    # Rect intersection against the capture region.
    if ($r.Left -lt $Rect.Right -and $r.Right -gt $Rect.Left -and
        $r.Top  -lt $Rect.Bottom -and $r.Bottom -gt $Rect.Top) {
      $len = [Win32CaptureNative]::GetWindowTextLength($h)
      $title = ''
      if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [void][Win32CaptureNative]::GetWindowText($h, $sb, $sb.Capacity)
        $title = $sb.ToString()
      }
      if ($title -eq '') { continue }   # untitled shells are chrome, not real occluders
      $hits += "'$title' at $($r.Left),$($r.Top) ${w}x${ht}"
    }
  }
  return $hits
}

# Physical pixels, not logical. Must happen before any rect is read.
[void][Win32CaptureNative]::SetProcessDPIAware()

$candidates = @(Get-Process |
  Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -like "*$ProcessName*" })

if ($List) {
  if ($candidates.Count -eq 0) { Write-Host "No windowed process matches '*$ProcessName*'."; exit 0 }
  $candidates | ForEach-Object {
    "{0,-28} pid={1,-8} hwnd={2} title='{3}'" -f $_.ProcessName, $_.Id, $_.MainWindowHandle, $_.MainWindowTitle
  }
  exit 0
}

if ($candidates.Count -eq 0) {
  throw "No windowed process matches '*$ProcessName*'. Run with -List to see what is available."
}
if ($candidates.Count -gt 1) {
  $names = ($candidates | ForEach-Object { "$($_.ProcessName)(pid $($_.Id))" }) -join ', '
  throw "Ambiguous: $($candidates.Count) windows match '*$ProcessName*' -> $names. Narrow -ProcessName."
}

$proc = $candidates[0]
$hwnd = $proc.MainWindowHandle

# Fail loudly rather than return a screen copy of a window that is not on screen.
if ([Win32CaptureNative]::IsIconic($hwnd)) {
  throw "'$($proc.ProcessName)' (pid $($proc.Id)) is MINIMISED. Restore it first; a screen copy of a minimised window is meaningless."
}

# DWMWA_EXTENDED_FRAME_BOUNDS = 9. Fall back to GetWindowRect if DWM declines.
$rect = New-Object Win32CaptureNative+RECT
$hr = [Win32CaptureNative]::DwmGetWindowAttribute($hwnd, 9, [ref]$rect, 16)
if ($hr -ne 0) {
  if (-not [Win32CaptureNative]::GetWindowRect($hwnd, [ref]$rect)) {
    throw "Could not read the window rect for pid $($proc.Id) (DWM hr=$hr, GetWindowRect failed)."
  }
}

$width  = $rect.Right  - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -le 0 -or $height -le 0) {
  throw "Degenerate window rect ${width}x${height} for pid $($proc.Id). Refusing to write an empty image."
}

if (-not $OutFile) {
  $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
  $OutFile = Join-Path $env:TEMP "beamng_window_$stamp.png"
}
$OutFile = [System.IO.Path]::GetFullPath($OutFile)
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# Raise first if asked, so the settle delay and the occlusion check both see the final state.
# NOTE: SetForegroundWindow is REFUSED by Windows for many background callers and returns false
# without raising anything. Verify against GetForegroundWindow rather than trusting the return
# value: check the behaviour, not the call's own report.
if ($Focus) {
  [void][Win32CaptureNative]::ShowWindow($hwnd, 9)      # SW_RESTORE
  [void][Win32CaptureNative]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds $SettleMs
  if ([Win32CaptureNative]::GetForegroundWindow() -ne $hwnd) {
    Write-Warning "-Focus did not take: Windows refused to raise pid $($proc.Id). Capturing anyway; the frame may be stale, and click the window yourself if it matters."
  }
}

if (-not $AllowOccluded) {
  $occ = Get-Occluders -Target $hwnd -Rect $rect
  if ($occ.Count -gt 0) {
    throw ("OCCLUDED: {0} window(s) overlap the capture region, so the image would contain them instead of the game -> {1}. Move/minimise them, or re-run with -Focus, or pass -AllowOccluded to capture regardless." -f $occ.Count, ($occ -join '; '))
  }
}

$bmp = $null; $gfx = $null
try {
  $bmp = New-Object System.Drawing.Bitmap($width, $height)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size,
                      [System.Drawing.CopyPixelOperation]::SourceCopy)
  $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
  if ($gfx) { $gfx.Dispose() }
  if ($bmp) { $bmp.Dispose() }
}

Write-Host ("captured {0}x{1} from {2} (pid {3}) -> {4}" -f `
  $width, $height, $proc.ProcessName, $proc.Id, $OutFile)
Write-Output $OutFile
