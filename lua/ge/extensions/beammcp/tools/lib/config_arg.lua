-- config_arg: pure helpers for the polymorphic `config` argument shared by spawn_vehicle and set_config.
-- A config may be a string (.pc name), a table (inline single-vehicle config {parts={...}, vars={...}}),
-- or nil (no config). normalize validates and passes the value straight through (the engine serializes a
-- table); summarize produces a compact echo for the tool return (a big inline table is not echoed verbatim).
local M = {}

-- normalize(config, label) -> (value, ok, err). ok distinguishes a valid nil from a rejection. `label` is
-- the calling tool name, used for the error prefix. No internal-shape validation (honest "spawn & report").
function M.normalize(config, label)
  local t = type(config)
  if config == nil or t == "string" or t == "table" then
    return config, true, nil
  end
  return nil, false, label .. ": 'config' must be a string or a table"
end

-- summarize(value) -> {inline=true, parts=<count>} for a table; otherwise the value unchanged (string/nil).
function M.summarize(value)
  if type(value) ~= "table" then return value end  -- string or nil
  local n = 0
  if type(value.parts) == "table" then
    for _ in pairs(value.parts) do n = n + 1 end
  end
  return { inline = true, parts = n }
end

return M
