-- cdp/targets: discover and select CEF DevTools page targets from GET :8080/json. Pure parse/select
-- with the HTTP GET injected (discover(httpGet)) for testability; the engine-coupled GET is realHttpGet.
local M = {}
local DEFAULT_NEEDLE = "main/index.html"

-- discover(httpGet) -> targets array | nil, err.  httpGet() returns the raw body of GET :8080/json.
function M.discover(httpGet)
  local ok, body = pcall(httpGet)
  if not ok or type(body) ~= "string" or body == "" then
    return nil, "cef_eval: CEF CDP endpoint not reachable on :" .. tostring(M.CDP_PORT) .. " (launch with -cefdev?)"
  end
  local okJson, list = pcall(jsonDecode, body)
  if not okJson or type(list) ~= "table" then
    return nil, "cef_eval: malformed /json from :" .. tostring(M.CDP_PORT)
  end
  return list
end

-- A BeamNG CEF page is served from the local:// scheme (e.g. local://local/ui/.../main/index.html). Steam's
-- web-helper CEF — which squats the same default :8080 debug port as -cefdev — uses about:blank?.../
-- steamloopback.host/data:. Allowlisting local:// pins us to BeamNG and never surfaces or evals a foreign
-- (Steam) target, even one whose title/url happens to match the search needle.
function M.isBeamngTarget(t)
  return type(t) == "table" and t.type == "page"
    and tostring(t.url or ""):lower():find("^local://") ~= nil
end

-- curate(list) -> array of BeamNG page targets only (drops foreign CEF pages). Used by the panel count and by
-- select, so neither ever counts nor connects to a non-BeamNG (e.g. Steam) target.
function M.curate(list)
  local out = {}
  for _, t in ipairs(list or {}) do if M.isBeamngTarget(t) then out[#out + 1] = t end end
  return out
end

-- select(targets, query) -> wsUrl | nil, err.  Considers only BeamNG (local://) page targets. Default
-- (nil/empty) = the Main UI page; otherwise the first BeamNG page whose url or title contains `query`
-- (case-insensitive substring). When the endpoint answers but has no BeamNG pages, the error says so and
-- names the port — the SteamOS-collision diagnostic.
function M.select(targets, query)
  local needle = (query == nil or query == "") and DEFAULT_NEEDLE or query
  local nlow = needle:lower()
  local beamng = M.curate(targets)
  if #beamng == 0 then
    local total = #(targets or {})
    if total > 0 then
      return nil, "cef_eval: the CDP endpoint on :" .. tostring(M.CDP_PORT) .. " has " .. total
        .. " target(s) but none are BeamNG (local://) - looks like another CEF app (e.g. Steam, whose debug "
        .. "port collides with -cefdev) on that port. Set 'cefPort' to BeamNG's -cefdev port, or free :"
        .. tostring(M.CDP_PORT) .. "."
    end
    return nil, "cef_eval: no CEF page targets on :" .. tostring(M.CDP_PORT) .. " (launch BeamNG with -cefdev?)"
  end
  local available = {}
  for _, t in ipairs(beamng) do
    local url, title = tostring(t.url or ""), tostring(t.title or "")
    available[#available + 1] = title
    if url:lower():find(nlow, 1, true) or title:lower():find(nlow, 1, true) then
      if t.webSocketDebuggerUrl and t.webSocketDebuggerUrl ~= "" then
        return t.webSocketDebuggerUrl
      end
    end
  end
  return nil, "cef_eval: no BeamNG target matching '" .. needle .. "' (available: "
    .. table.concat(available, ", ") .. ")"
end

-- CDP endpoint (Chrome -cefdev default).
M.CDP_HOST, M.CDP_PORT = "localhost", 8080

-- realHttpGet() -> body string.  Zero-arg (discover() calls it with no args). Engine-coupled, VALIDATED
-- live: HTTP/1.1 keep-alive, so read the status line + headers, parse Content-Length, then read exactly
-- that many bytes (NOT "*a"/socket.http — both hang on keep-alive). Raises on socket failure (discover
-- wraps it in pcall).
function M.realHttpGet()
  local saved = package.loaded["socket.http"]; package.loaded["socket.http"] = nil
  local copas = require("libs/copas/copas"); package.loaded["socket.http"] = saved
  local socket = require("socket")
  local sock = socket.tcp()
  copas.settimeout(sock, 2)  -- copas' user-timeout; a plain sock:settimeout is clobbered to 0 by copas.connect
  assert(copas.connect(sock, M.CDP_HOST, M.CDP_PORT), "connect failed")
  copas.send(sock, "GET /json HTTP/1.1\r\nHost: " .. M.CDP_HOST .. "\r\nAccept: */*\r\n\r\n")
  copas.receive(sock, "*l")   -- status line
  local clen
  while true do
    local line = copas.receive(sock, "*l")
    if not line or line == "" then break end
    local k, v = line:match("^(.-):%s*(.*)$")
    if k and k:lower() == "content-length" then clen = tonumber(v) end
  end
  local body = clen and clen > 0 and copas.receive(sock, clen) or ""
  pcall(function() sock:close() end)
  return body
end

return M
