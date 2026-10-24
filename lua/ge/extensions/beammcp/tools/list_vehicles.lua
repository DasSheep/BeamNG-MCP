-- list_vehicles: enumerate spawned vehicles (GE-synchronous, read-only).
local M = {}

local function handler(_args)
  local playerId = nil
  local pv = be:getPlayerVehicle(0)
  if pv then playerId = pv:getId() end

  local vehicles = {}
  local count = be:getObjectCount()
  for i = 0, count - 1 do
    local v = be:getObject(i)
    if v then
      local p = v:getPosition()
      local vid = v:getId()
      vehicles[#vehicles + 1] = {
        id = vid,
        model = v:getJBeamFilename(),
        isPlayer = (vid == playerId),
        pos = { x = p.x, y = p.y, z = p.z },
      }
    end
  end
  return { count = #vehicles, vehicles = vehicles }
end

M.def = {
  description = "List spawned vehicles: id, model, isPlayer, position.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = handler,
}

function M.register(registry)
  registry:add("list_vehicles", M.def)
end

return M
