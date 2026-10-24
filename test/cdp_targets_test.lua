require("support.beamng_stubs")            -- jsonDecode/jsonEncode/log
local targets = require("beammcp/cdp/targets")

local SAMPLE = '[' ..
  '{"type":"page","title":"BeamNG Main UI","url":"local://local/ui/entrypoints/main/index.html#/play","webSocketDebuggerUrl":"ws://localhost:8080/devtools/page/AAA"},' ..
  '{"type":"page","title":"52535-@sunburst2_gauges_display","url":"local://local/vehicles/sunburst2/gauges_screen/gauges_screen.html","webSocketDebuggerUrl":"ws://localhost:8080/devtools/page/BBB"}' ..
  ']'

-- Real shape captured from a SteamOS box where Steam's web-helper CEF squats :8080 (the same default debug
-- port as BeamNG's -cefdev). All targets are about:blank?.../steamloopback.host — never the local:// scheme.
local STEAM_SAMPLE = '[' ..
  '{"type":"page","title":"Library Supernav","url":"about:blank?createflags=4538378&pid=0&browser=-1"},' ..
  '{"type":"page","title":"Store Supernav","url":"about:blank?createflags=4538378&pid=0&browser=-1"},' ..
  '{"type":"page","title":"SharedJSContext","url":"https://steamloopback.host/routes/library/home"}' ..
  ']'

-- Mixed: a Steam page whose URL CONTAINS the default needle "main/index.html" alongside the real BeamNG page.
-- select must still pick the BeamNG (local://) target, never the foreign one that merely matches the needle.
local MIXED = '[' ..
  '{"type":"page","title":"Steam Root Menu","url":"about:blank?createflags=4538378&decoy=main/index.html"},' ..
  '{"type":"page","title":"BeamNG Main UI","url":"local://local/ui/entrypoints/main/index.html#/play","webSocketDebuggerUrl":"ws://localhost:8080/devtools/page/AAA"}' ..
  ']'

test("discover: valid body -> targets array", function()
  local list, err = targets.discover(function() return SAMPLE end)
  assertNil(err)
  assertEqual(#list, 2)
  assertEqual(list[1].title, "BeamNG Main UI")
end)

test("discover: httpGet error -> not-reachable message", function()
  local list, err = targets.discover(function() error("conn refused") end)
  assertNil(list)
  assertMatch(err, "not reachable")
end)

test("discover: empty body -> not-reachable message", function()
  local list, err = targets.discover(function() return "" end)
  assertNil(list)
  assertMatch(err, "not reachable")
end)

test("discover: malformed json -> malformed message", function()
  local list, err = targets.discover(function() return "not json{" end)
  assertNil(list)
  assertMatch(err, "malformed")
end)

test("select: default needle picks the Main UI page", function()
  local list = targets.discover(function() return SAMPLE end)
  local ws = targets.select(list, nil)
  assertEqual(ws, "ws://localhost:8080/devtools/page/AAA")
end)

test("select: substring matches a non-default target", function()
  local list = targets.discover(function() return SAMPLE end)
  local ws = targets.select(list, "gauges")
  assertEqual(ws, "ws://localhost:8080/devtools/page/BBB")
end)

test("select: no match -> error listing available titles", function()
  local list = targets.discover(function() return SAMPLE end)
  local ws, err = targets.select(list, "nonexistent")
  assertNil(ws)
  assertMatch(err, "no BeamNG target")
  assertMatch(err, "BeamNG Main UI")
end)

test("curate: keeps only BeamNG local:// page targets, drops foreign (Steam) ones", function()
  local list = targets.discover(function() return MIXED end)
  local beamng = targets.curate(list)
  assertEqual(#beamng, 1)
  assertMatch(beamng[1].url, "^local://")
end)

test("select: a foreign (Steam) endpoint -> clear not-BeamNG error naming the port", function()
  local list = targets.discover(function() return STEAM_SAMPLE end)
  local ws, err = targets.select(list, nil)
  assertNil(ws)
  assertMatch(err, "none are BeamNG")
  assertMatch(err, "Steam")           -- names the likely culprit
  assertMatch(err, ":" .. tostring(targets.CDP_PORT))  -- and the port
end)

test("select: never picks a Steam target even when it matches the needle (picks BeamNG local://)", function()
  local list = targets.discover(function() return MIXED end)
  -- both the decoy Steam url and the BeamNG url contain "main/index.html"
  local ws = targets.select(list, "main/index.html")
  assertEqual(ws, "ws://localhost:8080/devtools/page/AAA")  -- the BeamNG (local://) target, not Steam
end)

test("select: foreign-endpoint error reports the configured cefPort", function()
  local saved = targets.CDP_PORT
  targets.CDP_PORT = 9999
  local list = targets.discover(function() return STEAM_SAMPLE end)
  local _, err = targets.select(list, nil)
  targets.CDP_PORT = saved
  assertMatch(err, ":9999")
end)
