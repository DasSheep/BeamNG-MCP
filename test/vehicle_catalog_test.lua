require("support.beamng_stubs")
local vc       = require("beammcp/tools/vehicle_catalog")
local registry = require("core.registry")

-- Sample model-info tables (the array=true form of getModelList). barstow omits Country;
-- tanker is minimal (no Brand/Country) and has NO configs in CONFIGS below.
local MODELS = {
  { key = "pigeon",  Name = "Ibishu Pigeon",  Type = "Car",     default_pc = "1.4", Brand = "Ibishu", Country = "Japan" },
  { key = "barstow", Name = "Gavril Barstow", Type = "Car",     default_pc = "v8",  Brand = "Gavril" },
  { key = "tanker",  Name = "Tanker Trailer", Type = "Trailer" },
}

-- Sample config tables (the array=true form of getConfigList; ALL models flat). A config IS the raw
-- info.json: flat Power/Weight/"Top Speed"/Drivetrain. barstow v8 carries no perf fields -> perf {}.
local CONFIGS = {
  { model_key = "pigeon",  key = "1.4",  Name = "Ibishu Pigeon 1.4",  Configuration = "1.4",  is_default_config = true,
    Power = 30, Weight = 700, ["Top Speed"] = 120, Drivetrain = "RWD" },
  { model_key = "pigeon",  key = "base", Name = "Ibishu Pigeon base", Configuration = "base", is_default_config = false,
    Power = 22, Weight = 655, ["Top Speed"] = 110, Drivetrain = "RWD" },
  { model_key = "barstow", key = "v8",   Name = "Gavril Barstow v8",  Configuration = "v8",   is_default_config = true },
}

test("curateModel picks the six identity fields", function()
  local r = vc.curateModel(MODELS[1])
  assertEqual(r.key, "pigeon")
  assertEqual(r.name, "Ibishu Pigeon")
  assertEqual(r.type, "Car")
  assertEqual(r.default_pc, "1.4")
  assertEqual(r.brand, "Ibishu")
  assertEqual(r.country, "Japan")
end)

test("curateModel is nil-tolerant on missing optional fields (brand/country/default_pc)", function()
  local r = vc.curateModel(MODELS[3])  -- tanker: no Brand/Country/default_pc
  assertEqual(r.key, "tanker")
  assertEqual(r.type, "Trailer")
  assertNil(r.brand)
  assertNil(r.country)
  assertNil(r.default_pc)
end)

test("curateModel handles partial absence (brand present, country absent)", function()
  local r = vc.curateModel(MODELS[2])  -- barstow: Brand but no Country
  assertEqual(r.brand, "Gavril")
  assertNil(r.country)
  assertEqual(r.default_pc, "v8")
end)

test("flattenPerf reads the four flat fields", function()
  local p = vc.flattenPerf(CONFIGS[2])  -- pigeon base
  assertEqual(p.power, 22)
  assertEqual(p.weight, 655)
  assertEqual(p.topSpeed, 110)
  assertEqual(p.drivetrain, "RWD")
end)

test("flattenPerf omits absent fields and returns {} for a bare config", function()
  local p = vc.flattenPerf(CONFIGS[3])  -- barstow v8: no perf fields
  assertNil(p.power)
  assertNil(p.weight)
  assertNil(p.topSpeed)
  assertNil(p.drivetrain)
  local n = 0; for _ in pairs(p) do n = n + 1 end
  assertEqual(n, 0)
end)

test("flattenPerf tolerates a string where a number is expected (pass-through)", function()
  local p = vc.flattenPerf({ ["Top Speed"] = "n/a" })
  assertEqual(p.topSpeed, "n/a")
end)

test("flattenPerf keeps falsy-but-present values (0 and empty string)", function()
  local p = vc.flattenPerf({ Power = 0, Weight = 0, Drivetrain = "" })
  assertEqual(p.power, 0)
  assertEqual(p.weight, 0)
  assertEqual(p.drivetrain, "")
  assertNil(p.topSpeed)  -- still absent -> omitted
end)

test("curateConfig maps is_default_config -> is_default and nests perf", function()
  local r = vc.curateConfig(CONFIGS[1])  -- pigeon 1.4 (default)
  assertEqual(r.key, "1.4")
  assertEqual(r.name, "Ibishu Pigeon 1.4")
  assertEqual(r.configuration, "1.4")
  assertEqual(r.is_default, true)
  assertEqual(r.perf.power, 30)
  local r2 = vc.curateConfig(CONFIGS[2])
  assertEqual(r2.is_default, false)
end)

test("list_spawnable_models compact default: key/name/type rows, sorted, no detail fields, no total", function()
  vc.fetchModels = function() return MODELS end
  local res, err = vc.modelsDef.handler({})
  assertNil(err)
  assertEqual(res.count, 3)
  assertEqual(res.models[1].key, "barstow")  -- sorted: barstow < pigeon < tanker
  assertEqual(res.models[2].key, "pigeon")
  assertEqual(res.models[3].key, "tanker")
  assertEqual(res.models[1].name, "Gavril Barstow")
  assertEqual(res.models[2].type, "Car")
  assertNil(res.models[2].default_pc) -- compact omits the detail fields
  assertNil(res.models[2].brand)
  assertNil(res.total)                -- unfiltered -> no total
end)

test("list_spawnable_models: types breakdown over the full catalog", function()
  vc.fetchModels = function() return MODELS end
  local res = vc.modelsDef.handler({})
  assertEqual(res.types.Car, 2)
  assertEqual(res.types.Trailer, 1)
end)

test("list_spawnable_models: type= filter narrows + adds total; breakdown stays full-catalog", function()
  vc.fetchModels = function() return MODELS end
  local res = vc.modelsDef.handler({ type = "Car" })
  assertEqual(res.count, 2)
  assertEqual(res.total, 3)
  assertEqual(res.types.Car, 2)       -- breakdown is still the WHOLE catalog
  assertEqual(res.types.Trailer, 1)
  assertEqual(res.models[1].key, "barstow")
  assertEqual(res.models[2].key, "pigeon")
end)

test("list_spawnable_models: brand= filter (nil-safe for brand-less models)", function()
  vc.fetchModels = function() return MODELS end
  local res = vc.modelsDef.handler({ brand = "Ibishu" })
  assertEqual(res.count, 1)
  assertEqual(res.total, 3)
  assertEqual(res.models[1].key, "pigeon") -- tanker (no Brand) excluded, not matched
end)

test("list_spawnable_models: type= + brand= combine", function()
  vc.fetchModels = function() return MODELS end
  local res = vc.modelsDef.handler({ type = "Car", brand = "Gavril" })
  assertEqual(res.count, 1)
  assertEqual(res.models[1].key, "barstow")
end)

test("list_spawnable_models: detail=true returns the full six fields", function()
  vc.fetchModels = function() return MODELS end
  local res = vc.modelsDef.handler({ detail = true })
  assertEqual(res.models[2].key, "pigeon")
  assertEqual(res.models[2].default_pc, "1.4")
  assertEqual(res.models[2].brand, "Ibishu")
  assertEqual(res.models[2].country, "Japan")
  -- detail composes with filters (and still reports total)
  local r2 = vc.modelsDef.handler({ type = "Car", detail = true })
  assertEqual(r2.count, 2)
  assertEqual(r2.total, 3)
  assertEqual(r2.models[1].default_pc, "v8") -- barstow
end)

test("list_spawnable_models: rejects non-string type/brand and non-boolean detail", function()
  vc.fetchModels = function() return MODELS end
  local r1, e1 = vc.modelsDef.handler({ type = 7 })
  assertNil(r1); assertMatch(e1, "'type' must be a string")
  local r2, e2 = vc.modelsDef.handler({ brand = {} })
  assertNil(r2); assertMatch(e2, "'brand' must be a string")
  local r3, e3 = vc.modelsDef.handler({ detail = "yes" })
  assertNil(r3); assertMatch(e3, "'detail' must be a boolean")
end)

test("list_spawnable_models: nil fetch -> catalog error", function()
  vc.fetchModels = function() return nil end
  local res, err = vc.modelsDef.handler({})
  assertNil(res)
  assertMatch(err, "failed to read vehicle catalog")
end)

test("list_vehicle_configs compact default: key/name/is_default only, sorted, no perf/configuration/total", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local res, err = vc.configsDef.handler({ model = "pigeon" })
  assertNil(err)
  assertEqual(res.model, "pigeon")
  assertEqual(res.count, 2)
  assertEqual(res.configs[1].key, "1.4")   -- sorted: "1.4" < "base"
  assertEqual(res.configs[2].key, "base")
  assertEqual(res.configs[1].name, "Ibishu Pigeon 1.4")
  assertEqual(res.configs[1].is_default, true)
  assertNil(res.configs[1].perf)           -- compact drops perf
  assertNil(res.configs[1].configuration)  -- ...and configuration
  assertNil(res.total)                     -- 2 < cap -> not capped
end)

test("list_vehicle_configs detail=true: restores configuration + perf", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local res = vc.configsDef.handler({ model = "pigeon", detail = true })
  assertEqual(res.configs[1].configuration, "1.4")
  assertEqual(res.configs[1].perf.topSpeed, 120)
  assertEqual(res.configs[1].is_default, true)
end)

test("list_vehicle_configs limit caps the list + reports total + note", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local res = vc.configsDef.handler({ model = "pigeon", limit = 1 })
  assertEqual(res.count, 1)
  assertEqual(res.total, 2)
  assertEqual(res.configs[1].key, "1.4") -- deterministic top-N by key
  assertMatch(res.note, "top 1 of 2 configs")
end)

test("list_vehicle_configs rejects non-number limit / non-boolean detail", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local r1, e1 = vc.configsDef.handler({ model = "pigeon", limit = "x" })
  assertNil(r1); assertMatch(e1, "'limit' must be a number")
  local r2, e2 = vc.configsDef.handler({ model = "pigeon", detail = "yes" })
  assertNil(r2); assertMatch(e2, "'detail' must be a boolean")
end)

test("list_vehicle_configs: known model with zero configs -> count 0", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local res, err = vc.configsDef.handler({ model = "tanker" })  -- in MODELS, no CONFIGS rows
  assertNil(err)
  assertEqual(res.count, 0)
  assertEqual(#res.configs, 0)
end)

test("list_vehicle_configs: unknown model -> error", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return CONFIGS end
  local res, err = vc.configsDef.handler({ model = "nope" })
  assertNil(res)
  assertMatch(err, "unknown model 'nope'")
end)

test("list_vehicle_configs: rejects non-string / empty model", function()
  local r1, e1 = vc.configsDef.handler({})
  assertNil(r1); assertMatch(e1, "'model' must be a non%-empty string")
  local r2, e2 = vc.configsDef.handler({ model = "" })
  assertNil(r2); assertMatch(e2, "'model' must be a non%-empty string")
  local r3, e3 = vc.configsDef.handler({ model = 7 })
  assertNil(r3); assertMatch(e3, "'model' must be a non%-empty string")
  local r4, e4 = vc.configsDef.handler(nil)
  assertNil(r4); assertMatch(e4, "'model' must be a non%-empty string")
end)

test("list_vehicle_configs: nil fetchConfigs -> catalog error (after model validated)", function()
  vc.fetchModels  = function() return MODELS end
  vc.fetchConfigs = function() return nil end
  local res, err = vc.configsDef.handler({ model = "pigeon" })
  assertNil(res)
  assertMatch(err, "failed to read vehicle catalog")
end)

test("register adds list_spawnable_models and list_vehicle_configs", function()
  local r = registry.new()
  vc.register(r)
  local names = {}
  for _, t in ipairs(r:list()) do names[t.name] = true end
  assertTrue(names["list_spawnable_models"])
  assertTrue(names["list_vehicle_configs"])
end)

test("list_vehicle_configs rejects a limit below 1 (not a 'Showing top 0' result)", function()
  local res, err = vc.configsDef.handler({ model = "pigeon", limit = 0 })
  assertNil(res)
  assertMatch(err, "'limit' must be >= 1")
end)
