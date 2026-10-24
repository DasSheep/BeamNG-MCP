require('support/beamng_stubs')
local json=require('json')
local function runtime(root)
 local mod=dofile('beammp/BeamMCP/lua/beammcp_server/runtime.lua')
 return mod.new({plugin='Example',generation='test1',root=root or _G,
   encode=json.encode,decode=json.decode,common='lua/common/beammcp/',allowEval=true,
   clock=os.clock,mp={GetServerVersion=function() return 3,9,3 end}})
end
test('BeamMP runtime evaluates in the selected plugin and bounds output',function()
 local root=setmetatable({counter=41,print=print},{__index=_G})
 local r=runtime(root)
 local result,err=r:call('lua_eval',{code='counter=counter+1; print("hello"); return counter'})
 assertNil(err);assertEqual(result.value,42);assertEqual(root.counter,42);assertEqual(result.output,'hello')
 local result2=r:call('lua_eval',{code='return string.rep("x",100000)',maxBytes=1024})
 assertTrue(#json.encode(result2)<=1024);assertTrue(result2.truncated)
end)
test('BeamMP inspection reads target globals and source without execution',function()
 local root={count=17,trap=function() error('must not execute') end,print=print}
 local r=runtime(root)
 local result,err=r:call('read_lua',{fields={{name='n',path={'count'}}}})
 assertNil(err);assertEqual(result.values.n,17)
 local inspected=r:call('inspect_lua',{path={'trap'}})
 assertEqual(inspected.value.type,'function')
end)
test('BeamMP eval restores print after errors and enforces opt in',function()
 local root=setmetatable({print=print},{__index=_G});local old=root.print
 local r=runtime(root)
 local result,err=r:call('lua_eval',{code='error("expected")'})
 assertNil(result);assertMatch(err,'expected');assertEqual(root.print,old)
 r.allowEval=false
 result,err=r:call('lua_eval',{code='return 1'})
 assertNil(result);assertMatch(err,'disabled')
end)
test('BeamMP rejects expired or stale queued requests before side effects',function()
 local bridge=dofile('beammp/BeamMCP/lua/beammcp_server/bridge.lua')
 local calls=0
 local function call() calls=calls+1;return {value=1} end
 local r=bridge.execute({id='abc',generation='old',expiresAt=1000,method='lua_eval',args={}},'new',0,call)
 assertTrue(r.error~=nil);assertEqual(calls,0)
 r=bridge.execute({id='abc',generation='new',expiresAt=1000,method='lua_eval',args={}},'new',1001,call)
 assertTrue(r.error~=nil);assertEqual(calls,0)
 r=bridge.execute({id='abc',generation='new',expiresAt=1000,method='lua_eval',args={}},'new',999,call)
 assertEqual(r.result.value,1);assertEqual(calls,1)
end)
test('BeamMP log paging never advances past an omitted entry when the byte budget fills',function()
 local r=runtime()
 for i=1,30 do r:record('log',{text=string.rep('x',800)..i}) end
 local cursor,seen=0,{}
 for _=1,40 do
   local page,err=r:call('console_logs',{cursor=cursor,limit=100,maxBytes=1024})
   assertNil(err);assertTrue(#json.encode(page)<=1024)
   for _,entry in ipairs(page.entries) do
     assertTrue(not seen[entry.cursor]);seen[entry.cursor]=true
   end
   if page.cursor==cursor then break end
   cursor=page.cursor
 end
 local total=0;for _ in pairs(seen) do total=total+1 end
 assertEqual(total,30);assertEqual(cursor,30)
end)
