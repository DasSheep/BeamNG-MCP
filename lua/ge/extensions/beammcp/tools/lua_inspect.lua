-- Compact API discovery and opt-in source excerpts. Both VMs use the same raw inspector.
local inspector=require('beammcp/inspect')
local vehicleRead=require('beammcp/tools/lib/ve_read')
local M={}

local function handler(operation)
  return function(args)
    local a,err=inspector.validate(args,operation=='source')
    if not a then return nil,err end
    if a.scope=='ge' then return inspector[operation](a) end
    -- Quote JSON as a Lua string; paths are data, never Lua expressions. Reuse correlation,
    -- vehicle selection, timeout and late-reply handling from the existing eval route.
    local code='local r,e=require("beammcp/inspect").'..operation
      ..'(jsonDecode('..serialize(jsonEncode(a))..')); if e then error(e,0) end; return r'
    return vehicleRead.run(a.id,code,'inspect_lua')
  end
end

local function schema(source)
  local properties={
    path={type='array',maxItems=24,description='Raw keys from _G; e.g. ["powertrain"]. Use {"via":"metatable"} or {"via":"index"} steps to browse methods.',
      items={anyOf={{type='string',maxLength=256},{type='number'},{type='boolean'},
        {type='object',properties={via={type='string',enum={'metatable','index'}}},required={'via'},additionalProperties=false}}}},
    scope={type='string',enum={'ge','vehicle'},description='Default ge; vehicle uses player unless id supplied.'},
    id={type='integer',minimum=0,maximum=2147483647},
    limit={type='integer',minimum=1,maximum=100,description=source and 'Max lines per page; default 40.' or 'Max entries per page; default 20.'},
    offset={type='integer',minimum=0,maximum=source and 524288 or 10000,
      description=source and 'Byte offset within function source; use nextOffset.' or 'Sorted match offset; use nextOffset on an unchanged table.'},
    maxBytes={type='integer',minimum=1024,maximum=16384,description='Encoded result budget; default 4096 bytes.'},
  }
  if not source then
    properties.filter={type='string',maxLength=128,description='Case-insensitive literal substring of key.'}
    properties.kind={type='string',enum={'table','function','string','number','boolean','userdata','cdata','thread'}}
    properties.searchValues={type='boolean',description='Also search bounded scalar previews.'}
    properties.sort={type='string',enum={'key','type','value'},description='Default key; value sorts bounded previews as text.'}
    properties.detail={type='boolean',description='Include function parameters and source locations; default false.'}
    properties.preview={type='integer',minimum=0,maximum=512,description='String preview bytes; default 128.'}
  end
  return {type='object',properties=properties,additionalProperties=false}
end

M.inspect={
  description='Discover live Lua APIs/state without executing inspected code. One table level, compact by default; narrow path/filter/kind before detail=true. Explicit metatable/index paths never invoke metamethods. nextOffset pages unchanged tables; scanTruncated means narrow the path (10k-key scan cap). Opaque/oversized keys are counted as omittedKeys.',
  annotations={readOnlyHint=true,destructiveHint=false,openWorldHint=false},
  inputSchema=schema(false),handler=handler('inspect'),
}
M.source={
  description='Read the defining Lua source of a function path in GE or vehicle Lua. Returns source, line, text and nextOffset (byte continuation); native/generated/missing sources report unavailable. Default 40 lines/4096 encoded bytes; files over 512 KiB are refused. Reads current disk source; live debug line metadata may be stale after edits.',
  annotations={readOnlyHint=true,destructiveHint=false,openWorldHint=false},
  inputSchema=schema(true),handler=handler('source'),
}
function M.register(registry)
  registry:add('inspect_lua',M.inspect)
  registry:add('get_lua_source',M.source)
end
require('beammcp/identity').stamp('beammcp/tools/lua_inspect',M)
return M
