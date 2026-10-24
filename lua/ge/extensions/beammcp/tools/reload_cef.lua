-- reload_cef: hot-reload the CEF (web UI) layer by firing the GE global reloadUI(). Fire-and-return —
-- reloadUI() is async (the UI rebuilds over the next moments) with no clean readiness signal, so the tool
-- returns immediately; callers wait briefly then screenshot/inspect. The engine call lives in a stubbable
-- M.reloadUI field, so the handler is unit-testable.
local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.reloadUI() reloadUI() end

local function handler(_args)
  M.reloadUI()
  return { reloaded = true }
end

M.def = {
  description = "Hot-reload the CEF web UI layer (fires reloadUI). Fire-and-return; the UI rebuilds "
    .. "asynchronously, so wait briefly before inspecting. Returns { reloaded = true }. No arguments.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = handler,
}

function M.register(registry)
  registry:add("reload_cef", M.def)
end

return M
