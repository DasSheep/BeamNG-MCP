require("support.beamng_stubs")
local gvc      = require("beammcp/tools/get_vehicle_config")
local registry = require("core.registry")
local realFetch = gvc.fetch   -- captured before tests stub it (runner has no teardown)

-- Synthetic partsTree mirroring the recon shape: root is the main part; each node has
-- id (slot name) / path (unique) / chosenPartName (installed part or "") / children (map).
-- frontaxle+rearaxle both contain a child with id="wheel" -> a cross-parent slot-id COLLISION.
local PT = {
  id = "main", path = "/", chosenPartName = "dumptruck",
  children = {
    engine = { id = "engine", path = "/engine/", chosenPartName = "dump_engine", children = {
      turbo = { id = "turbo", path = "/engine/turbo/", chosenPartName = "dump_turbo", children = {} },
    } },
    paint_design = { id = "paint_design", path = "/paint_design/", chosenPartName = "", children = {} }, -- empty slot
    frontaxle = { id = "frontaxle", path = "/frontaxle/", chosenPartName = "fa", children = {
      wheel = { id = "wheel", path = "/frontaxle/wheel/", chosenPartName = "wheel_F", children = {} },
    } },
    rearaxle = { id = "rearaxle", path = "/rearaxle/", chosenPartName = "ra", children = {
      wheel = { id = "wheel", path = "/rearaxle/wheel/", chosenPartName = "wheel_R", children = {} },
    } },
  },
}

local function countKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- ---- pure flatten ------------------------------------------------------------------------

test("flatten: id-keyed {slot:part}; root excluded; empty dropped; collision -> path fallback", function()
  local f = gvc.flatten(PT)
  assertEqual(f.engine, "dump_engine")
  assertEqual(f.turbo, "dump_turbo")        -- nested descendants included
  assertEqual(f.frontaxle, "fa")
  assertEqual(f.rearaxle, "ra")
  assertNil(f.paint_design)                 -- empty chosenPartName dropped
  assertNil(f.main)                         -- root/main part excluded from the flat map
  assertNil(f.wheel)                         -- collided id NOT used as a key...
  assertEqual(f["/frontaxle/wheel/"], "wheel_F")  -- ...both collided entries fall back to full path
  assertEqual(f["/rearaxle/wheel/"], "wheel_R")
  assertEqual(countKeys(f), 6)
end)

test("flatten: no children / empty -> empty map", function()
  assertEqual(countKeys(gvc.flatten({ id = "main", chosenPartName = "x" })), 0)
  assertEqual(countKeys(gvc.flatten({ id = "main", chosenPartName = "x", children = {} })), 0)
end)

-- ---- pure buildTree ----------------------------------------------------------------------

test("buildTree: nested structure keyed by slot, empty slots included, leaves omit children", function()
  local t = gvc.buildTree(PT)
  assertEqual(t.engine.part, "dump_engine")
  assertEqual(t.engine.children.turbo.part, "dump_turbo")
  assertEqual(t.paint_design.part, "")        -- empty slot SHOWN in the tree
  assertNil(t.paint_design.children)          -- leaf has no children key
  assertEqual(t.frontaxle.children.wheel.part, "wheel_F")
  assertEqual(t.rearaxle.children.wheel.part, "wheel_R")
end)

-- ---- handler dispatch (stub fetch) -------------------------------------------------------

local function stubFetch(model, mainPart, pt)
  gvc.fetch = function(_id) return { model = model, mainPart = mainPart, partsTree = pt } end
end

test("handler default: model/mainPart/count/parts, no tree", function()
  stubFetch("dumptruck", "dumptruck", PT)
  local res, err = gvc.def.handler({ id = 1 })
  assertNil(err)
  assertEqual(res.model, "dumptruck")
  assertEqual(res.mainPart, "dumptruck")
  assertEqual(res.count, 6)
  assertEqual(res.parts.engine, "dump_engine")
  assertEqual(res.parts["/rearaxle/wheel/"], "wheel_R")
  assertNil(res.tree)
end)

test("handler detail=true: adds tree, keeps the flat parts", function()
  stubFetch("dumptruck", "dumptruck", PT)
  local res = gvc.def.handler({ id = 1, detail = true })
  assertEqual(res.parts.engine, "dump_engine")
  assertEqual(res.tree.engine.children.turbo.part, "dump_turbo")
end)

test("handler: fetch failure -> clean error", function()
  gvc.fetch = function(_id) return nil, "get_vehicle_config: unknown vehicle id 999" end
  local res, err = gvc.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 999")
end)

test("handler rejects non-number id, non-boolean detail, non-table args", function()
  stubFetch("dumptruck", "dumptruck", PT)
  local r1, e1 = gvc.def.handler({ id = "x" })
  assertNil(r1); assertMatch(e1, "'id' must be a number")
  local r2, e2 = gvc.def.handler({ id = 1, detail = "yes" })
  assertNil(r2); assertMatch(e2, "'detail' must be a boolean")
  local r3, e3 = gvc.def.handler("nope")
  assertNil(r3); assertMatch(e3, "must be an object")
end)

test("handler defaults id to the player vehicle", function()
  _G.be = { getPlayerVehicleID = function(_self, _n) return 1 end }
  stubFetch("dumptruck", "dumptruck", PT)
  local res = gvc.def.handler({})
  assertEqual(res.count, 6)
end)

test("register adds it under 'get_vehicle_config'", function()
  gvc.fetch = realFetch
  local r = registry.new()
  gvc.register(r)
  assertEqual(r:list()[1].name, "get_vehicle_config")
end)
