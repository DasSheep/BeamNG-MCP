-- F: run a Lua chunk in the host VM, capturing the return value and printed output.
-- Error-capture pattern lifted from BeamNG's util/wsTest.lua (loadstring + xpcall + traceback).
local M = {}
local output = require('beammcp/output')

local function handler(args)
  if type(args) ~= "table" or type(args.code) ~= "string" then
    return nil, "lua_eval: 'code' must be a string"
  end

  local budget,err=output.budget(args.maxBytes)
  if not budget then return nil,err end
  -- Execution remains synchronous; output limits do not interrupt an infinite user-code loop.
  local result=output.execute(args.code,budget,'=lua_eval')
  if not result.ok then return nil,output.errorText(result.err,result.output,budget) end
  result.ok=nil
  return result
end

M.def = {
  description = "Execute a Lua chunk in the GE (game-engine/world) VM; returns its value and printed "
    .. "output (4096 encoded bytes by default; truncated=true marks omitted data). "
    .. "For per-vehicle physics state use vehicle_lua_eval.",
  annotations = { readOnlyHint = false, openWorldHint = true, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = { code = { type = "string", description = "Lua source to execute" },
      maxBytes={type='integer',minimum=1024,maximum=16384,description='Encoded result budget; default 4096.'} },
    required = { "code" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("lua_eval", M.def)
end

require('beammcp/identity').stamp('beammcp/tools/lua_eval',M)
return M
