require('support.beamng_stubs')
package.path = 'lua/common/?.lua;' .. package.path
local function api()
  local ok, mod = pcall(require, 'beammcp/inspect')
  assertTrue(ok, 'shared Lua inspection module must exist')
  return mod
end

test('discovery pages mixed scalar keys without gaps and preserves false', function()
  local root = { bag = { [false]=false, [3]='three', z=9, a=1 } }
  local all, offset = {}, 0
  repeat
    local r = assert(api().inspect({path={'bag'}, limit=1, offset=offset}, root))
    all[#all+1] = r.entries[1]
    offset = r.nextOffset
  until not offset
  assertEqual(#all, 4)
  assertEqual(all[1].key, false)
  assertEqual(all[1].value, false)
  assertEqual(all[2].key, 3)
  assertEqual(all[3].key, 'a')
  assertEqual(all[4].key, 'z')
end)

test('inspection never executes index pairs tostring or equality metamethods', function()
  local calls = 0
  local function trap() calls=calls+1; error('must not execute') end
  local proxy = newproxy(true)
  getmetatable(proxy).__tostring = trap
  local object = setmetatable({good=42}, {__index=trap,__pairs=trap,__tostring=trap,__eq=trap})
  local r = assert(api().inspect({detail=true}, {object=object, proxy=proxy}))
  assertEqual(#r.entries, 2)
  local missing, err = api().inspect({path={'object','missing'}}, {object=object})
  assertNil(missing)
  assertMatch(err, 'missing')
  assertEqual(calls, 0)
end)

test('explicit metatable and index steps discover methods without invoking them', function()
  local root = {obj=setmetatable({}, {__index={method=function(a,b,...) end}})}
  local r = assert(api().inspect({path={'obj',{via='index'}}, detail=true}, root))
  assertEqual(r.entries[1].key, 'method')
  assertEqual(r.entries[1].params[1], 'a')
  assertEqual(r.entries[1].params[2], 'b')
  assertEqual(r.entries[1].vararg, true)
  assertTrue(r.entries[1].line > 0)
  local m = assert(api().inspect({path={'obj',{via='metatable'}}}, root))
  assertEqual(m.entries[1].key, '__index')
end)

test('protected and functional indexes return explicit errors', function()
  local root = {hidden=setmetatable({}, {__metatable=false}), dynamic=setmetatable({}, {__index=function() error('called') end})}
  local r,e = api().inspect({path={'hidden',{via='metatable'}}}, root)
  assertNil(r); assertMatch(e, 'protected')
  r,e = api().inspect({path={'dynamic',{via='index'}}}, root)
  assertNil(r); assertMatch(e, 'function')
end)

test('filters apply before pagination; value search is explicit', function()
  local root = {alpha='needle', beta=7, gamma='other', delta=false}
  local r = assert(api().inspect({filter='NEEDLE', searchValues=true, kind='string'}, root))
  assertEqual(r.matched, 1); assertEqual(r.entries[1].key, 'alpha')
  r = assert(api().inspect({filter='needle'}, root))
  assertEqual(#r.entries, 0)
end)

test('cyclic values and nonfinite values stay JSON serializable', function()
  local root = {inf=math.huge, nan=0/0}; root.self=root
  root[{}]=true; root[string.rep('x',300)]=true
  local r = assert(api().inspect({}, root))
  assertEqual(r.omittedKeys, 2)
  assertEqual(r.matched, 3)
  assertTrue(#jsonEncode(r)>0)
end)

test('response budget includes escaped JSON and continuation is gap free', function()
  local root = {}
  for i=1,80 do root[string.format('key%03d',i)] = string.rep('\001',300) end
  local offset, seen = 0, {}
  repeat
    local r = assert(api().inspect({maxBytes=1024, preview=512, limit=100, offset=offset},root))
    assertTrue(#jsonEncode(r)<=1024)
    for _,row in ipairs(r.entries) do assertNil(seen[row.key]); seen[row.key]=true end
    assertTrue(not r.nextOffset or r.nextOffset>offset)
    offset=r.nextOffset
  until not offset
  local n=0; for _ in pairs(seen) do n=n+1 end
  assertEqual(n,80)
end)

test('oversized scans are explicit and refuse misleading offset pages', function()
  local root={}; for i=1,10001 do root[i]=i end
  local r=assert(api().inspect({},root))
  assertEqual(r.scanTruncated,true)
  assertNil(r.nextOffset)
  local v,e=api().inspect({offset=20},root)
  assertNil(v); assertMatch(e,'scan')
end)

test('invalid arguments and scalar traversal fail cleanly', function()
  for _,args in ipairs({{limit=0},{maxBytes=1},{offset=0/0},{path='foo'},{path={{via='call'}}},{detail=1},{kind='nope'},{sort='nope'},{filter=9},
    {path=false},{scope=false},{filter=false},{sort=false},{preview=false}}) do
    local r,e=api().inspect(args,{})
    assertNil(r); assertEqual(type(e),'string')
  end
  local r,e=api().inspect({path={'n','x'}},{n=42})
  assertNil(r); assertMatch(e,'table')
end)

test('value filtering includes false and protected table sentinels remain opaque', function()
  local root={flag=false,hidden=setmetatable({}, {__metatable={fake=true}})}
  local r=assert(api().inspect({filter='false',searchValues=true},root))
  assertEqual(r.matched,1); assertEqual(r.entries[1].value,false)
  local v,e=api().inspect({path={'hidden',{via='metatable'}}},root)
  assertNil(v); assertMatch(e,'protected')
end)

test('UTF-8 and binary previews remain encodable and source continuation preserves Unicode',function()
  local unicode=string.char(240,159,154,151)
  local r=assert(api().inspect({preview=5},{s=unicode..unicode,binary=string.char(255)}))
  assertEqual(r.entries[1].value,'\\xFF')
  assertEqual(r.entries[2].value,unicode)
  local src='return function()\n  return "'..string.rep(unicode,1500)..'"\nend'
  local f=assert(loadstring(src,'@unicode.lua'))()
  local chunks,offset={},0
  repeat
    local p=assert(api().source({path={'f'},offset=offset,maxBytes=1024},{f=f},function() return src end))
    assertTrue(#jsonEncode(p)<=1024)
    chunks[#chunks+1]=p.text; offset=p.nextOffset
  until not offset
  assertEqual(table.concat(chunks),src)
end)

test('direct function metadata supports boolean keys and marks native signatures unknown', function()
  local r=assert(api().inspect({path={true},detail=true},{[true]=function(id) end}))
  assertEqual(r.value.params[1],'id')
  r=assert(api().inspect({path={'sin'},detail=true},math))
  assertEqual(r.value.native,true)
  assertNil(r.value.params)
end)

test('source pages reconstruct long lines exactly within encoded budget', function()
  local src='return function(id)\n  local s="'..string.rep('x',12000)..'"\n  return id\nend\n'
  local fn=assert(loadstring(src,'@fixture.lua'))()
  local offset,out=0,{}
  repeat
    local r=assert(api().source({path={'f'},offset=offset,maxBytes=1024,limit=2},{f=fn},function(path,cap)
      assertEqual(path,'fixture.lua'); assertTrue(cap<=1024*1024); return src
    end))
    assertTrue(#jsonEncode(r)<=1024)
    out[#out+1]=r.text
    assertTrue(not r.nextOffset or r.nextOffset>offset)
    offset=r.nextOffset
  until not offset
  assertEqual(table.concat(out),src)
end)

test('source handles native chunks missing files and large files', function()
  local r=assert(api().source({path={'f'}},{f=math.sin}))
  assertEqual(r.unavailable,'native')
  r=assert(api().source({path={'f'}},{f=assert(loadstring('return 1'))}))
  assertEqual(r.unavailable,'generated chunk')
  local f=assert(loadstring('return 1','@missing.lua'))
  r=assert(api().source({path={'f'}},{f=f},function() return nil,'missing file' end))
  assertEqual(r.unavailable,'missing file')
  r=assert(api().source({path={'f'}},{f=f},function() return string.rep('x',524289) end))
  assertMatch(r.unavailable,'limit')
end)

test('source errors also respect encoded budget with escaped source names',function()
  local f=assert(loadstring('return 1','@'..string.rep('\001',240)..'.lua'))
  local r,e=api().source({path={'f'},maxBytes=1024},{f=f},function() return nil,'missing file' end)
  assertTrue((r and #jsonEncode(r)<=1024) or (not r and type(e)=='string'))
end)

test('source default VFS-compatible reader reads exact defining lines from disk',function()
  local function fixture(value)
    return value+1
  end
  local r=assert(api().source({path={'f'}},{f=fixture}))
  assertNil(r.unavailable)
  assertMatch(r.text,'local function fixture%(value%)')
  assertMatch(r.text,'return value%+1')
  assertNil(r.nextOffset)
end)
