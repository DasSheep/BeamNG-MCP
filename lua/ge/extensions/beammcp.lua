-- G: BeamNG GE extension. Binds the MCP server's lifetime + tick to the GE frame.
-- Load with: extensions.load('beammcp')
local M = {}
local identity = require('beammcp/identity')
local serverIdentity = identity.captureDeployment()

local jsonrpc  = require("beammcp/core/jsonrpc")
local registry = require("beammcp/core/registry")
local methods  = require("beammcp/core/methods")
local lua_eval = require("beammcp/tools/lua_eval")
local lua_inspect = require("beammcp/tools/lua_inspect")
local lua_observe = require('beammcp/tools/lua_observe')
local runtime_info = require('beammcp/tools/runtime_info')
local get_vehicle_state      = require("beammcp/tools/get_vehicle_state")
local list_vehicles          = require("beammcp/tools/list_vehicles")
local console_logs           = require("beammcp/tools/console_logs")
local get_vehicle_powertrain = require("beammcp/tools/get_vehicle_powertrain")
local get_vehicle_tuning = require("beammcp/tools/get_vehicle_tuning")
local get_vehicle_config = require("beammcp/tools/get_vehicle_config")
local screenshot             = require("beammcp/tools/screenshot")
local screenshot_native      = require("beammcp/tools/screenshot_native")
local vehicle_lua_eval       = require("beammcp/tools/vehicle_lua_eval")
local spawn_vehicle          = require("beammcp/tools/spawn_vehicle")
local switch_vehicle         = require("beammcp/tools/switch_vehicle")
local reset_vehicle          = require("beammcp/tools/reset_vehicle")
local teleport_vehicle       = require("beammcp/tools/teleport_vehicle")
local set_config             = require("beammcp/tools/set_config")
local ui_visibility_tools    = require("beammcp/tools/ui_visibility")
local cef_eval               = require("beammcp/tools/cef_eval")
local get_game_state         = require("beammcp/tools/get_game_state")
local reload_cef             = require("beammcp/tools/reload_cef")
local damage                 = require("beammcp/tools/damage")
local beam_damage            = require("beammcp/tools/beam_damage")
local part_condition         = require("beammcp/tools/part_condition")
local vehicle_parts          = require("beammcp/tools/vehicle_parts")
local vehicle_catalog        = require("beammcp/tools/vehicle_catalog")
local levels                 = require("beammcp/tools/levels")
local ui_state               = require("beammcp/tools/lib/ui_state")
local manipulations          = require("beammcp/tools/manipulations")
local sim_speed    = require("beammcp/tools/sim_speed")
local recover_game_state = require("beammcp/tools/recover_game_state")
local autoheal           = require("beammcp/reload/autoheal")
local authtoken    = require("beammcp/tools/lib/authtoken")
local instructions = require("beammcp/instructions")
local cdp_targets            = require("beammcp/cdp/targets")
local store_mod  = require("beammcp/store")
local status_mod = require("beammcp/status")
local panel_mod  = require("beammcp/panel")
local logcapture             = require("beammcp/logcapture")
local mcphttp  = require("beammcp/http/mcp")
local server   = require("beammcp/http/server")
local bind     = require("beammcp/bind")

local DEFAULT_PORT = 23512
local BIND_HOST    = "127.0.0.1"

local CDP_PROBE_SEC = 2.5
local cdpProbeAccum = 0
local cdpProbeInFlight = false  -- at most one probe; a wedged endpoint must not stack coroutines
local cdpStatus = {}
local function wallClock() return require('socket').gettime() end
runtime_info.configure({serverIdentity=serverIdentity,clock=wallClock,
  getCefStatus=function() return cdpStatus end,
  modules=function() return {
    beammcp=M, ['beammcp/output']=require('beammcp/output'),
    ['beammcp/inspect']=require('beammcp/inspect'), ['beammcp/observe']=require('beammcp/observe'),
    ['beammcp/tools/lua_eval']=lua_eval, ['beammcp/tools/vehicle_lua_eval']=vehicle_lua_eval,
    ['beammcp/tools/lua_inspect']=lua_inspect, ['beammcp/tools/lua_observe']=lua_observe,
    ['beammcp/tools/runtime_info']=runtime_info, ['beammcp/tools/console_logs']=console_logs,
    ['beammcp/tools/cef_eval']=cef_eval, ['beammcp/cdp/client']=require('beammcp/cdp/client'),
  } end})
-- copas is already loaded by http/server; load it via the same shim (BeamNG preloads socket.http).
local copas = (function()
  local saved = package.loaded["socket.http"]; package.loaded["socket.http"] = nil
  local c = require("libs/copas/copas"); package.loaded["socket.http"] = saved
  return c
end)()

local started = false
local store               -- persisted settings (settings/beammcp.json)
local statusRec           -- live status + activity record
local panel               -- the in-game ImGui panel

-- ensureAuthToken: guarantee a token exists whenever auth is enabled. Mints one (engine entropy) only when
-- the stored token is missing/empty, so enabling auth (or loading with auth already on) never leaves a blank
-- secret. Closes over the module-level `store`, which is assigned in onExtensionLoaded before any call site.
local function ensureAuthToken()
  local tok = store:get("authToken", nil)
  if type(tok) ~= "string" or tok == "" then
    if not store:set("authToken", authtoken.generate()) then
      log("E", "beammcp.store", "failed to persist 'authToken'")
    end
  end
end

function M.onExtensionLoaded()
  if started then return end
  logcapture.install()
  if setExtensionUnloadMode then setExtensionUnloadMode(M, "manual") end

  store = store_mod.new({
    path  = "settings/beammcp.json",
    read  = jsonReadFile,
    write = jsonWriteFile,
  }):load()
  -- Lua-reload recovery: arm from the snapshot file written by the previous VM's onSerialize (if any).
  autoheal.toastEnabled = function() return store:get("reloadToast", true) ~= false end
  autoheal.onLoaded()
  local port = tonumber(store:get("port", DEFAULT_PORT)) or DEFAULT_PORT
  -- CDP target port for cef_eval (Chrome -cefdev default 8080). Configurable because another CEF app (e.g.
  -- Steam's web helper on SteamOS) can squat :8080; point this at BeamNG's actual -cefdev port.
  cdp_targets.CDP_PORT = tonumber(store:get("cefPort", cdp_targets.CDP_PORT)) or cdp_targets.CDP_PORT
  local simControlEnabled = store:get("simControl", false) == true
  local requireAuth = store:get("requireAuth", false) == true
  if requireAuth then ensureAuthToken() end

  -- bind address: stored (default loopback), validated, then fail-closed-resolved against auth — a
  -- non-loopback bind is downgraded to loopback unless auth is on (bind.resolve), so the RCE endpoint is
  -- never reachable off-loopback unauthenticated.
  local bindHostRaw = bind.validate(store:get("bindHost", BIND_HOST)) or BIND_HOST
  local bindHost, bindDowngraded = bind.resolve(bindHostRaw, requireAuth)
  if bindDowngraded then
    log("W", "beammcp.http", "bind '" .. bindHostRaw .. "' requires auth; binding " .. bindHost
      .. " instead - enable 'Require auth' to expose on the network")
  end

  statusRec = status_mod.new()
  statusRec:setMenuOpen(getMissionFilename and getMissionFilename() == "" or false)
  get_game_state.menuOpenSource = function() return statusRec:snapshot().menuOpen end
  get_game_state.lastReloadSource = autoheal.lastCompact
  recover_game_state.lastSource   = autoheal.lastCompact

  local rpc = jsonrpc.new()
  local reg = registry.new()
  methods.register(rpc, reg, { name = "beammcp", version = "0.1.0" },
    function(label) statusRec:record(label) end,
    instructions.build(simControlEnabled, requireAuth))
  lua_eval.register(reg)
  lua_inspect.register(reg)
  lua_observe.register(reg)
  runtime_info.register(reg)
  get_vehicle_state.register(reg)
  list_vehicles.register(reg)
  console_logs.register(reg)
  get_vehicle_powertrain.register(reg)
  get_vehicle_tuning.register(reg)
  get_vehicle_config.register(reg)
  screenshot.register(reg)
  screenshot_native.register(reg)
  vehicle_lua_eval.register(reg)
  spawn_vehicle.register(reg)
  switch_vehicle.register(reg)
  reset_vehicle.register(reg)
  teleport_vehicle.register(reg)
  set_config.register(reg)
  ui_visibility_tools.register(reg)
  cef_eval.register(reg)
  get_game_state.register(reg)
  reload_cef.register(reg)
  damage.register(reg)
  beam_damage.register(reg)
  part_condition.register(reg)
  vehicle_parts.register(reg)
  vehicle_catalog.register(reg)
  levels.register(reg)
  ui_state.register(reg)
  manipulations.register(reg)
  sim_speed.register(reg, function() return store:get("simControl", false) == true end)
  recover_game_state.register(reg)

  local handler = mcphttp.new(rpc, {
    required = function() return store:get("requireAuth", false) == true end,
    token    = function() return store:get("authToken", nil) end,
  })
  server.start(bindHost, port,
    function(req) return handler:respond(req) end,
    function(req) return handler:precheck(req) end)  -- head-only gate: reject before the body is read
  statusRec:setServer(bindHost, port, #reg:list())

  panel = panel_mod.new({
    getIm              = function() return ui_imgui end,
    getPinned          = function() return store:get("pinned", false) == true end,
    setPinned          = function(v)
      if not store:set("pinned", v) then log("E", "beammcp.store", "failed to persist 'pinned'") end
    end,
    getPort            = function() return tonumber(store:get("port", DEFAULT_PORT)) or DEFAULT_PORT end,
    setPort            = function(n)
      if not store:set("port", n) then log("E", "beammcp.store", "failed to persist 'port'") end
    end,
    getBindHost        = function()
      local v = store:get("bindHost", BIND_HOST); return type(v) == "string" and v or BIND_HOST
    end,
    setBindHost        = function(v)
      if not store:set("bindHost", v) then log("E", "beammcp.store", "failed to persist 'bindHost'") end
    end,
    getCefPort         = function() return tonumber(store:get("cefPort", cdp_targets.CDP_PORT)) or cdp_targets.CDP_PORT end,
    setCefPort         = function(n)
      if not store:set("cefPort", n) then log("E", "beammcp.store", "failed to persist 'cefPort'") end
      cdp_targets.CDP_PORT = n   -- live: the CDP probe is a fresh connection each tick, so no restart needed
      cdpStatus = {} -- the previous endpoint's availability is not evidence for the new port
    end,
    getSimControl      = function() return store:get("simControl", false) == true end,
    setSimControl      = function(v)
      if not store:set("simControl", v) then log("E", "beammcp.store", "failed to persist 'simControl'") end
    end,
    getReloadToast     = function() return store:get("reloadToast", true) ~= false end,
    setReloadToast     = function(v)
      if not store:set("reloadToast", v) then log("E", "beammcp.store", "failed to persist 'reloadToast'") end
    end,
    getRequireAuth     = function() return store:get("requireAuth", false) == true end,
    setRequireAuth     = function(v)
      if not store:set("requireAuth", v) then log("E", "beammcp.store", "failed to persist 'requireAuth'") end
      if v == true then ensureAuthToken() end
    end,
    getAuthToken       = function() return store:get("authToken", nil) end,
    regenerateToken    = function()
      if not store:set("authToken", authtoken.generate()) then
        log("E", "beammcp.store", "failed to persist 'authToken'")
      end
    end,
    getMissionFilename = function() return getMissionFilename and getMissionFilename() or "" end,
    bigMapActive       = function() return freeroam_bigMapMode ~= nil and freeroam_bigMapMode.bigMapActive() == true end,
    photoModeOpen      = function() return photoModeOpen == true end,
  })

  started = true
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if not started then return end
  statusRec:tick(dtReal)
  ui_state.update(dtReal)
  levels.update(dtReal)
  server.update()
  -- real (not sim) time so a paused sim can't stall the gate; clamped so one long hitch frame after a heavy
  -- reload can't consume the gate's whole 10 s timeout by itself.
  local okh, errh = pcall(autoheal.update, math.min(dtReal or 0, 0.25))
  if not okh then log("E", "beammcp.reload", "update error: " .. tostring(errh)) end
  cdpProbeAccum = cdpProbeAccum + (dtReal or 0)
  if cdpProbeAccum >= CDP_PROBE_SEC and not cdpProbeInFlight then
    cdpProbeAccum = 0
    cdpProbeInFlight = true
    local probePort=cdp_targets.CDP_PORT
    copas.addthread(function()
      local ok, err = pcall(function()
        local list = cdp_targets.discover(cdp_targets.realHttpGet)
        if probePort==cdp_targets.CDP_PORT then
          local count=list and #cdp_targets.curate(list) or 0
          cdpStatus={active=list~=nil,targets=count,checkedAt=wallClock(),port=probePort}
          statusRec:setCdp(list ~= nil,count)  -- BeamNG targets only
        end
      end)
      cdpProbeInFlight = false
      if not ok then log("E", "beammcp.cdp", "probe error: " .. tostring(err)) end
    end)
  end
  local ok, err = pcall(function() panel:draw(statusRec:snapshot()) end)
  if not ok then log("E", "beammcp.panel", "draw error: " .. tostring(err)) end
end

function M.onLoadingScreenFadeout()
  levels.onLoadingScreenFadeout()
end

function M.onUiChangedState(toState, fromState)
  if type(toState) ~= "string" then return end
  local menu = toState:sub(1, 4) == "menu"
  if panel then panel:setMenuOpen(menu) end
  if statusRec then statusRec:setMenuOpen(menu) end
end

-- Lua-reload hooks. onSerialize writes our independent snapshot file and returns its reloadId into the
-- engine blob; onDeserialized receives it back (never called if the blob import failed -> "total"). These
-- MUST keep the onSerialize/onDeserialized names (the engine's package-serializer hook contract), and
-- autoheal's own methods MUST NOT be named that -- see test/reload_package_hooks_test.lua for why.
function M.onSerialize()
  return autoheal.captureForReload()
end

function M.onDeserialized(data)
  autoheal.receiveBlobId(data)
end

function M.onExtensionUnloaded()
  if started then server.stop(); started = false end
  logcapture.reset()  -- unhook _G.log; otherwise each unload/reload chains another wrapper + ring
end

identity.stamp('beammcp',M,serverIdentity)
return M
