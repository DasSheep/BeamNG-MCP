local registry = require("core.registry")
local sw = require("beammcp/tools/switch_vehicle")

local function stubBe(existsId, model)
  _G.be = {
    getObjectByID = function(self, id)
      return (id == existsId) and { getJBeamFilename = function() return model end } or nil
    end,
    getPlayerVehicleID = function(self, n) return existsId end,
    enterVehicle = function(self, seat, veh) end,
  }
end

test("success: returns {vehicleId, model}", function()
  stubBe(45, "pigeon")
  sw.switchTo = function(id) return true end
  local res, err = sw.def.handler({ id = 45 })
  assertNil(err)
  assertEqual(res.vehicleId, 45)
  assertEqual(res.model, "pigeon")
end)

test("unknown id -> error", function()
  stubBe(45, "pigeon")
  local res, err = sw.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "no vehicle with id 999")
end)

test("bad args: non-number id", function()
  stubBe(45, "pigeon")
  local res, err = sw.def.handler({ id = "x" })
  assertNil(res)
  assertMatch(err, "'id' must be a number")
end)

test("failure: switchTo false -> failed-to-switch error", function()
  stubBe(45, "pigeon")
  sw.switchTo = function() return false end
  local res, err = sw.def.handler({ id = 45 })
  assertNil(res)
  assertMatch(err, "failed to switch")
end)

test("register adds it under 'switch_vehicle'", function()
  local r = registry.new()
  sw.register(r)
  assertEqual(r:list()[1].name, "switch_vehicle")
end)
