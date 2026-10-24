require('support.beamng_stubs')
local bridge=require('beammcp/async/ve_bridge')
local function fixture(fn)
  local key='beammcp/async/sleep'
  local oldSleep,oldSerialize,oldObj=package.loaded[key],serialize,obj
  local time=0
  package.loaded[key]=function(dt) time=time+dt end
  _G.serialize=function(s) return string.format('%q',s) end
  local evaluator=dofile('lua/ge/extensions/beammcp/tools/vehicle_lua_eval.lua')
  evaluator.now=function() return time end
  bridge.pending={};bridge.seq=0
  local ok,err=pcall(fn,evaluator,function() return time end)
  package.loaded[key]=oldSleep;_G.serialize=oldSerialize;_G.obj=oldObj
  assertTrue(ok,err)
end
test('real vehicle bridge preserves source pages larger than the public default budget',function()
  fixture(function(e)
    _G.obj={queueGameEngineLua=function(_,code) assert(loadstring(code))() end}
    local v={queueLuaCommand=function(_,code) assert(loadstring(code))() end}
    local r=assert(e.evalVE(v,"return {text=string.rep('x',12000)}"))
    assertEqual(r.ok,true);assertEqual(#r.value.text,12000);assertNil(next(bridge.pending))
  end)
end)
test('real vehicle await uses subsecond deadlines and discards late replies',function()
  fixture(function(e,now)
    local v={queueLuaCommand=function() end}
    assertNil(e.evalVE(v,'return 1',nil,0.05));assertTrue(now()<=0.050001)
    assertNil(next(bridge.pending));bridge.resolve(1,'{"ok":true}');assertNil(next(bridge.pending))
  end)
end)
test('vehicle queue failure releases the correlation slot',function()
  fixture(function(e)
    local r=e.evalVE({queueLuaCommand=function() error('vehicle gone') end},'return 1')
    assertEqual(r.ok,false);assertMatch(r.err,'vehicle gone');assertNil(next(bridge.pending))
  end)
end)
