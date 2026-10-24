-- sleep: copas.sleep via the socket.http shim. copas.lua errors at require time if socket.http is loaded
-- (BeamNG preloads it), so drop it, require copas (already cached by the server), restore it, then sleep.
-- copas.sleep yields the request coroutine so onUpdate's copas.step(0) keeps the frame alive. Returns
-- the function directly so callers pass it straight to await's opts.sleep. Engine-coupled (needs copas);
-- off-engine tests inject a fake copas via package.loaded.
local function sleep(t)
  local saved = package.loaded["socket.http"]; package.loaded["socket.http"] = nil
  local copas = require("libs/copas/copas"); package.loaded["socket.http"] = saved
  return copas.sleep(t)
end

return sleep
