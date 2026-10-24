-- authtoken: pure helpers for the bearer-auth gate. generate() mints a token from engine entropy
-- (Engine.generateUUID, injected so off-engine tests stub it); equal() is a constant-time, length-safe
-- compare used by the gate so a bad token can't be distinguished by timing. No engine coupling beyond the
-- injected uuidFn — keeps http/mcp.lua pure and unit-testable.
local M = {}
local bit = require("bit")

-- Length-safe equality with no value-dependent early exit: folds the length difference into the
-- accumulator and scans the longer string fully, so a first-mismatch BYTE POSITION never leaks via timing
-- (the usual token-compare oracle). NOTE: the iteration count is max(#a,#b), so compare time still scales
-- with the longer string — this leaks LENGTH to a same-process observer. That is acceptable for a local MCP
-- gate (the threat model is not a remote/in-process timing oracle); it is not a full constant-time compare.
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  local la, lb = #a, #b
  local diff = bit.bxor(la, lb)
  local n = la > lb and la or lb
  for i = 1, n do
    local ca = i <= la and a:byte(i) or 0
    local cb = i <= lb and b:byte(i) or 0
    diff = bit.bor(diff, bit.bxor(ca, cb))
  end
  return diff == 0
end

-- Mint a token: two UUIDs, dashes stripped, concatenated (~64 hex-ish chars). uuidFn defaults to the GE
-- global Engine.generateUUID; tests pass a stub. The () around gsub take only its first return value.
function M.generate(uuidFn)
  uuidFn = uuidFn or Engine.generateUUID
  local a = (tostring(uuidFn()):gsub("%-", ""))
  local b = (tostring(uuidFn()):gsub("%-", ""))
  return a .. b
end

return M
