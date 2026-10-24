require("support.beamng_stubs")
local client = require("beammcp/cdp/client")

-- Model the bundled codec's five-result API, including bytes-short and leftover data.
local function wire(payload, opcode, fin)
  local n = #payload
  local length = n < 126 and "" or (n < 65536 and string.char(math.floor(n / 256), n % 256)
    or string.char(0, 0, 0, 0, 0, math.floor(n / 65536), math.floor(n / 256) % 256, n % 256))
  return string.char((fin == false and 0 or 128) + (opcode or 1), n < 126 and n or (n < 65536 and 126 or 127))
    .. length .. payload
end

local function withSocket(data, opts, fn)
  opts = opts or {}
  local names = { "libs/copas/copas", "socket", "libs/lua-websockets/websocket/frame", "beammcp/cdp/targets" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local state = { sent = {}, encodes = {}, reads = {}, closed = 0, now = 0 }
  local input = opts.handshake or "HTTP/1.1 101 Switching Protocols\r\n\r\n"
  input = input .. (data or "")
  local sock = { close = function() state.closed = state.closed + 1 end }
  package.loaded[names[1]] = {
    settimeout = function(_, seconds) state.timeout = seconds end,
    connect = function() return not opts.connectFail end,
    send = function(_, bytes)
      state.sent[#state.sent + 1] = bytes
      if opts.sendFail == #state.sent then return nil, "timeout" end
      return #bytes
    end,
    receive = function(_, count)
      state.reads[#state.reads + 1] = count
      state.now = state.now + (opts.readTime or 0)
      if count == "*l" then
        local at = input:find("\n", 1, true)
        if not at then return nil, "closed" end
        local line = input:sub(1, at - 1):gsub("\r$", "")
        input = input:sub(at + 1)
        return line
      end
      if #input < count then return nil, opts.receiveError or "closed", input end
      local result = input:sub(1, count)
      input = input:sub(count + 1)
      return result
    end,
  }
  package.loaded[names[2]] = { tcp = function() return sock end, gettime = function() return state.now end }
  package.loaded[names[3]] = {
    TEXT = 1, CONTINUATION = 0, BINARY = 2, CLOSE = 8, PING = 9, PONG = 10,
    encode = function(payload, opcode, masked, fin)
      state.encodes[#state.encodes + 1] = { payload = payload, opcode = opcode, masked = masked, fin = fin }
      return wire(payload, opcode, fin)
    end,
    decode = function(bytes)
      if #bytes < 2 then return nil, 2 - #bytes end
      local a, n = bytes:byte(1, 2)
      local header = 2
      if n == 126 then
        if #bytes < 4 then return nil, 4 - #bytes end
        n = bytes:byte(3) * 256 + bytes:byte(4)
        header = 4
      elseif n == 127 then
        if #bytes < 10 then return nil, 10 - #bytes end
        n = 0
        for i = 3, 10 do n = n * 256 + bytes:byte(i) end
        header = 10
      end
      if #bytes < header + n then return nil, header + n - #bytes end
      return bytes:sub(header + 1, header + n), a >= 128, a % 16, bytes:sub(header + n + 1), false
    end,
  }
  package.loaded[names[4]] = { CDP_PORT = 9222 }
  local ok, err = pcall(fn, state)
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  if not ok then error(err, 0) end
end

local function connect(opts) return client.realWsConnect("ws://localhost:9222/devtools/page/test", opts) end

test("CDP transport reassembles text with interleaved ping and pong", function()
  withSocket(wire("first", 1, false) .. wire("ping", 9) .. wire("ignored", 10) .. wire("last", 0), {}, function(s)
    local c = assert(connect())
    assertEqual(c:receive(), "firstlast")
    assertEqual(s.encodes[1].opcode, 10)
    assertEqual(s.encodes[1].payload, "ping")
    assertTrue(s.encodes[1].masked)
    c:close()
    assertEqual(s.encodes[2].opcode, 8)
    assertTrue(s.encodes[2].masked)
    assertEqual(s.closed, 1)
  end)
end)

test("CDP transport preserves successive messages", function()
  withSocket(wire("one") .. wire("two"), {}, function()
    local c = assert(connect())
    assertEqual(c:receive(), "one")
    assertEqual(c:receive(), "two")
    c:close()
  end)
end)

test("CDP peer close is acknowledged masked and reported", function()
  local payload = string.char(3, 232) .. "done"
  withSocket(wire(payload, 8), {}, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "closed")
    assertEqual(s.encodes[1].opcode, 8)
    assertEqual(s.encodes[1].payload, payload)
    assertTrue(s.encodes[1].masked)
    c:close()
    assertEqual(s.closed, 1)
  end)
end)

local malformed = {
  { "unexpected continuation", wire("x", 0) },
  { "nested text", wire("x", 1, false) .. wire("y", 1) },
  { "binary", wire("x", 2) },
  { "reserved opcode", wire("x", 3) },
  { "reserved bits", string.char(193, 0) },
  { "masked server frame", string.char(129, 128) },
  { "fragmented ping", wire("x", 9, false) },
  { "oversized control", wire(string.rep("x", 126), 9) },
  { "one byte close", wire("x", 8) },
  { "nonminimal length", string.char(129, 126, 0, 1) .. "x" },
  { "nonminimal 64 bit length", string.char(129, 127, 0, 0, 0, 0, 0, 0, 255, 255) },
  { "truncated 16 bit length", string.char(129, 126, 0) },
  { "truncated 64 bit length", string.char(129, 127, 0, 0, 0, 0) },
  { "invalid 64 bit length", string.char(129, 127, 128, 0, 0, 0, 0, 0, 0, 0) },
}
for _, case in ipairs(malformed) do
  test("CDP transport rejects " .. case[1], function()
    withSocket(case[2], {}, function(s)
      local c = assert(connect())
      local msg, err = c:receive()
      assertNil(msg)
      assertMatch(err, "cef_eval:")
      assertEqual(s.closed, 1)
    end)
  end)
end

test("CDP caps advertised payload before reading or allocating it", function()
  withSocket(string.char(129, 127, 0, 0, 0, 0, 0, 32, 0, 0), {}, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "message exceeds")
    for _, n in ipairs(s.reads) do if type(n) == "number" then assertTrue(n <= 8) end end
  end)
end)

test("CDP rejects maximum unsigned 63 bit length before payload receive", function()
  withSocket(string.char(129, 127, 127, 255, 255, 255, 255, 255, 255, 255), {}, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "message exceeds")
    assertEqual(s.reads[#s.reads], 8)
    assertEqual(s.closed, 1)
  end)
end)

local response = jsonEncode({ id = 1, result = { result = { value = "reply" } } })
local event = wire(jsonEncode({ method = "Runtime.consoleAPICalled", params = {} }))

for _, eventCount in ipairs({ 49, 50 }) do
  test("CDP eval message limit with " .. eventCount .. " unmatched events", function()
    withSocket(event:rep(eventCount) .. wire(response), {}, function(s)
      local ok, value = client.eval(client.realWsConnect, "ws://localhost:9222/test", "1")
      assertEqual(ok, eventCount == 49)
      if ok then assertEqual(value, "reply") else assertMatch(value, "after 50 frames") end
      assertEqual(s.closed, 1)
    end)
  end)
end

for _, controls in ipairs({ 255, 256 }) do
  test("CDP eval wire limit with " .. controls .. " control frames", function()
    withSocket(wire("", 10):rep(controls) .. wire(response), {}, function(s)
      local ok, value = client.eval(client.realWsConnect, "ws://localhost:9222/test", "1")
      assertEqual(ok, controls == 255)
      if ok then assertEqual(value, "reply") else assertMatch(value, "wire frame limit") end
      assertEqual(s.closed, 1)
    end)
  end)
end

test("CDP eval counts fragmented replies as one message", function()
  local cut = math.floor(#response / 2)
  withSocket(event:rep(49) .. wire(response:sub(1, cut), 1, false) .. wire("ping", 9)
    .. wire(response:sub(cut + 1), 0), {}, function(s)
    local ok, value = client.eval(client.realWsConnect, "ws://localhost:9222/test", "1")
    assertTrue(ok)
    assertEqual(value, "reply")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP peer close discards an unfinished message", function()
  withSocket(wire("partial", 1, false) .. wire("", 8), {}, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "closed")
    assertEqual(s.closed, 1)
    c:close()
    assertEqual(s.closed, 1)
  end)
end)

test("CDP caps aggregate fragmented payload", function()
  withSocket(wire("12345", 1, false) .. wire("6789", 0), {}, function()
    local c = assert(connect({ maxMessageBytes = 8 }))
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "message exceeds")
  end)
end)

for _, size in ipairs({ 126, 65536, 1048576 }) do
  test("CDP accepts bounded extended payload of " .. size .. " bytes", function()
    local payload = string.rep("x", size)
    withSocket(wire(payload), {}, function()
      local c = assert(connect())
      assertEqual(c:receive(), payload)
      c:close()
    end)
  end)
end

test("CDP frame budget spans successive messages", function()
  withSocket(wire("one") .. wire("two"), {}, function()
    local c = assert(connect({ maxWireFrames = 1 }))
    assertEqual(c:receive(), "one")
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "frame limit")
  end)
end)

test("CDP ping send failure closes socket", function()
  withSocket(wire("ping", 9), { sendFail = 2 }, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "send failed")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP upgrade headers are bounded", function()
  withSocket("", { handshake = "HTTP/1.1 101 Switching Protocols\r\nX: " .. string.rep("x", 8192) }, function(s)
    local c, err = connect()
    assertNil(c)
    assertMatch(err, "headers exceed")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP caps empty control frame floods", function()
  withSocket(wire("", 10):rep(4), {}, function(s)
    local c = assert(connect({ maxWireFrames = 3 }))
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "frame limit")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP deadline terminates slow fragmented messages", function()
  withSocket(wire("x", 1, false):rep(4), {}, function(s)
    local c = assert(connect({ timeout = 1 }))
    s.now = 2
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "timeout")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP truncated payload reports receive error and closes", function()
  withSocket(string.char(129, 5) .. "x", { receiveError = "timeout" }, function(s)
    local c = assert(connect())
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "timeout")
    assertEqual(s.closed, 1)
  end)
end)

test("CDP deadline includes time spent inside a successful read", function()
  withSocket(wire("text"), {}, function(s)
    local c = assert(connect({ timeout = 1 }))
    local original = package.loaded["libs/copas/copas"].receive
    package.loaded["libs/copas/copas"].receive = function(...)
      s.now = s.now + 2
      return original(...)
    end
    local msg, err = c:receive()
    assertNil(msg)
    assertMatch(err, "timeout")
    assertEqual(s.closed, 1)
  end)
end)

for _, case in ipairs({
  { "connect", { connectFail = true } },
  { "upgrade send", { sendFail = 1 } },
  { "truncated upgrade", { handshake = "HTTP/1.1 101 Switching Protocols\r\n" } },
  { "invalid status", { handshake = "HTTP/1.1 200 101\r\n\r\n" } },
}) do
  test("CDP closes socket after failed " .. case[1], function()
    withSocket("", case[2], function(s)
      local c, err = connect()
      assertNil(c)
      assertMatch(err, "cef_eval:")
      assertEqual(s.closed, 1)
    end)
  end)
end

test("CDP failed command send closes socket", function()
  withSocket("", { sendFail = 2 }, function(s)
    local c = assert(connect())
    assertNil(c:send("command"))
    assertEqual(s.closed, 1)
  end)
end)

test("CDP eval propagates transport error details", function()
  local closed = false
  local ok, err = client.eval(function() return {
    send = function() return true end,
    receive = function() return nil, "cef_eval: message exceeds 1048576 bytes" end,
    close = function() closed = true end,
  } end, "ws://x", "x")
  assertTrue(not ok)
  assertMatch(err, "message exceeds")
  assertTrue(closed)
end)
