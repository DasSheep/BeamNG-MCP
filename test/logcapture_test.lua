require("support.beamng_stubs")
local logcapture = require("beammcp/logcapture")

test("install wraps _G.log: records the entry AND chains to the original", function()
  logcapture.reset()
  local seen = {}
  _G.log = function(level, tag, msg) seen[#seen + 1] = { level, tag, msg } end
  logcapture.install({ now = function() return 7 end })
  _G.log("I", "mytag", "hello")
  assertEqual(#seen, 1)                 -- original still called
  assertEqual(seen[1][3], "hello")
  local recent = logcapture.recent()
  assertEqual(#recent, 1)
  assertEqual(recent[1].time, 7)
  assertEqual(recent[1].level, "I")
  assertEqual(recent[1].tag, "mytag")
  assertEqual(recent[1].msg, "hello")
  logcapture.reset()
end)

test("install is idempotent (second call does not double-wrap)", function()
  logcapture.reset()
  local count = 0
  _G.log = function() count = count + 1 end
  logcapture.install()
  logcapture.install()
  _G.log("I", "t", "m")
  assertEqual(count, 1)
  logcapture.reset()
end)

test("ring is bounded: oldest entries are evicted beyond cap", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ cap = 2 })
  _G.log("I", "t", "a")
  _G.log("I", "t", "b")
  _G.log("I", "t", "c")
  local recent = logcapture.recent()
  assertEqual(#recent, 2)
  assertEqual(recent[1].msg, "b")
  assertEqual(recent[2].msg, "c")
  logcapture.reset()
end)

test("recent filters by minLevel and honors limit (opts form)", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install()
  _G.log("D", "t", "dbg")
  _G.log("E", "t", "err1")
  _G.log("E", "t", "err2")
  local errs, total = logcapture.recent({ limit = 1, level = "W" })
  assertEqual(#errs, 1)
  assertEqual(errs[1].msg, "err2")
  assertEqual(total, 2)   -- two entries at/above W before the limit
  logcapture.reset()
end)

test("recent delegates tag/match filtering to logfmt.select", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install()
  _G.log("I", "net", "connecting")
  _G.log("E", "net", "socket error")
  _G.log("E", "disk", "io error")
  local out = logcapture.recent({ tag = "net", match = "error" })
  assertEqual(#out, 1)
  assertEqual(out[1].msg, "socket error")
  logcapture.reset()
end)

test("reset restores the original _G.log", function()
  logcapture.reset()
  local original = function() end
  _G.log = original
  logcapture.install()
  assertTrue(_G.log ~= original)
  logcapture.reset()
  assertEqual(_G.log, original)
end)

test("ring survives multiple wraparounds: order preserved, exactly cap entries", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ cap = 3 })
  for n = 1, 10 do _G.log("I", "t", "m" .. n) end   -- wraps the cap-3 ring three times
  local recent = logcapture.recent()
  assertEqual(#recent, 3)
  assertEqual(recent[1].msg, "m8")
  assertEqual(recent[2].msg, "m9")
  assertEqual(recent[3].msg, "m10")
  logcapture.reset()
end)
