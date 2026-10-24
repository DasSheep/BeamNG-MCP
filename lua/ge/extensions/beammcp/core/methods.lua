-- D: MCP method semantics. Registers methods into an rpc, backed by a registry.
local M = {}

local PROTOCOL_VERSION = "2025-06-18"
local INVALID_PARAMS   = -32602

local function shapeToolResult(text, isError)
  return { content = { { type = "text", text = text } }, isError = isError }
end

function M.register(rpc, registry, serverInfo, onActivity, instructions)
  serverInfo = serverInfo or { name = "beammcp", version = "0.1.0" }
  local record = onActivity or function() end

  -- Wrap each handler: fire one activity event per request (tool name for tools/call, else the method),
  -- then delegate. `return handler(params)` forwards BOTH return values (result, errTable) — do not
  -- collapse to a single local or tool errors are dropped.
  local function reg(method, handler)
    rpc:register(method, function(params)
      local label = method
      if method == "tools/call" and type(params) == "table" and type(params.name) == "string" then
        label = params.name
      end
      record(label)
      return handler(params)
    end)
  end

  reg("initialize", function(_params)
    local r = {
      protocolVersion = PROTOCOL_VERSION,
      capabilities = { tools = {} },
      serverInfo = serverInfo,
    }
    if instructions ~= nil then r.instructions = instructions end
    return r
  end)

  reg("notifications/initialized", function(_params)
    return nil
  end)

  reg("ping", function(_params)
    return {}
  end)

  reg("tools/list", function(_params)
    return { tools = registry:list() }
  end)

  reg("tools/call", function(params)
    if type(params) ~= "table" or type(params.name) ~= "string" then
      return nil, { code = INVALID_PARAMS, message = "Invalid params: 'name' is required" }
    end
    local result, err, kind = registry:invoke(params.name, params.arguments or {})
    if result == nil and err ~= nil then
      if kind == "not_found" then
        return nil, { code = INVALID_PARAMS, message = err }
      end
      return shapeToolResult(tostring(err), true)
    end
    -- A handler may return pre-formed MCP content blocks (e.g. an image) under __mcpContent; pass them
    -- through verbatim. Any other table is jsonEncode'd to a text block, exactly as before.
    if type(result) == "table" and result.__mcpContent ~= nil then
      return { content = result.__mcpContent, isError = false }
    end
    local text
    if type(result) == "table" then
      text = jsonEncode(result)
    else
      text = tostring(result)
    end
    return shapeToolResult(text, false)
  end)
end

return M
