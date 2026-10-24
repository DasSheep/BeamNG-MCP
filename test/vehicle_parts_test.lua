require("support.beamng_stubs")
local vp       = require("beammcp/tools/vehicle_parts")
local registry = require("core.registry")

-- a small model graph: veh -> {veh_engine, veh_body}; veh_engine -> i4/v8; i4/v8 -> eng_internals;
-- orphan_slot/orphan_part are NOT reachable from veh.
local SAMPLE = {
  mainPart = "veh",
  slotMap = {
    veh_engine    = { "eng_i4", "eng_v8" },
    veh_body      = { "body_std" },
    eng_internals = { "int_stock", "int_race" },
    orphan_slot   = { "orphan_part" },
  },
  partInfo = {
    veh       = { description = "Main", subSlots = { "veh_engine", "veh_body" } },
    eng_i4    = { description = "I4", subSlots = { "eng_internals" } },
    eng_v8    = { description = "V8", subSlots = { "eng_internals" } },
    body_std  = { description = "Body", subSlots = {} },
    int_stock = { description = "Stock", subSlots = {} },
    int_race  = { description = "Race", subSlots = {} },
    orphan_part = { description = "Orphan", subSlots = {} },
  },
}

-- a cycle: a -> slotB -> b -> slotA -> a
local CYCLE = {
  mainPart = "a",
  slotMap = { slotB = { "b" }, slotA = { "a" } },
  partInfo = {
    a = { description = "A", subSlots = { "slotB" } },
    b = { description = "B", subSlots = { "slotA" } },
  },
}

test("buildReachable trims to slots/parts reachable from mainPart", function()
  local r = vp.buildReachable(SAMPLE)
  assertTrue(r.slots.veh_engine ~= nil)
  assertTrue(r.slots.eng_internals ~= nil)           -- reachable via i4/v8
  assertNil(r.slots.orphan_slot)                     -- unreachable dropped
  assertTrue(r.parts.veh ~= nil)
  assertTrue(r.parts.int_race ~= nil)
  assertNil(r.parts.orphan_part)                     -- unreachable part dropped
end)

test("buildReachable terminates on a cycle", function()
  local r = vp.buildReachable(CYCLE)
  assertTrue(r.slots.slotA ~= nil)
  assertTrue(r.slots.slotB ~= nil)
  assertTrue(r.parts.a ~= nil)
  assertTrue(r.parts.b ~= nil)
end)

test("handler: forwards model to loadRaw", function()
  local seen
  vp.loadRaw = function(model) seen = model; return SAMPLE end
  vp.def.handler({ model = "pigeon" })
  assertEqual(seen, "pigeon")
end)

test("handler: unknown model (loadRaw nil) -> error", function()
  vp.loadRaw = function() return nil end
  local res, err = vp.def.handler({ model = "nope" })
  assertNil(res)
  assertMatch(err, "unknown or unloadable model 'nope'")
end)

test("handler: rejects non-string / empty model", function()
  local res1, err1 = vp.def.handler({})
  assertNil(res1); assertMatch(err1, "'model' must be a non%-empty string")
  local res2, err2 = vp.def.handler({ model = "" })
  assertNil(res2); assertMatch(err2, "'model' must be a non%-empty string")
end)

test("register adds get_vehicle_parts", function()
  local r = registry.new()
  vp.register(r)
  assertEqual(r:list()[1].name, "get_vehicle_parts")
end)

-- ---- M.buildScoped (pure) ----
test("buildScoped at the main part returns its slots -> candidate names + its own description", function()
  local r = vp.buildScoped(SAMPLE, "veh")
  assertEqual(r.part, "veh")
  assertEqual(r.description, "Main")
  assertEqual(r.slots.veh_engine[1], "eng_i4")
  assertEqual(r.slots.veh_engine[2], "eng_v8")
  assertEqual(r.slots.veh_body[1], "body_std")
  assertEqual(type(r.slots.veh_engine[1]), "string")  -- candidates are NAMES, not tables-with-descriptions
end)

test("buildScoped at a deeper part returns that part's slots", function()
  local r = vp.buildScoped(SAMPLE, "eng_i4")
  assertEqual(r.part, "eng_i4")
  assertEqual(r.description, "I4")
  assertEqual(r.slots.eng_internals[1], "int_stock")
  assertEqual(r.slots.eng_internals[2], "int_race")
end)

test("buildScoped at a leaf part returns empty slots", function()
  local r = vp.buildScoped(SAMPLE, "body_std")
  assertEqual(r.part, "body_std")
  local n = 0; for _ in pairs(r.slots) do n = n + 1 end
  assertEqual(n, 0)
end)

test("buildScoped for an unknown part returns nil", function()
  assertNil(vp.buildScoped(SAMPLE, "nope"))
end)

-- ---- M.buildSummary (pure) ----
test("buildSummary returns reachable slots -> candidate counts + totals (orphan excluded)", function()
  local r = vp.buildSummary(SAMPLE)
  assertEqual(r.slots.veh_engine, 2)
  assertEqual(r.slots.veh_body, 1)
  assertEqual(r.slots.eng_internals, 2)
  assertNil(r.slots.orphan_slot)
  assertEqual(r.counts.reachableSlots, 3)
  assertEqual(r.counts.totalSlots, 4)
  assertEqual(r.counts.totalParts, 7)
end)

-- ---- M.buildFull (pure) ----
test("buildFull returns the reachable flat map + a size note", function()
  local r = vp.buildFull(SAMPLE)
  assertTrue(r.slots.veh_engine ~= nil)
  assertTrue(r.parts.veh ~= nil)
  assertNil(r.slots.orphan_slot)
  assertNil(r.parts.orphan_part)
  assertMatch(r.note, "3 slots / 6 parts")
  assertMatch(r.note, "prefer scoped/summary")
end)

-- ---- handler mode dispatch ----
test("handler default -> scoped at the main part", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh" })
  assertNil(err)
  assertEqual(res.mode, "scoped")
  assertEqual(res.model, "veh")
  assertEqual(res.mainPart, "veh")
  assertEqual(res.part, "veh")
  assertEqual(res.slots.veh_engine[1], "eng_i4")
end)

test("handler part=P -> scoped at P", function()
  vp.loadRaw = function() return SAMPLE end
  local res = vp.def.handler({ model = "veh", part = "eng_i4" })
  assertEqual(res.mode, "scoped")
  assertEqual(res.part, "eng_i4")
  assertEqual(res.slots.eng_internals[1], "int_stock")
end)

test("handler summary=true -> summary mode", function()
  vp.loadRaw = function() return SAMPLE end
  local res = vp.def.handler({ model = "veh", summary = true })
  assertEqual(res.mode, "summary")
  assertEqual(res.slots.veh_engine, 2)
  assertEqual(res.counts.totalParts, 7)
end)

test("handler full=true -> full mode with note", function()
  vp.loadRaw = function() return SAMPLE end
  local res = vp.def.handler({ model = "veh", full = true })
  assertEqual(res.mode, "full")
  assertTrue(res.parts.veh ~= nil)
  assertMatch(res.note, "prefer scoped/summary")
end)

test("handler rejects summary AND full together", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh", summary = true, full = true })
  assertNil(res); assertMatch(err, "at most one of summary / full")
end)

test("handler rejects part together with summary/full", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh", part = "eng_i4", summary = true })
  assertNil(res); assertMatch(err, "'part' applies only to scoped mode")
end)

test("handler unknown part -> error", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh", part = "nope" })
  assertNil(res); assertMatch(err, "unknown part 'nope'")
end)

-- ---- M.buildFilter (pure) ----
test("buildFilter: matches on slot NAME, returns that slot's candidates", function()
  local r = vp.buildFilter(SAMPLE, "body")
  assertEqual(r.count, 1)
  assertEqual(r.slots.veh_body[1], "body_std")
  assertNil(r.slots.veh_engine)
end)

test("buildFilter: matches on a CANDIDATE name -> slot included with ALL its candidates", function()
  local r = vp.buildFilter(SAMPLE, "race")   -- int_race is a candidate of eng_internals
  assertEqual(r.count, 1)
  assertEqual(r.slots.eng_internals[1], "int_stock") -- non-matching sibling kept
  assertEqual(r.slots.eng_internals[2], "int_race")
end)

test("buildFilter: case-insensitive; matches multiple slots by name", function()
  local r = vp.buildFilter(SAMPLE, "ENG")   -- veh_engine + eng_internals
  assertEqual(r.count, 2)
  assertTrue(r.slots.veh_engine ~= nil)
  assertTrue(r.slots.eng_internals ~= nil)
end)

test("buildFilter: only searches REACHABLE slots (orphan excluded)", function()
  local r = vp.buildFilter(SAMPLE, "orphan")
  assertEqual(r.count, 0)
  local n = 0; for _ in pairs(r.slots) do n = n + 1 end
  assertEqual(n, 0)
end)

test("buildFilter: no match -> count 0, empty slots", function()
  local r = vp.buildFilter(SAMPLE, "zzz")
  assertEqual(r.count, 0)
end)

-- ---- handler filter mode ----
test("handler filter=X -> filter mode with matching slots + count", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh", filter = "eng" })
  assertNil(err)
  assertEqual(res.mode, "filter")
  assertEqual(res.mainPart, "veh")
  assertEqual(res.filter, "eng")
  assertEqual(res.count, 2)
  assertEqual(res.slots.veh_engine[1], "eng_i4")
  assertNil(res.note)            -- matched -> no note
end)

test("handler filter with no match -> count 0 + note", function()
  vp.loadRaw = function() return SAMPLE end
  local res = vp.def.handler({ model = "veh", filter = "zzz" })
  assertEqual(res.mode, "filter")
  assertEqual(res.count, 0)
  assertMatch(res.note, "no reachable slots")
end)

test("handler empty filter='' -> ignored, falls through to scoped", function()
  vp.loadRaw = function() return SAMPLE end
  local res = vp.def.handler({ model = "veh", filter = "" })
  assertEqual(res.mode, "scoped")
  assertEqual(res.part, "veh")
end)

test("handler rejects filter together with summary / full / part", function()
  vp.loadRaw = function() return SAMPLE end
  local r1, e1 = vp.def.handler({ model = "veh", filter = "eng", summary = true })
  assertNil(r1); assertMatch(e1, "at most one of summary / full / filter")
  local r2, e2 = vp.def.handler({ model = "veh", filter = "eng", full = true })
  assertNil(r2); assertMatch(e2, "at most one of summary / full / filter")
  local r3, e3 = vp.def.handler({ model = "veh", filter = "eng", part = "eng_i4" })
  assertNil(r3); assertMatch(e3, "'part' applies only to scoped mode")
end)

test("handler rejects non-string filter", function()
  vp.loadRaw = function() return SAMPLE end
  local res, err = vp.def.handler({ model = "veh", filter = 7 })
  assertNil(res); assertMatch(err, "'filter' must be a string")
end)
