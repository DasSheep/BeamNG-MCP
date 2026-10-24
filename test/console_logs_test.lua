require("support.beamng_stubs")
local console_logs = require("beammcp/tools/console_logs")
local logcapture   = require("beammcp/logcapture")
local registry     = require("core.registry")
local originalReadLogFile = console_logs.readLogFile

test("buffer source returns recent ring entries (default source)", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ now = function() return 1 end })
  _G.log("E", "t", "boom")
  local res = console_logs.def.handler({})        -- no args -> source defaults to "buffer"
  assertEqual(res.source, "buffer")
  assertEqual(#res.entries, 1)
  assertEqual(res.entries[1].msg, "boom")
  logcapture.reset()
end)

test("file source parses the log file contents and filters by level", function()
  console_logs.readLogFile = function() return "1|I|t| info\n2|E|t| err" end
  local res = console_logs.def.handler({ source = "file", level = "E" })
  assertEqual(res.source, "file")
  assertEqual(#res.entries, 1)
  assertEqual(res.entries[1].msg, "err")
end)

test("file source returns nil + message when the log file is unreadable", function()
  console_logs.readLogFile = function() return nil end
  local res, err = console_logs.def.handler({ source = "file" })
  assertNil(res)
  assertMatch(err, "cannot read")
end)

test("an unknown source is rejected", function()
  local res, err = console_logs.def.handler({ source = "nope" })
  assertNil(res)
  assertMatch(err, "source must be")
end)

test("buffer source supports a tag filter", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ now = function() return 1 end })
  _G.log("I", "net", "connecting")
  _G.log("E", "disk", "io error")
  local res = console_logs.def.handler({ tag = "net" })
  assertEqual(#res.entries, 1)
  assertEqual(res.entries[1].tag, "net")
  logcapture.reset()
end)

test("file source supports a match (message substring) filter", function()
  console_logs.readLogFile = function() return "1|I|t| connecting\n2|E|t| socket error" end
  local res = console_logs.def.handler({ source = "file", match = "error" })
  assertEqual(#res.entries, 1)
  assertEqual(res.entries[1].msg, "socket error")
end)

test("limit clamps to the hard max of 200 and notes both truncation and the cap", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ cap = 300, now = function() return 1 end })
  for i = 1, 250 do _G.log("I", "t", "m" .. i) end
  local res = console_logs.def.handler({ limit = 500, maxBytes = 16384 })
  assertEqual(#res.entries, 200)            -- clamped to the hard max
  assertEqual(res.entries[200].msg, "m250") -- newest last
  assertMatch(res.note, "200 of 250")
  assertMatch(res.note, "capped at 200")
  logcapture.reset()
end)

test("a truncation under the cap notes the total but not the cap", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ cap = 300, now = function() return 1 end })
  for i = 1, 60 do _G.log("I", "t", "m" .. i) end
  local res = console_logs.def.handler({ limit = 10 })
  assertEqual(#res.entries, 10)
  assertMatch(res.note, "10 of 60")
  assertEqual(res.note:find("capped"), nil)   -- requested 10 is below the hard cap
  logcapture.reset()
end)

test("no note when nothing is truncated", function()
  logcapture.reset()
  _G.log = function() end
  logcapture.install({ now = function() return 1 end })
  _G.log("I", "t", "only one")
  local res = console_logs.def.handler({})
  assertEqual(#res.entries, 1)
  assertNil(res.note)
  logcapture.reset()
end)

test("rejects non-string tag/match and non-number limit", function()
  local r1, e1 = console_logs.def.handler({ tag = 7 })
  assertNil(r1); assertMatch(e1, "'tag' must be a string")
  local r2, e2 = console_logs.def.handler({ match = {} })
  assertNil(r2); assertMatch(e2, "'match' must be a string")
  local r3, e3 = console_logs.def.handler({ limit = "x" })
  assertNil(r3); assertMatch(e3, "'limit' must be a number")
end)

test("register adds it under 'console_logs'", function()
  local r = registry.new()
  console_logs.register(r)
  assertEqual(r:list()[1].name, "console_logs")
end)

test("limit below 1 is rejected (not an empty 'Showing last 0' result)", function()
  local res, err = console_logs.def.handler({ limit = 0 })
  assertNil(res)
  assertMatch(err, "'limit' must be >= 1")
end)
console_logs.readLogFile = originalReadLogFile
