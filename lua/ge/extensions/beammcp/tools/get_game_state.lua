-- get_game_state: a one-shot snapshot of session/lifecycle state for verification harnesses (menu/pause/
-- level/vehicle/resolution). The seven direct GE-sync reads live in a stubbable M.readState(); the handler
-- adds actual committed UI state and requested transition status. Menu fields use the engine router,
-- falling back to the legacy mission/hook data only when the router is unavailable. Synchronous.
local M = {}
local mp = require("beammcp/tools/lib/mp")
local ui = require("beammcp/tools/lib/ui_state")
local levels = require("beammcp/tools/levels")

-- read one engine accessor, degrading to nil if it errors/is absent (so one missing field can't sink the
-- whole snapshot).
local function tryGet(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

-- Engine-coupled (stubbed in tests, verified in-engine): the seven direct GE-sync reads.
function M.readState()
  return {
    uiState         = ui.read(),
    gameMode        = tryGet(function() return core_gamestate.state.state end),
    freeroamActive  = tryGet(function() return freeroam_freeroam.state.freeroamActive == true end),
    worldReadyState = worldReadyState,
    loading         = tryGet(function() return core_gamestate.loading() end),
    paused          = tryGet(function() return simTimeAuthority.getPause() end),
    simSpeed        = tryGet(function() return simTimeAuthority.get() end),
    level           = tryGet(function() return getCurrentLevelIdentifier() end),
    mission         = tryGet(function() return getMissionFilename() end),
    playerVehicleId = tryGet(function() return be:getPlayerVehicleID(0) end),
    resolution      = tryGet(function() return settings.getValue("GraphicDisplayResolutions") end),
    multiplayer     = tryGet(function() return mp.isActive(mp.probe()) end),
    timeOfDay       = tryGet(function()
      local tod = core_environment.getTimeOfDay()
      if type(tod) ~= "table" then return nil end
      return { time = tod.time, dayLength = tod.dayLength, dayScale = tod.dayScale }
    end),
  }
end

-- Injected by beammcp.lua to expose the hook-tracked menu flag (status:snapshot().menuOpen). nil until wired.
M.menuOpenSource = nil
-- Injected by beammcp.lua (reload/autoheal.lastCompact): the last automatic post-reload recovery, or nil.
M.lastReloadSource = nil

local function handler(_args)
  local s = M.readState()
  local state, request = ui.snapshot()
  s.uiState, s.uiTransition = state, request
  s.uiStateKnown = state ~= nil
  s.levelTransition = levels.transitionSnapshot()
  -- mainMenu describes the UI; mission emptiness remains a separate world fact.
  if state then s.mainMenu = state == "menu" or state == "menu.mainmenu"
  else s.mainMenu = (s.mission == "") end
  if state then s.menuOpen = state == "menu" or state:sub(1, 5) == "menu."
  else s.menuOpen = (M.menuOpenSource and M.menuOpenSource()) or false end
  local last = M.lastReloadSource and M.lastReloadSource() or nil
  if last ~= nil then s.lastReloadRecovery = last end
  return s
end

M.def = {
  description = "Snapshot of game/session state: paused, simSpeed, level, mission, playerVehicleId, "
    .. "resolution, multiplayer (active BeamMP session detected), timeOfDay, uiState (actual engine UI route), "
    .. "uiTransition, levelTransition (requested targets/status/errors), gameMode, freeroamActive, "
    .. "worldReadyState (2=initialized), loading, mainMenu, menuOpen, and "
    .. "lastReloadRecovery (what the automatic post-Lua-reload repair did, if a reload happened). "
    .. "Synchronous read; no arguments.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = handler,
}

function M.register(registry)
  registry:add("get_game_state", M.def)
end

return M
