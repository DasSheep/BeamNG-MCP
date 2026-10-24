-- teleport_vehicle: move a LIVE vehicle (keeps id, part-config, accumulated damage) to an arbitrary world
-- position / heading / velocity. Default (exact=false) uses spawn.safeTeleport — ground-snaps to a non-colliding
-- spot near pos and lands at rest; exact=true uses raw veh:setPositionRotation (exact coords, preserves momentum).
-- speed sets an absolute velocity after placement (the 2j applyClusterVelocityScaleAdd mechanism, scale 0). repair
-- (safe path only) resets deformation. Synchronous, fire-and-return. The engine calls live in M.doTeleport /
-- M.applyVelocity / M.safeRot (stubbed in tests, verified in-engine); the handler and parsers are pure.
local M = {}

-- Pure validators for {x,y,z[,w]} number tables from JSON (copied from spawn_vehicle).
local function isVec3(t)
  return type(t) == "table" and type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number"
end
local function isQuat(t)
  return isVec3(t) and type(t.w) == "number"
end

-- Pure: validate the arg table and enforce the repair+exact gate. Returns (parsed, err) where parsed is
-- { id?, pos, rot?, speed?, exact, repair } (exact/repair default false; pos required).
function M.parseArgs(args)
  if type(args) ~= "table" then
    return nil, "teleport_vehicle: arguments must be an object"
  end
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "teleport_vehicle: 'id' must be a number"
  end
  if not isVec3(args.pos) then
    return nil, "teleport_vehicle: 'pos' must be { x, y, z } numbers"
  end
  if args.rot ~= nil and type(args.rot) ~= "number" and not isQuat(args.rot) then
    return nil, "teleport_vehicle: 'rot' must be a heading number (degrees) or a quaternion { x, y, z, w }"
  end
  if args.speed ~= nil and type(args.speed) ~= "number" and not isVec3(args.speed) then
    return nil, "teleport_vehicle: 'speed' must be a number (m/s along heading) or a vector { x, y, z }"
  end
  if args.exact ~= nil and type(args.exact) ~= "boolean" then
    return nil, "teleport_vehicle: 'exact' must be a boolean"
  end
  if args.repair ~= nil and type(args.repair) ~= "boolean" then
    return nil, "teleport_vehicle: 'repair' must be a boolean"
  end
  local exact = args.exact == true
  local repair = args.repair == true
  if repair and exact then
    return nil, "teleport_vehicle: repair applies only to safe teleport (exact=true preserves vehicle state)"
  end
  return { id = args.id, pos = args.pos, rot = args.rot, speed = args.speed, exact = exact, repair = repair }, nil
end

-- Pure: resolve a speed spec into a velocity vector (copied from spawn_vehicle). A number scales the heading
-- direction; a {x,y,z} table is the explicit vector (dir unused then).
function M.resolveVelocity(speed, dir)
  if type(speed) == "number" then
    return dir.x * speed, dir.y * speed, dir.z * speed
  end
  return speed.x, speed.y, speed.z
end

-- Engine-coupled (stubbed in tests, pinned in-engine). spawn.safeTeleport internally pre-multiplies
-- quat(0,0,1,0) * rot (a 180°-about-Z convention flip, spawn.lua:621). Pre-multiplying our desired rotation by
-- the same quaternion cancels it (quat(0,0,1,0)^2 == quat(0,0,0,-1), the same rotation as identity — the sign is
-- rotationally irrelevant), so the engine's flip composed with ours yields the requested facing — matching
-- spawn_vehicle's heading semantics on both paths.
function M.safeRot(q)
  return quat(0, 0, 1, 0) * q
end

-- Engine-coupled (stubbed in tests, verified in-engine). Place veh at pos with orientation rot (a heading number
-- in degrees, a {x,y,z,w} quat, or nil = keep current). exact=true -> raw setPositionRotation (exact coords,
-- preserves momentum); else spawn.safeTeleport (ground-snap, lands at rest, repair maps to its resetVehicle arg).
function M.doTeleport(veh, pos, rot, exact, repair)
  local posv = vec3(pos.x, pos.y, pos.z)
  local rotq
  if rot == nil then
    rotq = veh:getRotation()
  elseif type(rot) == "number" then
    rotq = quatFromEuler(0, 0, math.rad(rot))   -- heading degrees about the up (Z) axis
  else
    rotq = quat(rot.x, rot.y, rot.z, rot.w)
  end
  if exact then
    veh:setPositionRotation(posv.x, posv.y, posv.z, rotq.x, rotq.y, rotq.z, rotq.w)
  else
    -- safeTeleport(veh, pos, rot, checkOnlyStatics, visibilityPoint, removeTraffic, centeredPosition, resetVehicle)
    spawn.safeTeleport(veh, posv, M.safeRot(rotq), nil, nil, false, false, repair)
  end
end

-- Engine-coupled (stubbed in tests, verified in-engine). Set veh's absolute velocity after placement. A scalar
-- speed scales the vehicle's CURRENT forward heading (veh:getDirectionVector, read after the transform set — the
-- actual resulting facing, incl. any safeTeleport snap; the scalar+heading same-frame propagation is pinned
-- in-engine); a vector is applied directly. scale 0 = set-absolute, overriding any preserved momentum (the exact
-- path), so the result is exactly `speed` on both paths.
function M.applyVelocity(veh, speed)
  local dir = type(speed) == "number" and veh:getDirectionVector() or nil
  local vx, vy, vz = M.resolveVelocity(speed, dir)
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, vx, vy, vz)
end

local function handler(args)
  local p, err = M.parseArgs(args)
  if not p then return nil, err end
  local id = p.id or be:getPlayerVehicleID(0)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "teleport_vehicle: no vehicle with id " .. tostring(id) end
  M.doTeleport(veh, p.pos, p.rot, p.exact, p.repair)
  if p.speed ~= nil then M.applyVelocity(veh, p.speed) end
  local out = { vehicleId = id, pos = p.pos, exact = p.exact, repaired = p.repair }
  if p.rot ~= nil then out.rot = p.rot end
  if p.speed ~= nil then out.speed = p.speed end
  return out
end

M.def = {
  description = "Teleport a LIVE vehicle (keeps its id, part-config, and accumulated damage) to a world "
    .. "position/heading/velocity. Default ground-snaps to a non-colliding spot near pos and lands at rest "
    .. "(spawn.safeTeleport); exact=true places at the exact coords (setPositionRotation, preserves momentum). "
    .. "Defaults to the player vehicle. Note: applied velocity only shows in getVelocity after a physics step.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (default: player)" },
      pos = { type = "object", description = "world position { x, y, z } (required)" },
      rot = {
        type = { "number", "object" },
        description = "heading in degrees (number) or quaternion { x, y, z, w }; omitted keeps current orientation",
      },
      speed = {
        type = { "number", "object" },
        description = "absolute velocity: m/s along heading (number) or world vector { x, y, z }",
      },
      exact = {
        type = "boolean",
        description = "true = exact coords (setPositionRotation); false (default) = ground-snap (safeTeleport)",
      },
      repair = {
        type = "boolean",
        description = "true = also reset deformation (safe path only; errors when combined with exact=true)",
      },
    },
    required = { "pos" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("teleport_vehicle", M.def)
end

return M
