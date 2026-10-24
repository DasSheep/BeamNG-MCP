require("support.beamng_stubs")
local gvt      = require("beammcp/tools/get_vehicle_tuning")
local registry = require("core.registry")
local realFetch = gvt.fetch   -- captured before tests stub it (runner has no teardown)

-- Fixture: a name-keyed variables map like core_vehicle_manager.getVehicleData(id).vdata.variables.
local VARS = {
  ["$spring_F"] = { name="$spring_F", category="Suspension", subCategory="Front", unit="N/m",
                    min=10000, max=100000, default=30000, val=35000, title="Spring Rate",
                    description="Spring stiffness", stepDis=500 },
  ["$camber_F"] = { name="$camber_F", category="Wheel Alignment", subCategory="Front", unit="",
                    min=0.99, max=1.01, default=1.0, val=1.0, title="Camber F", description="Front camber",
                    stepDis=0.001 },
  ["$camber_R"] = { name="$camber_R", category="Wheel Alignment", subCategory="Rear", unit="",
                    min=0.99, max=1.01, default=1.0, val=1.0, title="Camber R", description="Rear camber" },
  ["$secret"]   = { name="$secret", category="Debug", min=0, max=1, default=0, val=0, hidden=true },
}

-- ---- pure shapers ------------------------------------------------------------------------

test("buildSnapshot: groups name->val by category, excludes hidden, counts non-hidden", function()
  local s = gvt.buildSnapshot(VARS)
  assertEqual(s.count, 3)                                  -- hidden $secret excluded
  assertEqual(s.categories["Suspension"]["$spring_F"], 35000)
  assertEqual(s.categories["Wheel Alignment"]["$camber_F"], 1.0)
  assertEqual(s.categories["Wheel Alignment"]["$camber_R"], 1.0)
  assertNil(s.categories["Debug"])                         -- hidden category not present
end)

test("buildSnapshot: empty vars -> count 0, empty categories", function()
  local s = gvt.buildSnapshot({})
  assertEqual(s.count, 0)
  local n = 0; for _ in pairs(s.categories) do n = n + 1 end
  assertEqual(n, 0)
end)

test("buildActionable category: rows carry val/min/max/default/unit/subCategory, sorted, no detail fields", function()
  local r = gvt.buildActionable(VARS, { category = "Suspension" })
  assertEqual(r.count, 1)
  local v = r.vars[1]
  assertEqual(v.name, "$spring_F")
  assertEqual(v.val, 35000)
  assertEqual(v.min, 10000)
  assertEqual(v.max, 100000)
  assertEqual(v.default, 30000)
  assertEqual(v.unit, "N/m")
  assertEqual(v.subCategory, "Front")
  assertNil(v.title)        -- detail off
  assertNil(v.step)
end)

test("buildActionable category: sorts by name; omits empty unit", function()
  local r = gvt.buildActionable(VARS, { category = "Wheel Alignment" })
  assertEqual(r.count, 2)
  assertEqual(r.vars[1].name, "$camber_F")  -- sorted
  assertEqual(r.vars[2].name, "$camber_R")
  assertNil(r.vars[1].unit)                 -- empty unit omitted
end)

test("buildActionable name: case-insensitive substring across categories", function()
  local r = gvt.buildActionable(VARS, { name = "CAMBER" })
  assertEqual(r.count, 2)
  assertEqual(r.vars[1].name, "$camber_F")
  assertEqual(r.vars[2].name, "$camber_R")
end)

test("buildActionable category + name combine (AND)", function()
  local r = gvt.buildActionable(VARS, { category = "Wheel Alignment", name = "_f" })
  assertEqual(r.count, 1)
  assertEqual(r.vars[1].name, "$camber_F")
end)

test("buildActionable detail=true adds title/description/step", function()
  local r = gvt.buildActionable(VARS, { category = "Suspension", detail = true })
  local v = r.vars[1]
  assertEqual(v.title, "Spring Rate")
  assertEqual(v.description, "Spring stiffness")
  assertEqual(v.step, 500)   -- from stepDis
end)

test("buildActionable excludes hidden vars", function()
  local r = gvt.buildActionable(VARS, { name = "secret" })
  assertEqual(r.count, 0)
end)

test("categorySet: distinct non-hidden categories", function()
  local set = gvt.categorySet(VARS)
  assertTrue(set["Suspension"])
  assertTrue(set["Wheel Alignment"])
  assertNil(set["Debug"])  -- hidden-only category excluded
end)

-- ---- handler dispatch (stub fetch) -------------------------------------------------------

local function stubFetch(model, vars)
  gvt.fetch = function(_id) return { model = model, variables = vars } end
end

test("handler default: grouped snapshot with model + count", function()
  stubFetch("testcar", VARS)
  local res, err = gvt.def.handler({ id = 1 })
  assertNil(err)
  assertEqual(res.model, "testcar")
  assertEqual(res.count, 3)
  assertEqual(res.categories["Suspension"]["$spring_F"], 35000)
end)

test("handler category: actionable rows with ranges", function()
  stubFetch("testcar", VARS)
  local res = gvt.def.handler({ id = 1, category = "Suspension" })
  assertEqual(res.category, "Suspension")
  assertEqual(res.count, 1)
  assertEqual(res.vars[1].max, 100000)
end)

test("handler name: substring match echoes name", function()
  stubFetch("testcar", VARS)
  local res = gvt.def.handler({ id = 1, name = "camber" })
  assertEqual(res.name, "camber")
  assertEqual(res.count, 2)
end)

test("handler unknown category -> error listing the car's categories", function()
  stubFetch("testcar", VARS)
  local res, err = gvt.def.handler({ id = 1, category = "Nope" })
  assertNil(res)
  assertMatch(err, "unknown category 'Nope'")
  assertMatch(err, "Suspension")  -- lists the actual categories
end)

test("handler: no tunables -> count 0, empty categories", function()
  stubFetch("plaincar", {})
  local res = gvt.def.handler({ id = 1 })
  assertEqual(res.count, 0)
  local n = 0; for _ in pairs(res.categories) do n = n + 1 end
  assertEqual(n, 0)
end)

test("handler: fetch failure -> clean error", function()
  gvt.fetch = function(_id) return nil, "get_vehicle_tuning: unknown vehicle id 999" end
  local res, err = gvt.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 999")
end)

test("handler rejects non-number id and non-table args", function()
  stubFetch("testcar", VARS)
  local r1, e1 = gvt.def.handler({ id = "x" })
  assertNil(r1); assertMatch(e1, "'id' must be a number")
  local r2, e2 = gvt.def.handler("nope")
  assertNil(r2); assertMatch(e2, "must be an object")
end)

test("empty-string name/category are treated as no filter (cheap snapshot, not a full ranges dump)", function()
  stubFetch("testcar", VARS)
  local res = gvt.def.handler({ id = 1, name = "" })
  assertEqual(res.count, 3)
  assertTrue(res.categories ~= nil)  -- snapshot, not actionable
  assertNil(res.vars)
  local res2 = gvt.def.handler({ id = 1, category = "" })
  assertTrue(res2.categories ~= nil)
  assertNil(res2.vars)
end)

test("handler rejects non-string category/name and non-boolean detail", function()
  stubFetch("testcar", VARS)
  local r1, e1 = gvt.def.handler({ id = 1, category = 7 })
  assertNil(r1); assertMatch(e1, "'category' must be a string")
  local r2, e2 = gvt.def.handler({ id = 1, name = {} })
  assertNil(r2); assertMatch(e2, "'name' must be a string")
  local r3, e3 = gvt.def.handler({ id = 1, detail = "yes" })
  assertNil(r3); assertMatch(e3, "'detail' must be a boolean")
end)

test("handler defaults id to the player vehicle", function()
  _G.be = { getPlayerVehicleID = function(_self, _n) return 1 end }
  stubFetch("testcar", VARS)
  local res = gvt.def.handler({})
  assertEqual(res.model, "testcar")
end)

test("register adds it under 'get_vehicle_tuning'", function()
  gvt.fetch = realFetch  -- restore the real seam before the register check
  local r = registry.new()
  gvt.register(r)
  assertEqual(r:list()[1].name, "get_vehicle_tuning")
end)
