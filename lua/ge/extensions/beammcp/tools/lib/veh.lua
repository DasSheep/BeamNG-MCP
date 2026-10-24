-- veh: shared vehicle-id resolution for tool handlers. One canonical check for the optional args.id
-- (must be a number when present) + player-vehicle fallback, so no handler passes an unvalidated id
-- into be:getObjectByID — a C++ binding that throws an unshaped engine error on a string/table id.
local M = {}

-- resolveId(args, label) -> id | nil, err. args may be nil / not a table (treated as "no id").
function M.resolveId(args, label)
  local id = type(args) == "table" and args.id or nil
  if id ~= nil and type(id) ~= "number" then
    return nil, label .. ": 'id' must be a number"
  end
  return id or be:getPlayerVehicleID(0)
end

return M
