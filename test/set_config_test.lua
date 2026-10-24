local registry = require("core.registry")
local sc = require("beammcp/tools/set_config")
-- Captured before any test stubs them (the existing handler tests permanently stub sc.applyConfig; the
-- runner has no teardown). The merge tests below restore the real ones.
local realApplyConfig   = sc.applyConfig
local realCurrentConfig = sc.currentConfig

local function stubBe(playerId, model)
  _G.be = {
    getPlayerVehicleID = function(self, n) return playerId end,
    getObjectByID = function(self, id)
      return (id == playerId) and { getJBeamFilename = function() return model end } or nil
    end,
  }
end

test("success: returns {vehicleId, model, config}", function()
  stubBe(45, "us_semi")
  sc.applyConfig = function(veh, model, config) return 45 end
  local res, err = sc.def.handler({ config = "tc84_tridrive" })
  assertNil(err)
  assertEqual(res.vehicleId, 45)
  assertEqual(res.model, "us_semi")
  assertEqual(res.config, "tc84_tridrive")
end)

test("passes the current model (and target vehicle) to applyConfig", function()
  stubBe(45, "us_semi")
  local seen = {}
  sc.applyConfig = function(veh, model, config) seen.veh = veh; seen.model = model; seen.config = config; return 45 end
  sc.def.handler({ config = "tandem" })
  assertEqual(seen.model, "us_semi")
  assertEqual(seen.config, "tandem")
  assertTrue(seen.veh ~= nil)
  assertEqual(seen.veh:getJBeamFilename(), "us_semi")
end)

test("inline table config: passed through to applyConfig; return is compacted", function()
  stubBe(45, "us_semi")
  local seen = {}
  sc.applyConfig = function(veh, model, config) seen.config = config; return 45 end
  local cfg = { parts = { a = "x", b = "y" } }
  local res, err = sc.def.handler({ config = cfg })
  assertNil(err)
  assertEqual(seen.config, cfg)          -- table passed through unchanged
  assertEqual(res.config.inline, true)   -- return is compacted, not the raw table
  assertEqual(res.config.parts, 2)
end)

test("failure: applyConfig nil -> failed-to-apply error names a string config", function()
  stubBe(45, "us_semi")
  sc.applyConfig = function() return nil end
  local res, err = sc.def.handler({ config = "bogus" })
  assertNil(res)
  assertMatch(err, "failed to apply")
  assertMatch(err, "bogus")
end)

test("failure: applyConfig nil with a table config -> generic error (no concat crash)", function()
  stubBe(45, "us_semi")
  sc.applyConfig = function() return nil end
  local res, err = sc.def.handler({ config = { parts = {} } })
  assertNil(res)
  assertMatch(err, "failed to apply")
  assertMatch(err, "inline config")
end)

test("bad args: missing config is required", function()
  stubBe(45, "us_semi")
  local res, err = sc.def.handler({})
  assertNil(res)
  assertMatch(err, "'config' is required")
end)

test("bad args: non-string non-table config", function()
  stubBe(45, "us_semi")
  local res, err = sc.def.handler({ config = 5 })
  assertNil(res)
  assertMatch(err, "'config' must be a string or a table")
end)

test("bad args: non-number id", function()
  stubBe(45, "us_semi")
  local res, err = sc.def.handler({ config = "x", id = "45" })
  assertNil(res)
  assertMatch(err, "'id' must be a number")
end)

test("unknown id -> error", function()
  stubBe(45, "us_semi")
  local res, err = sc.def.handler({ config = "x", id = 999 })
  assertNil(res)
  assertMatch(err, "no vehicle with id 999")
end)

-- ---- M.mergeConfig (pure: overlay patch onto current) ----
test("mergeConfig overlays patch parts+vars onto current (patch keys win)", function()
  local m = sc.mergeConfig(
    { parts = { a = "x", b = "y" }, vars = { ["$1"] = 1, ["$2"] = 2 } },
    { parts = { b = "z" }, vars = { ["$2"] = 9, ["$3"] = 3 } })
  assertEqual(m.parts.a, "x")            -- current kept
  assertEqual(m.parts.b, "z")            -- patch wins
  assertEqual(m.vars["$1"], 1)
  assertEqual(m.vars["$2"], 9)           -- patch wins
  assertEqual(m.vars["$3"], 3)           -- patch adds
end)

test("mergeConfig: vars-only patch keeps current parts; parts-only keeps current vars", function()
  local v = sc.mergeConfig({ parts = { a = "x" }, vars = { ["$1"] = 1 } }, { vars = { ["$2"] = 2 } })
  assertEqual(v.parts.a, "x"); assertEqual(v.vars["$2"], 2)
  local p = sc.mergeConfig({ parts = { a = "x" }, vars = { ["$1"] = 1 } }, { parts = { a = "z" } })
  assertEqual(p.parts.a, "z"); assertEqual(p.vars["$1"], 1)
end)

test("mergeConfig does not mutate current", function()
  local cur = { parts = { a = "x" }, vars = { ["$1"] = 1 } }
  sc.mergeConfig(cur, { parts = { a = "z" }, vars = { ["$1"] = 9 } })
  assertEqual(cur.parts.a, "x"); assertEqual(cur.vars["$1"], 1)
end)

-- ---- M.applyConfig (merge-path; stub currentConfig + replaceVehicle) ----
test("applyConfig table -> merges patch onto current config before replaceVehicle", function()
  sc.applyConfig = realApplyConfig
  sc.currentConfig = function(_veh) return { parts = { engine = "e_stock", body = "b1" }, vars = { ["$a"] = 1, ["$b"] = 2 } } end
  local seen
  _G.core_vehicles = { replaceVehicle = function(_m, opts, _v) seen = opts.config; return { getID = function() return 7 end } end }
  local vid = sc.applyConfig({ getID = function() return 7 end }, "mdl",
    { parts = { body = "b2" }, vars = { ["$b"] = 9, ["$c"] = 3 } })
  assertEqual(vid, 7)
  assertEqual(seen.parts.engine, "e_stock")  -- build preserved
  assertEqual(seen.parts.body, "b2")         -- patched slot
  assertEqual(seen.vars["$a"], 1)            -- other tuning preserved
  assertEqual(seen.vars["$b"], 9)            -- patched
  assertEqual(seen.vars["$c"], 3)            -- added
  sc.currentConfig = realCurrentConfig
end)

test("applyConfig string -> passes the string through (no merge / no currentConfig read)", function()
  sc.applyConfig = realApplyConfig
  local called = false
  sc.currentConfig = function() called = true; return nil end
  local seen
  _G.core_vehicles = { replaceVehicle = function(_m, opts, _v) seen = opts.config; return { getID = function() return 7 end } end }
  sc.applyConfig({ getID = function() return 7 end }, "mdl", "tc84_tridrive")
  assertEqual(seen, "tc84_tridrive")
  assertEqual(called, false)                 -- string path never reads current config
  sc.currentConfig = realCurrentConfig
end)

test("applyConfig table with no readable current config -> applies the patch as-is", function()
  sc.applyConfig = realApplyConfig
  sc.currentConfig = function() return nil end
  local seen
  _G.core_vehicles = { replaceVehicle = function(_m, opts, _v) seen = opts.config; return { getID = function() return 7 end } end }
  local patch = { vars = { ["$x"] = 1 } }
  sc.applyConfig({ getID = function() return 7 end }, "mdl", patch)
  assertEqual(seen, patch)
  sc.currentConfig = realCurrentConfig
end)

test("register adds it under 'set_config'", function()
  local r = registry.new()
  sc.register(r)
  assertEqual(r:list()[1].name, "set_config")
end)
