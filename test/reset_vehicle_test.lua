local registry = require("core.registry")
local rv = require("beammcp/tools/reset_vehicle")

local function stubBe(playerId)
  _G.be = {
    getPlayerVehicleID = function(self, n) return playerId end,
    getObjectByID = function(self, id) return (id == playerId) and { __id = id } or nil end,
  }
end

test("spawn mode (default): doReset called with 'spawn', defaults to player id", function()
  stubBe(45)
  local seen = {}
  rv.doReset = function(veh, mode) seen.mode = mode end
  local res, err = rv.def.handler({})
  assertNil(err)
  assertEqual(res.vehicleId, 45)
  assertEqual(res.mode, "spawn")
  assertEqual(seen.mode, "spawn")
end)

test("recover mode passes through", function()
  stubBe(45)
  local seen = {}
  rv.doReset = function(veh, mode) seen.mode = mode end
  local res = rv.def.handler({ mode = "recover" })
  assertEqual(res.mode, "recover")
  assertEqual(seen.mode, "recover")
end)

test("explicit id is used", function()
  stubBe(45)
  local seen = {}
  rv.doReset = function(veh, mode) seen.veh = veh end
  local res = rv.def.handler({ id = 45 })
  assertEqual(res.vehicleId, 45)
  assertEqual(seen.veh.__id, 45)
end)

test("bad args: non-number id", function()
  stubBe(45)
  rv.doReset = function() end
  local res, err = rv.def.handler({ id = "45" })
  assertNil(res)
  assertMatch(err, "'id' must be a number")
end)

test("bad mode -> error", function()
  stubBe(45)
  rv.doReset = function() end
  local res, err = rv.def.handler({ mode = "fly" })
  assertNil(res)
  assertMatch(err, "'mode' must be 'spawn' or 'recover'")
end)

test("unknown id -> error", function()
  stubBe(45)
  rv.doReset = function() end
  local res, err = rv.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "no vehicle with id 999")
end)

test("register adds it under 'reset_vehicle'", function()
  local r = registry.new()
  rv.register(r)
  assertEqual(r:list()[1].name, "reset_vehicle")
end)

test("'mode' schema carries the closed enum the handler enforces", function()
  local rv = require("beammcp/tools/reset_vehicle")
  local e = rv.def.inputSchema.properties.mode.enum
  assertTrue(type(e) == "table")
  assertEqual(e[1], "spawn")
  assertEqual(e[2], "recover")
end)
