local registry = require("core.registry")
local tv = require("beammcp/tools/teleport_vehicle")

local realDoTeleport = tv.doTeleport       -- captured before handler tests stub it (runner has no teardown)
local realApplyVelocity = tv.applyVelocity
local realSafeRot = tv.safeRot

-- parseArgs(args) -> (parsed, err): pure validation + the repair+exact gate.
test("parseArgs: valid pos + heading rot + scalar speed; exact/repair default false", function()
  local p, err = tv.parseArgs({ pos = { x = 1, y = 2, z = 3 }, rot = 90, speed = 10 })
  assertNil(err)
  assertEqual(p.pos.x, 1); assertEqual(p.pos.z, 3)
  assertEqual(p.rot, 90); assertEqual(p.speed, 10)
  assertEqual(p.exact, false); assertEqual(p.repair, false)
end)

test("parseArgs: quaternion rot and vector speed accepted", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, rot = { x=0,y=0,z=0,w=1 }, speed = { x=0,y=5,z=0 } })
  assertNil(err)
  assertEqual(p.rot.w, 1); assertEqual(p.speed.y, 5)
end)

test("parseArgs: rot and speed are optional", function()
  local p, err = tv.parseArgs({ pos = { x=1,y=1,z=1 } })
  assertNil(err); assertNil(p.rot); assertNil(p.speed)
end)

test("parseArgs: non-table args -> error", function()
  local p, err = tv.parseArgs("nope")
  assertNil(p); assertMatch(err, "must be an object")
end)

test("parseArgs: missing pos -> error", function()
  local p, err = tv.parseArgs({ rot = 90 })
  assertNil(p); assertMatch(err, "'pos'")
end)

test("parseArgs: malformed pos (missing z) -> error", function()
  local p, err = tv.parseArgs({ pos = { x = 1, y = 2 } })
  assertNil(p); assertMatch(err, "'pos'")
end)

test("parseArgs: non-number id -> error", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, id = "5" })
  assertNil(p); assertMatch(err, "'id' must be a number")
end)

test("parseArgs: malformed rot table (missing w) -> error", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, rot = { x=0,y=0,z=0 } })
  assertNil(p); assertMatch(err, "'rot'")
end)

test("parseArgs: malformed speed table (non-number field) -> error", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, speed = { x=0, y="fast", z=0 } })
  assertNil(p); assertMatch(err, "'speed'")
end)

test("parseArgs: non-boolean exact -> error", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, exact = "yes" })
  assertNil(p); assertMatch(err, "'exact' must be a boolean")
end)

test("parseArgs: non-boolean repair -> error", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, repair = 1 })
  assertNil(p); assertMatch(err, "'repair' must be a boolean")
end)

test("parseArgs: repair=true with exact=true is gated", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, exact = true, repair = true })
  assertNil(p); assertMatch(err, "repair applies only to safe teleport")
end)

test("parseArgs: repair=true with exact=false passes", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, repair = true })
  assertNil(err); assertEqual(p.repair, true); assertEqual(p.exact, false)
end)

test("parseArgs: exact=true alone passes", function()
  local p, err = tv.parseArgs({ pos = { x=0,y=0,z=0 }, exact = true })
  assertNil(err); assertEqual(p.exact, true); assertEqual(p.repair, false)
end)

-- resolveVelocity(speed, dir) -> vx, vy, vz : pure. number -> dir*speed; table -> the vector.
test("resolveVelocity: scalar scales the direction vector", function()
  local vx, vy, vz = tv.resolveVelocity(10, { x = 0, y = 1, z = 0 })
  assertEqual(vx, 0); assertEqual(vy, 10); assertEqual(vz, 0)
end)

test("resolveVelocity: vector passes through (dir ignored)", function()
  local vx, vy, vz = tv.resolveVelocity({ x = 1, y = 2, z = 3 }, nil)
  assertEqual(vx, 1); assertEqual(vy, 2); assertEqual(vz, 3)
end)

-- M.doTeleport / M.applyVelocity: engine-coupled. Stub the engine globals to capture the calls; the quaternion
-- compensation in M.safeRot is stubbed here and pinned in-engine.

test("doTeleport exact=true: setPositionRotation with exact coords; rot=nil keeps current orientation", function()
  local savedVec3 = _G.vec3
  _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local seen = {}
  local veh = {
    getRotation = function() return { x = 0, y = 0, z = 0, w = 1 } end,
    setPositionRotation = function(self, px, py, pz, rx, ry, rz, rw)
      seen = { px = px, py = py, pz = pz, rw = rw }
    end,
  }
  realDoTeleport(veh, { x = 10, y = 20, z = 0.5 }, nil, true, false)
  assertEqual(seen.px, 10); assertEqual(seen.pz, 0.5)
  assertEqual(seen.rw, 1)   -- current rotation (from getRotation) used when rot omitted
  _G.vec3 = savedVec3
end)

test("doTeleport exact=true: heading number routes through quatFromEuler (not getRotation)", function()
  local savedVec3, savedQFE = _G.vec3, _G.quatFromEuler
  _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local capturedAngle
  _G.quatFromEuler = function(a, b, c) capturedAngle = c; return { x = 0, y = 0, z = 0, w = 1 } end
  local called = false
  local veh = { setPositionRotation = function(self) called = true end }  -- no getRotation: must not be called
  realDoTeleport(veh, { x = 0, y = 0, z = 0 }, 90, true, false)
  assertTrue(called)
  assertEqual(capturedAngle, math.rad(90))
  _G.vec3, _G.quatFromEuler = savedVec3, savedQFE
end)

test("doTeleport exact=true: quaternion-table rot routes through quat()", function()
  local savedVec3, savedQuat = _G.vec3, _G.quat
  _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  _G.quat = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
  local seen = {}
  local veh = { setPositionRotation = function(self, px, py, pz, rx, ry, rz, rw) seen = { rx = rx, rw = rw } end }
  realDoTeleport(veh, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 1, w = 0 }, true, false)
  assertEqual(seen.rx, 0); assertEqual(seen.rw, 0)   -- the {x,y,z,w} quat reached setPositionRotation
  _G.vec3, _G.quat = savedVec3, savedQuat
end)

test("doTeleport exact=false (safe): spawn.safeTeleport, traffic/centered off, repair as resetVehicle", function()
  local savedVec3, savedSpawn = _G.vec3, _G.spawn
  _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local captured = {}
  _G.spawn = { safeTeleport = function(veh, pos, rot, a, b, removeTraffic, centered, resetVehicle)
    captured = { pos = pos, removeTraffic = removeTraffic, centered = centered, resetVehicle = resetVehicle }
  end }
  tv.safeRot = function(q) return q end    -- bypass engine quat math off-engine (pinned in-engine)
  local veh = { getRotation = function() return { x = 0, y = 0, z = 0, w = 1 } end }
  realDoTeleport(veh, { x = 1, y = 2, z = 3 }, nil, false, false)
  assertEqual(captured.pos.x, 1); assertEqual(captured.pos.z, 3)
  assertEqual(captured.removeTraffic, false)
  assertEqual(captured.centered, false)
  assertEqual(captured.resetVehicle, false)
  tv.safeRot = realSafeRot
  _G.vec3, _G.spawn = savedVec3, savedSpawn
end)

test("doTeleport safe: repair=true -> resetVehicle=true", function()
  local savedVec3, savedSpawn = _G.vec3, _G.spawn
  _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local captured = {}
  _G.spawn = { safeTeleport = function(veh, pos, rot, a, b, rt, c, resetVehicle) captured.resetVehicle = resetVehicle end }
  tv.safeRot = function(q) return q end
  local veh = { getRotation = function() return { x = 0, y = 0, z = 0, w = 1 } end }
  realDoTeleport(veh, { x = 0, y = 0, z = 0 }, nil, false, true)
  assertEqual(captured.resetVehicle, true)
  tv.safeRot = realSafeRot
  _G.vec3, _G.spawn = savedVec3, savedSpawn
end)

test("applyVelocity: scalar speed -> velocity along getDirectionVector, scale 0 (set-absolute)", function()
  local seen = {}
  local veh = {
    getDirectionVector = function() return { x = 0, y = 1, z = 0 } end,
    getRefNodeId = function() return 3 end,
    applyClusterVelocityScaleAdd = function(self, node, scale, vx, vy, vz)
      seen = { node = node, scale = scale, vx = vx, vy = vy, vz = vz }
    end,
  }
  realApplyVelocity(veh, 10)
  assertEqual(seen.node, 3); assertEqual(seen.scale, 0)
  assertEqual(seen.vx, 0); assertEqual(seen.vy, 10); assertEqual(seen.vz, 0)
end)

test("applyVelocity: vector speed applied directly, scale 0", function()
  local seen = {}
  local veh = {
    getRefNodeId = function() return 1 end,
    applyClusterVelocityScaleAdd = function(self, node, scale, vx, vy, vz)
      seen = { scale = scale, vx = vx, vy = vy, vz = vz }
    end,
  }
  realApplyVelocity(veh, { x = 1, y = 2, z = 3 })
  assertEqual(seen.scale, 0)
  assertEqual(seen.vx, 1); assertEqual(seen.vy, 2); assertEqual(seen.vz, 3)
end)

-- handler: pure dispatch. Stub tv.doTeleport / tv.applyVelocity (reals captured at top).
local function stubBe(playerId)
  _G.be = {
    getPlayerVehicleID = function(self, n) return playerId end,
    getObjectByID = function(self, id) return (id == playerId) and { __id = id } or nil end,
  }
end

test("handler: defaults to player id; routes parsed values to doTeleport", function()
  stubBe(45)
  local seen = {}
  tv.doTeleport = function(veh, pos, rot, exact, repair) seen = { veh = veh, pos = pos, rot = rot, exact = exact, repair = repair } end
  tv.applyVelocity = function() end
  local res, err = tv.def.handler({ pos = { x = 1, y = 2, z = 3 }, rot = 90 })
  assertNil(err)
  assertEqual(res.vehicleId, 45)
  assertEqual(seen.veh.__id, 45)
  assertEqual(seen.pos.x, 1); assertEqual(seen.rot, 90)
  assertEqual(seen.exact, false); assertEqual(seen.repair, false)
end)

test("handler: explicit id is used", function()
  stubBe(45)
  tv.doTeleport = function() end
  local res = tv.def.handler({ id = 45, pos = { x = 0, y = 0, z = 0 } })
  assertEqual(res.vehicleId, 45)
end)

test("handler: unknown id -> error", function()
  stubBe(45)
  tv.doTeleport = function() end
  local res, err = tv.def.handler({ id = 999, pos = { x = 0, y = 0, z = 0 } })
  assertNil(res); assertMatch(err, "no vehicle with id 999")
end)

test("handler: parse error surfaces (missing pos)", function()
  stubBe(45)
  tv.doTeleport = function() end
  local res, err = tv.def.handler({ rot = 90 })
  assertNil(res); assertMatch(err, "'pos'")
end)

test("handler: gate error surfaces (repair+exact)", function()
  stubBe(45)
  tv.doTeleport = function() end
  local res, err = tv.def.handler({ pos = { x = 0, y = 0, z = 0 }, exact = true, repair = true })
  assertNil(res); assertMatch(err, "repair applies only to safe teleport")
end)

test("handler: applyVelocity called only when speed given; echoed", function()
  stubBe(45)
  tv.doTeleport = function() end
  local seen = {}
  tv.applyVelocity = function(veh, speed) seen.speed = speed end
  local res = tv.def.handler({ pos = { x = 0, y = 0, z = 0 }, speed = 25 })
  assertEqual(seen.speed, 25)
  assertEqual(res.speed, 25)
end)

test("handler: no speed -> applyVelocity not called; speed omitted from echo", function()
  stubBe(45)
  tv.doTeleport = function() end
  local called = false
  tv.applyVelocity = function() called = true end
  local res = tv.def.handler({ pos = { x = 0, y = 0, z = 0 } })
  assertEqual(called, false)
  assertNil(res.speed)
end)

test("handler: return echo (exact false, repaired reflects repair, rot omitted when absent)", function()
  stubBe(45)
  tv.doTeleport = function() end
  local res = tv.def.handler({ pos = { x = 1, y = 2, z = 3 }, repair = true })
  assertEqual(res.exact, false)
  assertEqual(res.repaired, true)
  assertEqual(res.pos.x, 1)
  assertNil(res.rot)
end)

test("handler: vector speed echoes back through out.speed (by reference)", function()
  stubBe(45)
  tv.doTeleport = function() end
  tv.applyVelocity = function() end
  local vel = { x = 1, y = 0, z = 0 }
  local res = tv.def.handler({ pos = { x = 0, y = 0, z = 0 }, speed = vel })
  assertEqual(res.speed, vel)       -- table echoed by reference
  assertEqual(res.speed.x, 1)
end)

test("handler: quaternion rot echoes back through out.rot", function()
  stubBe(45)
  tv.doTeleport = function() end
  local q = { x = 0, y = 0, z = 0, w = 1 }
  local res = tv.def.handler({ pos = { x = 0, y = 0, z = 0 }, rot = q })
  assertEqual(res.rot, q)
  assertEqual(res.rot.w, 1)
end)

test("register adds it under 'teleport_vehicle'", function()
  local r = registry.new()
  tv.register(r)
  assertEqual(r:list()[1].name, "teleport_vehicle")
end)

test("parseArgs: numeric id passes through", function()
  local p, err = tv.parseArgs({ pos = { x = 0, y = 0, z = 0 }, id = 3 })
  assertNil(err); assertEqual(p.id, 3)
end)
