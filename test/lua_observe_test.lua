require('support.beamng_stubs')
local function tools()
  local ok,m=pcall(require,'beammcp/tools/lua_observe'); assertTrue(ok,'observation tools must exist'); return m
end
test('selected values are raw leaves with per-field missing errors',function()
  local ok,m=pcall(require,'beammcp/observe'); assertTrue(ok,'shared snapshot module must exist')
  local root={flag=false,n=42,t={}}; root.t.self=root.t
  local r=assert(m.snapshot({fields={{name='n',path={'n'}},{name='flag',path={'flag'}},{name='table',path={'t'}},{name='absent',path={'missing'}}}},root))
  assertEqual(r.values.n,42); assertEqual(r.values.flag,false)
  assertEqual(r.values.table.type,'table'); assertMatch(r.unavailable.absent,'missing')
end)
local function fake(fn)
  local m=tools(); local oldFetch,oldNow,oldSleep,oldResolve=m.fetch,m.now,m.sleep,m.resolve
  local time,calls=0,0
  m.now=function() return time end
  m.sleep=function(dt) time=time+dt end
  m.resolve=function(a) return a end
  m.fetch=function() calls=calls+1; return {values={rpm=calls*10,flag=false}} end
  local ok,err=pcall(fn,m,function() return calls,time end)
  m.fetch=oldFetch;m.now=oldNow;m.sleep=oldSleep;m.resolve=oldResolve
  assertTrue(ok,err)
end
test('sampling summarizes numeric ranges and changes without returning samples by default',function()
  fake(function(m,state)
    local r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=0.25,interval=0.1}))
    assertEqual(r.count,3);assertEqual(r.summary.rpm.min,10);assertEqual(r.summary.rpm.max,30)
    assertEqual(r.summary.rpm.changes,2);assertNil(r.samples);assertEqual(r.status,'complete')
    local calls,time=state();assertEqual(calls,3);assertTrue(time<=0.251)
  end)
end)
test('wait stops on typed condition and timeout is explicit',function()
  fake(function(m)
    local r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=1,interval=0.1,
      condition={field='rpm',op='ge',value=30}}))
    assertEqual(r.status,'matched');assertEqual(r.count,3)
    r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=0.1,interval=0.1,
      condition={field='rpm',op='gt',value=999}}))
    assertEqual(r.status,'timeout')
  end)
end)
test('truncated string preview cannot falsely satisfy an equality condition',function()
  fake(function(m)
    m.fetch=function() return {values={rpm='prefix'},truncatedFields={rpm=true}} end
    local r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=0.1,interval=0.1,
      condition={field='rpm',op='eq',value='prefix'}}))
    assertEqual(r.status,'timeout')
  end)
end)
test('observation bounds optional samples and releases slot after read failure',function()
  fake(function(m)
    m.fetch=function() return {values={rpm=string.rep('\001',512)}} end
    local r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=1,interval=0.05,samples=true,maxBytes=1024}))
    assertTrue(#jsonEncode(r)<=1024);assertTrue(r.truncated or r.samplesTruncated)
    m.fetch=function() error('gone') end
    local v,e=m.observe.handler({fields={{name='rpm',path={'rpm'}}}})
    assertNil(v);assertMatch(e,'gone');assertEqual(m.active,0)
  end)
end)
test('observation rejects costly or malformed requests before reading',function()
  fake(function(m)
    m.fetch=function() error('must not read') end
    for _,args in ipairs({{fields={}},{fields={{name='a',path={}},{name='a',path={}}}},
      {fields={{name='a',path={}}},interval=0.001},{fields={{name='a',path={}}},duration=100},
      {fields={{name='a',path={}}},condition={field='missing',op='exists'}}}) do
      local r,e=m.observe.handler(args);assertNil(r);assertEqual(type(e),'string')
    end
  end)
end)
test('nonfinite selected numbers are unavailable rather than string values',function()
  local r=assert(require('beammcp/observe').snapshot({fields={{name='n',path={'n'}}}},{n=math.huge}))
  assertNil(r.values.n);assertMatch(r.unavailable.n,'finite')
end)
test('changed cannot use a truncated or opaque baseline and ne cannot match an object',function()
  fake(function(m)
    for _,op in ipairs({'changed','ne'}) do
      local calls=0
      m.fetch=function()
        calls=calls+1
        if calls==1 then return {values={rpm='prefix'},truncatedFields={rpm=true}} end
        return {values={rpm={type='table'}}}
      end
      local r=assert(m.observe.handler({fields={{name='rpm',path={'rpm'}}},duration=0.25,interval=0.1,
        condition={field='rpm',op=op,value=10}}))
      assertEqual(r.status,'timeout')
    end
  end)
end)
test('observation pins player identity once and rejects a third active request',function()
  local resolve=tools().resolve
  local oldBe=be
  local ok,err=pcall(function()
    fake(function(m)
      local player,lookups=45,0
      _G.be={getPlayerVehicleID=function() lookups=lookups+1;return player end,getObjectByID=function() return {} end}
      m.resolve=resolve
      m.fetch=function(a) assertEqual(a.id,45);player=99;return {values={rpm=10}} end
      local r=assert(m.observe.handler({scope='vehicle',fields={{name='rpm',path={'rpm'}}},duration=0.25,interval=0.1}))
      assertEqual(r.vehicleId,45);assertEqual(lookups,1);assertEqual(r.count,3)
      m.active=2
      local v,e=m.observe.handler({fields={{name='rpm',path={'rpm'}}}})
      m.active=0
      assertNil(v);assertMatch(e,'already active')
    end)
  end)
  _G.be=oldBe;tools().active=0;assertTrue(ok,err)
end)
test('minimum budget preserves complete status and scope under a large summary',function()
  fake(function(m)
    local fields,values={},{}
    for i=1,16 do
      local name=string.rep('a',30)..string.format('%02d',i)
      fields[i]={name=name,path={'x'}};values[name]=string.rep('\001',512)
    end
    local calls=0
    m.fetch=function() calls=calls+1;if calls==1 then return {values=values} end;return nil,'vehicle gone' end
    local r=assert(m.observe.handler({scope='vehicle',id=45,fields=fields,preview=512,maxBytes=1024}))
    assertEqual(r.status,'unavailable');assertEqual(r.scope,'vehicle');assertEqual(r.vehicleId,45)
    assertEqual(r.count,1);assertTrue(#jsonEncode(r)<=1024);assertTrue(r.truncated)
  end)
end)
