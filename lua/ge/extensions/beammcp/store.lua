-- store: persisted key-value over a single JSON document in the userfolder (settings/beammcp.json).
-- Holds the whole document in memory; set() writes the full doc back so other keys are preserved.
-- Engine-agnostic: file IO (jsonReadFile/jsonWriteFile) is injected as io.read/io.write, so off-engine
-- tests use in-memory fakes. Reusable for any future persisted setting (e.g. an editable port).
local M = {}

-- io = { path = "settings/beammcp.json", read = function(path)->table|any, write = function(path, tbl, pretty)->bool }
function M.new(io)
  local self = { io = io, data = {} }

  function self:load()
    local d = self.io.read(self.io.path)
    self.data = (type(d) == "table") and d or {}
    return self
  end

  function self:get(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return v
  end

  function self:set(key, value)
    self.data[key] = value
    return self.io.write(self.io.path, self.data, true)  -- pretty = true
  end

  return self
end

return M
