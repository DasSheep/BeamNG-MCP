-- vehicle_catalog: read-only vehicle catalog discovery (GE-synchronous).
--   list_spawnable_models()      -> every spawnable model (identity)
--   list_vehicle_configs(model)  -> a model's factory .pc configs (identity + perf summary)
-- A config object IS the raw info.json, so perf is read from flat top-level fields
-- (Power / Weight / "Top Speed" / Drivetrain), NOT the processed `aggregates` (filter form).
-- list_spawnable_models is compact by default (token-reduction): key/name/type rows + a
-- per-type breakdown; type=/brand= filters narrow it; detail=true adds default_pc/brand/country.
local shape = require("beammcp/tools/lib/shape")

local M = {}

-- ---- pure curation -----------------------------------------------------------------------
function M.curateModel(m)
  return {
    key        = m.key,
    name       = m.Name,
    type       = m.Type,
    default_pc = m.default_pc,
    brand      = m.Brand,
    country    = m.Country,
  }
end

-- Compact identity for the default view: just key/name/type.
function M.curateModelCompact(m)
  return { key = m.key, name = m.Name, type = m.Type }
end

-- Filter raw model-info rows by exact Type and/or Brand match. nil filter = no constraint; nil-safe
-- (a model without a Brand never matches a brand filter). Pure.
function M.filterModels(models, typeFilter, brandFilter)
  local out = {}
  for _, m in ipairs(models) do
    if (typeFilter == nil or m.Type == typeFilter)
      and (brandFilter == nil or m.Brand == brandFilter) then
      out[#out + 1] = m
    end
  end
  return out
end

-- Flatten a config's perf summary from its flat info.json fields; omit any absent field.
function M.flattenPerf(c)
  local perf = {}
  if c.Power        ~= nil then perf.power      = c.Power end
  if c.Weight       ~= nil then perf.weight     = c.Weight end
  if c["Top Speed"] ~= nil then perf.topSpeed   = c["Top Speed"] end
  if c.Drivetrain   ~= nil then perf.drivetrain = c.Drivetrain end
  return perf
end

function M.curateConfig(c)
  return {
    key           = c.key,
    name          = c.Name,
    configuration = c.Configuration,
    is_default    = c.is_default_config == true,
    perf          = M.flattenPerf(c),
  }
end

-- Compact identity for the default view: key/name/is_default (drops configuration + the perf sub-table).
function M.curateConfigCompact(c)
  return { key = c.key, name = c.Name, is_default = c.is_default_config == true }
end

function M.modelKeySet(models)
  local set = {}
  for _, m in ipairs(models) do
    if m.key ~= nil then set[m.key] = true end
  end
  return set
end

-- ---- engine seam (stubbed in tests, verified in-engine) ----------------------------------
-- Flat array of model-info tables (getModelList's array=true form), or nil on failure.
function M.fetchModels()
  if not (core_vehicles and core_vehicles.getModelList) then return nil end
  local ok, res = pcall(core_vehicles.getModelList, true)
  if not ok or type(res) ~= "table" or type(res.models) ~= "table" then return nil end
  return res.models
end

-- Flat array of config tables across ALL models (getConfigList's array=true form), or nil on failure.
function M.fetchConfigs()
  if not (core_vehicles and core_vehicles.getConfigList) then return nil end
  local ok, res = pcall(core_vehicles.getConfigList, true)
  if not ok or type(res) ~= "table" or type(res.configs) ~= "table" then return nil end
  return res.configs
end

local function byKey(a, b) return tostring(a.key) < tostring(b.key) end

-- ---- handlers ----------------------------------------------------------------------------
local function modelsHandler(args)
  args = type(args) == "table" and args or {}
  if args.type ~= nil and type(args.type) ~= "string" then
    return nil, "list_spawnable_models: 'type' must be a string"
  end
  if args.brand ~= nil and type(args.brand) ~= "string" then
    return nil, "list_spawnable_models: 'brand' must be a string"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "list_spawnable_models: 'detail' must be a boolean"
  end
  local models = M.fetchModels()
  if type(models) ~= "table" then
    return nil, "list_spawnable_models: failed to read vehicle catalog"
  end

  -- types breakdown is ALWAYS over the FULL catalog (the "map" of what's filterable).
  local types = shape.breakdown(models, function(m) return m.Type end)

  local detail = args.detail == true
  local isFiltered = (args.type ~= nil) or (args.brand ~= nil)
  local filtered = M.filterModels(models, args.type, args.brand)

  local out = {}
  for _, m in ipairs(filtered) do
    out[#out + 1] = detail and M.curateModel(m) or M.curateModelCompact(m)
  end
  table.sort(out, byKey)

  local res = { count = #out, types = types, models = out }
  if isFiltered then res.total = #models end
  return res
end

M.modelsDef = {
  description = "List spawnable vehicle models. DEFAULT (compact): per-model {key,name,type} plus a `types` " ..
                "breakdown (counts per type across the whole catalog). Filter with type= and/or brand= (exact " ..
                "match; adds `total` = full count). detail=true adds {default_pc,brand,country}. The model " ..
                "catalog — not currently-spawned vehicles (see list_vehicles).",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      type   = { type = "string",  description = "filter to this exact model Type (e.g. 'Car'); see the `types` breakdown" },
      brand  = { type = "string",  description = "filter to this exact Brand (only branded vehicles have one)" },
      detail = { type = "boolean", description = "include default_pc/brand/country per model instead of the compact view" },
    },
  },
  handler = modelsHandler,
}

local DEFAULT_CONFIG_LIMIT = 50  -- compact default cap; bounds pathological models (e.g. simple_traffic, 222)

local function configsHandler(args)
  args = type(args) == "table" and args or {}
  local model = args.model
  if type(model) ~= "string" or model == "" then
    return nil, "list_vehicle_configs: 'model' must be a non-empty string"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "list_vehicle_configs: 'detail' must be a boolean"
  end
  if args.limit ~= nil and type(args.limit) ~= "number" then
    return nil, "list_vehicle_configs: 'limit' must be a number"
  end
  if args.limit ~= nil and args.limit < 1 then
    return nil, "list_vehicle_configs: 'limit' must be >= 1"
  end
  local models = M.fetchModels()
  if type(models) ~= "table" then
    return nil, "list_vehicle_configs: failed to read vehicle catalog"
  end
  if not M.modelKeySet(models)[model] then
    return nil, "list_vehicle_configs: unknown model '" .. model .. "' (use list_spawnable_models)"
  end
  local configs = M.fetchConfigs()
  if type(configs) ~= "table" then
    return nil, "list_vehicle_configs: failed to read vehicle catalog"
  end
  local detail = args.detail == true
  local out = {}
  for _, c in ipairs(configs) do
    if c.model_key == model then
      out[#out + 1] = detail and M.curateConfig(c) or M.curateConfigCompact(c)
    end
  end
  table.sort(out, byKey) -- deterministic top-N when capped

  local limit = args.limit or DEFAULT_CONFIG_LIMIT
  local capped, total = shape.capList(out, limit)
  local res = { count = #capped, model = model, configs = capped }
  if total > #capped then
    res.total = total
    res.note = (shape.capNote(#capped, total, "configs"):gsub("^%s+", "")) .. " Pass limit= for more."
  end
  return res
end

M.configsDef = {
  description = "List a model's factory .pc configs. DEFAULT (compact): key/name/is_default, capped at " ..
                "50 (adds `total` + a note; raise/lower with limit=). detail=true adds configuration + a perf " ..
                "summary {power, weight, topSpeed, drivetrain}. Pass a 'model' key from list_spawnable_models.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      model  = { type = "string",  description = "model key, e.g. 'pigeon' (from list_spawnable_models)" },
      limit  = { type = "number",  description = "max configs to return (default 50); capped list reports `total`" },
      detail = { type = "boolean", description = "include configuration + perf per config instead of the compact view" },
    },
    required = { "model" },
  },
  handler = configsHandler,
}

function M.register(registry)
  registry:add("list_spawnable_models", M.modelsDef)
  registry:add("list_vehicle_configs", M.configsDef)
end

return M
