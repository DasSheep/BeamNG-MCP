-- guard camera: camera recovery after a Lua reload, refined against an in-engine total-failure repro.
--  * registry empty + vehicle data present -> core_camera.onVehicleSpawned (camera data only)
--  * registry empty + vehicle data LOST (total blob failure) -> the vehicle is NEVER reloaded/reset
--    (that would reset its damage). Instead un-strand the engine's fallback freecam (it lands
--    at the world origin) next to the car and report a mitigation asking for Ctrl+R.
--  * a global camera is overridden ONLY when the snapshot proves none was active before the reload
--    (engine fallback); a freecam the player chose is kept. Mode preference: snapshot -> current -> orbit.
local env = require("beammcp/reload/env")
local M = { name = "camera" }

M.STRANDED_DIST = 50   -- metres: a freecam further than this from the car is considered stranded
M.MITIGATION = "vehicle cameras need a vehicle reload - press Ctrl+R (resets damage)"
M.FREE_CAMS = { free = true, smoothFree = true }   -- global cameras that setPosition/setRotation actually move

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.cam() return rawget(_G, "core_camera") end
function M.playerVehicle() return be:getPlayerVehicle(0) end
function M.vehicleData(id) return core_vehicle_manager.getVehicleData(id) end
function M.distanceToVehicle(v) return (M.cam().getPosition() - v:getPosition()):length() end
function M.moveFreecamNear(v)
  local vp = v:getPosition()
  local dir = v:getDirectionVector()
  dir.z = 0
  if dir:length() < 1e-3 then dir = vec3(0, 1, 0) end
  dir = dir:normalized()
  local up = vec3(0, 0, 1)
  local cp = vp - dir * 8 + up * 3                       -- 8 m behind, 3 m up (verified live)
  local rot = quatFromDir((vp - cp):normalized(), up)
  -- setPosRot is a no-op unless the active camera is exactly "free" (commands.isFreeCamera()); the
  -- engine's total-failure fallback is "smoothFree", which needs setPosition/setRotation instead
  -- (verified in-engine: setPosRot left the camera ~490 m away, setPosition/setRotation moved it
  -- next to the car).
  M.cam().setPosition(0, cp)
  M.cam().setRotation(0, rot)
end

local function isEmpty(t) return type(t) ~= "table" or next(t) == nil end

-- the engine's fallback: a global camera is active but the snapshot proves none was before the reload
-- (camMode ~= nil is evidence the snapshot camera read actually succeeded; a swallowed pcall failure
-- also leaves camGlobal nil and must not be mistaken for "no global camera was active").
local function isFallback(global, ctx)
  local snap = ctx and ctx.snap
  return global ~= nil and type(snap) == "table" and snap.camGlobal == nil and snap.camMode ~= nil
end

function M.check(ctx)
  if env.mission() == "" then return { skip = "no level loaded" } end
  local cam = M.cam()
  if not cam then return { skip = "core_camera unavailable" } end
  local global = cam.getActiveGlobalCameraName()
  local v = M.playerVehicle()
  if not v then
    if global then return nil end
    return { issue = "no vehicle and no global camera active" }
  end
  local data = cam.getCameraDataById(v:getID())
  if isEmpty(data) then return { issue = "vehicle camera registry empty" } end
  if global then
    if isFallback(global, ctx) then
      return { issue = "engine fell back to global camera '" .. tostring(global) .. "'" }
    end
    return nil
  end
  local mode = cam.getActiveCamName(0)
  if not (mode and data[mode]) then return { issue = "no active vehicle camera mode" } end
  return nil
end

local function pickMode(data, snap, current)
  local wanted = snap and snap.camMode
  if wanted and data[wanted] then return wanted end
  if current and data[current] then return current end
  if data.orbit then return "orbit" end
  return nil
end

function M.repair(ctx)
  local cam = M.cam()
  local global = cam.getActiveGlobalCameraName()
  local v = M.playerVehicle()
  if not v then
    if not global then cam.setByName("free", false) end
    return
  end
  local id = v:getID()
  local data = cam.getCameraDataById(id)
  if isEmpty(data) then
    local vd = M.vehicleData(id)
    if vd and vd.vdata then
      cam.onVehicleSpawned(id)
      data = cam.getCameraDataById(id)
    end
  end
  if isEmpty(data) then
    if global and M.FREE_CAMS[global] and M.distanceToVehicle(v) > M.STRANDED_DIST then M.moveFreecamNear(v) end
    return { mitigated = M.MITIGATION }
  end
  if global and not isFallback(global, ctx) then return end
  local current = (not global) and cam.getActiveCamName(0) or nil
  local mode = pickMode(data, ctx and ctx.snap, current)
  if mode and (global or mode ~= current) then cam.setByName(0, mode, false) end
end

-- followUp: the engine only falls back to a freecam ~1 s AFTER the heal (our levelflag repair re-opens the
-- camera-update gate). Called each frame by autoheal for a short window after a `mitigated` outcome.
-- Returns true when done (freecam now near the car), false to keep waiting for the fallback to appear.
function M.followUp(_ctx)
  local cam = M.cam()
  local global = cam and cam.getActiveGlobalCameraName()
  if not (global and M.FREE_CAMS[global]) then return false end
  local v = M.playerVehicle()
  if v and M.distanceToVehicle(v) > M.STRANDED_DIST then M.moveFreecamNear(v) end
  return true
end

return M
