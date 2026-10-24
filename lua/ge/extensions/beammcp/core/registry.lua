-- E: tool registry. Protocol-agnostic: holds tool defs, lists descriptors, invokes by name.
local M = {}

function M.new()
  local self = { tools = {}, order = {} }

  function self:add(name, def)
    assert(type(name) == "string", "tool name must be a string")
    assert(type(def) == "table" and type(def.handler) == "function", "def.handler must be a function")
    if self.tools[name] == nil then
      self.order[#self.order + 1] = name
    end
    self.tools[name] = def
  end

  -- Returns read-only descriptors. `inputSchema` is shared by reference with the stored def
  -- (no deep copy) — callers MUST NOT mutate it. `description`/`inputSchema` are optional and are
  -- omitted from the JSON object when nil.
  function self:list()
    local out = {}
    for _, name in ipairs(self.order) do
      local d = self.tools[name]
      out[#out + 1] = {
        name = name,
        description = d.description,
        inputSchema = d.inputSchema,
        annotations = d.annotations,
      }
    end
    return out
  end

  -- On unknown tool returns `nil, msg, 'not_found'`; on a tool/handler error returns `nil, msg`;
  -- on success returns `result`.
  function self:invoke(name, args)
    local d = self.tools[name]
    if not d then return nil, "unknown tool: " .. tostring(name), "not_found" end
    local ok, a, b = pcall(d.handler, args)
    if not ok then
      return nil, "tool error: " .. tostring(a)
    end
    return a, b
  end

  return self
end

return M
