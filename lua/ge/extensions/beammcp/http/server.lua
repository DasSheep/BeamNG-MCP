-- A: minimal HTTP/1.1 server over BeamNG's bundled copas. Owns the sockets only — accept, wrap,
-- arm the idle timeout, then hand the connection to http/exchange for the request/response cycle.
-- Pump update() from onUpdate.
local M = {}

-- copas.lua:47 errors if socket.http is already loaded (Lua 5.1); BeamNG pre-loads it in the GE VM.
-- We use only copas's raw-TCP server, so hide socket.http across the require and restore it.
local _savedHttp = package.loaded["socket.http"]
package.loaded["socket.http"] = nil
local copas = require("libs/copas/copas")
package.loaded["socket.http"] = _savedHttp

local socket   = require("libs/luasocket/socket.socket")
local exchange = require("beammcp/http/exchange")

-- Copas' default per-socket user-timeout is effectively infinite; without this a peer that connects
-- and stalls pins its coroutine + select slot forever (slowloris). Applies per receive/send op, so
-- it never fires during handler work (tool awaits are not socket I/O).
local REQUEST_TIMEOUT_SEC = 10

local server      -- the copas server handle
local runOpts     -- { onRequest, precheck } injected via start()

local function onClient(c)
  c = copas.wrap(c)
  c:settimeout(REQUEST_TIMEOUT_SEC)  -- wrapped settimeout = copas.settimeout (the user-timeout)
  local ok, err = pcall(exchange.run, c, runOpts)
  if not ok then
    log("E", "beammcp.http", "connection error: " .. tostring(err))
  end
  pcall(function() c:close() end)  -- always close, even if the exchange threw
end

function M.start(host, port, onRequest, precheck)
  M.stop()  -- idempotent: drop any prior listener so a re-start can't orphan one / double-bind
  runOpts = { onRequest = onRequest, precheck = precheck }
  local sock = assert(socket.bind(host, port))
  server = copas.addserver(sock, onClient)
  log("I", "beammcp.http", "listening on " .. host .. ":" .. port)
end

function M.update()
  copas.step(0)
end

function M.stop()
  if server then copas.removeserver(server); server = nil end
end

return M
