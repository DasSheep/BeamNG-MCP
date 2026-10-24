require("support.beamng_stubs")            -- jsonDecode/jsonEncode
local client = require("beammcp/cdp/client")

local function fakeClient(frames)
  local i = 0
  return {
    sent = {},
    send = function(self, data) self.sent[#self.sent + 1] = data; return true end,
    receive = function(self) i = i + 1; return frames[i] end,   -- string or nil
    close = function(self) self.closed = true end,
  }
end

test("buildEval sets the Runtime.evaluate command", function()
  local cmd = client.buildEval("document.title")
  assertEqual(cmd.method, "Runtime.evaluate")
  assertEqual(cmd.params.expression, "document.title")
  assertTrue(cmd.params.returnByValue == true)
  assertTrue(cmd.params.awaitPromise == true)
end)

test("parseDecoded: success returns the by-value result", function()
  local ok, val = client.parseDecoded({ id = 1, result = { result = { type = "string", value = "nav" } } })
  assertTrue(ok)
  assertEqual(val, "nav")
end)

test("parseDecoded: undefined result -> ok with nil value", function()
  local ok, val = client.parseDecoded({ id = 1, result = { result = { type = "undefined" } } })
  assertTrue(ok)
  assertNil(val)
end)

test("parseDecoded: JS exception -> error with description", function()
  local ok, err = client.parseDecoded({ id = 1, result = {
    exceptionDetails = { exception = { description = "ReferenceError: foo is not defined" } } } })
  assertTrue(not ok)
  assertMatch(err, "ReferenceError")
end)

test("parseDecoded: protocol error -> error with message", function()
  local ok, err = client.parseDecoded({ id = 1, error = { message = "Cannot find context" } })
  assertTrue(not ok)
  assertMatch(err, "Cannot find context")
end)

test("eval: skips events, returns the matching id's value", function()
  local frames = {
    jsonEncode({ method = "Runtime.consoleAPICalled", params = {} }),   -- an event, no id
    jsonEncode({ id = 1, result = { result = { value = "nav" } } }),     -- the response
  }
  local c = fakeClient(frames)
  local ok, val = client.eval(function() return c end, "ws://x", "loc")
  assertTrue(ok)
  assertEqual(val, "nav")
  assertTrue(c.closed)                       -- connection closed after the response
  assertMatch(c.sent[1], "Runtime.evaluate") -- the command was sent
end)

test("eval: connection closes before response -> error", function()
  local c = fakeClient({ nil })              -- receive returns nil immediately
  local ok, err = client.eval(function() return c end, "ws://x", "loc")
  assertTrue(not ok)
  assertMatch(err, "closed")
end)

test("eval: connect failure -> error", function()
  local ok, err = client.eval(function() return nil, "boom" end, "ws://x", "loc")
  assertTrue(not ok)
  assertMatch(err, "boom")
end)

-- parseWsUrl: pure ws:// URL split with an injectable default port (Chrome may omit the port; the
-- fallback must be the CONFIGURED CDP port, not a hardcoded 8080 — the SteamOS :8080 collision).
test("parseWsUrl splits host, explicit port, and path", function()
  local host, port, path = client.parseWsUrl("ws://localhost:9222/devtools/page/AB12", 8080)
  assertEqual(host, "localhost")
  assertEqual(port, 9222)
  assertEqual(path, "/devtools/page/AB12")
end)

test("parseWsUrl without a port falls back to the given default, not 8080", function()
  local host, port, path = client.parseWsUrl("ws://localhost/devtools/page/AB12", 9222)
  assertEqual(host, "localhost")
  assertEqual(port, 9222)
  assertEqual(path, "/devtools/page/AB12")
end)

test("parseWsUrl rejects a non-ws url", function()
  local host, err = client.parseWsUrl("http://localhost:8080/x", 8080)
  assertNil(host)
  assertMatch(err, "bad ws url")
end)
