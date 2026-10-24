local logfmt = require("beammcp/tools/lib/logfmt")

test("parses a well-formed line and strips the single leading msg space", function()
  local e = logfmt.parse("986.577|D|GELua.core_vehicleBridge.| Registering value")
  assertEqual(e.time, 986.577)
  assertEqual(e.level, "D")
  assertEqual(e.tag, "GELua.core_vehicleBridge.")
  assertEqual(e.msg, "Registering value")
end)

test("keeps pipes that occur inside the message", function()
  local e = logfmt.parse("12.3|I|tag| a|b|c")
  assertEqual(e.msg, "a|b|c")
end)

test("returns nil for a line with no pipes (tolerates a partial final line)", function()
  assertNil(logfmt.parse("truncated line fragment"))
end)

test("levelRank orders D < I < W < E and unknown ranks 0", function()
  assertTrue(logfmt.levelRank("D") < logfmt.levelRank("I"))
  assertTrue(logfmt.levelRank("I") < logfmt.levelRank("W"))
  assertTrue(logfmt.levelRank("W") < logfmt.levelRank("E"))
  assertEqual(logfmt.levelRank("?"), 0)
end)

-- matches: pure predicate (level / tag / match), case-insensitive substring for tag+match.
test("matches: no opts -> everything passes", function()
  assertTrue(logfmt.matches({ level = "D", tag = "t", msg = "m" }, {}))
  assertTrue(logfmt.matches({ level = "D", tag = "t", msg = "m" }, nil))
end)

test("matches: level is at-or-above minimum", function()
  assertTrue(logfmt.matches({ level = "E", tag = "t", msg = "m" }, { level = "W" }))
  assertTrue(not logfmt.matches({ level = "D", tag = "t", msg = "m" }, { level = "W" }))
end)

test("matches: tag is a case-insensitive substring of the entry tag", function()
  assertTrue(logfmt.matches({ level = "I", tag = "GELua.core", msg = "m" }, { tag = "gelua" }))
  assertTrue(not logfmt.matches({ level = "I", tag = "GELua.core", msg = "m" }, { tag = "vehicle" }))
end)

test("matches: match is a case-insensitive substring of the message", function()
  assertTrue(logfmt.matches({ level = "I", tag = "t", msg = "Connection FAILED" }, { match = "failed" }))
  assertTrue(not logfmt.matches({ level = "I", tag = "t", msg = "ok" }, { match = "failed" }))
end)

test("matches: filters combine (AND)", function()
  local e = { level = "E", tag = "net", msg = "socket error" }
  assertTrue(logfmt.matches(e, { level = "W", tag = "net", match = "error" }))
  assertTrue(not logfmt.matches(e, { level = "W", tag = "net", match = "timeout" }))
end)

-- select: filter an entries array by matches() then take the last `limit`; returns (entries, total).
test("select: filters then takes the last limit, reporting the true total", function()
  local entries = {
    { level = "I", tag = "t", msg = "a" },
    { level = "E", tag = "t", msg = "b" },
    { level = "E", tag = "t", msg = "c" },
    { level = "E", tag = "t", msg = "d" },
  }
  local out, total = logfmt.select(entries, { level = "W", limit = 2 })
  assertEqual(total, 3)        -- 3 entries at/above W
  assertEqual(#out, 2)         -- last 2 of them
  assertEqual(out[1].msg, "c")
  assertEqual(out[2].msg, "d")
end)

test("select: no limit returns all matching + total", function()
  local entries = { { level = "I", tag = "t", msg = "a" }, { level = "I", tag = "t", msg = "b" } }
  local out, total = logfmt.select(entries, {})
  assertEqual(#out, 2)
  assertEqual(total, 2)
end)

-- tail: parse contents then select; opts table {limit, level, tag, match}.
test("tail returns the last `limit` parseable entries and drops garbage lines", function()
  local contents = "1|I|t| a\n2|I|t| b\n3|I|t| c\ngarbage-no-pipes"
  local out, total = logfmt.tail(contents, { limit = 2 })
  assertEqual(#out, 2)
  assertEqual(total, 3)
  assertEqual(out[1].msg, "b")
  assertEqual(out[2].msg, "c")
end)

test("tail filters to entries at or above minLevel", function()
  local contents = "1|D|t| dbg\n2|W|t| warn\n3|E|t| err"
  local out = logfmt.tail(contents, { level = "W" })
  assertEqual(#out, 2)
  assertEqual(out[1].level, "W")
  assertEqual(out[2].level, "E")
end)

test("tail supports tag + match filters", function()
  local contents = "1|I|net| connecting\n2|E|net| socket error\n3|E|disk| io error"
  local out = logfmt.tail(contents, { tag = "net", match = "error" })
  assertEqual(#out, 1)
  assertEqual(out[1].msg, "socket error")
end)
