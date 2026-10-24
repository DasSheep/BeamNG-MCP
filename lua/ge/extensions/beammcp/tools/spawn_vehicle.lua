-- spawn_vehicle: spawn a model (optionally with a part-config). replace=true (default) swaps the active
-- vehicle in place via replaceVehicle; replace=false adds a new vehicle via spawnNewVehicle (which
-- auto-enters it). config is a .pc name (string) OR an inline config table {parts={...}, vars={...}} (the
-- engine serializes a table). Both spawn paths are synchronous: the vehicle is ready on return. The engine
-- call lives in M.spawn (stubbed in tests, verified in-engine); the handler is pure.
local M = {}
local config_arg = require("beammcp/tools/lib/config_arg")

-- Pure validators for placement vectors (plain {x,y,z[,w]} number tables from JSON).
local function isVec3(t)
  return type(t) == "table" and type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number"
end
local function isQuat(t)
  return isVec3(t) and type(t.w) == "number"
end

-- Pure: validate pos/rot/speed and enforce the replace gate. Returns (placement, err) where placement is
-- { pos?, rot?, speed? } (or nil when none given). pos/rot/speed only take effect on the add-new path, so
-- supplying any of them with replace=true is an error (the replace path keeps the existing position).
function M.parsePlacement(args, replace)
  local hasPlacement = args.pos ~= nil or args.rot ~= nil or args.speed ~= nil
  if not hasPlacement then return nil, nil end
  if replace then
    return nil, "spawn_vehicle: pos/rot/speed placement requires replace=false "
      .. "(the replace path keeps the existing vehicle's position)"
  end
  if args.pos ~= nil and not isVec3(args.pos) then
    return nil, "spawn_vehicle: 'pos' must be { x, y, z } numbers"
  end
  if args.rot ~= nil and type(args.rot) ~= "number" and not isQuat(args.rot) then
    return nil, "spawn_vehicle: 'rot' must be a heading number (degrees) or a quaternion { x, y, z, w }"
  end
  if args.speed ~= nil and type(args.speed) ~= "number" and not isVec3(args.speed) then
    return nil, "spawn_vehicle: 'speed' must be a number (m/s along heading) or a vector { x, y, z }"
  end
  return { pos = args.pos, rot = args.rot, speed = args.speed }, nil
end

-- Pure: validate `focus` and enforce the focus gate. Returns (focus, err). `focus` controls whether the
-- newly added vehicle is entered (camera + control move to it). It applies only to the add-new path, so
-- supplying it with replace=true is a misuse (the replace path keeps the player's current vehicle). Check
-- order: omitted -> ok; replace gate (any value) -> error; non-boolean -> error.
function M.parseFocus(args, replace)
  if args.focus == nil then return nil, nil end
  if replace then
    return nil, "spawn_vehicle: focus applies only when replace=false "
      .. "(the replace path keeps your current vehicle and camera)"
  end
  if type(args.focus) ~= "boolean" then
    return nil, "spawn_vehicle: 'focus' must be a boolean"
  end
  return args.focus, nil
end

-- Engine-coupled (stubbed in tests, verified in-engine). Fire the spawn; return the new vehicle id or nil.
-- pcall: an unknown model makes the engine throw inside prepareConfigData; convert that to a nil result so
-- the handler returns a clean "failed to spawn" message instead of leaking the raw engine error.
function M.spawn(model, config, replace, pos, rot, focus)
  local opt = {}
  if config ~= nil then opt.config = config end
  if pos ~= nil then opt.pos = vec3(pos.x, pos.y, pos.z) end
  if rot ~= nil then
    if type(rot) == "number" then
      opt.rot = quatFromEuler(0, 0, math.rad(rot))   -- heading degrees about the up (Z) axis
    else
      opt.rot = quat(rot.x, rot.y, rot.z, rot.w)
    end
  end
  -- background spawn: don't enter the new vehicle. Self-defending — scoped to the add-new path so M.spawn is
  -- correct independent of the handler's focus gate (replace keeps the player's own vehicle regardless).
  if not replace and focus == false then opt.autoEnterVehicle = false end
  local fn = replace and core_vehicles.replaceVehicle or core_vehicles.spawnNewVehicle
  local ok, veh = pcall(fn, model, opt)
  if not ok then return nil end
  return veh and veh:getID() or nil
end

-- Pure: resolve a speed spec into a world velocity vector (m/s). A number scales the heading direction;
-- a {x,y,z} table is the explicit vector (dir is unused then).
function M.resolveVelocity(speed, dir)
  if type(speed) == "number" then
    return dir.x * speed, dir.y * speed, dir.z * speed
  end
  return speed.x, speed.y, speed.z
end

-- Engine-coupled (stubbed in tests, verified in-engine). Impart a velocity to a freshly-spawned vehicle.
-- For a scalar speed we read the vehicle's forward heading; applyClusterVelocityScaleAdd(refNode, scale, dx,dy,dz)
-- sets v = v_existing*scale + delta; scale=1 -> additive.
-- Both spawn paths are synchronous, so the vehicle is settled (getDirectionVector valid) here.
function M.applyVelocity(veh, speed)
  local dir = type(speed) == "number" and veh:getDirectionVector() or nil
  local vx, vy, vz = M.resolveVelocity(speed, dir)
  veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1, vx, vy, vz)
end

local function handler(args)
  if type(args) ~= "table" or type(args.model) ~= "string" then
    return nil, "spawn_vehicle: 'model' must be a string"
  end
  local config, ok, cerr = config_arg.normalize(args.config, "spawn_vehicle")
  if not ok then return nil, cerr end
  local replace = args.replace ~= false   -- default true; only an explicit false adds a new vehicle
  local placement, perr = M.parsePlacement(args, replace)
  if perr then return nil, perr end
  local focus, ferr = M.parseFocus(args, replace)
  if ferr then return nil, ferr end
  local vid = M.spawn(args.model, config, replace, placement and placement.pos, placement and placement.rot, focus)
  if not vid then
    return nil, "spawn_vehicle: failed to spawn model '" .. args.model .. "' (unknown model or config?)"
  end
  if placement and placement.speed ~= nil then
    local veh = be:getObjectByID(vid)
    if veh then M.applyVelocity(veh, placement.speed) end
  end
  local out = { vehicleId = vid, model = args.model, config = config_arg.summarize(config) }
  if placement then
    out.placement = { pos = placement.pos, rot = placement.rot, speed = placement.speed }
  end
  if not replace then out.focused = (focus ~= false) end  -- honest: was the new vehicle entered?
  return out
end

M.def = {
  description = "Spawn a vehicle by model. config is a .pc name (string) OR an inline config table "
    .. "{ parts = {slot=part}, vars = {...} } (build one from get_vehicle_parts). replace=true (default) "
    .. "swaps the active vehicle in place; replace=false adds a new vehicle (see focus for background "
    .. "spawns). Returns the new vehicle id.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      model = { type = "string", description = "jbeam model name, e.g. 'pigeon', 'us_semi'" },
      config = {
        type = { "string", "object" },
        description = "part-config: a .pc name (string) or an inline { parts, vars } table",
      },
      replace = { type = "boolean", description = "replace the active vehicle (default true) vs add new" },
      pos = {
        type = "object",
        description = "world position { x, y, z }; requires replace=false",
      },
      rot = {
        type = { "number", "object" },
        description = "heading in degrees (number) or quaternion { x, y, z, w }; requires replace=false",
      },
      speed = {
        type = { "number", "object" },
        description = "m/s along heading (number) or world velocity vector { x, y, z }; requires replace=false",
      },
      focus = {
        type = "boolean",
        description = "enter the new vehicle (default true; camera+control move to it). focus=false spawns "
          .. "it in the background, leaving the camera/control on your current car. Requires replace=false; "
          .. "no-op when there are no existing vehicles.",
      },
    },
    required = { "model" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("spawn_vehicle", M.def)
end

return M
