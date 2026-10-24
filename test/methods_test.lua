require("support.beamng_stubs")
local jsonrpc  = require("core.jsonrpc")
local registry = require("core.registry")
local methods  = require("core.methods")
local json     = require("json")

local function newCore()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  methods.register(rpc, reg, { name = "beammcp", version = "0.1.0" })
  return rpc, reg
end

local function call(rpc, s) return json.decode(rpc:handle(s)) end

test("initialize returns protocol version, tools capability, serverInfo", function()
  local rpc = newCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
  assertTrue(type(d.result.protocolVersion) == "string")
  assertTrue(type(d.result.capabilities.tools) == "table")
  assertEqual(d.result.serverInfo.name, "beammcp")
end)

test("notifications/initialized yields no response", function()
  local rpc = newCore()
  assertNil(rpc:handle('{"jsonrpc":"2.0","method":"notifications/initialized"}'))
end)

test("ping returns a result", function()
  local rpc = newCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":2,"method":"ping"}')
  assertNil(d.error)
  assertTrue(type(d.result) == "table")
end)

test("tools/list reports a registered tool", function()
  local rpc, reg = newCore()
  reg:add("t", {
    description = "d",
    annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
    inputSchema = { type = "object" },
    handler = function() return 1 end,
  })
  local d = call(rpc, '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')
  assertEqual(d.result.tools[1].name, "t")
  assertEqual(d.result.tools[1].annotations.readOnlyHint, true)
end)

test("tools/call shapes a successful result as text content, isError false", function()
  local rpc, reg = newCore()
  reg:add("greet", { description = "d", inputSchema = {}, handler = function(a) return "hi " .. a.who end })
  local d = call(rpc, '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"greet","arguments":{"who":"bob"}}}')
  assertEqual(d.result.isError, false)
  assertEqual(d.result.content[1].type, "text")
  assertMatch(d.result.content[1].text, "hi bob")
end)

test("tools/call of a tool that errors yields isError true", function()
  local rpc, reg = newCore()
  reg:add("oops", { description = "d", inputSchema = {}, handler = function() return nil, "tool failed" end })
  local d = call(rpc, '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"oops","arguments":{}}}')
  assertEqual(d.result.isError, true)
  assertMatch(d.result.content[1].text, "tool failed")
end)

test("tools/call of unknown tool is a protocol error -32602", function()
  local rpc = newCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ghost"}}')
  assertEqual(d.error.code, -32602)
end)

test("tools/call without a name is invalid params -32602", function()
  local rpc = newCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}')
  assertEqual(d.error.code, -32602)
end)

test("tools/call defaults missing arguments to an empty table", function()
  local rpc, reg = newCore()
  reg:add("noargs", { description = "d", inputSchema = { type = "object" }, handler = function(a)
    return "args type: " .. type(a)
  end })
  local d = call(rpc, '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"noargs"}}')
  assertEqual(d.result.isError, false)
  assertMatch(d.result.content[1].text, "args type: table")
end)

test("initialize uses default serverInfo when none provided", function()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  methods.register(rpc, reg)  -- no serverInfo arg
  local d = json.decode(rpc:handle('{"jsonrpc":"2.0","id":9,"method":"initialize","params":{}}'))
  assertEqual(d.result.serverInfo.name, "beammcp")
  assertEqual(d.result.serverInfo.version, "0.1.0")
end)

test("tools/call passes through __mcpContent blocks as the result content", function()
  local rpc, reg = newCore()
  reg:add("shot", { description = "d", inputSchema = {}, handler = function()
    return { __mcpContent = { { type = "image", data = "QUJD", mimeType = "image/png" } } }
  end })
  local d = call(rpc, '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"shot","arguments":{}}}')
  assertEqual(d.result.isError, false)
  assertEqual(d.result.content[1].type, "image")
  assertEqual(d.result.content[1].data, "QUJD")
  assertEqual(d.result.content[1].mimeType, "image/png")
end)

test("onActivity fires per request: method name normally, tool name for tools/call", function()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  reg:add("greet", { description = "d", inputSchema = {}, handler = function() return "hi" end })
  local seen = {}
  methods.register(rpc, reg, nil, function(label) seen[#seen + 1] = label end)

  rpc:handle('{"jsonrpc":"2.0","id":1,"method":"ping"}')
  rpc:handle('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{}}}')

  assertEqual(seen[1], "ping")
  assertEqual(seen[2], "greet")
end)

test("onActivity falls back to 'tools/call' when name is missing", function()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  local seen = {}
  methods.register(rpc, reg, nil, function(label) seen[#seen + 1] = label end)
  local d = json.decode(rpc:handle('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{}}'))
  assertEqual(seen[1], "tools/call")
  assertEqual(d.error.code, -32602)  -- record fires before delegation, even when the handler errors
end)

test("tools/call still forwards the tool's error result (multi-return preserved under wrapping)", function()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  reg:add("oops", { description = "d", inputSchema = {}, handler = function() return nil, "tool failed" end })
  methods.register(rpc, reg, nil, function() end)
  local d = json.decode(rpc:handle('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"oops","arguments":{}}}'))
  assertEqual(d.result.isError, true)
  assertMatch(d.result.content[1].text, "tool failed")
end)

test("initialize includes instructions when provided", function()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  methods.register(rpc, reg, { name = "beammcp", version = "0.1.0" }, nil, "do the thing")
  local d = json.decode(rpc:handle('{"jsonrpc":"2.0","id":30,"method":"initialize","params":{}}'))
  assertEqual(d.result.instructions, "do the thing")
end)

test("initialize omits instructions when not provided", function()
  local rpc = newCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":31,"method":"initialize","params":{}}')
  assertNil(d.result.instructions)
end)
