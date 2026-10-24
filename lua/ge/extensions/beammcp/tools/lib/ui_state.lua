-- UI route snapshots and requests use the engine router's committed state.
local M = {}
local request
local nextId = 0
local function router()
  return extensions and extensions.ui_router
end
local function readEntry()
  local r = router()
  if not (r and r.getCurrent) then return nil end
  local ok, entry = pcall(r.getCurrent)
  if ok and type(entry) == "table" and type(entry.request) == "table" then return entry end
end
function M.read()
  local entry = readEntry()
  return entry and entry.request.name
end
function M.snapshot(trackedRequest)
  local entry = readEntry()
  local state = entry and entry.request.name
  local req = trackedRequest or request
  if req and req.status == "pending" and entry == req.entry and state == req.requestedUiState then
    req.status = "ready"
  end
  return state, req and { requestId = req.id, requestedUiState = req.requestedUiState,
    status = req.status, error = req.error } or nil
end
function M.navigate(state)
  local r = router()
  if not (r and r.navigate) then return nil, "UI router unavailable" end
  local ok, result = pcall(r.navigate, state)
  if not ok then return nil, tostring(result) end
  if type(result) ~= "table" or result.success ~= true then
    return nil, "UI navigation rejected: " .. tostring(type(result) == "table" and result.reason or result)
  end
  if type(result.data) ~= "table" then return nil, "UI router returned no navigation identity" end
  if request and request.status == "pending" then
    request.status, request.error = "failed", "UI request superseded by another navigation request"
  end
  nextId = nextId + 1
  request = { id = nextId, entry = result.data, requestedUiState = state, status = "pending", elapsed = 0 }
  return true, nil, request
end
function M.update(dt)
  M.snapshot()
  if request and request.status == "pending" then
    request.elapsed = request.elapsed + (dt or 0)
    if request.elapsed >= 15 then
      request.status, request.error = "failed", "UI route was not confirmed within 15 seconds"
    end
  end
end
M.def = {
  description = "Request a UI route through the normal engine router (e.g. play or menu). Returns "
    .. "the actual uiState and requestedUiState separately; poll get_game_state.uiTransition.status "
    .. "until ready or failed. Does not load a level or initialize Free Roam.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {
    uiState = { type = "string", description = "Engine UI route name, e.g. play or menu" },
  }, required = { "uiState" } },
  handler = function(args)
    if type(args) ~= "table" or type(args.uiState) ~= "string" or args.uiState == "" then
      return nil, "set_ui_state: uiState must be a non-empty string"
    end
    local ok, err = M.navigate(args.uiState)
    if not ok then return nil, "set_ui_state: " .. err end
    local state, transition = M.snapshot()
    return { uiState = state, uiTransition = transition }
  end,
}
function M.register(registry)
  registry:add("set_ui_state", M.def)
end
return M
