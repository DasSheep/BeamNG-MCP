require("support.beamng_stubs")
local pc       = require("beammcp/tools/part_condition")
local registry = require("core.registry")

-- ---- M.shapeSummary (pure) ----
test("shapeSummary lists damaged parts sorted by damage desc, rounded, with name", function()
  local raw = {
    parts = {
      ["pigeon/pigeon_frame"] = { name = "frame", damage = 0.15 },
      ["pigeon/pigeon_body"]  = { name = "body",  damage = 0.62 },
    },
    beamsDeformed = 142,
  }
  local out = pc.shapeSummary(raw)
  assertEqual(#out.parts, 2)
  assertEqual(out.parts[1].part, "pigeon/pigeon_body")   -- highest damage first
  assertEqual(out.parts[1].name, "body")
  assertEqual(out.parts[1].damage, 0.62)
  assertEqual(out.parts[2].name, "frame")
  assertEqual(out.parts[2].damage, 0.15)
  assertMatch(out.note, "2 damaged part")          -- damaged sentence
  assertMatch(out.note, "detail=true")             -- HINT appended when damaged
end)

test("shapeSummary drops zero/negative-damage parts and derives a name from the path", function()
  local raw = {
    parts = {
      ["m/clean"]  = { damage = 0 },          -- dropped (no damage)
      ["m/also"]   = { damage = -0.1 },        -- dropped
      ["veh/hood"] = { damage = 0.40 },        -- kept; no name field -> basename "hood"
    },
    beamsDeformed = 1,
  }
  local out = pc.shapeSummary(raw)
  assertEqual(#out.parts, 1)
  assertEqual(out.parts[1].name, "hood")
  assertEqual(out.parts[1].damage, 0.40)
end)

test("shapeSummary reports beams.deformed (the only beam metric)", function()
  local out = pc.shapeSummary({ parts = {}, beamsDeformed = 142 })
  assertEqual(out.beams.deformed, 142)
  assertNil(out.beams.broken)        -- no broken metric (unreliable; not reported)
  assertNil(out.integrity)           -- no integrity (no read-safe source)
end)

test("shapeSummary defaults beams.deformed to 0 when absent", function()
  local out = pc.shapeSummary({ parts = {} })
  assertEqual(out.beams.deformed, 0)
end)

test("shapeSummary on a pristine payload -> empty parts, zero beams, undamaged note", function()
  local out = pc.shapeSummary({ parts = {}, beamsDeformed = 0 })
  assertEqual(#out.parts, 0)
  assertEqual(out.beams.deformed, 0)
  assertMatch(out.note, "undamaged")
end)

-- ---- M.capList (pure) ----
test("capList returns the whole list and its true total when at/under the cap", function()
  local arr = { "a", "b", "c" }
  local capped, total = pc.capList(arr, 5)
  assertEqual(#capped, 3); assertEqual(total, 3)
end)

test("capList truncates to N and reports the true total when over the cap", function()
  local arr = {}
  for i = 1, 10 do arr[i] = i end
  local capped, total = pc.capList(arr, 4)
  assertEqual(#capped, 4); assertEqual(total, 10)
  assertEqual(capped[1], 1); assertEqual(capped[4], 4)   -- keeps the first N (already severity-sorted)
end)

-- ---- M.shapeDetail (pure) ----
test("shapeDetail includes the summary fields", function()
  local out = pc.shapeDetail({
    parts = { ["v/body"] = { name = "body", damage = 0.5 } },
    beamsDeformed = 3,
  })
  assertEqual(#out.parts, 1)
  assertEqual(out.beams.deformed, 3)
end)

test("shapeDetail curates deformGroups: damaged-only, sorted by damage desc", function()
  local out = pc.shapeDetail({
    parts = {}, beamsDeformed = 0,
    deformGroups = { body_rear = 0.20, body_front = 0.80, untouched = 0 },
  })
  assertEqual(#out.deformGroups, 2)
  assertEqual(out.deformGroups[1].group, "body_front")
  assertEqual(out.deformGroups[1].damage, 0.80)
  assertEqual(out.deformGroups[2].group, "body_rear")
end)

test("shapeDetail caps deformGroups at the cap and notes the true total", function()
  local dg = {}
  for i = 1, 40 do dg["g" .. i] = 0.5 end
  local out = pc.shapeDetail({ parts = {}, beamsDeformed = 0, deformGroups = dg })
  assertEqual(#out.deformGroups, 30)                 -- DETAIL_CAP
  assertMatch(out.note, "top 30 of 40 deform groups")
end)

test("shapeDetail omits empty deformGroups", function()
  local out = pc.shapeDetail({ parts = {}, beamsDeformed = 0 })
  assertNil(out.deformGroups)
end)

-- ---- M.fetch (engine seam; stub be + evalVE, restore evalVE even on failure) ----
local vle = require("beammcp/tools/vehicle_lua_eval")
local realEvalVE = vle.evalVE
local realFetch = pc.fetch        -- captured before any test monkey-patches it; restored at end of file
local function withEval(stub, fn)
  vle.evalVE = stub
  local ok, err = pcall(fn)
  vle.evalVE = realEvalVE
  if not ok then error(err, 2) end
end
local function stubBe(playerId, knownId)
  _G.be = {
    getPlayerVehicleID = function() return playerId or 7 end,
    -- knownId == nil means "accept any id"; pass a specific id to make only that one resolve.
    getObjectByID = function(id) if knownId == nil or id == knownId then return {} end return nil end,
  }
end

test("fetch on an unknown vehicle id returns a clean error", function()
  stubBe(7, 5)   -- only id 5 exists
  local data, err = pc.fetch(9, false)
  assertNil(data); assertMatch(err, "unknown vehicle id 9")
end)

test("fetch surfaces a nil evalVE payload as 'no response'", function()
  stubBe(7, nil)
  withEval(function() return nil end, function()
    local data, err = pc.fetch(1, false)
    assertNil(data); assertMatch(err, "no response from vehicle VM")
  end)
end)

test("fetch surfaces an evalVE ok=false error", function()
  stubBe(7, nil)
  withEval(function() return { ok = false, err = "boom" } end, function()
    local data, err = pc.fetch(1, false)
    assertNil(data); assertMatch(err, "boom")
  end)
end)

test("fetch returns the value and picks the summary vs detail chunk", function()
  stubBe(7, nil)
  local seen
  withEval(function(veh, chunk) seen = chunk; return { ok = true, value = { parts = {} } } end, function()
    local data = pc.fetch(1, false)
    assertTrue(data ~= nil)
    assertMatch(seen, "getPartDamageData")               -- summary chunk reads part damage
    assertTrue(seen:find("deformGroupDamage") == nil)    -- ...and NOT the detail-only structure
    pc.fetch(1, true)
    assertMatch(seen, "deformGroupDamage")               -- detail chunk adds the deform-group read
  end)
end)

-- ---- handler / def ----
test("get_part_condition rejects non-table args", function()
  local r, e = pc.def.handler("nope")
  assertNil(r); assertMatch(e, "must be an object")
end)

test("get_part_condition rejects a non-number id and a non-boolean detail", function()
  stubBe()
  local r1, e1 = pc.def.handler({ id = "x" })
  assertNil(r1); assertMatch(e1, "'id' must be a number")
  local r2, e2 = pc.def.handler({ detail = "yes" })
  assertNil(r2); assertMatch(e2, "'detail' must be a boolean")
end)

test("get_part_condition defaults id to the player, routes summary, and attaches id", function()
  stubBe(11)
  local seen
  pc.fetch = function(id, detail) seen = { id, detail }
    return { parts = { ["v/body"] = { name = "body", damage = 0.5 } }, beamsDeformed = 2 }
  end
  local res, err = pc.def.handler({})
  assertNil(err)
  assertEqual(seen[1], 11)                  -- defaulted to the player vehicle
  assertEqual(seen[2], false)               -- summary
  assertEqual(res.id, 11)                   -- echoed
  assertEqual(#res.parts, 1)
  assertNil(res.deformGroups)               -- summary shape (no detail fields)
end)

test("get_part_condition detail=true routes to the detail shape", function()
  stubBe(3)
  pc.fetch = function(id, detail)
    return { parts = {}, beamsDeformed = 0, deformGroups = { body_front = 0.7 } }
  end
  local res = pc.def.handler({ detail = true })
  assertEqual(res.id, 3)
  assertEqual(#res.deformGroups, 1)
  assertEqual(res.deformGroups[1].group, "body_front")
end)

test("get_part_condition surfaces a fetch error", function()
  stubBe()
  pc.fetch = function() return nil, "get_part_condition: unknown vehicle id 5" end
  local r, e = pc.def.handler({ id = 5 })
  assertNil(r); assertMatch(e, "unknown vehicle id 5")
end)

pc.fetch = realFetch   -- restore the real seam so tests appended later see it (runner has no teardown)

test("register adds get_part_condition", function()
  local r = registry.new()
  pc.register(r)
  local names = {}
  for _, t in ipairs(r:list()) do names[t.name] = true end
  assertTrue(names["get_part_condition"])
end)
