-- instructions: builds the MCP `initialize.instructions` directive (server->LLM usage guidance). Pure. The
-- content depends on whether operator sim-time control is enabled: enabled -> teach the slow/pause-then-
-- restore pattern (so the agent can act in a real-time manner despite roundtrip latency) with a hard
-- never-in-multiplayer warning; disabled -> just state the sim runs in real time and control is off. A
-- second axis (authEnabled) appends a note that every request must carry an Authorization: Bearer header.
local M = {}

function M.build(simControlEnabled, authEnabled)
  local base = "This MCP server runs inside a live BeamNG.drive game engine; the simulation advances in "
    .. "real time, so the world keeps moving between your tool calls. Most list/telemetry tools are compact "
    .. "by default; pass detail=true (or full=true) to expand, and narrow with filters (type=) or scope args "
    .. "(device=, part=, key=) — escalate to full output only when needed. "
    .. "Discover Lua APIs with inspect_lua: narrow path/filter/kind first, detail=true for signatures; "
    .. "get_lua_source reads one function. Follow nextOffset only as needed; scanTruncated requires a narrower path. "
    .. "Use read_lua for selected fields and observe_lua for bounded waits/summaries. Eval, logs and observation "
    .. "default to 4096 result bytes; increase maxBytes only when needed. Reuse console_logs cursors and "
    .. "groupDuplicates to avoid repeated output. runtime_info reports loaded-code origins and VM availability. "
    .. "Use load_level for Free Roam entry; it also requests the gameplay UI route play after world "
    .. "readiness/fadeout. Poll get_game_state.levelTransition.status until ready or failed; matching the "
    .. "level alone is insufficient. uiState is the committed route; uiTransition reports set_ui_state "
    .. "requests. Main Menu during loading is transitional, not a reason to restart the load. "
    .. "After a Lua reload the server automatically repairs engine state the reload lost (camera, HUD game "
    .. "state, night lights, UI layers; vanished extensions are reported, and reloaded only after a total "
    .. "persistence-blob failure); get_game_state.lastReloadRecovery shows what happened, and "
    .. "recover_game_state re-checks (dry-run) or repairs (apply=true) camera, HUD game state, "
    .. "night lights and levelLoaded on demand, e.g. when the camera or HUD looks wrong."
  local s
  if simControlEnabled then
    s = base .. " When you need tight timing, use set_sim_speed: lower 'factor' (e.g. 0.05) to watch a "
      .. "fast transient in slow motion, or 'pause=true' to freeze physics so you can queue several actions "
      .. "and verify results with no sim-time passing, then resume with 'pause=false' and restore speed with "
      .. "'factor=1.0' (always undo your changes). NEVER "
      .. "change sim time during a BeamMP/multiplayer session - it desyncs the server, and set_sim_speed "
      .. "will refuse if it detects one."
  else
    s = base .. " Operator sim-time control is disabled, so the simulation cannot be slowed or paused."
  end
  if authEnabled then
    s = s .. " Authentication is enabled: every request must carry an 'Authorization: Bearer <token>' "
      .. "header (the operator configures this in the MCP client)."
  end
  return s
end

return M
