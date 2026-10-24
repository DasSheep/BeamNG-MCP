local config_arg = require("beammcp/tools/lib/config_arg")

-- normalize: (value, ok, err)
test("normalize: nil is valid, returns nil value", function()
  local v, ok, err = config_arg.normalize(nil, "spawn_vehicle")
  assertNil(v); assertTrue(ok); assertNil(err)
end)

test("normalize: a string passes through", function()
  local v, ok, err = config_arg.normalize("base", "spawn_vehicle")
  assertEqual(v, "base"); assertTrue(ok); assertNil(err)
end)

test("normalize: a table passes through (no shape validation)", function()
  local t = { parts = { body = "x" } }
  local v, ok, err = config_arg.normalize(t, "spawn_vehicle")
  assertEqual(v, t); assertTrue(ok); assertNil(err)
end)

test("normalize: a number is rejected with the label prefix", function()
  local v, ok, err = config_arg.normalize(5, "spawn_vehicle")
  assertNil(v); assertEqual(ok, false)
  assertMatch(err, "spawn_vehicle: 'config' must be a string or a table")
end)

test("normalize: a boolean is rejected", function()
  local v, ok, err = config_arg.normalize(true, "set_config")
  assertNil(v); assertEqual(ok, false)
  assertMatch(err, "set_config: 'config' must be a string or a table")
end)

-- summarize: compact echo for the return shape
test("summarize: a string returns itself", function()
  assertEqual(config_arg.summarize("base"), "base")
end)

test("summarize: nil returns nil", function()
  assertNil(config_arg.summarize(nil))
end)

test("summarize: a table returns {inline=true, parts=<count>}", function()
  local s = config_arg.summarize({ parts = { a = "x", b = "y", c = "" } })
  assertEqual(s.inline, true)
  assertEqual(s.parts, 3)
end)

test("summarize: a table with no parts reports 0", function()
  local s = config_arg.summarize({ vars = { x = 1 } })
  assertEqual(s.inline, true)
  assertEqual(s.parts, 0)
end)

test("summarize: a table whose parts is not a table reports 0 (no crash)", function()
  local s = config_arg.summarize({ parts = "engine_I4" })
  assertEqual(s.inline, true)
  assertEqual(s.parts, 0)
end)
