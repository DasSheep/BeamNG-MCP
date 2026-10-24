-- B: MCP Streamable-HTTP conformance (JSON-only). Bridges an HTTP request to the core seam
-- rpc:handle(jsonString). No sockets — unit-testable with a stub rpc.
local M = {}

-- IPv4 loopback only — matches the server's 127.0.0.1 bind. (No IPv6 entries: the listener never
-- serves ::1, so an IPv6 Origin can't legitimately reach us.)
local LOOPBACK = { ["127.0.0.1"] = true, ["localhost"] = true }

local function originAllowed(origin)
  if not origin then return true end                 -- no Origin: local non-browser client
  local host = origin:match("^%w+://([^:/]+)")       -- scheme://host[:port]
  return host ~= nil and LOOPBACK[host:lower()] == true  -- hosts are case-insensitive (RFC 3986)
end

local authtoken = require("beammcp/tools/lib/authtoken")

-- Host header is "host[:port]" (no scheme). nil/absent -> allowed (parity with absent Origin: the
-- DNS-rebind attacker is a browser, which always sends Host). A present non-loopback Host -> rejected.
local function hostAllowed(hostHeader)
  if not hostHeader then return true end
  local host = hostHeader:match("^([^:]+)")
  return host ~= nil and LOOPBACK[host:lower()] == true
end

-- "Authorization: Bearer <token>" -> <token>, else nil. Scheme match is case-insensitive; token case kept.
local function bearerToken(authHeader)
  if type(authHeader) ~= "string" then return nil end
  local scheme, tok = authHeader:match("^(%a+)%s+(.+)$")
  if scheme ~= nil and scheme:lower() == "bearer" then return tok end
  return nil
end

local function baseUrl(req)
  return "http://" .. (req.headers["host"] or "127.0.0.1:23512")
end

local function jsonResponse(body)
  return {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = jsonEncode(body),
  }
end

local function protectedResourceMetadata(req)
  local base = baseUrl(req)
  return jsonResponse({
    resource = base .. "/mcp",
    authorization_servers = { base },
  })
end

local function authorizationServerMetadata(req)
  local base = baseUrl(req)
  return jsonResponse({
    issuer = base,
    authorization_endpoint = base .. "/oauth/authorize",
    token_endpoint = base .. "/oauth/token",
    registration_endpoint = base .. "/oauth/register",
    response_types_supported = { "code" },
    grant_types_supported = { "authorization_code" },
    code_challenge_methods_supported = { "S256" },
    token_endpoint_auth_methods_supported = { "none" },
  })
end

function M.new(rpc, auth)
  local self = { rpc = rpc }
  self.auth = auth or { required = function() return false end, token = function() return nil end }

  -- precheck(req) -> resp | nil: the body-independent gate (routing + auth + Origin/Host). Returns
  -- the final response for any request decided by its head alone — metadata GETs and every
  -- rejection — so the HTTP layer can answer before buffering the body. nil = authorized POST /mcp.
  function self:precheck(req)
    if req.method == "GET"
      and (req.path == "/.well-known/oauth-protected-resource"
        or req.path == "/.well-known/oauth-protected-resource/mcp") then
      return protectedResourceMetadata(req)
    end
    if req.method == "GET" and req.path == "/.well-known/oauth-authorization-server" then
      return authorizationServerMetadata(req)
    end
    if req.path ~= "/mcp" then
      return { status = 404, headers = {}, body = "" }
    end
    if req.method ~= "POST" then
      return { status = 405, headers = { ["Allow"] = "POST" }, body = "" }
    end
    if self.auth.required() then
      local expected = self.auth.token()
      local provided = bearerToken(req.headers["authorization"])
      if type(expected) ~= "string" or expected == ""
         or provided == nil or not authtoken.equal(provided, expected) then
        return { status = 401, headers = { ["WWW-Authenticate"] = "Bearer" }, body = "" }
      end
    else
      if not originAllowed(req.headers["origin"]) then
        return { status = 403, headers = {}, body = "" }
      end
      if not hostAllowed(req.headers["host"]) then
        return { status = 403, headers = {}, body = "" }
      end
    end
    return nil
  end

  function self:respond(req)
    local early = self:precheck(req)
    if early then return early end
    local respBody = self.rpc:handle(req.body)
    if respBody == nil then
      return { status = 202, headers = {}, body = "" }
    end
    return { status = 200, headers = { ["Content-Type"] = "application/json" }, body = respBody }
  end

  return self
end

return M
