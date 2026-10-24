require("support.beamng_stubs")
local registry = require("core.registry")

local function sampleDef(tag)
  return {
    description = "desc " .. tag,
    annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
    inputSchema = { type = "object" },
    handler = function(args) return { echoed = args, tag = tag } end,
  }
end

test("list reflects added tools in insertion order, without handlers", function()
  local r = registry.new()
  r:add("b_tool", sampleDef("b"))
  r:add("a_tool", sampleDef("a"))
  local list = r:list()
  assertEqual(#list, 2)
  assertEqual(list[1].name, "b_tool")
  assertEqual(list[2].name, "a_tool")
  assertEqual(list[1].description, "desc b")
  assertEqual(list[1].annotations.readOnlyHint, true)
  assertNil(list[1].handler)
end)

test("invoke calls the handler and returns its result", function()
  local r = registry.new()
  r:add("t", sampleDef("t"))
  local res = r:invoke("t", { x = 1 })
  assertEqual(res.tag, "t")
  assertEqual(res.echoed.x, 1)
end)

test("invoke of unknown tool returns nil + error string", function()
  local r = registry.new()
  local res, err = r:invoke("ghost", {})
  assertNil(res)
  assertMatch(err, "^unknown tool")
end)

test("re-adding a name replaces def without duplicating list entry", function()
  local r = registry.new()
  r:add("t", sampleDef("first"))
  r:add("t", sampleDef("second"))
  assertEqual(#r:list(), 1)
  assertEqual(r:invoke("t", {}).tag, "second")
end)

test("add rejects a non-string name", function()
  local r = registry.new()
  local ok = pcall(function() r:add(123, { handler = function() end }) end)
  assertEqual(ok, false)
end)

test("add rejects a def without a function handler", function()
  local r = registry.new()
  local ok = pcall(function() r:add("t", { description = "d" }) end)
  assertEqual(ok, false)
end)

test("invoke turns a thrown handler error into nil + 'tool error' message", function()
  local r = registry.new()
  r:add("boom", { description = "d", inputSchema = {}, handler = function() error("kaboom") end })
  local res, err = r:invoke("boom", {})
  assertNil(res)
  assertMatch(err, "tool error")
end)

test("invoke of unknown tool reports the not_found kind", function()
  local r = registry.new()
  local res, err, kind = r:invoke("ghost", {})
  assertNil(res)
  assertMatch(err, "^unknown tool")
  assertEqual(kind, "not_found")
end)
