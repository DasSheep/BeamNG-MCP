-- Sets the BeamNG globals the core relies on, for off-engine tests.
local json = require("json")

_G.jsonEncode = function(v) return json.encode(v) end
_G.jsonDecode = function(s)
  local ok, res = pcall(json.decode, s)   -- rxi json.decode errors on invalid input
  if not ok then return nil end
  return res
end
_G.log = function() end                    -- no-op; BeamNG's log(level, tag, msg)

return true
