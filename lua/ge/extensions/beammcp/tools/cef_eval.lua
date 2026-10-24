-- cef_eval: evaluate arbitrary JS in a BeamNG CEF page over the -cefdev CDP endpoint — the CEF twin of
-- lua_eval/vehicle_lua_eval. The engine-coupled round-trip (discover target -> connect -> Runtime.evaluate)
-- lives in M.evalCEF (stubbed in tests, verified in-engine); handler/shaping is pure. Returns {value}.
local targets = require("beammcp/cdp/targets")
local cdpclient = require("beammcp/cdp/client")
local output = require('beammcp/output')

local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine): discover the CEF target, connect, evaluate.
-- Returns ok, valueOrErr.
function M.evalCEF(code, target)
  local list, derr = targets.discover(targets.realHttpGet)
  if not list then return false, derr end
  local wsUrl, serr = targets.select(list, target)
  if not wsUrl then return false, serr end
  return cdpclient.eval(cdpclient.realWsConnect, wsUrl, code)
end

local function handler(args)
  if type(args) ~= "table" or type(args.code) ~= "string" or args.code == "" then
    return nil, "cef_eval: 'code' must be a non-empty string"
  end
  local budget,err=output.budget(args.maxBytes)
  if not budget then return nil,err end
  if args.target~=nil and type(args.target)~='string' then return nil,'target must be a string' end
  local ok, valueOrErr = M.evalCEF(args.code, args.target)
  if not ok then return nil, output.errorText(valueOrErr,nil,budget) end
  return output.fit({ value = valueOrErr },budget)
end

M.def = {
  description = "Evaluate JavaScript in a BeamNG CEF page's JS context over the -cefdev CDP endpoint "
    .. "and return the value. The CEF twin of lua_eval/vehicle_lua_eval. Requires BeamNG launched with "
    .. "-cefdev. Default result budget 4096 encoded bytes; truncated=true marks omitted data.",
  annotations = { readOnlyHint = false, openWorldHint = true, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      code = { type = "string", description = "JavaScript to evaluate in the CEF context" },
      target = { type = "string", description = "CEF page by title/url substring (default: Main UI)" },
      maxBytes={type='integer',minimum=1024,maximum=16384,description='Encoded result budget; default 4096.'},
    },
    required = { "code" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("cef_eval", M.def)
end

require('beammcp/identity').stamp('beammcp/tools/cef_eval',M)
return M
