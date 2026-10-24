-- Pure HTTP/1.1 helpers: parse a request head (array of lines) and frame a response string.
-- No sockets, no BeamNG globals — unit-testable off-engine.
local M = {}

local REASONS = {
  [200] = "OK", [202] = "Accepted", [400] = "Bad Request", [401] = "Unauthorized",
  [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
  [413] = "Payload Too Large", [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
}

function M.parse_head(lines)
  local req = { headers = {} }
  local first = lines[1] or ""
  -- version is the numeric part (e.g. "1.1"); parsed for completeness, not yet validated.
  req.method, req.path, req.version = first:match("^(%S+)%s+(%S+)%s+HTTP/([%d%.]+)")
  for i = 2, #lines do
    local k, v = lines[i]:match("^(.-):%s*(.*)$")
    if k then req.headers[k:lower()] = v end
  end
  return req
end

function M.content_length(headers)
  return tonumber(headers["content-length"] or "0") or 0
end

function M.frame_response(resp)
  local status = resp.status or 200
  local body = resp.body or ""
  local out = { "HTTP/1.1 " .. status .. " " .. (REASONS[status] or "Unknown") }
  if resp.headers then
    for k, v in pairs(resp.headers) do
      local lk = k:lower()
      if lk ~= "content-length" and lk ~= "connection" then  -- generated below; never duplicate
        out[#out + 1] = k .. ": " .. tostring(v)
      end
    end
  end
  out[#out + 1] = "Content-Length: " .. #body
  out[#out + 1] = "Connection: close"
  return table.concat(out, "\r\n") .. "\r\n\r\n" .. body
end

return M
