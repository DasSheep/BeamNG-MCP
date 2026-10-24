local message = require("http.message")

test("parse_head extracts method, path, and lowercased headers", function()
  local req = message.parse_head({
    "POST /mcp HTTP/1.1",
    "Host: 127.0.0.1:23512",
    "Content-Type: application/json",
    "Content-Length: 5",
  })
  assertEqual(req.method, "POST")
  assertEqual(req.path, "/mcp")
  assertEqual(req.headers["content-type"], "application/json")
  assertEqual(req.headers["content-length"], "5")
end)

test("parse_head handles a header value containing colons", function()
  local req = message.parse_head({ "GET /mcp HTTP/1.1", "Origin: http://127.0.0.1:23512" })
  assertEqual(req.method, "GET")
  assertEqual(req.headers["origin"], "http://127.0.0.1:23512")
end)

test("content_length returns the number, or 0 when absent", function()
  assertEqual(message.content_length({ ["content-length"] = "42" }), 42)
  assertEqual(message.content_length({}), 0)
end)

test("frame_response builds a status line, content-length, and body", function()
  local s = message.frame_response({ status = 200, headers = { ["Content-Type"] = "application/json" }, body = "{}" })
  assertMatch(s, "^HTTP/1%.1 200 OK\r\n")
  assertMatch(s, "Content%-Type: application/json\r\n")
  assertMatch(s, "Content%-Length: 2\r\n")
  assertMatch(s, "Connection: close\r\n")
  assertMatch(s, "\r\n\r\n{}$")
end)

test("frame_response maps known status codes to reason phrases", function()
  assertMatch(message.frame_response({ status = 202, body = "" }), "^HTTP/1%.1 202 Accepted\r\n")
  assertMatch(message.frame_response({ status = 404, body = "" }), "^HTTP/1%.1 404 Not Found\r\n")
  assertMatch(message.frame_response({ status = 405, body = "" }), "^HTTP/1%.1 405 Method Not Allowed\r\n")
end)

test("frame_response with empty body still sets Content-Length: 0", function()
  assertMatch(message.frame_response({ status = 202, body = "" }), "Content%-Length: 0\r\n")
end)

test("parse_head on a malformed request line leaves method/path nil", function()
  local req = message.parse_head({})
  assertNil(req.method)
  assertNil(req.path)
end)

test("frame_response uses 'Unknown' reason for an unmapped status code", function()
  assertMatch(message.frame_response({ status = 503, body = "" }), "^HTTP/1%.1 503 Unknown\r\n")
end)

test("frame_response ignores a caller-supplied Content-Length (no duplicate)", function()
  local s = message.frame_response({ status = 200, headers = { ["Content-Length"] = "999" }, body = "{}" })
  assertMatch(s, "Content%-Length: 2\r\n")
  local _, count = s:gsub("Content%-Length:", "")
  assertEqual(count, 1)
end)

test("frame_response knows the auth/limit status reasons (401/413/431)", function()
  assertMatch(message.frame_response({ status = 401 }), "^HTTP/1%.1 401 Unauthorized\r\n")
  assertMatch(message.frame_response({ status = 413 }), "^HTTP/1%.1 413 Payload Too Large\r\n")
  assertMatch(message.frame_response({ status = 431 }), "^HTTP/1%.1 431 Request Header Fields Too Large\r\n")
end)
