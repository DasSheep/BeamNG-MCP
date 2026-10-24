require("support.beamng_stubs")
local gvs      = require("beammcp/tools/get_vehicle_state")
local registry = require("core.registry")

-- Builds a stub `be` + `map` for one vehicle at id 45, with the given kinematics fields.
local function stubEngine(o)
  _G.be = {
    getPlayerVehicle = function(self, n) return { getId = function(self2) return 45 end } end,
    getObjectByID = function(self, id) return { getJBeamFilename = function(self2) return "roamer" end } end,
  }
  _G.map = { objects = { [45] = o } }
end

test("heading: +Y dirVec is 0 degrees, +X is 90", function()
  assertEqual(gvs._headingFromDirVec({ x = 0, y = 1, z = 0 }), 0)
  assertEqual(gvs._headingFromDirVec({ x = 1, y = 0, z = 0 }), 90)
end)

test("returns player vehicle state with speed in m/s and km/h", function()
  stubEngine({
    pos = { x = 1, y = 2, z = 3 },
    vel = { x = 10, y = 0, z = 0 },
    dirVec = { x = 0, y = 1, z = 0 },
    damage = 0,
  })
  local res, err = gvs.def.handler({})
  assertNil(err)
  assertEqual(res.id, 45)
  assertEqual(res.model, "roamer")
  assertEqual(res.speed_ms, 10)
  assertEqual(res.speed_kmh, 36)
  assertEqual(res.heading_deg, 0)
  assertEqual(res.damage, 0)
  assertEqual(res.pos.y, 2)
end)

test("unknown id returns nil + message", function()
  stubEngine({ pos = {x=0,y=0,z=0}, vel = {x=0,y=0,z=0}, dirVec = {x=0,y=1,z=0}, damage = 0 })
  local res, err = gvs.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "unknown vehicle")
end)

test("register adds it under 'get_vehicle_state'", function()
  local r = registry.new()
  gvs.register(r)
  assertEqual(r:list()[1].name, "get_vehicle_state")
end)
