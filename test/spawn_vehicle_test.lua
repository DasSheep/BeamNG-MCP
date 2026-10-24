local registry = require("core.registry")
local sv = require("beammcp/tools/spawn_vehicle")
local realSpawn = sv.spawn   -- captured before any test overwrites sv.spawn (runner has no teardown)

test("success: returns {vehicleId, model, config}", function()
  sv.spawn = function(model, config, replace) return 77 end
  local res, err = sv.def.handler({ model = "pigeon", config = "base" })
  assertNil(err)
  assertEqual(res.vehicleId, 77)
  assertEqual(res.model, "pigeon")
  assertEqual(res.config, "base")
end)

test("default replace is true; explicit false routes to add-new", function()
  local seen = {}
  sv.spawn = function(model, config, replace) seen.replace = replace; return 1 end
  sv.def.handler({ model = "pigeon" })
  assertEqual(seen.replace, true)
  sv.def.handler({ model = "pigeon", replace = false })
  assertEqual(seen.replace, false)
end)

test("failure: spawn nil -> failed-to-spawn error", function()
  sv.spawn = function() return nil end
  local res, err = sv.def.handler({ model = "nope" })
  assertNil(res)
  assertMatch(err, "failed to spawn")
  assertMatch(err, "nope")
end)

test("bad args: missing model", function()
  local res, err = sv.def.handler({})
  assertNil(res)
  assertMatch(err, "'model' must be a string")
end)

test("bad args: non-string non-table config", function()
  local res, err = sv.def.handler({ model = "pigeon", config = 5 })
  assertNil(res)
  assertMatch(err, "'config' must be a string or a table")
end)

test("inline table config: passed through to M.spawn; return is compacted", function()
  local seen = {}
  sv.spawn = function(model, config, replace) seen.config = config; return 88 end
  local cfg = { parts = { body = "pigeon_body", engine = "pigeon_engine_1" } }
  local res, err = sv.def.handler({ model = "pigeon", config = cfg })
  assertNil(err)
  assertEqual(seen.config, cfg)          -- table passed through unchanged
  assertEqual(res.vehicleId, 88)
  assertEqual(res.config.inline, true)   -- return compacted, not the raw table
  assertEqual(res.config.parts, 2)
end)

test("register adds it under 'spawn_vehicle'", function()
  local r = registry.new()
  sv.register(r)
  assertEqual(r:list()[1].name, "spawn_vehicle")
end)

-- parsePlacement(args, replace) -> (placement, err): pure validation + replace gate.
test("parsePlacement: no placement fields returns nil, nil", function()
  local p, err = sv.parsePlacement({ model = "pigeon" }, false)
  assertNil(p); assertNil(err)
end)

test("parsePlacement: pos with replace=true (default) is gated with an error", function()
  local p, err = sv.parsePlacement({ pos = { x = 0, y = 0, z = 0 } }, true)
  assertNil(p)
  assertMatch(err, "placement requires replace=false")
end)

test("parsePlacement: rot or speed with replace=true is gated too", function()
  local _, e1 = sv.parsePlacement({ rot = 90 }, true)
  assertMatch(e1, "placement requires replace=false")
  local _, e2 = sv.parsePlacement({ speed = 10 }, true)
  assertMatch(e2, "placement requires replace=false")
end)

test("parsePlacement: valid pos + heading rot + scalar speed with replace=false", function()
  local p, err = sv.parsePlacement({ pos = { x = 1, y = 2, z = 3 }, rot = 90, speed = 10 }, false)
  assertNil(err)
  assertEqual(p.pos.x, 1); assertEqual(p.pos.z, 3)
  assertEqual(p.rot, 90)
  assertEqual(p.speed, 10)
end)

test("parsePlacement: quaternion rot and vector speed are accepted", function()
  local p, err = sv.parsePlacement(
    { rot = { x = 0, y = 0, z = 0, w = 1 }, speed = { x = 0, y = 5, z = 0 } }, false)
  assertNil(err)
  assertEqual(p.rot.w, 1)
  assertEqual(p.speed.y, 5)
end)

test("parsePlacement: malformed pos (missing z) errors", function()
  local p, err = sv.parsePlacement({ pos = { x = 1, y = 2 } }, false)
  assertNil(p)
  assertMatch(err, "pos")
end)

test("parsePlacement: malformed rot table (missing w) errors", function()
  local p, err = sv.parsePlacement({ rot = { x = 0, y = 0, z = 0 } }, false)
  assertNil(p)
  assertMatch(err, "rot")
end)

test("parsePlacement: malformed speed table (non-number field) errors", function()
  local p, err = sv.parsePlacement({ speed = { x = 0, y = "fast", z = 0 } }, false)
  assertNil(p)
  assertMatch(err, "speed")
end)

test("handler: gate error surfaces (pos with default replace)", function()
  sv.spawn = function() return 1 end
  local res, err = sv.def.handler({ model = "pigeon", pos = { x = 0, y = 0, z = 0 } })
  assertNil(res)
  assertMatch(err, "placement requires replace=false")
end)

test("handler: pos/rot forwarded to M.spawn on the add-new path", function()
  local seen = {}
  sv.spawn = function(model, config, replace, pos, rot) seen.pos = pos; seen.rot = rot; return 9 end
  local res, err = sv.def.handler(
    { model = "pigeon", replace = false, pos = { x = 5, y = 6, z = 7 }, rot = 45 })
  assertNil(err)
  assertEqual(res.vehicleId, 9)
  assertEqual(seen.pos.x, 5); assertEqual(seen.pos.z, 7)
  assertEqual(seen.rot, 45)
  assertEqual(res.placement.pos.y, 6)
  assertEqual(res.placement.rot, 45)
end)

-- resolveVelocity(speed, dir) -> vx, vy, vz : pure. number -> dir*speed; table -> the vector.
test("resolveVelocity: scalar speed scales the direction vector", function()
  local vx, vy, vz = sv.resolveVelocity(10, { x = 0, y = 1, z = 0 })
  assertEqual(vx, 0); assertEqual(vy, 10); assertEqual(vz, 0)
end)

test("resolveVelocity: scalar speed along a diagonal heading", function()
  local vx, vy, vz = sv.resolveVelocity(2, { x = 1, y = 0, z = 0 })
  assertEqual(vx, 2); assertEqual(vy, 0); assertEqual(vz, 0)
end)

test("resolveVelocity: vector speed passes through (dir ignored)", function()
  local vx, vy, vz = sv.resolveVelocity({ x = 1, y = 2, z = 3 }, nil)
  assertEqual(vx, 1); assertEqual(vy, 2); assertEqual(vz, 3)
end)

test("handler: applies velocity after spawn when speed is given (replace=false)", function()
  _G.be = { getObjectByID = function(self, id) return { id = id } end }
  sv.spawn = function() return 12 end
  local seen = {}
  sv.applyVelocity = function(veh, speed) seen.veh = veh; seen.speed = speed end
  local res, err = sv.def.handler({ model = "pigeon", replace = false, speed = 25 })
  assertNil(err)
  assertEqual(res.vehicleId, 12)
  assertEqual(seen.veh.id, 12)
  assertEqual(seen.speed, 25)
  assertEqual(res.placement.speed, 25)
end)

test("handler: a vector speed reaches applyVelocity unchanged (replace=false)", function()
  _G.be = { getObjectByID = function(self, id) return { id = id } end }
  sv.spawn = function() return 13 end
  local seen = {}
  sv.applyVelocity = function(veh, speed) seen.speed = speed end
  local vel = { x = 0, y = 5, z = 0 }
  local res, err = sv.def.handler({ model = "pigeon", replace = false, speed = vel })
  assertNil(err)
  assertEqual(seen.speed, vel)            -- table reaches applyVelocity by reference
  assertEqual(res.placement.speed.y, 5)
end)

test("handler: no speed -> applyVelocity not called", function()
  _G.be = { getObjectByID = function(self, id) return { id = id } end }
  sv.spawn = function() return 12 end
  local called = false
  sv.applyVelocity = function() called = true end
  sv.def.handler({ model = "pigeon", replace = false, pos = { x = 0, y = 0, z = 0 } })
  assertEqual(called, false)
end)

-- The headline "AI builds a car" path: a synthesized inline config AND placement in one call.
test("handler: inline config + pos/rot/speed placement together (replace=false)", function()
  _G.be = { getObjectByID = function(self, id) return { id = id } end }
  local seen = {}
  sv.spawn = function(model, config, replace, pos, rot)
    seen.config = config; seen.replace = replace; seen.pos = pos; seen.rot = rot; return 50
  end
  sv.applyVelocity = function(veh, speed) seen.speed = speed end
  local cfg = { parts = { pigeon = "pigeon", engine = "pigeon_1300" }, vars = { ["$tune"] = 0.5 } }
  local res, err = sv.def.handler({
    model = "pigeon", config = cfg, replace = false,
    pos = { x = 1, y = 2, z = 3 }, rot = 90, speed = 7,
  })
  assertNil(err)
  assertEqual(seen.config, cfg)          -- synthesized config reaches M.spawn unchanged
  assertEqual(seen.replace, false)
  assertEqual(seen.pos.x, 1); assertEqual(seen.rot, 90)
  assertEqual(seen.speed, 7)             -- velocity applied
  assertEqual(res.vehicleId, 50)
  assertEqual(res.config.inline, true)   -- config compacted in the return
  assertEqual(res.config.parts, 2)
  assertEqual(res.placement.pos.z, 3)
  assertEqual(res.placement.rot, 90)
  assertEqual(res.placement.speed, 7)
end)

-- parseFocus(args, replace) -> (focus, err): pure validation + the focus gate. `focus` applies only to the
-- add-new path. Check order: omitted first, then the replace gate (any value is misuse with replace=true),
-- then the boolean type check.
test("parseFocus: omitted focus returns nil, nil", function()
  local f, err = sv.parseFocus({ model = "pigeon" }, false)
  assertNil(f); assertNil(err)
end)

test("parseFocus: focus=false with replace=true (default) is gated", function()
  local f, err = sv.parseFocus({ focus = false }, true)
  assertNil(f)
  assertMatch(err, "focus applies only when replace=false")
end)

test("parseFocus: focus=true with replace=true is also gated (any value is misuse)", function()
  local f, err = sv.parseFocus({ focus = true }, true)
  assertNil(f)
  assertMatch(err, "focus applies only when replace=false")
end)

test("parseFocus: non-boolean focus with replace=true hits the gate first (check order)", function()
  local f, err = sv.parseFocus({ focus = "yes" }, true)
  assertNil(f)
  assertMatch(err, "focus applies only when replace=false")
end)

test("parseFocus: non-boolean focus with replace=false errors on type", function()
  local f, err = sv.parseFocus({ focus = "yes" }, false)
  assertNil(f)
  assertMatch(err, "'focus' must be a boolean")
end)

test("parseFocus: focus=false with replace=false passes through", function()
  local f, err = sv.parseFocus({ focus = false }, false)
  assertEqual(f, false); assertNil(err)
end)

test("parseFocus: focus=true with replace=false passes through", function()
  local f, err = sv.parseFocus({ focus = true }, false)
  assertEqual(f, true); assertNil(err)
end)

-- handler wiring: focus reaches M.spawn and is echoed as `focused` on the add-new path only.
test("handler: focus=false forwarded to M.spawn and echoed focused=false (replace=false)", function()
  local seen = {}
  sv.spawn = function(model, config, replace, pos, rot, focus) seen.focus = focus; return 30 end
  local res, err = sv.def.handler({ model = "pigeon", replace = false, focus = false })
  assertNil(err)
  assertEqual(seen.focus, false)        -- reaches M.spawn as the 6th arg
  assertEqual(res.focused, false)       -- honest echo: not entered
end)

test("handler: omitted focus on the add-new path echoes focused=true (engine auto-enters)", function()
  sv.spawn = function(model, config, replace, pos, rot, focus) return 31 end
  local res, err = sv.def.handler({ model = "pigeon", replace = false })
  assertNil(err)
  assertEqual(res.focused, true)
end)

test("handler: focus=true on the add-new path echoes focused=true", function()
  sv.spawn = function(model, config, replace, pos, rot, focus) return 32 end
  local res, err = sv.def.handler({ model = "pigeon", replace = false, focus = true })
  assertNil(err)
  assertEqual(res.focused, true)
end)

test("handler: replace path omits focused (no focus choice there)", function()
  sv.spawn = function() return 33 end
  local res, err = sv.def.handler({ model = "pigeon" })   -- replace defaults true
  assertNil(err)
  assertNil(res.focused)
end)

test("handler: focus with default replace=true is gated", function()
  sv.spawn = function() return 1 end
  local res, err = sv.def.handler({ model = "pigeon", focus = false })
  assertNil(res)
  assertMatch(err, "focus applies only when replace=false")
end)

-- M.spawn opt-mapping for focus (real M.spawn; stub the engine global to capture opt; pos/rot omitted so the
-- vec3/quat engine globals are never touched). Saves/restores _G.core_vehicles to avoid leaking the stub.
test("M.spawn: focus=false sets opt.autoEnterVehicle=false on the add-new path", function()
  local savedCV = _G.core_vehicles
  local captured
  _G.core_vehicles = { spawnNewVehicle = function(model, opt) captured = opt; return { getID = function() return 1 end } end }
  realSpawn("pigeon", nil, false, nil, nil, false)
  assertEqual(captured.autoEnterVehicle, false)
  _G.core_vehicles = savedCV
end)

test("M.spawn: focus=true leaves autoEnterVehicle unset (engine default auto-enters)", function()
  local savedCV = _G.core_vehicles
  local captured
  _G.core_vehicles = { spawnNewVehicle = function(model, opt) captured = opt; return { getID = function() return 1 end } end }
  realSpawn("pigeon", nil, false, nil, nil, true)
  assertNil(captured.autoEnterVehicle)
  _G.core_vehicles = savedCV
end)

test("M.spawn: omitted focus leaves autoEnterVehicle unset", function()
  local savedCV = _G.core_vehicles
  local captured
  _G.core_vehicles = { spawnNewVehicle = function(model, opt) captured = opt; return { getID = function() return 1 end } end }
  realSpawn("pigeon", nil, false, nil, nil, nil)
  assertNil(captured.autoEnterVehicle)
  _G.core_vehicles = savedCV
end)

-- On the replace path M.spawn ignores focus entirely (self-defending: replace keeps the player's own
-- vehicle, so autoEnterVehicle must never be set there even if a focus value reached M.spawn).
test("M.spawn: replace path leaves autoEnterVehicle unset even when focus=false", function()
  local savedCV = _G.core_vehicles
  local captured
  _G.core_vehicles = { replaceVehicle = function(model, opt) captured = opt; return { getID = function() return 1 end } end }
  realSpawn("pigeon", nil, true, nil, nil, false)
  assertNil(captured.autoEnterVehicle)
  _G.core_vehicles = savedCV
end)
