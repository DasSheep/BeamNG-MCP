require("support.beamng_stubs")
local lv       = require("beammcp/tools/list_vehicles")
local registry = require("core.registry")

-- Stub `be` with two vehicles (ids 10, 20); player is 20.
local function stubBe()
  local function mkVeh(id, model, x)
    return {
      getId = function(self) return id end,
      getJBeamFilename = function(self) return model end,
      getPosition = function(self) return { x = x, y = 0, z = 0 } end,
    }
  end
  local objs = { [0] = mkVeh(10, "pickup", 1), [1] = mkVeh(20, "roamer", 2) }
  _G.be = {
    getObjectCount = function(self) return 2 end,
    getObject = function(self, i) return objs[i] end,
    getPlayerVehicle = function(self, n) return objs[1] end,  -- id 20
  }
end

test("lists all vehicles with id, model, isPlayer, pos", function()
  stubBe()
  local res = lv.def.handler({})
  assertEqual(res.count, 2)
  assertEqual(res.vehicles[1].id, 10)
  assertEqual(res.vehicles[1].model, "pickup")
  assertEqual(res.vehicles[1].isPlayer, false)
  assertEqual(res.vehicles[2].id, 20)
  assertEqual(res.vehicles[2].isPlayer, true)
  assertEqual(res.vehicles[2].pos.x, 2)
end)

test("register adds it under 'list_vehicles'", function()
  local r = registry.new()
  lv.register(r)
  assertEqual(r:list()[1].name, "list_vehicles")
end)
