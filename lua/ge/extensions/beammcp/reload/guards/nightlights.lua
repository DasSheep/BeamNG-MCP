-- guard nightlights: core_environment.onSerialize persists only groundWind, so every reload resets its
-- module-local `nightLights` registry to initialized=false and applynightLightsState returns early until the
-- next level start (street lights stop switching). Verified in-engine. The registry is only reachable
-- as an upvalue of core_environment's functions; the repair is the engine's own refresh.
local env = require("beammcp/reload/env")
local M = { name = "nightlights" }

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.readRegistry()
  local envm = rawget(_G, "core_environment")
  if type(envm) ~= "table" then return nil end
  for _, fn in pairs(envm) do
    if type(fn) == "function" then
      local i = 1
      while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == "nightLights" and type(v) == "table" then return v end
        i = i + 1
      end
    end
  end
  return nil
end

function M.refresh() core_environment.refreshnightLightsObjects() end

function M.check(_ctx)
  if env.mission() == "" then return { skip = "no level loaded" } end
  local reg = M.readRegistry()
  if not reg then return { skip = "night-lights registry not found" } end
  if reg.initialized ~= true then
    return { issue = "night-lights registry not initialized (lights will not switch)" }
  end
  return nil
end

function M.repair(_ctx) M.refresh() end

return M
