local mp = require("beammcp/tools/lib/mp")

-- shouldRefuse(probe): refuse if a session is active OR the mod is present but unreadable (fail-safe).
test("shouldRefuse: mod absent -> false (allow)", function()
  assertEqual(mp.shouldRefuse({ modLoaded = false, sessionActive = false }), false)
end)

test("shouldRefuse: mod present + session inactive -> false (allow)", function()
  assertEqual(mp.shouldRefuse({ modLoaded = true, sessionActive = false }), false)
end)

test("shouldRefuse: mod present + session active -> true (refuse)", function()
  assertEqual(mp.shouldRefuse({ modLoaded = true, sessionActive = true }), true)
end)

test("shouldRefuse: mod present + session unreadable(nil) -> true (fail-safe refuse)", function()
  assertEqual(mp.shouldRefuse({ modLoaded = true, sessionActive = nil }), true)
end)

-- isActive(probe): definitive in-session only (NOT the fail-safe unreadable case).
test("isActive: only definitive active session is true", function()
  assertEqual(mp.isActive({ modLoaded = true, sessionActive = true }), true)
  assertEqual(mp.isActive({ modLoaded = true, sessionActive = false }), false)
  assertEqual(mp.isActive({ modLoaded = true, sessionActive = nil }), false)
  assertEqual(mp.isActive({ modLoaded = false, sessionActive = false }), false)
end)

-- probe(): off-engine the BeamMP globals are absent -> modLoaded false.
test("probe: no BeamMP globals -> modLoaded false, sessionActive false", function()
  local p = mp.probe()
  assertEqual(p.modLoaded, false)
  assertEqual(p.sessionActive, false)
end)

test("probe: a present MPCoreNetwork global is detected as modLoaded", function()
  local saved = rawget(_G, "MPCoreNetwork")
  rawset(_G, "MPCoreNetwork", { isMPSession = function() return true end })
  local p = mp.probe()
  rawset(_G, "MPCoreNetwork", saved)
  assertEqual(p.modLoaded, true)
  assertEqual(p.sessionActive, true)
end)
