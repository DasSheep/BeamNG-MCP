-- get_vehicle_state: GE-synchronous kinematics + identity for the player (or given) vehicle.
-- Source: map.objects[id] (pos/vel/dirVec/damage) + be:getObjectByID (model). Read-only.
local M = {}

-- Heading in degrees from a direction vector: 0 = +Y, increasing clockwise, normalized [0,360).
function M._headingFromDirVec(d)
  local deg = math.deg(math.atan2(d.x, d.y))
  return (deg % 360 + 360) % 360
end

local function vlen(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

local function handler(args)
  args = args or {}
  local id = args.id
  if id ~= nil and type(id) ~= "number" then
    return nil, "get_vehicle_state: 'id' must be a number"
  end
  if id == nil then
    local pv = be:getPlayerVehicle(0)
    if not pv then return nil, "get_vehicle_state: no player vehicle" end
    id = pv:getId()
  end
  local o = map.objects[id]
  if not o then return nil, "get_vehicle_state: unknown vehicle id " .. tostring(id) end
  local veh = be:getObjectByID(id)
  local model = veh and veh:getJBeamFilename() or nil
  local vel = o.vel or { x = 0, y = 0, z = 0 }
  local speed = vlen(vel)
  return {
    id = id,
    model = model,
    -- pos/dirVec are always present on a live map.objects entry, but guard against a
    -- partially-initialized entry (spawn vs. first GE frame) so we never index nil.
    pos = o.pos and { x = o.pos.x, y = o.pos.y, z = o.pos.z } or nil,
    velocity = { x = vel.x, y = vel.y, z = vel.z },
    speed_ms = speed,
    speed_kmh = speed * 3.6,
    heading_deg = o.dirVec and M._headingFromDirVec(o.dirVec) or nil,
    damage = o.damage,
  }
end

M.def = {
  description = "GE-synchronous state of the player (or given id) vehicle: model, position, "
    .. "velocity, speed (m/s + km/h), heading, damage.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = { id = { type = "number", description = "vehicle id (default: player)" } },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_vehicle_state", M.def)
end

return M
