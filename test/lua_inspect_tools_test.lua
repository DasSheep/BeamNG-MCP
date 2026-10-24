require('support.beamng_stubs')
package.path='lua/common/?.lua;'..package.path
local function tools()
  local ok,mod=pcall(require,'beammcp/tools/lua_inspect')
  assertTrue(ok,'Lua inspection tool adapter must exist')
  return mod
end

test('register exposes two read-only tools with compact descriptions',function()
  local r=require('core.registry').new()
  tools().register(r)
  assertEqual(#r:list(),2)
  assertEqual(r:list()[1].name,'inspect_lua')
  assertEqual(r:list()[2].name,'get_lua_source')
  for _,d in ipairs(r:list()) do
    assertEqual(d.annotations.readOnlyHint,true)
    assertTrue(#d.description<600)
  end
end)

test('GE inspection works through the MCP JSON-RPC boundary',function()
  local reg=require('core.registry').new(); tools().register(reg)
  local rpc=require('core.jsonrpc').new()
  require('core.methods').register(rpc,reg)
  local out=jsonDecode(rpc:handle(jsonEncode({jsonrpc='2.0',id=1,method='tools/call',
    params={name='inspect_lua',arguments={path={'math'},kind='function',limit=3}}})))
  assertEqual(out.result.isError,false)
  local value=jsonDecode(out.result.content[1].text)
  assertEqual(#value.entries,3)
  assertTrue(value.nextOffset>0)
end)

test('vehicle route uses existing eval error handling and same shared implementation',function()
  local vle=require('beammcp/tools/vehicle_lua_eval')
  local oldEval,oldBe,oldSerialize=vle.evalVE,be,serialize
  local selected,queued
  _G.be={getPlayerVehicleID=function() return 45 end,getObjectByID=function(_,id) selected=id; return id==45 and {} or nil end}
  _G.serialize=function(s) return string.format('%q',s) end
  vle.evalVE=function(_,code)
    queued=code
    local ok,result=pcall(assert(loadstring(code)))
    return {ok=ok,value=ok and result or nil,err=not ok and result or nil,output=''}
  end
  local ok,err=pcall(function()
    local r=assert(tools().inspect.handler({scope='vehicle',path={'math'},kind='function',limit=2}))
    assertEqual(#r.entries,2); assertEqual(selected,45)
    assertMatch(queued,'beammcp/inspect')
    local src=assert(tools().source.handler({scope='vehicle',id=45,path={'math','sin'}}))
    assertEqual(src.unavailable,'native')
    local missing,e=tools().inspect.handler({scope='vehicle',id=99})
    assertNil(missing); assertMatch(e,'unknown vehicle')
    vle.evalVE=function() return nil end
    missing,e=tools().inspect.handler({scope='vehicle'})
    assertNil(missing); assertMatch(e,'no response')
  end)
  vle.evalVE=oldEval; _G.be=oldBe; _G.serialize=oldSerialize
  assertTrue(ok,err)
end)

test('vehicle arguments are validated before any command is queued',function()
  local vle=require('beammcp/tools/vehicle_lua_eval')
  local old=vle.evalVE
  vle.evalVE=function() error('must not queue') end
  local ok,err=pcall(function()
    for _,a in ipairs({{scope='vehicle',id=0/0},{scope='vehicle',path='return 1'},{scope='vehicle',maxBytes=999999}}) do
      local r,e=tools().inspect.handler(a); assertNil(r); assertEqual(type(e),'string')
    end
  end)
  vle.evalVE=old
  assertTrue(ok,err)
end)
