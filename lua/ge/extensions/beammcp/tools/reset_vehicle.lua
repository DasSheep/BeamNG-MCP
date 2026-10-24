-- reset_vehicle: reset a vehicle (default: active). mode='spawn' (default) resets to the spawn point
-- (Ctrl+R, veh:reset()); mode='recover' rights it in place via the VE recovery module. Both settle
-- near-immediately (onVehicleResetted ~0.03s), so this is fire-and-return — no await. The engine call is
-- isolated in M.doReset (stubbed in tests, verified in-engine); the handler is pure.
local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.doReset(veh, mode)
  if mode == "recover" then
    veh:queueLuaCommand("recovery.recoverInPlace()")   -- VE-side: right the vehicle at its position
  else
    veh:reset()                                        -- reset to spawn point
  end
end

local function handler(args)
  args = (type(args) == "table") and args or {}
  local mode = args.mode or "spawn"
  if mode ~= "spawn" and mode ~= "recover" then
    return nil, "reset_vehicle: 'mode' must be 'spawn' or 'recover'"
  end
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "reset_vehicle: 'id' must be a number"
  end
  local id = args.id or be:getPlayerVehicleID(0)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "reset_vehicle: no vehicle with id " .. tostring(id) end
  M.doReset(veh, mode)
  return { vehicleId = id, mode = mode }
end

M.def = {
  description = "Reset a vehicle (default: active). mode='spawn' (default) resets to the spawn point "
    .. "(Ctrl+R); mode='recover' rights it in place.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (default: player)" },
      mode = { type = "string", enum = { "spawn", "recover" }, default = "spawn",
               description = "'spawn' (reset to spawn point) or 'recover' (right in place)" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("reset_vehicle", M.def)
end

return M
