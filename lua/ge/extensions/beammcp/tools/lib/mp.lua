-- mp: best-effort BeamMP (multiplayer) session detection. probe() reads the BeamMP mod's GE presence and
-- active-session state (engine-coupled, stubbable); shouldRefuse/isActive are pure policy. Used to refuse
-- sim-time control during a synced session (a local sim-clock change would desync it) and to expose a
-- visibility flag in get_game_state. BeamMP is a third-party mod: all reads are rawget/pcall-guarded and
-- the exact symbols are confirmed in-engine (a recon miss -> modLoaded=false -> never a false refusal).
local M = {}

-- Engine-coupled (stubbed in tests, confirmed in-engine). Returns { modLoaded, sessionActive } where
-- sessionActive is true/false, or nil when the mod is present but its state can't be read.
function M.probe()
  local mpcn = rawget(_G, "MPCoreNetwork")
  local mpgn = rawget(_G, "MPGameNetwork")
  local modLoaded = (mpcn ~= nil) or (mpgn ~= nil)
  if not modLoaded then return { modLoaded = false, sessionActive = false } end
  local sessionActive = nil
  if mpcn ~= nil and type(mpcn.isMPSession) == "function" then
    local ok, v = pcall(mpcn.isMPSession)
    if ok then sessionActive = v and true or false end
  end
  return { modLoaded = true, sessionActive = sessionActive }
end

-- Pure: refuse sim-time control if a session is active OR (fail-safe) the mod is present but unreadable.
function M.shouldRefuse(probe)
  return probe.modLoaded and probe.sessionActive ~= false
end

-- Pure: definitive "in an active MP session" for visibility (does NOT report the unreadable case as active).
function M.isActive(probe)
  return probe.modLoaded and probe.sessionActive == true
end

return M
