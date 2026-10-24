-- set_config: apply a part-config to a vehicle (default: active), keeping its model. Rebuilds the vehicle
-- in place via replaceVehicle(currentModel, {config=...}, veh) — synchronous, vehicle ready on return.
-- `config` is a string (.pc name) OR an inline table {parts={...}, vars={...}} (the engine serializes a
-- table). The engine call is isolated in M.applyConfig (stubbed in tests, verified in-engine).
local M = {}
local config_arg = require("beammcp/tools/lib/config_arg")
local get_vehicle_config = require("beammcp/tools/get_vehicle_config")  -- reuse its partsTree flatten

-- Pure: shallow-overlay an inline patch onto the current config (patch keys win); never mutates `current`.
-- Returns { parts, vars } so a partial set_config preserves the installed build + untouched tuning vars.
function M.mergeConfig(current, patch)
  local parts = {}
  for k, v in pairs((current and current.parts) or {}) do parts[k] = v end
  if type(patch.parts) == "table" then for k, v in pairs(patch.parts) do parts[k] = v end end
  local vars = {}
  for k, v in pairs((current and current.vars) or {}) do vars[k] = v end
  if type(patch.vars) == "table" then for k, v in pairs(patch.vars) do vars[k] = v end end
  return { parts = parts, vars = vars }
end

-- Engine-coupled (stubbed in tests): the vehicle's CURRENT config as { parts = {slot:part}, vars = {...} },
-- or nil if unreadable. parts come from flattening config.partsTree (the get_vehicle_config .pc-equivalent,
-- a proven lossless replaceVehicle round-trip); vars are config.vars (all current variable values).
function M.currentConfig(veh)
  local ok, vData = pcall(function() return core_vehicle_manager.getVehicleData(veh:getID()) end)
  if not ok then return nil end
  local cfg = vData and vData.config
  if type(cfg) ~= "table" or type(cfg.partsTree) ~= "table" then return nil end
  return { parts = get_vehicle_config.flatten(cfg.partsTree), vars = cfg.vars or {} }
end

-- Engine-coupled (stubbed in tests, verified in-engine). Apply a config to `veh` in place (same model),
-- respawning in place via replaceVehicle (position preserved; velocity/damage reset). A STRING (.pc name) is
-- a full swap. An inline TABLE is a PATCH: it's merged onto the vehicle's current config (read here) so the
-- installed build + untouched vars survive — only the given parts/vars change. Returns the settled id or nil.
-- (If the current config can't be read, the patch is applied as-is — today's best-effort behavior.)
function M.applyConfig(veh, model, config)
  local effective = config
  if type(config) == "table" then
    local cur = M.currentConfig(veh)
    if cur then
      effective = M.mergeConfig(cur, config)
    elseif type(log) == "function" then
      -- rare: current config unreadable -> can't merge; the patch is applied as-is and the build may reset
      log("W", "set_config", "could not read current config to merge; applying the inline config as-is (build may reset)")
    end
  end
  local ok, v = pcall(core_vehicles.replaceVehicle, model, { config = effective }, veh)
  if not ok then return nil end
  return v and v:getID() or nil
end

local function handler(args)
  if type(args) ~= "table" then
    return nil, "set_config: 'config' must be a string or a table"
  end
  local config, ok, cerr = config_arg.normalize(args.config, "set_config")
  if not ok then return nil, cerr end
  if config == nil then return nil, "set_config: 'config' is required" end
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "set_config: 'id' must be a number"
  end
  local id = args.id or be:getPlayerVehicleID(0)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "set_config: no vehicle with id " .. tostring(id) end
  local model = veh:getJBeamFilename()
  local vid = M.applyConfig(veh, model, config)
  if not vid then
    local label = type(config) == "string" and ("'" .. config .. "'") or "the inline config"
    return nil, "set_config: failed to apply config " .. label .. " (unknown config?)"
  end
  return { vehicleId = vid, model = model, config = config_arg.summarize(config) }
end

M.def = {
  description = "Apply a part-config to a vehicle (default: active), keeping its model. config is a .pc "
    .. "name (string) = a full swap, OR an inline table { parts = {slot=part}, vars = {...} } = a PATCH that "
    .. "MERGES onto the vehicle's current config (installed build + untouched tuning vars are preserved; only "
    .. "the given parts/vars change — so set vars to tune, or swap one slot, without rebuilding the rest). "
    .. "A patch only adds/overrides (it can't REMOVE a part — pass a .pc name for a full swap). "
    .. "Respawns the vehicle in place (position kept; velocity/damage reset) and returns its id.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      config = {
        type = { "string", "object" },
        description = "part-config: a .pc name (string) or an inline { parts, vars } table",
      },
      id = { type = "number", description = "vehicle id (default: player)" },
    },
    required = { "config" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("set_config", M.def)
end

return M
