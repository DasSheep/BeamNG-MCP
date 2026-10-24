local detect = require("beammcp/reload/detect")

local M1 = "/levels/west_coast_usa/main.level.json"
local function snap(over)
  local s = { v = 1, reloadId = "abc", at = 1000, level = M1 }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

test("no file -> cold", function()
  assertEqual(detect.classify(nil, nil, 1000, M1), "cold")
  assertEqual(detect.classify("garbage", "abc", 1000, M1), "cold")
end)

test("matching blob id -> normal", function()
  assertEqual(detect.classify(snap(), "abc", 1010, M1), "normal")
end)

test("fresh file, same level, no blob id -> total", function()
  assertEqual(detect.classify(snap(), nil, 1010, M1), "total")
end)

test("file older than MAX_AGE -> stale", function()
  assertEqual(detect.classify(snap(), "abc", 1000 + detect.MAX_AGE + 1, M1), "stale")
end)

test("clock went backwards -> stale", function()
  assertEqual(detect.classify(snap(), "abc", 999, M1), "stale")
end)

test("file from a different level -> stale", function()
  assertEqual(detect.classify(snap(), nil, 1010, "/levels/italy/main.level.json"), "stale")
end)

test("blob id that does not match the file -> stale", function()
  assertEqual(detect.classify(snap(), "other", 1010, M1), "stale")
end)

test("missing timestamp -> stale", function()
  assertEqual(detect.classify(snap({ at = "x" }), "abc", 1010, M1), "stale")
end)
