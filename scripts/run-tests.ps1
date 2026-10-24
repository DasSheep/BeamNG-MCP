# Runs all off-engine core tests through the tiny runner.
$ErrorActionPreference = "Stop"

# Resolve luajit: PATH first, then the winget install location (handles stale-PATH shells).
$luajit = (Get-Command luajit -ErrorAction SilentlyContinue).Source
if (-not $luajit) { $luajit = Join-Path $env:LOCALAPPDATA 'Programs\LuaJIT\bin\luajit.exe' }
if (-not (Test-Path $luajit)) {
  Write-Error "luajit not found. Install with: winget install -e --id DEVCOM.LuaJIT"
  exit 1
}

$tests = @(Get-ChildItem -Path test -Filter *_test.lua | ForEach-Object { "test/$($_.Name)" })
& $luajit test/runner.lua $tests
exit $LASTEXITCODE
