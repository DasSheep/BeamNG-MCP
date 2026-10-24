-- cdp/client: one CDP Runtime.evaluate over a WebSocket. Pure protocol (buildEval/parseDecoded/eval)
-- with wsConnect injected for testability; the engine-coupled connect is realWsConnect.
local M = {}
local CMD_ID = 1

-- buildEval(code) -> the CDP Runtime.evaluate command table.
function M.buildEval(code)
  return {
    id = CMD_ID,
    method = "Runtime.evaluate",
    params = { expression = code, returnByValue = true, awaitPromise = true, userGesture = true },
  }
end

-- parseDecoded(resp) -> ok, valueOrErr.  resp is the decoded Runtime.evaluate response table.
function M.parseDecoded(resp)
  if type(resp) ~= "table" then return false, "cef_eval: malformed CDP response" end
  if resp.error then
    return false, "cef_eval: CDP error: " .. tostring(resp.error.message or resp.error)
  end
  local result = resp.result
  if type(result) ~= "table" then return false, "cef_eval: unexpected CDP response shape" end
  if result.exceptionDetails then
    local ed = result.exceptionDetails
    local desc = (ed.exception and (ed.exception.description or ed.exception.value)) or ed.text
      or "JS exception"
    return false, "cef_eval: " .. tostring(desc)
  end
  local ro = result.result or {}     -- RemoteObject; .value present with returnByValue (absent = undefined)
  return true, ro.value
end

-- eval(wsConnect, wsUrl, code, opts) -> ok, valueOrErr.  wsConnect(wsUrl) -> client | nil, err, where
-- client has :send(text)->truthy, :receive()->msg|nil,err, :close(). Sends Runtime.evaluate, reads messages
-- until the matching id (skipping CDP events), returns the parsed value.
function M.eval(wsConnect, wsUrl, code, opts)
  opts = opts or {}
  local cli, cerr = wsConnect(wsUrl, opts)
  if not cli then return false, cerr or "cef_eval: failed to connect to CDP target" end
  local cmd = M.buildEval(code)
  local sent, serr = cli:send(jsonEncode(cmd))
  if not sent then cli:close(); return false, serr or "cef_eval: failed to send CDP command" end
  local maxFrames = opts.maxFrames or 50
  for _ = 1, maxFrames do
    local msg, rerr = cli:receive()
    if msg == nil then cli:close(); return false, rerr or "cef_eval: CDP connection closed before response" end
    local rok, resp = pcall(jsonDecode, msg)
    if rok and type(resp) == "table" and resp.id == cmd.id then
      cli:close()
      return M.parseDecoded(resp)
    end
    -- else: a CDP event (no/other id) — skip and keep reading
  end
  cli:close()
  return false, "cef_eval: no matching CDP response after " .. maxFrames .. " frames"
end

-- parseWsUrl(wsUrl, defaultPort) -> host, port, path | nil, err.  Pure. Chrome may omit the port in
-- webSocketDebuggerUrl; the fallback is the CONFIGURED CDP port (cefPort), never a hardcoded 8080 —
-- on the SteamOS collision setup a hardcoded fallback would connect to Steam's CEF.
function M.parseWsUrl(wsUrl, defaultPort)
  local host, port, path = wsUrl:match("^ws://([^:/]+):(%d+)(/.*)$")
  if not host then host, path = wsUrl:match("^ws://([^:/]+)(/.*)$") end
  if not host then return nil, "cef_eval: bad ws url" end
  return host, tonumber(port) or defaultPort, path
end

-- realWsConnect(wsUrl, opts) -> client | nil, err. The bundled client_copas
-- HANGS under our copas.step(0) pump, so we hand-roll the WS: raw copas socket + manual RFC-6455 upgrade
-- + frame.encode/decode. Returns a client with :send(text)/:receive()->msg|nil/:close() (the shape eval
-- expects). Limits cover the whole exchange: timeout seconds, maxWireFrames, and maxMessageBytes
-- per reassembled text message. Header lengths are checked before requesting payload bytes.
function M.realWsConnect(wsUrl, opts)
  opts = opts or {}
  local saved = package.loaded["socket.http"]; package.loaded["socket.http"] = nil
  local copas = require("libs/copas/copas"); package.loaded["socket.http"] = saved
  local socket = require("socket")
  local frame = require("libs/lua-websockets/websocket/frame")
  local targets = require("beammcp/cdp/targets")
  local host, port, path = M.parseWsUrl(wsUrl, targets.CDP_PORT)
  if not host then return nil, port end   -- port carries the error message on failure
  local sock, sockErr = socket.tcp()
  if not sock then return nil, "cef_eval: ws socket failed: " .. tostring(sockErr) end
  local deadline = socket.gettime() + (opts.timeout or 5)
  local maxBytes, maxFrames = opts.maxMessageBytes or 1024 * 1024, opts.maxWireFrames or 256
  local closed, frameCount = false, 0
  local function shutdown()
    if not closed then closed = true; pcall(function() sock:close() end) end
  end
  local function fail(reason)
    shutdown()
    return nil, "cef_eval: " .. reason
  end
  local function budget()
    if closed then return nil, "cef_eval: CDP connection closed" end
    local remaining = deadline - socket.gettime()
    if remaining <= 0 then return fail("CDP timeout") end
    -- copas.connect resets the underlying socket's timeout, so use its own timeout API.
    copas.settimeout(sock, remaining)
    return true
  end
  local function send(bytes)
    local ok, err = budget()
    if not ok then return nil, err end
    local count, sendErr = copas.send(sock, bytes)
    if count ~= #bytes then return fail("ws send failed: " .. tostring(sendErr or "short write")) end
    return budget()
  end
  local function read(count)
    local ok, err = budget()
    if not ok then return nil, err end
    if count == 0 then return "" end
    local bytes, readErr = copas.receive(sock, count)
    if not bytes or #bytes ~= count then return fail("ws receive failed: " .. tostring(readErr or "short read")) end
    ok, err = budget()
    if not ok then return nil, err end
    return bytes
  end
  local ready, readyErr = budget()
  if not ready then return nil, readyErr end
  if not copas.connect(sock, host, port) then return fail("ws tcp connect failed") end
  local sent, sendErr = send("GET " .. path .. " HTTP/1.1\r\nHost: " .. host .. ":" .. port
    .. "\r\nUpgrade: websocket\r\nConnection: Upgrade"
    .. "\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
  if not sent then return nil, sendErr end
  -- Bound the upgrade too: a line-oriented receive can accumulate an unlimited line.
  local headerBytes = 0
  local function readLine()
    local chars = {}
    while headerBytes < 8192 do
      local char, err = read(1)
      if not char then return nil, err end
      headerBytes = headerBytes + 1
      if char == "\n" then return table.concat(chars):gsub("\r$", "") end
      chars[#chars + 1] = char
    end
    return fail("ws upgrade headers exceed 8192 bytes")
  end
  local status, statusErr = readLine()
  if not status then return nil, statusErr end
  if not status:match("^HTTP/1%.[01] 101%s") then return fail("ws upgrade failed: " .. status) end
  while true do
    local line, err = readLine()
    if not line then return nil, err end
    if line == "" then break end
  end
  local function sendFrame(payload, opcode)
    return send(frame.encode(payload, opcode, true, true))
  end
  local client = {}
  function client:send(text) return sendFrame(text, frame.TEXT) end
  function client:receive()
    local parts, total, fragmented = {}, 0, false
    while true do
      if frameCount >= maxFrames then return fail("CDP wire frame limit exceeded") end
      local header, err = read(2)
      if not header then return nil, err end
      frameCount = frameCount + 1
      local first, second = header:byte(1, 2)
      local opcode, final, length = first % 16, first >= 128, second % 128
      if first % 128 >= 16 or second >= 128 then return fail("invalid WS reserved bits or masked server frame") end
      if opcode ~= frame.TEXT and opcode ~= frame.CONTINUATION and opcode ~= frame.CLOSE
        and opcode ~= frame.PING and opcode ~= frame.PONG then return fail("unsupported WS opcode") end
      local control = opcode >= 8
      if control and (not final or length > 125) then return fail("invalid WS control frame") end
      if not control and ((opcode == frame.CONTINUATION) ~= fragmented) then
        return fail("invalid WS fragmentation sequence")
      end
      if length >= 126 then
        local size = length == 126 and 2 or 8
        local extended
        extended, err = read(size)
        if not extended then return nil, err end
        if size == 8 and extended:byte(1) >= 128 then return fail("invalid WS payload length") end
        header = header .. extended
        length = 0
        for i = 1, size do length = length * 256 + extended:byte(i) end
        if (size == 2 and length < 126) or (size == 8 and length < 65536) then
          return fail("invalid WS nonminimal payload length")
        end
      end
      if not control and length > maxBytes - total then return fail("CDP message exceeds " .. maxBytes .. " bytes") end
      local payload
      payload, err = read(length)
      if not payload then return nil, err end
      -- The bundled codec returns payload, FIN, opcode, leftover, masked (or nil, bytesShort).
      local ok, decoded, fin, op, leftover, masked = pcall(frame.decode, header .. payload)
      if not ok or decoded == nil or fin ~= final or op ~= opcode or leftover ~= "" or masked then
        return fail("invalid WS frame")
      end
      if opcode == frame.CLOSE then
        if #decoded == 1 then return fail("invalid WS close payload") end
        sendFrame(decoded, frame.CLOSE)
        return fail("CDP connection closed before response")
      elseif opcode == frame.PING then
        local pong, pongErr = sendFrame(decoded, frame.PONG)
        if not pong then return nil, pongErr end
      elseif not control then
        total = total + #decoded
        parts[#parts + 1] = decoded
        if final then return table.concat(parts) end
        fragmented = true
      end
    end
  end
  function client:close()
    if not closed then sendFrame("", frame.CLOSE); shutdown() end
  end
  return client
end

require('beammcp/identity').stamp('beammcp/cdp/client',M)
return M
