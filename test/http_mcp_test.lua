local mcp = require("http.mcp")

-- stub rpc: returns a JSON string for a request, nil for a notification (body == "NOTIFY")
local function stubRpc()
  return { handle = function(self, body) if body == "NOTIFY" then return nil end return '{"jsonrpc":"2.0","id":1,"result":{}}' end }
end

local function req(t) t.headers = t.headers or {}; return t end

test("non-/mcp path returns 404", function()
  local h = mcp.new(stubRpc())
  assertEqual(h:respond(req({ method = "POST", path = "/other", body = "" })).status, 404)
end)

test("GET on /mcp returns 405 with Allow: POST", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "GET", path = "/mcp", body = "" }))
  assertEqual(r.status, 405)
  assertEqual(r.headers["Allow"], "POST")
end)

test("DELETE on /mcp returns 405", function()
  local h = mcp.new(stubRpc())
  assertEqual(h:respond(req({ method = "DELETE", path = "/mcp", body = "" })).status, 405)
end)

test("POST request returns 200 application/json with the rpc body", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
  assertEqual(r.headers["Content-Type"], "application/json")
  assertMatch(r.body, '"result"')
end)

test("POST notification returns 202 empty", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", body = "NOTIFY" }))
  assertEqual(r.status, 202)
  assertEqual(r.body, "")
end)

test("present non-loopback Origin is rejected with 403", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { origin = "http://evil.example.com" }, body = "{}" }))
  assertEqual(r.status, 403)
end)

test("loopback Origin is allowed", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { origin = "http://127.0.0.1:23512" }, body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("absent Origin is allowed (local non-browser client)", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("a host-prefix spoof like 127.0.0.1.evil.com is rejected (exact match, not prefix)", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { origin = "http://127.0.0.1.evil.com" }, body = "{}" }))
  assertEqual(r.status, 403)
end)

test("loopback Origin is matched case-insensitively", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { origin = "http://LOCALHOST:23512" }, body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("OAuth protected-resource metadata is exposed for tunnel-client readiness", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({
    method = "GET",
    path = "/.well-known/oauth-protected-resource/mcp",
    headers = { host = "127.0.0.1:23512" },
    body = "",
  }))
  assertEqual(r.status, 200)
  assertEqual(r.headers["Content-Type"], "application/json")
  assertMatch(r.body, '"resource":"http://127%.0%.0%.1:23512/mcp"')
  assertMatch(r.body, '"authorization_servers"')
end)

test("OAuth authorization-server metadata is exposed for tunnel-client readiness", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({
    method = "GET",
    path = "/.well-known/oauth-authorization-server",
    headers = { host = "127.0.0.1:23512" },
    body = "",
  }))
  assertEqual(r.status, 200)
  assertEqual(r.headers["Content-Type"], "application/json")
  assertMatch(r.body, '"issuer":"http://127%.0%.0%.1:23512"')
  assertMatch(r.body, '"authorization_endpoint"')
end)

-- a handler whose auth is ON with a fixed token
local function authHandler(token)
  return mcp.new(stubRpc(), {
    required = function() return true end,
    token    = function() return token end,
  })
end

-- auth OFF (default) Host checks ---------------------------------------------------------------------
test("auth off: present non-loopback Host is rejected with 403", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { host = "evil.example.com:23512" }, body = "{}" }))
  assertEqual(r.status, 403)
end)

test("auth off: loopback Host is allowed", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp", headers = { host = "127.0.0.1:23512" },
    body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("auth off: absent Host is allowed (lenient parity with absent Origin)", function()
  local h = mcp.new(stubRpc())
  local r = h:respond(req({ method = "POST", path = "/mcp",
    body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

-- auth ON bearer checks ------------------------------------------------------------------------------
test("auth on: valid bearer token -> 200", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "Bearer secret-token" },
    body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("auth on: missing token -> 401 with WWW-Authenticate", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp", body = "{}" }))
  assertEqual(r.status, 401)
  assertEqual(r.headers["WWW-Authenticate"], "Bearer")
end)

test("auth on: wrong token -> 401", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "Bearer nope" }, body = "{}" }))
  assertEqual(r.status, 401)
end)

test("auth on: raw token without Bearer scheme -> 401", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "secret-token" }, body = "{}" }))
  assertEqual(r.status, 401)
end)

test("auth on: double Bearer prefix -> 401", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "Bearer Bearer secret-token" }, body = "{}" }))
  assertEqual(r.status, 401)
end)

test("auth on: required but empty configured token -> fail-closed 401", function()
  local h = mcp.new(stubRpc(), { required = function() return true end, token = function() return "" end })
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "Bearer anything" }, body = "{}" }))
  assertEqual(r.status, 401)
end)

test("auth on: tunnel-style non-loopback Origin/Host + valid token -> 200 (loopback checks relaxed)", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { origin = "https://chatgpt.com", host = "tunnel.example.com", authorization = "Bearer secret-token" },
    body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

test("bearer scheme is case-insensitive", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp",
    headers = { authorization = "bearer secret-token" },
    body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' }))
  assertEqual(r.status, 200)
end)

-- precheck: the body-independent gate (routing + auth + Origin/Host), run by the HTTP layer BEFORE
-- the request body is buffered. Returns the final response for any head-decided request; nil means
-- "authorized POST /mcp - read the body and call respond".
test("precheck: auth on + missing token -> 401 without touching the rpc", function()
  local h = mcp.new({ handle = function() error("rpc must not run at precheck time") end },
    { required = function() return true end, token = function() return "secret-token" end })
  local r = h:precheck(req({ method = "POST", path = "/mcp" }))
  assertEqual(r.status, 401)
  assertEqual(r.headers["WWW-Authenticate"], "Bearer")
end)

test("precheck: authorized POST /mcp -> nil (proceed to body)", function()
  local h = authHandler("secret-token")
  local r = h:precheck(req({ method = "POST", path = "/mcp",
    headers = { authorization = "Bearer secret-token" } }))
  assertNil(r)
end)

test("precheck: auth off + loopback -> nil (proceed to body)", function()
  local h = mcp.new(stubRpc())
  assertNil(h:precheck(req({ method = "POST", path = "/mcp", headers = { host = "127.0.0.1:23512" } })))
end)

test("precheck: auth off + non-loopback Host -> 403", function()
  local h = mcp.new(stubRpc())
  local r = h:precheck(req({ method = "POST", path = "/mcp", headers = { host = "evil.example.com" } }))
  assertEqual(r.status, 403)
end)

test("precheck: non-/mcp path -> 404", function()
  local h = mcp.new(stubRpc())
  assertEqual(h:precheck(req({ method = "GET", path = "/nope" })).status, 404)
end)

test("precheck: well-known metadata GET is answered from the head alone", function()
  local h = mcp.new(stubRpc())
  local r = h:precheck(req({ method = "GET", path = "/.well-known/oauth-protected-resource",
    headers = { host = "127.0.0.1:23512" } }))
  assertEqual(r.status, 200)
  assertMatch(r.body, '"resource"')
end)

test("respond still delegates through the same gate (401 path unchanged)", function()
  local h = authHandler("secret-token")
  local r = h:respond(req({ method = "POST", path = "/mcp", body = "{}" }))
  assertEqual(r.status, 401)
end)
