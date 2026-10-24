-- await(isReady, opts): block until isReady() is truthy or a timeout elapses, sleeping between checks.
-- Engine-agnostic on purpose: opts.sleep and opts.now are injected (the engine passes copas.sleep and
-- a wall clock; tests pass fakes), so this unit has no copas/engine dependency and is fully unit-testable.
-- In-engine, copas.sleep yields the request coroutine so onUpdate's copas.step(0) keeps the frame alive.
local M = {}

-- Returns true if isReady() became truthy before the timeout, false otherwise.
function M.await(isReady, opts)
  opts = opts or {}
  local sleep = opts.sleep or error("await: opts.sleep is required")
  local now = opts.now or os.time
  local timeoutSec = opts.timeoutSec or 5
  local pollSec = opts.pollSec or 0.03
  local deadline = now() + timeoutSec
  while not isReady() do
    local remaining=deadline-now()
    if remaining<=0 then return false end
    sleep(math.min(pollSec,remaining))
  end
  return true
end

return M
