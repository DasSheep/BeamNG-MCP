-- C: JSON-RPC 2.0 envelope. Transport-agnostic. Uses BeamNG globals jsonEncode/jsonDecode.
local M = {}

local PARSE_ERROR      = -32700
local INVALID_REQUEST  = -32600
local METHOD_NOT_FOUND  = -32601
local INVALID_PARAMS   = -32602
local INTERNAL_ERROR   = -32603

M.codes = {
  PARSE_ERROR = PARSE_ERROR, INVALID_REQUEST = INVALID_REQUEST,
  METHOD_NOT_FOUND = METHOD_NOT_FOUND, INVALID_PARAMS = INVALID_PARAMS,
  INTERNAL_ERROR = INTERNAL_ERROR,
}

-- Known deviation: when the id can't be determined (parse error / invalid request) we pass
-- id=nil, so the encoder omits the `id` key rather than emitting `"id": null` as JSON-RPC 2.0 §5.1
-- prefers. Lua can't hold a null-valued table key, and neither BeamNG's nor the test encoder maps a
-- sentinel to null inside an object without extra machinery. This only affects responses to
-- malformed input (real MCP requests always carry an id, which we echo). Revisit in-engine if a
-- client rejects it. See docs/architecture.md (known limitations).
local function errorResponse(id, code, message)
  return jsonEncode({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

local function resultResponse(id, result)
  return jsonEncode({ jsonrpc = "2.0", id = id, result = result })
end

function M.new()
  local self = { handlers = {} }

  function self:register(method, fn)
    self.handlers[method] = fn
  end

  function self:handle(jsonString)
    local msg = jsonDecode(jsonString)
    if type(msg) ~= "table" then
      return errorResponse(nil, PARSE_ERROR, "Parse error")
    end

    -- The decoder can represent both [] and {} as an empty Lua table. Check the
    -- parsed input's opening token so unsupported batches never become notifications.
    if jsonString:match("^%s*%[") then
      return errorResponse(nil, INVALID_REQUEST, "Invalid Request: batches are not supported")
    end

    local id = msg.id
    local isNotification = (msg.id == nil)

    if type(msg.method) ~= "string" then
      if isNotification then return nil end
      return errorResponse(id, INVALID_REQUEST, "Invalid Request")
    end

    local fn = self.handlers[msg.method]
    if not fn then
      if isNotification then return nil end
      return errorResponse(id, METHOD_NOT_FOUND, "Method not found: " .. msg.method)
    end

    local ok, result, errTable = pcall(fn, msg.params)
    if isNotification then return nil end
    if not ok then
      return errorResponse(id, INTERNAL_ERROR, "Internal error: " .. tostring(result))
    end
    if result == nil and errTable ~= nil then
      return errorResponse(id, errTable.code or INTERNAL_ERROR, errTable.message or "error")
    end
    return resultResponse(id, result)
  end

  return self
end

return M
