-- vehicle_lua_eval: run arbitrary Lua in the active/given vehicle's VE VM and return its result, the
-- VE-side twin of lua_eval. The VE result can't return synchronously, so M.evalVE rides the async
-- await seam (copas.sleep yields the request coroutine; onUpdate's copas.step(0) runs the VE callback
-- that resolves the correlation slot). The result is shaped exactly like lua_eval: {value, output}, or
-- nil + a traceback/error message. The engine-coupled round-trip lives in M.evalVE (stubbed in tests,
-- verified in-engine); handler/shaping is pure.
-- await seam (copas.sleep poll) + the VE→GE correlation bridge; both used by M.evalVE.
local await  = require("beammcp/async/await")
local bridge = require("beammcp/async/ve_bridge")
local sleep  = require("beammcp/async/sleep")

local veh = require("beammcp/tools/lib/veh")
local output = require('beammcp/output')

local M = {}
function M.now() return require('socket').gettime() end
local TIMEOUT_SEC = 5

-- Engine-coupled (stubbed in tests, verified in-engine). Fires the VE eval, awaits the correlation
-- slot via copas.sleep, and returns the decoded payload table {ok,value,output,err} (or nil on timeout).
function M.evalVE(veh, code, maxBytes, timeoutSec)
  local id = bridge.begin()
  local queued,err=pcall(function() veh:queueLuaCommand(bridge.wrapVE(id, code, serialize,maxBytes)) end)
  if not queued then bridge.take(id); return {ok=false,err=output.clip(tostring(err),1024),output=''} end
  local ok,ready=pcall(await.await,function() return bridge.isReady(id) end,
    { timeoutSec = timeoutSec or TIMEOUT_SEC, sleep = sleep, now=M.now })
  local json = bridge.take(id)          -- also clears (abandons) the slot on timeout
  if not ok then return {ok=false,err=output.clip(tostring(ready),1024),output=''} end
  if not ready or not json then return nil end
  return jsonDecode(json)
end

local function handler(args)
  if type(args) ~= "table" or type(args.code) ~= "string" then
    return nil, "vehicle_lua_eval: 'code' must be a string"
  end
  local budget,err=output.budget(args.maxBytes)
  if not budget then return nil,err end
  local id, iderr = veh.resolveId(args, "vehicle_lua_eval")
  if not id then return nil, iderr end
  local vehObj = be:getObjectByID(id)
  if not vehObj then return nil, "vehicle_lua_eval: unknown vehicle id " .. tostring(id) end

  local payload = M.evalVE(vehObj, args.code,budget)
  if not payload then
    return nil, "vehicle_lua_eval: no response from vehicle VM within " .. TIMEOUT_SEC .. "s"
  end
  if not payload.ok then
    return nil,output.errorText(payload.err,payload.output,budget)
  end
  return output.fit({ value = payload.value, output = payload.output,truncated=payload.truncated },budget)
end

M.def = {
  description = "Execute a Lua chunk in the active (or given) vehicle's VE VM; returns its value and "
    .. "printed output. Default budget 4096 encoded bytes; truncated=true marks omitted data.",
  annotations = { readOnlyHint = false, openWorldHint = true, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      code = { type = "string", description = "Lua source to execute in the vehicle VM" },
      id = { type = "number", description = "vehicle id (default: player)" },
      maxBytes={type='integer',minimum=1024,maximum=16384,description='Encoded result budget; default 4096.'},
    },
    required = { "code" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("vehicle_lua_eval", M.def)
end

require('beammcp/identity').stamp('beammcp/tools/vehicle_lua_eval',M)
return M
