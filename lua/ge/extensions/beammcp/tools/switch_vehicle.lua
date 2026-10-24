-- switch_vehicle: make a spawned vehicle the active (player) vehicle. be:enterVehicle takes effect
-- synchronously (getPlayerVehicleID reflects it immediately), so the tool sets it and returns. The engine
-- call lives in M.switchTo (stubbed in tests, verified in-engine); the handler is pure.
local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine). Enter the vehicle; return true if it is now the
-- player vehicle.
function M.switchTo(id)
  be:enterVehicle(0, be:getObjectByID(id))
  return be:getPlayerVehicleID(0) == id
end

local function handler(args)
  if type(args) ~= "table" or type(args.id) ~= "number" then
    return nil, "switch_vehicle: 'id' must be a number"
  end
  local veh = be:getObjectByID(args.id)
  if not veh then return nil, "switch_vehicle: no vehicle with id " .. args.id end
  if not M.switchTo(args.id) then
    return nil, "switch_vehicle: failed to switch to vehicle " .. args.id
  end
  return { vehicleId = args.id, model = veh:getJBeamFilename() }
end

M.def = {
  description = "Make a spawned vehicle the active (player) vehicle. Returns the vehicle id and model.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (from list_vehicles)" },
    },
    required = { "id" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("switch_vehicle", M.def)
end

return M
