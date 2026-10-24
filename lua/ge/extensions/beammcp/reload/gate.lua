-- reload/gate: pure "is the world ready for repairs" gate, ticked once per frame after a reload. Repairs
-- must not run while the level is still loading or before the engine's own deserialization settled.
--   ready   - level loaded, not loading, >= MIN_FRAMES ticks, and a player vehicle (or VEHICLE_GRACE s passed)
--   timeout - TIMEOUT s elapsed without becoming ready (no repairs)
--   wait    - keep ticking
local M = {}

M.MIN_FRAMES = 10
M.VEHICLE_GRACE = 3   -- seconds
M.TIMEOUT = 10        -- seconds

function M.new()
  local g = { frames = 0, elapsed = 0 }
  function g:tick(dt, probe)
    self.frames = self.frames + 1
    self.elapsed = self.elapsed + (tonumber(dt) or 0)
    if self.elapsed >= M.TIMEOUT then return "timeout" end
    if self.frames < M.MIN_FRAMES then return "wait" end
    if probe.mission == "" or probe.loading then return "wait" end
    if not probe.hasVehicle and self.elapsed < M.VEHICLE_GRACE then return "wait" end
    return "ready"
  end
  return g
end

return M
