local await = require("beammcp/async/await")

test("returns true immediately when the predicate is already ready (no sleeps)", function()
  local sleeps = 0
  local ok = await.await(function() return true end,
    { sleep = function() sleeps = sleeps + 1 end, now = function() return 0 end })
  assertTrue(ok)
  assertEqual(sleeps, 0)
end)

test("polls until ready, sleeping once per not-ready check", function()
  local calls = 0
  local ready = function() calls = calls + 1; return calls > 3 end  -- false on 1..3, true on 4
  local t, sleeps = 0, 0
  local ok = await.await(ready, {
    sleep = function(d) sleeps = sleeps + 1; t = t + d end,
    now = function() return t end,
    timeoutSec = 5, pollSec = 0.1,
  })
  assertTrue(ok)
  assertEqual(sleeps, 3)
end)

test("returns false once the timeout elapses", function()
  local t = 0
  local ok = await.await(function() return false end, {
    sleep = function(d) t = t + d end,
    now = function() return t end,
    timeoutSec = 1, pollSec = 0.3,
  })
  assertTrue(not ok)
end)
test('short timeouts do not request sleep beyond the remaining deadline',function()
  local t=0
  assertEqual(await.await(function() return false end,{now=function() return t end,
    sleep=function(dt) t=t+dt end,timeoutSec=0.01,pollSec=0.03}),false)
  assertTrue(t<=0.010001)
end)
