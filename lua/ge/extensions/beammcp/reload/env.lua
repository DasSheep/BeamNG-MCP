-- reload/env: shared engine reads for the reload guards (stubbable seams). mission() is the current
-- mission file ("" in the main menu); loading() is the engine's level-loading flag; hasPlayerVehicle()
-- reports a player vehicle; levelDir() derives the `levelLoaded` value server.lua:332 sets
-- ("/levels/<name>/") from a mission path.
local M = {}

function M.mission()
  local ok, v = pcall(function() return getMissionFilename() end)
  if ok and type(v) == "string" then return v end
  return ""
end

function M.loading()
  local ok, v = pcall(function() return VariableRegistry.get("$loadingLevel") end)
  if not ok then return false end
  return v == true or v == 1 or v == "1" or v == "true"
end

function M.hasPlayerVehicle()
  local ok, v = pcall(function() return be:getPlayerVehicle(0) end)
  return ok and v ~= nil
end

function M.levelDir(mission)
  if type(mission) ~= "string" then return nil end
  local name = mission:match("^/?levels/([^/]+)/")
  return name and ("/levels/" .. name .. "/") or nil
end

return M
