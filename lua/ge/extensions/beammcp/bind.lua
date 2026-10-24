-- bind: pure policy for the server's listen address. Single source of truth for "what's a valid bind host"
-- (validate), "is this the loopback interface" (isLoopback), and the FAIL-CLOSED coupling to auth (resolve):
-- the RCE endpoint must never be reachable off-loopback without bearer auth, so a non-loopback bind requested
-- while auth is off is forced back to 127.0.0.1. Engine-agnostic + side-effect-free → fully unit-tested.
local M = {}

-- 127.0.0.0/8 is the loopback block. 0.0.0.0 (all interfaces) and LAN IPs are NOT loopback.
function M.isLoopback(host)
  return type(host) == "string" and host:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

-- validate(host) -> host on success, else (nil, message). Accepts a dotted-quad IPv4 (each octet 0-255),
-- which covers 0.0.0.0, 127.0.0.1 and any LAN address. IPv6 / hostnames are out of scope (the listener is
-- IPv4); a bad value never reaches socket.bind.
function M.validate(host)
  local err = "bind address must be an IPv4 address like 0.0.0.0 or 127.0.0.1"
  if type(host) ~= "string" then return nil, err end
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then return nil, err end
  for _, oct in ipairs({ a, b, c, d }) do
    local n = tonumber(oct)
    if n == nil or n > 255 then return nil, err end  -- %d+ already excludes negatives
  end
  return host
end

-- resolve(bindHost, authEnabled) -> (effectiveHost, downgraded). The fail-closed rule: a loopback bind is
-- always honored; a non-loopback bind is honored only when auth is enabled, otherwise it is downgraded to
-- loopback (downgraded=true so the caller can warn). Assumes bindHost is already validated.
function M.resolve(bindHost, authEnabled)
  if M.isLoopback(bindHost) or authEnabled == true then
    return bindHost, false
  end
  return "127.0.0.1", true
end

return M
