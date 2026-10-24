require("support.beamng_stubs")
local damage   = require("beammcp/tools/damage")
local registry = require("core.registry")

local function stubBe(playerId)
  _G.be = { getPlayerVehicleID = function() return playerId or 7 end }
end

-- M.filterActive (pure)
test("filterActive drops false and 0, keeps live values, drops emptied groups", function()
  local raw = {
    engine = { headGasketDamaged = false, coolantOverheating = true },
    wheels = { brakeOverHeatFL = 0, brakeOverHeatFR = 12.5, tireFL = false },
    body   = { FL = 0, FR = 0 },  -- all zero -> whole group dropped
  }
  local f = damage.filterActive(raw)
  assertEqual(f.engine.coolantOverheating, true)
  assertNil(f.engine.headGasketDamaged)
  assertEqual(f.wheels.brakeOverHeatFR, 12.5)
  assertNil(f.wheels.brakeOverHeatFL)
  assertNil(f.wheels.tireFL)
  assertNil(f.body)
end)

-- get_damage_data
test("get_damage_data default is ACTIVE-ONLY, with a note when entries were dropped", function()
  stubBe()
  damage.fetch = function(id) return { engine = { headGasketDamaged = false, coolantOverheating = true } } end
  local res, err = damage.getDef.handler({})
  assertNil(err)
  assertEqual(res.damage.engine.coolantOverheating, true)
  assertNil(res.damage.engine.headGasketDamaged)
  assertMatch(res.note, "full=true")
end)

test("get_damage_data default has no note when nothing was filtered out", function()
  stubBe()
  damage.fetch = function(id) return { engine = { coolantOverheating = true } } end
  local res = damage.getDef.handler({})
  assertNil(res.note)
end)

test("get_damage_data forwards id to fetch", function()
  stubBe()
  local seen
  damage.fetch = function(id) seen = id; return {} end
  damage.getDef.handler({ id = 42 })
  assertEqual(seen, 42)
end)

test("get_damage_data defaults to the player vehicle id", function()
  stubBe(99)
  local seen
  damage.fetch = function(id) seen = id; return {} end
  damage.getDef.handler({})
  assertEqual(seen, 99)
end)

test("get_damage_data full=true returns the raw table (incl. false/0)", function()
  stubBe()
  damage.fetch = function() return { engine = { a = false, b = true } } end
  local res = damage.getDef.handler({ full = true })
  assertEqual(res.damage.engine.b, true)
  assertEqual(res.damage.engine.a, false)
  assertNil(res.note)
end)

test("get_damage_data rejects a non-number id with a shaped error", function()
  stubBe()
  damage.fetch = function() return {} end
  local res, err = damage.getDef.handler({ id = "seven" })
  assertNil(res)
  assertMatch(err, "get_damage_data: 'id' must be a number")
end)

test("filterActive also reports kept/total entry counts", function()
  local _, kept, total = damage.filterActive({ engine = { a = false, b = true, c = 3 } })
  assertEqual(kept, 2)
  assertEqual(total, 3)
end)

test("get_damage_data surfaces a fetch error", function()
  stubBe()
  damage.fetch = function() return nil, "get_damage_data: unknown vehicle id 5" end
  local res, err = damage.getDef.handler({ id = 5 })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 5")
end)

-- trigger_damage
test("trigger_damage forwards (id,group,name,value) to apply and returns confirmation", function()
  stubBe()
  local seen
  damage.apply = function(id, group, name, value) seen = { id, group, name, value }; return true end
  local res, err = damage.triggerDef.handler({ id = 3, group = "engine", name = "headGasketDamaged", value = true })
  assertNil(err)
  assertEqual(res.ok, true)
  assertEqual(res.group, "engine")
  assertEqual(res.name, "headGasketDamaged")
  assertEqual(res.value, true)
  assertEqual(seen[1], 3)
  assertEqual(seen[4], true)
end)

test("trigger_damage accepts a numeric value", function()
  stubBe()
  local seenVal
  damage.apply = function(id, group, name, value) seenVal = value; return true end
  local res, err = damage.triggerDef.handler({ group = "body", name = "FL", value = 0.5 })
  assertNil(err)
  assertEqual(res.value, 0.5)
  assertEqual(seenVal, 0.5)
end)

test("trigger_damage rejects non-table args", function()
  stubBe()
  local res, err = damage.triggerDef.handler("nope")
  assertNil(res)
  assertMatch(err, "must be an object")
end)

test("trigger_damage rejects missing/empty group", function()
  stubBe()
  local res, err = damage.triggerDef.handler({ name = "x", value = true })
  assertNil(res)
  assertMatch(err, "'group' must be a non%-empty string")
end)

test("trigger_damage rejects missing/empty name", function()
  stubBe()
  local res, err = damage.triggerDef.handler({ group = "engine", value = true })
  assertNil(res)
  assertMatch(err, "'name' must be a non%-empty string")
end)

test("trigger_damage rejects a non-boolean/non-number value (and does not call apply)", function()
  stubBe()
  local called = false
  damage.apply = function() called = true; return true end
  local res, err = damage.triggerDef.handler({ group = "engine", name = "x", value = "oops" })
  assertNil(res)
  assertMatch(err, "'value' must be a boolean or number")
  assertTrue(not called)
end)

test("trigger_damage surfaces an apply error", function()
  stubBe()
  damage.apply = function() return nil, "trigger_damage: unknown vehicle id 5" end
  local res, err = damage.triggerDef.handler({ id = 5, group = "engine", name = "x", value = true })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 5")
end)

-- registration
test("register adds get_damage_data and trigger_damage", function()
  local r = registry.new()
  damage.register(r)
  local names = {}
  for _, t in ipairs(r:list()) do names[t.name] = true end
  assertTrue(names["get_damage_data"])
  assertTrue(names["trigger_damage"])
end)

test("trigger_damage rejects a non-finite numeric value (inf/nan build invalid Lua chunks)", function()
  stubBe()
  local applied = false
  damage.apply = function() applied = true; return true end
  for _, v in ipairs({ math.huge, -math.huge, 0/0 }) do
    local res, err = damage.triggerDef.handler({ group = "engine", name = "x", value = v })
    assertNil(res)
    assertMatch(err, "finite")
  end
  assertEqual(applied, false)
end)

test("trigger_damage rejects a non-number id with a shaped error", function()
  stubBe()
  damage.apply = function() return true end
  local res, err = damage.triggerDef.handler({ group = "engine", name = "x", value = true, id = "seven" })
  assertNil(res)
  assertMatch(err, "trigger_damage: 'id' must be a number")
end)

test("trigger_damage 'value' schema declares the boolean-or-number union", function()
  local t = damage.triggerDef.inputSchema.properties.value.type
  assertTrue(type(t) == "table")
  assertEqual(t[1], "boolean")
  assertEqual(t[2], "number")
end)

test("descriptions disambiguate: trigger_damage points at damage_vehicle for physical breakage", function()
  assertMatch(damage.triggerDef.description, "damage_vehicle")
end)
