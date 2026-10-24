require("support.beamng_stubs")
local jsonrpc  = require("core.jsonrpc")
local registry = require("core.registry")
local methods  = require("core.methods")
local lua_eval = require("tools.lua_eval")
local json     = require("json")

local function buildCore()
  local rpc = jsonrpc.new()
  local reg = registry.new()
  methods.register(rpc, reg, { name = "beammcp", version = "0.1.0" })
  lua_eval.register(reg)
  return rpc
end

local function call(rpc, s) return json.decode(rpc:handle(s)) end

test("initialize handshake", function()
  local rpc = buildCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')
  assertEqual(d.result.serverInfo.name, "beammcp")
end)

test("initialized notification is silent", function()
  local rpc = buildCore()
  assertNil(rpc:handle('{"jsonrpc":"2.0","method":"notifications/initialized"}'))
end)

test("tools/list exposes lua_eval", function()
  local rpc = buildCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  local names = {}
  for _, t in ipairs(d.result.tools) do names[t.name] = true end
  assertTrue(names["lua_eval"], "lua_eval should be listed")
end)

test("tools/call lua_eval runs Lua and returns its value via text content", function()
  local rpc = buildCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lua_eval","arguments":{"code":"return 6*7"}}}')
  assertEqual(d.result.isError, false)
  local payload = json.decode(d.result.content[1].text)   -- lua_eval result was json-encoded into text
  assertEqual(payload.value, 42)
end)

test("tools/call lua_eval reports a runtime error as isError", function()
  local rpc = buildCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lua_eval","arguments":{"code":"error(\'nope\')"}}}')
  assertEqual(d.result.isError, true)
  assertMatch(d.result.content[1].text, "nope")
end)

test("ping after handshake", function()
  local rpc = buildCore()
  local d = call(rpc, '{"jsonrpc":"2.0","id":5,"method":"ping"}')
  assertNil(d.error)
end)
