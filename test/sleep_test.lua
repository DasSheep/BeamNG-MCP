-- async/sleep wraps copas.sleep with the socket.http drop/restore shim. Off-engine we inject a fake
-- copas (and a fake preloaded socket.http) via package.loaded to exercise the wiring without real copas.
test("sleep forwards the duration to copas.sleep and restores socket.http afterward", function()
  local sentinel = {}                                   -- stands in for BeamNG's preloaded socket.http
  package.loaded["socket.http"] = sentinel
  local got
  package.loaded["libs/copas/copas"] = { sleep = function(t) got = t end }
  package.loaded["beammcp/async/sleep"] = nil           -- force a fresh require
  local sleep = require("beammcp/async/sleep")
  sleep(0.05)
  assertEqual(got, 0.05)
  assertEqual(package.loaded["socket.http"], sentinel)  -- shim restored it
  -- cleanup so later test files see a clean slate
  package.loaded["libs/copas/copas"] = nil
  package.loaded["socket.http"] = nil
  package.loaded["beammcp/async/sleep"] = nil
end)
