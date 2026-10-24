-- levels: level discovery + switching (the "world/scenario staging" map layer).
--   list_levels()       -> read-only curated catalog of available maps (core_levels.getList)
--   load_level({level}) -> fire-and-return switch to a map (freeroam_freeroam.startFreeroamByName; the
--                          default vehicle is pre-spawned at the default spawn). The load runs async behind a
--                          loading screen that stalls the MCP server's pump, so the handler fires and returns
--                          immediately; poll get_game_state.levelTransition.status for confirmed gameplay. Ungated, but REFUSED in a BeamMP
--                          session. Engine reads/writes live in M.fetchList / M.fire (stubbed in tests,
--                          verified in-engine); curators are pure.
local M = {}
local mp = require("beammcp/tools/lib/mp")
local ui = require("beammcp/tools/lib/ui_state")
local transition
function M.transitionSnapshot()
  return transition and { level = transition.level, requestedUiState = "play",
    status = transition.status, error = transition.error } or nil
end
function M.onLoadingScreenFadeout()
  if transition and transition.status == "loading" then transition.faded = true end
end
function M.update(dt)
  if not transition or transition.status == "ready" or transition.status == "failed" then return end
  transition.elapsed = transition.elapsed + (dt or 0)
  if transition.elapsed >= 120 then
    transition.status, transition.error = "failed", "Level/UI transition timed out after 120 seconds"
    return
  end
  local targetWorld = getCurrentLevelIdentifier() == transition.level
    and freeroam_freeroam and freeroam_freeroam.state
    and freeroam_freeroam.state.freeroamActive == true and worldReadyState == 2
    and core_gamestate and core_gamestate.loading() == false
  if not targetWorld then return end
  if transition.status == "loading" and transition.faded then
    local ok, err, req = ui.navigate("play")
    if not ok then transition.status, transition.error = "failed", err; return end
    transition.uiRequest, transition.status = req, "ui_pending"
  end
  if transition.status == "ui_pending" then
    local state, req = ui.snapshot(transition.uiRequest)
    if state == "play" and req and req.status == "ready" then transition.status = "ready"
    elseif req and req.status == "failed" then
      transition.status, transition.error = "failed", req.error
    end
  end
end

-- ---- pure curation -----------------------------------------------------------------------
-- Curate one core_levels.getList() entry to the agent-facing subset.
function M.curateLevel(l)
  local out = {
    levelName = l.levelName,
    title     = l.title or l.levelName,   -- engine only guarantees title when a level has no previews; fall back
    official  = l.official == true,
  }
  if l.size              ~= nil then out.size              = l.size end
  if l.biome             ~= nil then out.biome             = l.biome end
  if l.suitablefor       ~= nil then out.suitablefor       = l.suitablefor end
  if l.supportsTraffic   ~= nil then out.supportsTraffic   = l.supportsTraffic end
  if l.supportsTimeOfDay ~= nil then out.supportsTimeOfDay = l.supportsTimeOfDay end
  return out
end

-- Compact identity for the default view: levelName/title/official (drops the size/biome/suitablefor/traffic/
-- timeOfDay optionals, which detail=true restores via curateLevel).
function M.curateLevelCompact(l)
  return { levelName = l.levelName, title = l.title or l.levelName, official = l.official == true }
end

local function byLevelName(a, b) return tostring(a.levelName) < tostring(b.levelName) end

-- buildList(rawList, opts) -> { count, total?, levels=[curated...] } sorted by levelName.
-- opts.official (boolean) filters by official-status (adds `total` = full catalog count); opts.detail
-- chooses the full curateLevel vs the compact curateLevelCompact. Pure.
function M.buildList(rawList, opts)
  opts = opts or {}
  local detail = opts.detail == true
  local isFiltered = opts.official ~= nil
  local filtered = rawList
  if isFiltered then
    filtered = {}
    for _, l in ipairs(rawList) do
      if (l.official == true) == opts.official then filtered[#filtered + 1] = l end
    end
  end
  local out = {}
  for _, l in ipairs(filtered) do
    out[#out + 1] = detail and M.curateLevel(l) or M.curateLevelCompact(l)
  end
  table.sort(out, byLevelName)
  local res = { count = #out, levels = out }
  if isFiltered then res.total = #rawList end
  return res
end

function M.levelNameSet(rawList)
  local set = {}
  for _, l in ipairs(rawList) do
    if l.levelName ~= nil then set[l.levelName] = true end
  end
  return set
end

-- ---- engine seam (stubbed in tests, verified in-engine) ----------------------------------
-- Flat array of enriched level-info tables (core_levels.getList(), cached), or nil on failure.
function M.fetchList()
  if not (core_levels and core_levels.getList) then return nil end
  local ok, res = pcall(core_levels.getList)
  if not ok or type(res) ~= "table" then return nil end
  return res
end

-- ---- handlers ----------------------------------------------------------------------------
local function listHandler(args)
  args = type(args) == "table" and args or {}
  if args.official ~= nil and type(args.official) ~= "boolean" then
    return nil, "list_levels: 'official' must be a boolean"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "list_levels: 'detail' must be a boolean"
  end
  local raw = M.fetchList()
  if type(raw) ~= "table" then
    return nil, "list_levels: could not read the level catalog"
  end
  return M.buildList(raw, { detail = args.detail == true, official = args.official })
end

M.listDef = {
  description = "List the maps you can load. DEFAULT (compact): levelName (pass to load_level), title, "
    .. "official. official=true|false filters by official status (adds `total` = full count). detail=true "
    .. "adds (when present) size, biome, suitablefor, supportsTraffic, supportsTimeOfDay. The map catalog "
    .. "(not the vehicle catalog - see list_spawnable_models).",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      official = { type = "boolean", description = "filter to official (true) or non-official (false) maps" },
      detail   = { type = "boolean", description = "include size/biome/suitablefor/supportsTraffic/supportsTimeOfDay" },
    },
  },
  handler = listHandler,
}

-- Engine-coupled (stubbed in tests, verified in-engine). Fire the freeroam level switch (default freeroam:
-- the default vehicle is pre-spawned at the default spawn). startFreeroamByName returns a boolean (true if the
-- level exists in the engine). Rejection is returned; accepted loads complete on later frames.
function M.fire(level)
  return freeroam_freeroam.startFreeroamByName(level)
end

local LOAD_NOTE = "level load runs async behind a loading screen; the server is unresponsive during it. "
  .. "The tool navigates to play after fadeout/world readiness. Poll get_game_state.levelTransition.status "
  .. "until ready or failed; level matching alone is not completion. uiState is the actual committed route."

local function loadHandler(args)
  if type(args) ~= "table" then
    return nil, "load_level: arguments must be an object"
  end
  if type(args.level) ~= "string" or args.level == "" then
    return nil, "load_level: 'level' must be a non-empty string"
  end
  local raw = M.fetchList()
  if type(raw) ~= "table" then
    return nil, "load_level: could not read the level catalog"
  end
  if not M.levelNameSet(raw)[args.level] then
    return nil, "load_level: unknown level '" .. args.level .. "' (use list_levels)"
  end
  if mp.shouldRefuse(mp.probe()) then
    return nil, "load_level: refused - cannot switch levels during a BeamMP/multiplayer session"
  end
  transition = { level = args.level, status = "loading", elapsed = 0, faded = false }
  local ok, accepted = pcall(M.fire, args.level)
  if not ok or accepted == false then
    transition.status, transition.error = "failed", ok and "Free Roam start rejected" or tostring(accepted)
    return nil, "load_level: " .. transition.error
  end
  return { level = args.level, loading = true, requestedUiState = "play",
    uiState = ui.read(), levelTransition = M.transitionSnapshot(), note = LOAD_NOTE }
end

M.loadDef = {
  description = "Switch to a map by levelName (from list_levels); the default vehicle is pre-spawned at the "
    .. "default spawn (then use spawn_vehicle / teleport_vehicle to place exactly what you want). "
    .. "FIRE-AND-RETURN: returns { loading=true } immediately; the load runs async behind a loading screen "
    .. "during which the server is unresponsive. Automatically navigates to play after world readiness/fadeout; "
    .. "poll get_game_state.levelTransition.status until ready or failed (checks level, Free Roam, world, "
    .. "loading screen and actual UI route). Refused during a "
    .. "BeamMP/multiplayer session.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      level = { type = "string", description = "levelName from list_levels, e.g. 'gridmap_v2', 'west_coast_usa'" },
    },
    required = { "level" },
  },
  handler = loadHandler,
}

function M.register(registry)
  registry:add("list_levels", M.listDef)
  registry:add("load_level", M.loadDef)
end

return M
