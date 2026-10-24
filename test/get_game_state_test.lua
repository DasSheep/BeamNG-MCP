require("support.beamng_stubs")
local ggs      = require("beammcp/tools/get_game_state")
local registry = require("core.registry")

test("handler merges readState with mainMenu(false) and menuOpen", function()
  ggs.readState = function() return { paused = false, simSpeed = 1, level = "gridmap_v2",
    mission = "/levels/gridmap_v2/main.level.json", playerVehicleId = 45, resolution = "1438 1224" } end
  ggs.menuOpenSource = function() return false end
  local s, err = ggs.def.handler({})
  assertNil(err)
  assertEqual(s.level, "gridmap_v2")
  assertEqual(s.playerVehicleId, 45)
  assertEqual(s.resolution, "1438 1224")
  assertEqual(s.mainMenu, false)
  assertEqual(s.menuOpen, false)
end)

test("mainMenu is true when mission is empty", function()
  ggs.readState = function() return { mission = "" } end
  ggs.menuOpenSource = function() return false end
  local s = ggs.def.handler({})
  assertEqual(s.mainMenu, true)
end)

test("menuOpen reflects menuOpenSource", function()
  ggs.readState = function() return { mission = "/x" } end
  ggs.menuOpenSource = function() return true end
  local s = ggs.def.handler({})
  assertEqual(s.menuOpen, true)
end)

test("menuOpen defaults to false when no source is wired", function()
  ggs.readState = function() return { mission = "/x" } end
  ggs.menuOpenSource = nil
  local s = ggs.def.handler({})
  assertEqual(s.menuOpen, false)
end)

test("register adds it under 'get_game_state'", function()
  local r = registry.new()
  ggs.register(r)
  assertEqual(r:list()[1].name, "get_game_state")
end)

test("multiplayer field from readState passes through", function()
  ggs.readState = function() return { mission = "/x", multiplayer = true } end
  ggs.menuOpenSource = function() return false end
  local s = ggs.def.handler({})
  assertEqual(s.multiplayer, true)
end)

-- earlier tests stub ggs.readState, so exercise the REAL one on a fresh module instance
local function freshGgs()
  package.loaded["beammcp/tools/get_game_state"] = nil
  return require("beammcp/tools/get_game_state")
end

test("readState includes timeOfDay (folded in from the retired get_session_info)", function()
  _G.core_environment = { getTimeOfDay = function()
    return { time = 0.5, dayLength = 120, dayScale = 1, azimuthOverride = 0 }
  end }
  local s = freshGgs().readState()
  assertEqual(s.timeOfDay.time, 0.5)
  assertEqual(s.timeOfDay.dayLength, 120)
  assertEqual(s.timeOfDay.dayScale, 1)
  assertNil(s.timeOfDay.azimuthOverride)   -- curated fields only
  _G.core_environment = nil
end)

test("readState degrades timeOfDay to nil when core_environment is absent", function()
  _G.core_environment = nil
  local s = freshGgs().readState()
  assertNil(s.timeOfDay)
end)

test("lastReloadRecovery is included when the source returns a report", function()
  ggs.readState = function() return { mission = "/x" } end
  ggs.menuOpenSource = function() return false end
  ggs.lastReloadSource = function() return { classification = "normal", repaired = { "nightlights" } } end
  local s = ggs.def.handler({})
  assertEqual(s.lastReloadRecovery.classification, "normal")
  ggs.lastReloadSource = nil
end)

test("lastReloadRecovery is omitted when there was no reload", function()
  ggs.readState = function() return { mission = "/x" } end
  ggs.menuOpenSource = function() return false end
  ggs.lastReloadSource = function() return nil end
  assertNil(ggs.def.handler({}).lastReloadRecovery)
  ggs.lastReloadSource = nil
  assertNil(ggs.def.handler({}).lastReloadRecovery)
end)
