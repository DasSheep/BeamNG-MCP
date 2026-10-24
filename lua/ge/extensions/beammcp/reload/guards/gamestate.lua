-- guard gamestate: an empty core_gamestate.state in a loaded level means the CEF UI got no app layout (the
-- "blank HUD" symptom). A normal reload preserves it (the framework persists M.state for modules defining
-- onDeserialized), so this fires on a TOTAL blob failure. setGameState broadcasts GameStateUpdate itself.
local env = require("beammcp/reload/env")
local M = { name = "gamestate" }

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.gs() return rawget(_G, "core_gamestate") end

function M.check(_ctx)
  if env.mission() == "" then return { skip = "no level loaded" } end
  local gs = M.gs()
  if not gs then return { skip = "core_gamestate unavailable" } end
  local st = type(gs.state) == "table" and gs.state.state or nil
  if st == nil or st == "" then return { issue = "game state is empty (HUD has no layout)" } end
  return nil
end

function M.repair(ctx)
  local gs = M.gs()
  local s = ctx and ctx.snap and ctx.snap.gamestate
  if type(s) == "table" and type(s.state) == "string" and s.state ~= "" then
    gs.setGameState(s.state, s.appLayout, s.menuItems, s.options)
  else
    gs.setGameState("freeroam", "freeroam", "freeroam")
  end
end

return M
