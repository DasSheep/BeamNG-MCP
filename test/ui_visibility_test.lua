local registry = require("core.registry")
local ui = require("beammcp/tools/ui_visibility")

-- Install recording fakes over the engine seam (the handlers call M.setCef/M.setImgui/M.readState,
-- never the ui_visibility global directly, so no global stub is needed). `state` backs readState.
local function stub(state)
  local calls = { cef = {}, imgui = {} }
  ui.setCef = function(v) calls.cef[#calls.cef + 1] = v; state.cef = v end
  ui.setImgui = function(v) calls.imgui[#calls.imgui + 1] = v; state.imgui = v end
  ui.readState = function() return { cef = state.cef, imgui = state.imgui } end
  return calls
end

test("get returns current state", function()
  stub({ cef = true, imgui = false })
  local res, err = ui.getDef.handler({})
  assertNil(err)
  assertEqual(res.cef, true)
  assertEqual(res.imgui, false)
end)

test("get with nil args (MCP nil-params path) returns current state", function()
  stub({ cef = true, imgui = true })
  local res, err = ui.getDef.handler(nil)
  assertNil(err)
  assertEqual(res.cef, true)
  assertEqual(res.imgui, true)
end)

test("set cef only: setCef called, setImgui not, returns full state", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({ cef = false })
  assertNil(err)
  assertEqual(#calls.cef, 1)
  assertEqual(calls.cef[1], false)
  assertEqual(#calls.imgui, 0)
  assertEqual(res.cef, false)
  assertEqual(res.imgui, true)   -- unchanged field still reported
end)

test("set cef=true forwards true (value, not just call)", function()
  local calls = stub({ cef = false, imgui = false })
  local res, err = ui.setDef.handler({ cef = true })
  assertNil(err)
  assertEqual(#calls.cef, 1)
  assertEqual(calls.cef[1], true)
  assertEqual(res.cef, true)
  assertEqual(res.imgui, false)   -- unchanged field still reported
end)

test("set imgui only: setImgui called, setCef not", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({ imgui = false })
  assertNil(err)
  assertEqual(#calls.imgui, 1)
  assertEqual(calls.imgui[1], false)
  assertEqual(#calls.cef, 0)
  assertEqual(res.imgui, false)
  assertEqual(res.cef, true)
end)

test("set both: both called, returns full state", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({ cef = false, imgui = false })
  assertNil(err)
  assertEqual(#calls.cef, 1)
  assertEqual(#calls.imgui, 1)
  assertEqual(res.cef, false)
  assertEqual(res.imgui, false)
end)

test("omit both -> error, no engine calls", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({})
  assertNil(res)
  assertMatch(err, "provide cef and/or imgui")
  assertEqual(#calls.cef, 0)
  assertEqual(#calls.imgui, 0)
end)

test("non-boolean cef -> error, no engine calls", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({ cef = "yes" })
  assertNil(res)
  assertMatch(err, "'cef' must be a boolean")
  assertEqual(#calls.cef, 0)
end)

test("non-boolean imgui -> error, no engine calls", function()
  local calls = stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler({ imgui = 1 })
  assertNil(res)
  assertMatch(err, "'imgui' must be a boolean")
  assertEqual(#calls.imgui, 0)
end)

test("args not a table -> error", function()
  stub({ cef = true, imgui = true })
  local res, err = ui.setDef.handler("nope")
  assertNil(res)
  assertMatch(err, "must be an object")
end)

test("register adds get_ui_visibility and set_ui_visibility (2 tools)", function()
  local r = registry.new()
  ui.register(r)
  local names = {}
  for _, d in ipairs(r:list()) do names[d.name] = true end
  assertTrue(names["get_ui_visibility"], "get_ui_visibility registered")
  assertTrue(names["set_ui_visibility"], "set_ui_visibility registered")
  assertEqual(#r:list(), 2)
end)
