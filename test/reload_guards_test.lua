require("support.beamng_stubs")
local stub = require("support.stub")
local env  = require("beammcp/reload/env")

local MISSION = "/levels/west_coast_usa/main.level.json"
local inLevel = { mission = function() return MISSION end }
local inMenu  = { mission = function() return "" end }

-- ============================== levelflag ==============================
local levelflag = require("beammcp/reload/guards/levelflag")

test("levelflag: skipped in the main menu", function()
  stub.with(env, inMenu, function()
    assertEqual(levelflag.check({}).skip, "no level loaded")
  end)
end)

test("levelflag: ok when levelLoaded is set", function()
  stub.with(env, inLevel, function()
    stub.with(_G, { levelLoaded = "/levels/west_coast_usa/" }, function()
      assertNil(levelflag.check({}))
    end)
  end)
end)

test("levelflag: issue when nil; repair prefers the snapshot value, then is a no-op", function()
  stub.with(env, inLevel, function()
    stub.with(_G, { levelLoaded = stub.NIL }, function()
      assertMatch(levelflag.check({}).issue, "levelLoaded is nil")
      levelflag.repair({ snap = { levelLoaded = "/levels/west_coast_usa/" } })
      assertEqual(rawget(_G, "levelLoaded"), "/levels/west_coast_usa/")
      assertNil(levelflag.check({}))
      levelflag.repair({ snap = { levelLoaded = "/levels/west_coast_usa/" } })  -- idempotent
      assertEqual(rawget(_G, "levelLoaded"), "/levels/west_coast_usa/")
    end)
  end)
end)

test("levelflag: repair without a snapshot derives the dir from the mission", function()
  stub.with(env, inLevel, function()
    stub.with(_G, { levelLoaded = stub.NIL }, function()
      levelflag.repair({})
      assertEqual(rawget(_G, "levelLoaded"), "/levels/west_coast_usa/")
    end)
  end)
end)

-- ============================== camera ==============================
local camera = require("beammcp/reload/guards/camera")

-- fake core_camera. registry: vid -> {mode=true,...}; spawnFills: what onVehicleSpawned puts in the registry
local function fakeCam(o)
  local c = { global = o.global, mode = o.mode or o.global, registry = o.registry or {}, calls = {} }
  c.getActiveGlobalCameraName = function() return c.global end
  c.getActiveCamName = function() return c.mode end
  c.getCameraDataById = function(id) return c.registry[id] end
  c.onVehicleSpawned = function(id) c.calls[#c.calls + 1] = "spawned:" .. id; c.registry[id] = o.spawnFills end
  c.setByName = function(a, b)
    if type(a) == "number" then c.mode = b; c.global = nil; c.calls[#c.calls + 1] = "set:" .. b
    else c.global = a; c.mode = a; c.calls[#c.calls + 1] = "global:" .. a end
  end
  return c
end
local VEH = { getID = function() return 5 end }
local FULL = { orbit = true, driver = true, chase = true }

-- o: { cam, veh, vdata, dist }; returns a record of freecam moves
local function withCam(o, fn)
  local rec = { moved = 0 }
  stub.with(env, inLevel, function()
    stub.with(camera, { cam = function() return o.cam end, playerVehicle = function() return o.veh end,
                        vehicleData = function() return o.vdata end,
                        distanceToVehicle = function() return o.dist or 0 end,
                        moveFreecamNear = function() rec.moved = rec.moved + 1 end }, function() fn(rec) end)
  end)
  return rec
end

test("camera: skipped in menu", function()
  stub.with(env, inMenu, function() assertEqual(camera.check({}).skip, "no level loaded") end)
end)

test("camera: healthy vehicle camera -> ok", function()
  withCam({ cam = fakeCam({ mode = "orbit", registry = { [5] = FULL } }), veh = VEH }, function()
    assertNil(camera.check({}))
  end)
end)

test("camera: a freecam the operator chose (snapshot shows it) is never overridden", function()
  local c = fakeCam({ global = "free", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function()
    local ctx = { snap = { camGlobal = "free", camMode = "free" } }
    assertNil(camera.check(ctx))
    assertEqual(c.global, "free")
    assertEqual(#c.calls, 0)
  end)
end)

test("camera: without a snapshot (manual mode) an active global camera is left alone", function()
  local c = fakeCam({ global = "free", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function() assertNil(camera.check({})) end)
end)

test("camera: engine fallback to freecam (snapshot had none) -> back to the snapshot vehicle mode", function()
  local c = fakeCam({ global = "smoothFree", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function()
    local ctx = { snap = { camMode = "driver" } }   -- camGlobal nil: no global camera before the reload
    assertMatch(camera.check(ctx).issue, "fell back to global camera 'smoothFree'")
    camera.repair(ctx)
    assertEqual(c.mode, "driver")
    assertNil(c.global)
    assertNil(camera.check(ctx))
  end)
end)

test("camera: empty registry with vehicle data is rebuilt, then the snapshot mode is restored", function()
  local c = fakeCam({ registry = {}, spawnFills = FULL })
  withCam({ cam = c, veh = VEH, vdata = { vdata = {} } }, function()
    assertMatch(camera.check({}).issue, "registry empty")
    camera.repair({ snap = { camMode = "driver" } })
    assertEqual(c.calls[1], "spawned:5")
    assertEqual(c.mode, "driver")
    assertNil(camera.check({}))
  end)
end)

test("camera: vehicle data lost + stranded freecam -> freecam moved to the car, mitigated, vehicle untouched", function()
  local c = fakeCam({ global = "smoothFree", registry = {}, spawnFills = FULL })
  local rec = withCam({ cam = c, veh = VEH, vdata = nil, dist = 400 }, function()
    local res = camera.repair({ snap = { camMode = "orbit" } })
    assertEqual(res.mitigated, camera.MITIGATION)
    assertMatch(camera.MITIGATION, "Ctrl%+R")
    assertEqual(#c.calls, 0, "no onVehicleSpawned / setByName without vehicle data")
  end)
  assertEqual(rec.moved, 1)
end)

test("camera: vehicle data lost, freecam already near the car -> not moved, still mitigated", function()
  local c = fakeCam({ global = "smoothFree", registry = {} })
  local rec = withCam({ cam = c, veh = VEH, dist = 10 }, function()
    assertEqual(camera.repair({ snap = {} }).mitigated, camera.MITIGATION)
  end)
  assertEqual(rec.moved, 0)
end)

test("camera: vehicle data lost, global is neither free nor smoothFree -> not moved, still mitigated", function()
  local c = fakeCam({ global = "someOtherGlobal", registry = {}, spawnFills = FULL })
  local rec = withCam({ cam = c, veh = VEH, vdata = nil, dist = 400 }, function()
    local res = camera.repair({ snap = { camMode = "orbit" } })
    assertEqual(res.mitigated, camera.MITIGATION)
  end)
  assertEqual(rec.moved, 0)
end)

test("camera: isFallback requires camMode evidence too - a failed snapshot read never overrides an operator freecam", function()
  local c = fakeCam({ global = "free", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function()
    local ctx = { snap = {} }  -- camGlobal nil AND camMode nil: no evidence the snapshot camera was ever read
    assertNil(camera.check(ctx))
    camera.repair(ctx)
    assertEqual(c.global, "free")
    assertEqual(#c.calls, 0)
  end)
end)

test("camera: invalid active mode falls back current -> orbit", function()
  local c = fakeCam({ mode = "bogus", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function()
    assertMatch(camera.check({}).issue, "no active vehicle camera")
    camera.repair({ snap = { camMode = "alsoBogus" } })
    assertEqual(c.mode, "orbit")
    assertNil(camera.check({}))
  end)
end)

test("camera: no vehicle and no global -> free camera", function()
  local c = fakeCam({})
  withCam({ cam = c, veh = nil }, function()
    assertMatch(camera.check({}).issue, "no vehicle and no global")
    camera.repair({})
    assertEqual(c.global, "free")
    assertNil(camera.check({}))
  end)
end)

test("camera: repair is idempotent on a healthy camera", function()
  local c = fakeCam({ mode = "orbit", registry = { [5] = FULL } })
  withCam({ cam = c, veh = VEH }, function()
    camera.repair({ snap = { camMode = "orbit" } })
    camera.repair({ snap = { camMode = "orbit" } })
    assertEqual(c.mode, "orbit")
    assertEqual(#c.calls, 0)
  end)
end)

-- ============================== camera.followUp ==============================
-- The engine's own freecam fallback lands ~1 s AFTER our heal (the levelflag repair re-opens the
-- camera-update gate). followUp is polled for a short window afterward to catch it once it appears.

test("camera followUp: no global camera yet -> false, not moved", function()
  local c = fakeCam({ registry = { [5] = FULL } })   -- no global camera active
  local rec = withCam({ cam = c, veh = VEH, dist = 900 }, function()
    assertEqual(camera.followUp({}), false)
  end)
  assertEqual(rec.moved, 0)
end)

test("camera followUp: free fallback appeared, stranded -> moved, true", function()
  local c = fakeCam({ global = "free" })
  local rec = withCam({ cam = c, veh = VEH, dist = 900 }, function()
    assertEqual(camera.followUp({}), true)
  end)
  assertEqual(rec.moved, 1)
end)

test("camera followUp: smoothFree fallback already near the car -> true, not moved", function()
  local c = fakeCam({ global = "smoothFree" })
  local rec = withCam({ cam = c, veh = VEH, dist = 10 }, function()
    assertEqual(camera.followUp({}), true)
  end)
  assertEqual(rec.moved, 0)
end)

-- ============================== gamestate ==============================
local gamestate = require("beammcp/reload/guards/gamestate")

local function fakeGs(state)
  local g = { state = state, sets = {} }
  g.setGameState = function(s, layout, menu, opts)
    g.sets[#g.sets + 1] = { s, layout, menu, opts }
    g.state = { state = s, appLayout = layout, menuItems = menu, options = opts }
  end
  return g
end

test("gamestate: ok when a state is set", function()
  stub.with(env, inLevel, function()
    stub.with(gamestate, { gs = function() return fakeGs({ state = "freeroam" }) end }, function()
      assertNil(gamestate.check({}))
    end)
  end)
end)

test("gamestate: empty state restored from the snapshot", function()
  local g = fakeGs({})
  stub.with(env, inLevel, function()
    stub.with(gamestate, { gs = function() return g end }, function()
      assertMatch(gamestate.check({}).issue, "game state is empty")
      gamestate.repair({ snap = { gamestate = { state = "scenario", appLayout = "scenario", menuItems = "freeroam" } } })
      assertEqual(g.state.state, "scenario")
      assertEqual(g.sets[1][2], "scenario")
      assertNil(gamestate.check({}))
    end)
  end)
end)

test("gamestate: no snapshot -> freeroam default", function()
  local g = fakeGs({})
  stub.with(env, inLevel, function()
    stub.with(gamestate, { gs = function() return g end }, function()
      gamestate.repair({})
      assertEqual(g.state.state, "freeroam")
      assertEqual(g.state.appLayout, "freeroam")
    end)
  end)
end)

test("gamestate: skipped in menu", function()
  stub.with(env, inMenu, function() assertEqual(gamestate.check({}).skip, "no level loaded") end)
end)

-- ============================== nightlights ==============================
local nightlights = require("beammcp/reload/guards/nightlights")

test("nightlights: readRegistry finds the nightLights upvalue on core_environment", function()
  local nightLights = { initialized = true, lights = {} }
  local fakeEnv = { getTimeOfDay = function() return nightLights.initialized end }  -- closes over nightLights
  stub.with(_G, { core_environment = fakeEnv }, function()
    assertEqual(nightlights.readRegistry(), nightLights)
  end)
end)

test("nightlights: readRegistry returns nil when absent", function()
  stub.with(_G, { core_environment = stub.NIL }, function() assertNil(nightlights.readRegistry()) end)
  stub.with(_G, { core_environment = { f = function() return 1 end } }, function()
    assertNil(nightlights.readRegistry())
  end)
end)

test("nightlights: uninitialized registry -> issue; refresh repairs it", function()
  local reg = { initialized = false }
  local refreshed = 0
  stub.with(env, inLevel, function()
    stub.with(nightlights, { readRegistry = function() return reg end,
                             refresh = function() refreshed = refreshed + 1; reg.initialized = true end }, function()
      assertMatch(nightlights.check({}).issue, "not initialized")
      nightlights.repair({})
      assertEqual(refreshed, 1)
      assertNil(nightlights.check({}))
    end)
  end)
end)

test("nightlights: registry not found -> skipped", function()
  stub.with(env, inLevel, function()
    stub.with(nightlights, { readRegistry = function() return nil end }, function()
      assertEqual(nightlights.check({}).skip, "night-lights registry not found")
    end)
  end)
end)

-- ============================== ui_visibility ==============================
local uiGuard = require("beammcp/reload/guards/ui_visibility")
local uiv = require("beammcp/tools/ui_visibility")

test("ui_visibility: skipped without a snapshot", function()
  assertEqual(uiGuard.check({}).skip, "no snapshot")
end)

test("ui_visibility: restores only the differing flags", function()
  local cur = { cef = true, imgui = true }
  local setCalls = {}
  stub.with(uiv, { readState = function() return { cef = cur.cef, imgui = cur.imgui } end,
                   setCef = function(v) setCalls[#setCalls + 1] = "cef"; cur.cef = v end,
                   setImgui = function(v) setCalls[#setCalls + 1] = "imgui"; cur.imgui = v end }, function()
    local ctx = { snap = { ui = { cef = false, imgui = true } } }
    assertMatch(uiGuard.check(ctx).issue, "cef")
    uiGuard.repair(ctx)
    assertEqual(cur.cef, false)
    assertEqual(#setCalls, 1)
    assertNil(uiGuard.check(ctx))
  end)
end)

-- ============================== extensions ==============================
local extGuard = require("beammcp/reload/guards/extensions")

test("extensions: skipped without a snapshot", function()
  assertEqual(extGuard.check({}).skip, "no snapshot")
end)

test("extensions: reports vanished extensions (sorted), ignoring beammcp", function()
  stub.with(extGuard, { loadedNames = function() return { "core_camera" } end }, function()
    local r = extGuard.check({ snap = { extensions = { "core_camera", "someModHud", "beammcp", "AAA" } } })
    assertMatch(r.issue, "2 extension")
    assertEqual(r.missing[1], "AAA")
    assertEqual(r.missing[2], "someModHud")
  end)
end)

test("extensions: ok when all are back", function()
  stub.with(extGuard, { loadedNames = function() return { "a", "b" } end }, function()
    assertNil(extGuard.check({ snap = { extensions = { "a", "b" } } }))
  end)
end)

test("extensions: virtual flowgraph proxies are ignored on both sides", function()
  stub.with(extGuard, { loadedNames = function() return { "a" } end }, function()
    assertNil(extGuard.check({ snap = { extensions = { "a", "x_virtual_3" } } }))
  end)
end)

-- a mutable "loaded" set; loadBatch() loads the names in `loadable` and silently skips the rest (the
-- engine logs unresolvable names and loads the others). `mods` are the module tables module() returns.
local function extWorld(loaded, loadable, mods)
  local set, batches = {}, {}
  for _, n in ipairs(loaded) do set[n] = true end
  return {
    loadedNames = function() local l = {} for n in pairs(set) do l[#l + 1] = n end return l end,
    loadBatch = function(names)
      batches[#batches + 1] = #names
      for _, n in ipairs(names) do if loadable[n] then set[n] = true end end
    end,
    module = function(n) return set[n] and mods and mods[n] or nil end,
  }, batches
end

test("extensions: outside total mode the repair is declined (returns false) and loads nothing", function()
  local w, batches = extWorld({ "a" }, { b = true })
  stub.with(extGuard, w, function()
    local ctx = { classification = "normal", snap = { extensions = { "a", "b" } } }
    assertEqual(extGuard.repair(ctx), false)
    assertEqual(#batches, 0)
  end)
end)

test("extensions: total mode batch-loads missing names; unresolvable ones are reported as a mitigation", function()
  local w, batches = extWorld({ "a" }, { b = true, c = true })
  stub.with(env, inLevel, function()
    stub.with(extGuard, w, function()
      local ctx = { classification = "total", snap = { extensions = { "a", "b", "c", "someModHud" } } }
      local res = extGuard.repair(ctx)
      assertEqual(#batches, 1, "one batch call so dependencies resolve together")
      assertEqual(batches[1], 3)
      assertMatch(res.mitigated, "reloaded 2 of 3")
      assertMatch(res.mitigated, "someModHud")
      assertEqual(extGuard.check(ctx).missing[1], "someModHud")
    end)
  end)
end)

test("extensions: level-start hooks are replayed in engine order, only on the modules that came back", function()
  local calls = {}
  local function rec(tag) return function(arg) calls[#calls + 1] = tag .. ":" .. tostring(arg) end end
  local mods = {
    b = { onClientStartMission = rec("b.Start"), onClientPreStartMission = rec("b.Pre") },
    c = { onClientPostStartMission = rec("c.Post") },
    a = { onClientStartMission = rec("a.Start") },   -- was never missing: must NOT be replayed
  }
  local w = extWorld({ "a" }, { b = true, c = true }, mods)
  stub.with(env, { mission = function() return "/levels/West/main.level.json" end }, function()
    stub.with(extGuard, w, function()
      assertNil(extGuard.repair({ classification = "total", snap = { extensions = { "a", "b", "c" } } }))
    end)
  end)
  assertEqual(#calls, 3)
  assertEqual(calls[1], "b.Pre:/levels/west/main.level.json")    -- pre/post get the lowercased path
  assertEqual(calls[2], "c.Post:/levels/west/main.level.json")
  assertEqual(calls[3], "b.Start:/levels/West/main.level.json")  -- start gets getMissionFilename()
end)

test("extensions: a throwing level hook does not stop the others", function()
  local ran = false
  local mods = { b = { onClientPreStartMission = function() error("boom") end },
                 c = { onClientStartMission = function() ran = true end } }
  local w = extWorld({}, { b = true, c = true }, mods)
  stub.with(env, inLevel, function()
    stub.with(extGuard, w, function()
      extGuard.repair({ classification = "total", snap = { extensions = { "b", "c" } } })
    end)
  end)
  assertTrue(ran)
end)

test("extensions: total mode with everything reloadable returns nothing (clean re-check)", function()
  local w = extWorld({}, { b = true })
  stub.with(env, inLevel, function()
    stub.with(extGuard, w, function()
      local ctx = { classification = "total", snap = { extensions = { "b" } } }
      assertNil(extGuard.repair(ctx))
      assertNil(extGuard.check(ctx))
    end)
  end)
end)

test("extensions: repair does not replay level hooks when no level is loaded", function()
  local calls = {}
  local mods = { b = { onClientStartMission = function() calls[#calls + 1] = "b.Start" end } }
  local w = extWorld({}, { b = true }, mods)
  stub.with(env, inMenu, function()
    stub.with(extGuard, w, function()
      extGuard.repair({ classification = "total", snap = { extensions = { "b" } } })
    end)
  end)
  assertEqual(#calls, 0)
end)
