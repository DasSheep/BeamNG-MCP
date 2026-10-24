local bridge = require("beammcp/async/ve_bridge")

-- ve_bridge is a shared singleton (state must survive across the tool's require and the
-- queueGameEngineLua callback's require), so reset its fields between tests.
local function reset() bridge.pending = {}; bridge.seq = 0 end

test("begin returns strictly increasing ids and creates not-ready slots", function()
  reset()
  local a = bridge.begin()
  local b = bridge.begin()
  assertEqual(a, 1)
  assertEqual(b, 2)
  assertTrue(not bridge.isReady(a))
  assertTrue(not bridge.isReady(b))
end)

test("resolve fills the slot; isReady flips; take returns json and clears", function()
  reset()
  local id = bridge.begin()
  bridge.resolve(id, '{"ok":true}')
  assertTrue(bridge.isReady(id))
  assertEqual(bridge.take(id), '{"ok":true}')
  assertTrue(not bridge.isReady(id))      -- slot cleared by take
end)

test("take on an unresolved slot returns nil and clears it (timeout abandon)", function()
  reset()
  local id = bridge.begin()
  assertNil(bridge.take(id))
  assertTrue(not bridge.isReady(id))
end)

test("resolve for an unknown id is a no-op", function()
  reset()
  bridge.resolve(999, '{"x":1}')
  assertTrue(not bridge.isReady(999))
end)

test("late resolve after take is dropped (no cross-talk)", function()
  reset()
  local id = bridge.begin()
  bridge.take(id)                          -- abandon, e.g. on timeout
  bridge.resolve(id, '{"late":true}')      -- straggler callback arrives
  assertTrue(not bridge.isReady(id))
end)

test("resolve stores only the first response (idempotent)", function()
  reset()
  local id = bridge.begin()
  bridge.resolve(id, '{"first":true}')
  bridge.resolve(id, '{"second":true}')
  assertEqual(bridge.take(id), '{"first":true}')
end)

-- wrapVE builds a string of VE-VM Lua; its four payload branches (compile/runtime error,
-- success-serializable, not-serializable) reference VE-runtime globals (jsonEncode/serialize/obj),
-- so they're exercised in-engine, not off-engine. Off-engine we assert the string's structure.
test("wrapVE embeds the user code, a loadstring, and a resolve call with the id", function()
  reset()
  local fakeSerialize = function(s) return string.format("%q", s) end
  local out = bridge.wrapVE(7, "return electrics.values.rpm", fakeSerialize)
  assertMatch(out, "loadstring")
  assertMatch(out, "electrics%.values%.rpm")     -- the user code is embedded (via serialize)
  assertMatch(out, "queueGameEngineLua")
  assertMatch(out, "ve_bridge")
  assertMatch(out, "resolve%(7,")                 -- resolves the correct correlation id
end)

test("wrapVE uses the injected serialize to quote the code (not raw interpolation)", function()
  reset()
  local called = false
  local fakeSerialize = function(s) called = true; return '"<CODE>"' end
  local out = bridge.wrapVE(3, "anything", fakeSerialize)
  assertTrue(called)
  assertMatch(out, "<CODE>")
end)

test('vehicle wrapper caps payload before crossing the callback bridge',function()
  require('support.beamng_stubs')
  local oldObj,oldSerialize=obj,serialize
  local queued
  _G.serialize=function(s) return string.format('%q',s) end
  _G.obj={queueGameEngineLua=function(_,code) queued=code end}
  local id=bridge.begin()
  local chunk=bridge.wrapVE(id,"print(string.rep('x',10000)); return string.rep('y',10000)",serialize,1024)
  local ok,err=pcall(assert(loadstring(chunk)))
  _G.obj=oldObj; _G.serialize=oldSerialize
  assertTrue(ok,err)
  assert(loadstring(queued))()
  local raw=bridge.take(id)
  assertTrue(#raw<=1024)
  assertEqual(jsonDecode(raw).truncated,true)
end)
