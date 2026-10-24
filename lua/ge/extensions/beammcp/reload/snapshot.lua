-- reload/snapshot: the pre-reload "known good" record, written to its OWN file in onSerialize so it
-- survives even when the engine's persistence blob fails to import. Deliberately small: never per-vehicle
-- or per-object data (that is exactly what bloats the engine blob). All engine/IO calls are stubbable.
local M = {}
local env = require("beammcp/reload/env")

M.PATH = "settings/beammcp_reload_snapshot.json"
M.VERSION = 1

local function try(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

-- Engine/IO seams (stubbed in tests, verified in-engine).
function M.now() return os.time() end
function M.newId() return string.format("%x-%x", os.time(), math.random(0, 0x7fffffff)) end
function M.writeFile(path, data) return jsonWriteFile(path, data, false) end
function M.readFile(path) return jsonReadFile(path) end
function M.exists(path) return FS:fileExists(path) end
function M.removeFile(path) return FS:removeFile(path) end

function M.readEngine()
  return {
    level       = env.mission(),
    levelLoaded = try(function() return rawget(_G, "levelLoaded") end),
    gamestate   = try(function()
      local st = core_gamestate.state
      if type(st) ~= "table" then return nil end
      return { state = st.state, appLayout = st.appLayout, menuItems = st.menuItems, options = st.options }
    end),
    camGlobal   = try(function() return core_camera.getActiveGlobalCameraName() end),
    camMode     = try(function() return core_camera.getActiveCamName(0) end),
    playerVid   = try(function() return be:getPlayerVehicleID(0) end),
    ui          = try(function() return { cef = ui_visibility.getCef(), imgui = ui_visibility.getImgui() } end),
    tod         = try(function()
      local t = core_environment.getTimeOfDay()
      return t and { time = t.time, play = t.play } or nil
    end),
    extensions  = try(function()
      local names = extensions.getLoadedExtensionsNames(true)   -- excludeVirtual
      local out = {}
      for _, n in ipairs(names or {}) do
        if not (type(n) == "string" and n:find("_virtual_", 1, true)) then out[#out + 1] = n end
      end
      return out
    end),
  }
end

function M.capture()
  local s = M.readEngine()
  s.v = M.VERSION
  s.reloadId = M.newId()
  s.at = M.now()
  return s
end

function M.write(snap)
  local ok, res = pcall(M.writeFile, M.PATH, snap)
  if not ok then return false, tostring(res) end
  if res == false then return false, "write failed" end
  return true
end

function M.read()
  local okE, exists = pcall(M.exists, M.PATH)
  if not okE or not exists then return nil end
  local ok, v = pcall(M.readFile, M.PATH)
  if not ok or type(v) ~= "table" or v.v ~= M.VERSION or type(v.reloadId) ~= "string" then return nil end
  return v
end

function M.delete()
  pcall(M.removeFile, M.PATH)
end

return M
