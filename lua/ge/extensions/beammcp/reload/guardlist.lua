-- reload/guardlist: the canonical guard order. levelflag must precede camera (camera updates are gated on
-- levelLoaded). list(set) returns guard modules, optionally filtered by a {name=true} set.
local M = {}

M.ORDER = { "levelflag", "camera", "gamestate", "nightlights", "ui_visibility", "extensions" }

function M.list(names)
  local out = {}
  for _, n in ipairs(M.ORDER) do
    if names == nil or names[n] then out[#out + 1] = require("beammcp/reload/guards/" .. n) end
  end
  return out
end

function M.known(name)
  for _, n in ipairs(M.ORDER) do if n == name then return true end end
  return false
end

return M
