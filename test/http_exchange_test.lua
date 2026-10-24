require("support.beamng_stubs")
local exchange = require("http.exchange")

-- fake conn: "*l" reads walk `lines` (nil past the end = peer gone); numeric reads serve `bodyData`
-- and are recorded in bodyReads so tests can assert the body was (not) buffered. send() collects frames.
local function fakeConn(lines, bodyData)
  local i = 0
  local c = { bodyReads = {}, sent = {} }
  function c:receive(pat)
    if pat == "*l" then i = i + 1; return lines[i] end
    self.bodyReads[#self.bodyReads + 1] = pat
    return bodyData and bodyData:sub(1, pat) or nil
  end
  function c:send(s) self.sent[#self.sent + 1] = s end
  return c
end

local function okHandler(status)
  return function(req) return { status = status or 200, headers = {}, body = "handled:" .. tostring(req.body) } end
end

test("happy path: parses head, reads Content-Length body, sends the handler response", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Host: 127.0.0.1", "Content-Length: 2", "" }, "{}")
  local seen
  exchange.run(c, { onRequest = function(req) seen = req; return okHandler()(req) end })
  assertEqual(seen.method, "POST")
  assertEqual(seen.path, "/mcp")
  assertEqual(seen.body, "{}")
  assertMatch(c.sent[1], "^HTTP/1%.1 200 OK")
  assertMatch(c.sent[1], "handled:{}")
end)

test("no request line: sends nothing", function()
  local c = fakeConn({}, nil)
  exchange.run(c, { onRequest = okHandler() })
  assertEqual(#c.sent, 0)
end)

test("peer vanishes mid-headers: sends nothing", function()
  local c = fakeConn({ "GET /mcp HTTP/1.1", "Host: 127.0.0.1" }, nil)  -- no blank terminator
  exchange.run(c, { onRequest = okHandler() })
  assertEqual(#c.sent, 0)
end)

test("too many header lines -> 431, handler never runs", function()
  local lines = { "POST /mcp HTTP/1.1" }
  for n = 1, 10 do lines[#lines + 1] = "X-Pad-" .. n .. ": x" end
  lines[#lines + 1] = ""
  local c = fakeConn(lines, "{}")
  local ran = false
  exchange.run(c, { maxHeaderLines = 5, onRequest = function() ran = true end })
  assertMatch(c.sent[1], "^HTTP/1%.1 431 ")
  assertEqual(ran, false)
end)

test("Content-Length over the cap -> 413 before any body read", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Content-Length: 99", "" }, string.rep("x", 99))
  exchange.run(c, { maxBodyBytes = 10, onRequest = okHandler() })
  assertMatch(c.sent[1], "^HTTP/1%.1 413 ")
  assertEqual(#c.bodyReads, 0)
end)

test("precheck rejection is sent without buffering the body", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Content-Length: 2", "" }, "{}")
  local ran = false
  exchange.run(c, {
    precheck  = function() return { status = 401, headers = { ["WWW-Authenticate"] = "Bearer" }, body = "" } end,
    onRequest = function() ran = true end,
  })
  assertMatch(c.sent[1], "^HTTP/1%.1 401 ")
  assertEqual(#c.bodyReads, 0)
  assertEqual(ran, false)
end)

test("precheck sees the parsed head (no body yet); nil precheck result proceeds to the handler", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Content-Length: 2", "" }, "{}")
  local headSeen
  exchange.run(c, {
    precheck  = function(req) headSeen = { path = req.path, body = req.body }; return nil end,
    onRequest = okHandler(),
  })
  assertEqual(headSeen.path, "/mcp")
  assertNil(headSeen.body)
  assertMatch(c.sent[1], "handled:{}")
end)

test("zero Content-Length: no body read, empty body", function()
  local c = fakeConn({ "GET /mcp HTTP/1.1", "" }, nil)
  local seen
  exchange.run(c, { onRequest = function(req) seen = req; return okHandler()(req) end })
  assertEqual(seen.body, "")
  assertEqual(#c.bodyReads, 0)
end)

test("handler throws -> framed 500, not a bare close", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Content-Length: 2", "" }, "{}")
  exchange.run(c, { onRequest = function() error("boom") end })
  assertMatch(c.sent[1], "^HTTP/1%.1 500 ")
end)

test("precheck throws -> framed 500", function()
  local c = fakeConn({ "POST /mcp HTTP/1.1", "Content-Length: 2", "" }, "{}")
  exchange.run(c, { precheck = function() error("boom") end, onRequest = okHandler() })
  assertMatch(c.sent[1], "^HTTP/1%.1 500 ")
end)

test("default limits are sane (100 header lines, 4 MB body)", function()
  assertEqual(exchange.MAX_HEADER_LINES, 100)
  assertEqual(exchange.MAX_BODY_BYTES, 4 * 1024 * 1024)
end)
