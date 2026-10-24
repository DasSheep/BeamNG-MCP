-- One HTTP request/response exchange on an established connection. Enforces read limits (431/413)
-- and runs the head-only precheck BEFORE the body is buffered, so an unauthorized peer never makes
-- us allocate its payload; frames a 500 when the handler throws. Pure against conn:receive/:send —
-- unit-testable off-engine (server.lua owns the sockets and timeouts).
local M = {}

local message = require("beammcp/http/message")

M.MAX_HEADER_LINES = 100
M.MAX_BODY_BYTES   = 4 * 1024 * 1024

-- run(conn, opts): read one request, send one response (or nothing if the peer vanished mid-head).
-- opts { onRequest(req)->resp, precheck(req)->resp|nil, maxHeaderLines, maxBodyBytes }.
function M.run(conn, opts)
  local maxHead = opts.maxHeaderLines or M.MAX_HEADER_LINES
  local maxBody = opts.maxBodyBytes or M.MAX_BODY_BYTES
  local function send(resp) conn:send(message.frame_response(resp)) end

  local first = conn:receive("*l")
  if not first then return end
  local lines = { first }
  while true do
    local line = conn:receive("*l")
    if not line then return end   -- peer gone / timed out mid-head: nobody to answer
    if line == "" then break end
    if #lines - 1 >= maxHead then return send({ status = 431, headers = {}, body = "" }) end
    lines[#lines + 1] = line
  end

  local req = message.parse_head(lines)
  local len = message.content_length(req.headers)
  if len > maxBody then return send({ status = 413, headers = {}, body = "" }) end

  if opts.precheck then
    local ok, early = pcall(opts.precheck, req)
    if not ok then
      log("E", "beammcp.http", "precheck error: " .. tostring(early))
      return send({ status = 500, headers = {}, body = "" })
    end
    if early then return send(early) end
  end

  req.body = len > 0 and (conn:receive(len) or "") or ""
  local ok, resp = pcall(opts.onRequest, req)
  if not ok then
    log("E", "beammcp.http", "request handler error: " .. tostring(resp))
    resp = nil
  end
  send(resp or { status = 500, headers = {}, body = "" })
end

return M
