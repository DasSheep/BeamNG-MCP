-- set_sim_speed: set the sim speed factor and/or pause physics, so an agent can act in a more real-time
-- manner despite roundtrip latency (slow 'factor' to observe a transient; 'pause' to freeze physics so
-- actions can be queued / verified with zero sim-time passing, then restore factor=1.0). GATED: opt-in
-- (operator enables it in the panel; default off) AND refused during an active BeamMP/multiplayer session
-- (a local sim-clock change desyncs a tickrate-synced session). Engine writes live in M.apply (stubbed in
-- tests, verified in-engine); the handler is pure given the injected gateEnabled + the mp lib.
local M = {}
local mp = require("beammcp/tools/lib/mp")

-- Engine-coupled (stubbed in tests, verified in-engine). Apply each provided field; return read-back state.
-- Pause setter is simTimeAuthority.pause(paused) (NOT setPause, which doesn't exist — confirmed in-engine);
-- get()/getPause() are the reads.
function M.apply(factor, pause)
  if factor ~= nil then simTimeAuthority.set(factor) end
  if pause ~= nil then simTimeAuthority.pause(pause) end
  return { simSpeed = simTimeAuthority.get(), paused = simTimeAuthority.getPause() }
end

local function isFiniteNumber(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Public for tests: handler(args, gateEnabled). gateEnabled is a function()->bool (the live store gate).
function M.handler(args, gateEnabled)
  if type(args) ~= "table" then
    return nil, "set_sim_speed: arguments must be an object"
  end
  if args.factor == nil and args.pause == nil then
    return nil, "set_sim_speed: provide 'factor' (number) and/or 'pause' (boolean)"
  end
  if args.factor ~= nil and (not isFiniteNumber(args.factor) or args.factor <= 0) then
    return nil, "set_sim_speed: 'factor' must be a positive number (1.0 = normal, e.g. 0.05 = slow)"
  end
  if args.pause ~= nil and type(args.pause) ~= "boolean" then
    return nil, "set_sim_speed: 'pause' must be a boolean"
  end
  if not gateEnabled() then
    return nil, "set_sim_speed: sim-time control is disabled (operator must enable it in the panel; "
      .. "never enable it during a BeamMP/multiplayer session - it desyncs)"
  end
  if mp.shouldRefuse(mp.probe()) then
    return nil, "set_sim_speed: refused - an active multiplayer (BeamMP) session is detected; "
      .. "changing sim time would desync it"
  end
  return M.apply(args.factor, args.pause)
end

local DESCRIPTION = "Set the simulation speed factor and/or pause physics. factor: 1.0 = normal/real-time, "
  .. "<1 = slow-mo (e.g. 0.05) to observe a transient; pause: true freezes physics so you can queue actions "
  .. "and verify with zero sim-time passing. Provide factor and/or pause; restore with factor=1.0, "
  .. "pause=false. Returns { simSpeed, paused }. OPT-IN (operator-enabled; disabled by default) and REFUSED "
  .. "during a BeamMP/multiplayer session - changing local sim time desyncs a synced server."

function M.register(registry, gateEnabled)
  gateEnabled = gateEnabled or function() return false end
  registry:add("set_sim_speed", {
    description = DESCRIPTION,
    annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
    inputSchema = {
      type = "object",
      properties = {
        factor = { type = "number", description = "sim speed multiplier (1.0 normal, e.g. 0.05 slow)" },
        pause  = { type = "boolean", description = "true = freeze physics, false = resume" },
      },
    },
    handler = function(args) return M.handler(args, gateEnabled) end,
  })
end

return M
