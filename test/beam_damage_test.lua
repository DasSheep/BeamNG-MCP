require("support.beamng_stubs")
local bd       = require("beammcp/tools/beam_damage")
local registry = require("core.registry")

-- ---- M.buildApplyChunk (pure) ----
test("buildApplyChunk break_group quotes the group with %q and ends with return true", function()
  local c = bd.buildApplyChunk("break_group", "fender_a_L", nil)
  assertMatch(c, 'beamstate%.breakBreakGroup%("fender_a_L"%)')
  assertMatch(c, "return true$")
end)

test("buildApplyChunk break_hinges", function()
  assertEqual(bd.buildApplyChunk("break_hinges"), "beamstate.breakHinges() return true")
end)

test("buildApplyChunk deflate_tire with a wheel id", function()
  assertEqual(bd.buildApplyChunk("deflate_tire", nil, 3), "beamstate.deflateTire(3) return true")
end)

test("buildApplyChunk deflate_tire without a wheel -> all tires", function()
  assertEqual(bd.buildApplyChunk("deflate_tire", nil, nil), "beamstate.deflateTires() return true")
end)

test("buildApplyChunk deflate_tire with wheel 0 (a valid id) uses the integer branch", function()
  assertEqual(bd.buildApplyChunk("deflate_tire", nil, 0), "beamstate.deflateTire(0) return true")
end)

test("buildApplyChunk returns nil for an unknown kind (caller validates)", function()
  assertNil(bd.buildApplyChunk("bogus_kind", "g", nil))
end)

test("buildApplyChunk deform_group quotes the group", function()
  local c = bd.buildApplyChunk("deform_group", "differential_F", nil)
  assertMatch(c, 'beamstate%.triggerDeformGroup%("differential_F"%)')
end)

test("buildApplyChunk destroy", function()
  assertEqual(bd.buildApplyChunk("destroy"), "beamstate.breakAllBreakgroups() return true")
end)

-- Empirical injection proof: a malicious group is passed as ONE string argument, never executed.
test("buildApplyChunk is injection-safe (group is a literal arg, os.exit never runs)", function()
  local evil = 'x") os.exit(99) ("'
  local c = bd.buildApplyChunk("break_group", evil, nil)
  local fn = loadstring(c)
  assertTrue(fn ~= nil)                       -- compiles
  local captured
  setfenv(fn, { beamstate = { breakBreakGroup = function(a) captured = a end } })
  fn()                                        -- if injection worked, os.exit(99) would kill the test run here
  assertEqual(captured, evil)                 -- the entire payload arrived as a single string argument
end)

-- ---- list_damage_groups handler ----
local function stubBe(playerId) _G.be = { getPlayerVehicleID = function() return playerId or 7 end } end

test("list_damage_groups returns M.fetch's catalog and resolves the default id", function()
  stubBe(11)
  local seen
  bd.fetch = function(id) seen = id
    return { breakGroups = { "a" }, deformGroups = { "b" }, wheels = { { id = 0, name = "FL" } } }
  end
  local res, err = bd.listDef.handler({})
  assertNil(err)
  assertEqual(seen, 11)                       -- defaulted to the player vehicle
  assertEqual(res.breakGroups[1], "a")
  assertEqual(res.wheels[1].name, "FL")
end)

test("list_damage_groups forwards an explicit id and surfaces a fetch error", function()
  stubBe()
  local seen
  bd.fetch = function(id) seen = id; return nil, "list_damage_groups: unknown vehicle id 5" end
  local res, err = bd.listDef.handler({ id = 5 })
  assertEqual(seen, 5)
  assertNil(res); assertMatch(err, "unknown vehicle id 5")
end)

-- ---- damage_vehicle handler ----
test("damage_vehicle valid call forwards (id,kind,group,wheel) and returns {kind,ok}", function()
  stubBe(9)
  local seen
  bd.apply = function(id, kind, group, wheel) seen = { id, kind, group, wheel }; return true end
  local res, err = bd.damageDef.handler({ kind = "break_group", group = "fender_a_L" })
  assertNil(err)
  assertEqual(res.kind, "break_group"); assertEqual(res.ok, true)
  assertEqual(seen[1], 9); assertEqual(seen[2], "break_group"); assertEqual(seen[3], "fender_a_L")
end)

test("damage_vehicle deflate_tire forwards the wheel; omitted wheel -> nil", function()
  stubBe()
  local seen = "unset"
  bd.apply = function(id, kind, group, wheel) seen = wheel; return true end
  bd.damageDef.handler({ kind = "deflate_tire", wheel = 3 })
  assertEqual(seen, 3)
  bd.damageDef.handler({ kind = "deflate_tire" })
  assertNil(seen)
end)

test("damage_vehicle rejects non-table args", function()
  local r, e = bd.damageDef.handler("nope")
  assertNil(r); assertMatch(e, "must be an object")
end)

test("damage_vehicle rejects an unknown kind", function()
  stubBe()
  local r, e = bd.damageDef.handler({ kind = "explode" })
  assertNil(r); assertMatch(e, "'kind' must be one of")
end)

test("damage_vehicle break_group / deform_group require a non-empty group", function()
  stubBe()
  local r1, e1 = bd.damageDef.handler({ kind = "break_group" })
  assertNil(r1); assertMatch(e1, "requires a non%-empty 'group' string")
  local r2, e2 = bd.damageDef.handler({ kind = "deform_group", group = "" })
  assertNil(r2); assertMatch(e2, "requires a non%-empty 'group' string")
end)

test("damage_vehicle deflate_tire rejects a non-number wheel", function()
  stubBe()
  local r, e = bd.damageDef.handler({ kind = "deflate_tire", wheel = "FL" })
  assertNil(r); assertMatch(e, "'wheel' must be a number")
end)

test("damage_vehicle surfaces an M.apply error", function()
  stubBe()
  bd.apply = function() return nil, "damage_vehicle: no response from vehicle VM" end
  local r, e = bd.damageDef.handler({ kind = "destroy" })
  assertNil(r); assertMatch(e, "no response from vehicle VM")
end)

test("register adds list_damage_groups and damage_vehicle", function()
  local r = registry.new()
  bd.register(r)
  local names = {}
  for _, t in ipairs(r:list()) do names[t.name] = true end
  assertTrue(names["list_damage_groups"])
  assertTrue(names["damage_vehicle"])
end)

-- ---- M.shapeList (pure): compact-by-default discipline ----
test("shapeList passes small unfiltered catalogs through with no note", function()
  local res = bd.shapeList({ breakGroups = { "a", "b" }, deformGroups = { "d" },
    wheels = { { id = 1, name = "FL" } } }, nil)
  assertEqual(#res.breakGroups, 2)
  assertEqual(#res.deformGroups, 1)
  assertEqual(res.wheels[1].name, "FL")
  assertNil(res.note)
end)

test("shapeList filter narrows groups and wheel names (case-insensitive substring)", function()
  local res = bd.shapeList({
    breakGroups = { "fender_L", "door_R" }, deformGroups = { "Fender_crush" },
    wheels = { { id = 1, name = "FL" }, { id = 2, name = "RR" } },
  }, "fend")
  assertEqual(#res.breakGroups, 1)
  assertEqual(res.breakGroups[1], "fender_L")
  assertEqual(#res.deformGroups, 1)
  assertEqual(#res.wheels, 0)
end)

test("shapeList caps each list at MAX_LIST and says so in the note", function()
  local bg = {}
  for n = 1, bd.MAX_LIST + 50 do bg[n] = "group_" .. string.format("%04d", n) end
  local res = bd.shapeList({ breakGroups = bg, deformGroups = {}, wheels = {} }, nil)
  assertEqual(#res.breakGroups, bd.MAX_LIST)
  assertMatch(res.note, "breakGroups")
  assertMatch(res.note, "filter=")
end)

test("list_damage_groups rejects a non-number id with a shaped error", function()
  _G.be = { getPlayerVehicleID = function() return 7 end }
  bd.fetch = function() return { breakGroups = {}, deformGroups = {}, wheels = {} } end
  local res, err = bd.listDef.handler({ id = "seven" })
  assertNil(res)
  assertMatch(err, "list_damage_groups: 'id' must be a number")
end)

test("damage_vehicle rejects a non-number id with a shaped error", function()
  _G.be = { getPlayerVehicleID = function() return 7 end }
  bd.apply = function() return true end
  local res, err = bd.damageDef.handler({ kind = "destroy", id = "seven" })
  assertNil(res)
  assertMatch(err, "damage_vehicle: 'id' must be a number")
end)

test("damage_vehicle 'kind' schema carries the closed enum the handler enforces", function()
  local e = bd.damageDef.inputSchema.properties.kind.enum
  assertTrue(type(e) == "table")
  local set = {}
  for _, k in ipairs(e) do set[k] = true end
  for _, k in ipairs({ "break_group", "break_hinges", "deflate_tire", "deform_group", "destroy" }) do
    assertTrue(set[k], "enum missing " .. k)
  end
  assertEqual(#e, 5)
end)
