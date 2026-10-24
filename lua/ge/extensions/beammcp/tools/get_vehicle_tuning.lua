-- get_vehicle_tuning: read a SPAWNED vehicle's tuning variables (the adjustable knobs) for AI car tuning,
-- token-controlled. GE-synchronous read of core_vehicle_manager.getVehicleData(id).vdata.variables (each var:
-- name/category/subCategory/unit/min/max/default/val(current)/title/description/stepDis; hidden ones are
-- UI-scratch and excluded). Compact by default; ranges available on demand.
--   default          -> the current tune grouped by category {Cat={name=val,...}} (no ranges; cheap overview)
--   category=<Cat>   -> that category's knobs WITH ranges [{name,val,min,max,default,unit?,subCategory?}]
--   name=<substr>    -> knobs whose name matches (case-insensitive substring), same actionable shape
--   detail=true      -> adds title/description/step to the actionable (category/name) rows
-- Workflow: browse the snapshot -> pull a category for ranges -> adjust within [min,max] -> apply via
-- set_config's inline {vars}. The engine also clamps values to [min,max] at load (a safety net).
local shape = require("beammcp/tools/lib/shape")

local M = {}

-- include a var in the agent-facing output? (skip UI-hidden runtime scratch vars)
local function visible(v) return type(v) == "table" and v.hidden ~= true end

local ciContains = shape.ciContains   -- the canonical case-insensitive substring predicate

-- ---- pure shapers ------------------------------------------------------------------------

-- Grouped current-tune snapshot: { count, categories = { <Category> = { <name> = <val> } } }. Pure.
function M.buildSnapshot(vars)
  local categories, count = {}, 0
  for name, v in pairs(vars or {}) do
    if visible(v) then
      count = count + 1
      local cat = v.category or "Other"
      categories[cat] = categories[cat] or {}
      categories[cat][name] = v.val
    end
  end
  return { count = count, categories = categories }
end

-- Actionable rows (with ranges) filtered by opts.category (exact) and opts.name (ci substring); sorted by
-- name. detail adds title/description/step. Returns { count, vars = [rows] }. Pure.
function M.buildActionable(vars, opts)
  opts = opts or {}
  local rows = {}
  for name, v in pairs(vars or {}) do
    if visible(v)
      and (opts.category == nil or v.category == opts.category)
      and ciContains(name, opts.name) then
      local row = { name = name, val = v.val, min = v.min, max = v.max, default = v.default }
      if v.unit and v.unit ~= "" then row.unit = v.unit end
      if v.subCategory then row.subCategory = v.subCategory end
      if opts.detail then
        row.title = v.title
        row.description = v.description
        local step = v.stepDis or v.step
        if step then row.step = step end
      end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return { count = #rows, vars = rows }
end

-- Set of distinct categories among visible vars (for the unknown-category error). Pure.
function M.categorySet(vars)
  local set = {}
  for _, v in pairs(vars or {}) do
    if visible(v) and v.category then set[v.category] = true end
  end
  return set
end

-- ---- engine seam (stubbed in tests, verified in-engine) ----------------------------------
-- Returns { model, variables } for the vehicle id, or nil + clean error.
function M.fetch(id)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "get_vehicle_tuning: unknown vehicle id " .. tostring(id) end
  local vData = core_vehicle_manager.getVehicleData(id)
  local vd = vData and vData.vdata
  if not vd then return nil, "get_vehicle_tuning: no vehicle data for id " .. tostring(id) end
  return { model = veh:getJBeamFilename(), variables = vd.variables or {} }
end

local function handler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "get_vehicle_tuning: arguments must be an object"
  end
  args = args or {}
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "get_vehicle_tuning: 'id' must be a number"
  end
  if args.category ~= nil and type(args.category) ~= "string" then
    return nil, "get_vehicle_tuning: 'category' must be a string"
  end
  if args.name ~= nil and type(args.name) ~= "string" then
    return nil, "get_vehicle_tuning: 'name' must be a string"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "get_vehicle_tuning: 'detail' must be a boolean"
  end

  -- An empty-string filter means "no filter" — normalize to nil so it falls through to the cheap snapshot
  -- instead of matching everything (which would dump the full actionable ranges, defeating the compact default).
  local category = (args.category ~= nil and args.category ~= "") and args.category or nil
  local name     = (args.name ~= nil and args.name ~= "") and args.name or nil

  local id = args.id or be:getPlayerVehicleID(0)
  local data, err = M.fetch(id)
  if not data then return nil, err end
  local vars = data.variables

  if category ~= nil or name ~= nil then
    local cats = M.categorySet(vars)
    if category ~= nil and not cats[category] then
      local list = {}
      for c in pairs(cats) do list[#list + 1] = c end
      table.sort(list)
      return nil, "get_vehicle_tuning: unknown category '" .. category
        .. "' (categories: " .. table.concat(list, ", ") .. ")"
    end
    local built = M.buildActionable(vars, { category = category, name = name, detail = args.detail == true })
    local res = { model = data.model, count = built.count, vars = built.vars }
    if category ~= nil then res.category = category end
    if name ~= nil then res.name = name end
    return res
  end

  local snap = M.buildSnapshot(vars)
  return { model = data.model, count = snap.count, categories = snap.categories }
end

M.def = {
  description = "Read a SPAWNED vehicle's tuning variables (the adjustable knobs). DEFAULT (compact): the "
    .. "current tune grouped by category {Category:{name:value}} (no ranges). category= / name= return knobs "
    .. "WITH ranges [{name,val,min,max,default,unit}] — read ranges before adjusting so you pick a valid "
    .. "value. Apply changes via set_config's inline {vars}; the engine clamps to [min,max]. Defaults to "
    .. "the player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id       = { type = "number",  description = "vehicle id (default: player)" },
      category = { type = "string",  description = "return this category's knobs with ranges (see the default snapshot's categories)" },
      name     = { type = "string",  description = "case-insensitive substring of the variable name (e.g. 'camber')" },
      detail   = { type = "boolean", description = "add title/description/step to the category/name rows" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_vehicle_tuning", M.def)
end

return M
