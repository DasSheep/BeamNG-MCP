-- damage: read and induce vehicle damage state via the VE damageTracker. Both tools are curated VE evals
-- reusing vehicle_lua_eval.evalVE (the proven ve_bridge + await round-trip). get_damage_data extracts the
-- full damageData table (a module-local in damageTracker) via debug.getupvalue on damageTracker.getDamage —
-- the one place that hack is written. trigger_damage sets a flag via damageTracker.setDamage for telltale
-- testing. Engine coupling lives in stubbable M.fetch/M.apply; M.filterActive is pure. Registers two tools
-- (get/trigger are facets of one capability sharing the damageTracker VE module — the ui_visibility
-- precedent).
local vehicle_lua_eval = require("beammcp/tools/vehicle_lua_eval")
local veh = require("beammcp/tools/lib/veh")

local M = {}

-- VE chunk: find damageTracker's module-local damageData table (getDamage is a closure over it) and return
-- it. Matched by upvalue name (order-robust). Returns {} if absent / not yet populated.
local READ_CHUNK = [[
local dt = damageTracker
local data
if dt and dt.getDamage then
  for i = 1, 30 do
    local n, v = debug.getupvalue(dt.getDamage, i)
    if not n then break end
    if n == "damageData" then data = v; break end
  end
end
return data or {}
]]

-- Engine-coupled (stubbed in tests, verified in-engine): read the full damage table from the vehicle's VE.
function M.fetch(id)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "get_damage_data: unknown vehicle id " .. tostring(id) end
  local payload = vehicle_lua_eval.evalVE(veh, READ_CHUNK)
  if not payload then return nil, "get_damage_data: no response from vehicle VM" end
  if not payload.ok then return nil, "get_damage_data: " .. tostring(payload.err) end
  return payload.value or {}
end

-- Engine-coupled (stubbed in tests, verified in-engine): set one damage flag in the vehicle's VE.
function M.apply(id, group, name, value)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "trigger_damage: unknown vehicle id " .. tostring(id) end
  -- %q safely quotes the group/name strings; value is a validated boolean/number, so tostring yields a
  -- valid Lua literal ("true"/"false"/a number). notifyUI=false: set the flag + mark dirty (the DamageData
  -- guihook re-fires on the ~1/3s timer) without a message popup.
  local chunk = string.format("damageTracker.setDamage(%q, %q, %s, false) return true",
    group, name, tostring(value))
  local payload = vehicle_lua_eval.evalVE(veh, chunk)
  if not payload then return nil, "trigger_damage: no response from vehicle VM" end
  if not payload.ok then return nil, "trigger_damage: " .. tostring(payload.err) end
  return true
end

-- Pure: keep only live damage (drop false and 0), dropping any group left empty.
-- -> (filtered, keptEntries, totalEntries) so the handler can note how much it dropped.
function M.filterActive(damage)
  local out = {}
  local keptCount, totalCount = 0, 0
  for group, names in pairs(damage or {}) do
    local kept, any = {}, false
    for name, value in pairs(names) do
      totalCount = totalCount + 1
      if value ~= false and value ~= 0 then kept[name] = value; any = true; keptCount = keptCount + 1 end
    end
    if any then out[group] = kept end
  end
  return out, keptCount, totalCount
end

local function getHandler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "get_damage_data: arguments must be an object"
  end
  args = args or {}
  local id, iderr = veh.resolveId(args, "get_damage_data")
  if not id then return nil, iderr end
  local data, err = M.fetch(id)
  if not data then return nil, err end
  if args.full == true then return { damage = data } end
  local active, kept, total = M.filterActive(data)
  local res = { damage = active }
  if total > kept then
    res.note = string.format("Active damage only (%d of %d entries); pass full=true for every flag.",
      kept, total)
  end
  return res
end

local function triggerHandler(args)
  if type(args) ~= "table" then
    return nil, "trigger_damage: arguments must be an object"
  end
  if type(args.group) ~= "string" or args.group == "" then
    return nil, "trigger_damage: 'group' must be a non-empty string"
  end
  if type(args.name) ~= "string" or args.name == "" then
    return nil, "trigger_damage: 'name' must be a non-empty string"
  end
  if type(args.value) ~= "boolean" and type(args.value) ~= "number" then
    return nil, "trigger_damage: 'value' must be a boolean or number"
  end
  if type(args.value) == "number"
     and (args.value ~= args.value or args.value == math.huge or args.value == -math.huge) then
    return nil, "trigger_damage: 'value' must be a finite number (inf/nan are not Lua literals)"
  end
  local id, iderr = veh.resolveId(args, "trigger_damage")
  if not id then return nil, iderr end
  local ok, err = M.apply(id, args.group, args.name, args.value)
  if not ok then return nil, err end
  return { ok = true, group = args.group, name = args.name, value = args.value }
end

M.getDef = {
  description = "Read the vehicle's damage state (the damageTracker DamageData table — engine / wheels / "
    .. "transmission / etc. flags and scalars; the source dashboard/HUD damage warnings read). DEFAULT: only ACTIVE "
    .. "damage (set flags / nonzero scalars); full=true returns every entry incl. false/0. Defaults to "
    .. "the player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (default: player)" },
      full = { type = "boolean", description = "return the whole table, incl. inactive false/0 entries" },
    },
  },
  handler = getHandler,
}

M.triggerDef = {
  description = "Set one damage flag for telltale/warning testing (damageTracker.setDamage). value is a "
    .. "boolean (flags) or number (scalars). Flags only — does NOT deform the vehicle; for physical "
    .. "breakage use damage_vehicle. Defaults to the player vehicle.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      group = { type = "string", description = "damage group, e.g. 'engine'" },
      name = { type = "string", description = "damage key, e.g. 'headGasketDamaged'" },
      value = { type = { "boolean", "number" }, description = "boolean flag or numeric scalar to set" },
      id = { type = "number", description = "vehicle id (default: player)" },
    },
    required = { "group", "name", "value" },
  },
  handler = triggerHandler,
}

function M.register(registry)
  registry:add("get_damage_data", M.getDef)
  registry:add("trigger_damage", M.triggerDef)
end

return M
