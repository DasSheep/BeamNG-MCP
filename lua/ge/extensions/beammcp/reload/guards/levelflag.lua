-- guard levelflag: the global `levelLoaded` gates camera updates (core/cameraUpdate.lua:255). It is only
-- restored by importPersistentData, so a failed blob import leaves it nil and the camera frozen. Runs FIRST:
-- the camera guard depends on it.
local env = require("beammcp/reload/env")
local M = { name = "levelflag" }

function M.check(_ctx)
  if env.mission() == "" then return { skip = "no level loaded" } end
  if rawget(_G, "levelLoaded") == nil then
    return { issue = "levelLoaded is nil (camera updates are gated off)" }
  end
  return nil
end

function M.repair(ctx)
  local v = ctx and ctx.snap and ctx.snap.levelLoaded
  if type(v) ~= "string" or v == "" then v = env.levelDir(env.mission()) end
  if v then rawset(_G, "levelLoaded", v) end
end

return M
