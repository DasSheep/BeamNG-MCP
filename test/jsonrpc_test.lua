require("support.beamng_stubs")
local jsonrpc = require("core.jsonrpc")
local json = require("json")

local function decode(s) return json.decode(s) end

test("parse error (-32700) on invalid JSON, id null", function()
  local rpc = jsonrpc.new()
  local d = decode(rpc:handle("{not json"))
  assertEqual(d.error.code, -32700)
  -- assertNil accepts both JSON null and an omitted key; our chosen wire format omits `id` for
  -- undetectable-id errors (documented deviation in core/jsonrpc.lua errorResponse).
  assertNil(d.id)
end)

test("method not found (-32601) for a request", function()
  local rpc = jsonrpc.new()
  local d = decode(rpc:handle('{"jsonrpc":"2.0","id":1,"method":"nope"}'))
  assertEqual(d.error.code, -32601)
  assertEqual(d.id, 1)
end)

test("invalid request (-32600) when method missing on a request", function()
  local rpc = jsonrpc.new()
  local d = decode(rpc:handle('{"jsonrpc":"2.0","id":2}'))
  assertEqual(d.error.code, -32600)
  assertEqual(d.id, 2)
end)

test("successful dispatch returns result with matching id", function()
  local rpc = jsonrpc.new()
  rpc:register("echo", function(params) return { got = params.x } end)
  local d = decode(rpc:handle('{"jsonrpc":"2.0","id":3,"method":"echo","params":{"x":42}}'))
  assertEqual(d.result.got, 42)
  assertEqual(d.id, 3)
  assertNil(d.error)
end)

test("handler-signaled error maps to its code", function()
  local rpc = jsonrpc.new()
  rpc:register("bad", function() return nil, { code = -32602, message = "Invalid params" } end)
  local d = decode(rpc:handle('{"jsonrpc":"2.0","id":4,"method":"bad"}'))
  assertEqual(d.error.code, -32602)
end)

test("handler that raises maps to internal error (-32603)", function()
  local rpc = jsonrpc.new()
  rpc:register("boom", function() error("kaboom") end)
  local d = decode(rpc:handle('{"jsonrpc":"2.0","id":5,"method":"boom"}'))
  assertEqual(d.error.code, -32603)
end)

test("notification (no id) produces no response, handler still runs", function()
  local rpc = jsonrpc.new()
  local ran = false
  rpc:register("notify", function() ran = true end)
  local resp = rpc:handle('{"jsonrpc":"2.0","method":"notify"}')
  assertNil(resp)
  assertTrue(ran)
end)

test("notification with unknown method is silently dropped", function()
  local rpc = jsonrpc.new()
  assertNil(rpc:handle('{"jsonrpc":"2.0","method":"ghost"}'))
end)

for _, batch in ipairs({ "[]", " \r\n [ ]", '[{"jsonrpc":"2.0","id":1,"method":"echo"}]',
  '[{"jsonrpc":"2.0","method":"echo"}]' }) do
  test("unsupported batch returns invalid request: " .. batch, function()
    local rpc = jsonrpc.new()
    local called = false
    rpc:register("echo", function() called = true end)
    local response = rpc:handle(batch)
    assertTrue(response ~= nil)
    assertEqual(decode(response).error.code, -32600)
    assertTrue(not called)
  end)
end

test("array inside a notification is not a batch", function()
  local rpc = jsonrpc.new()
  local called = false
  rpc:register("echo", function(params) called = params[1] == "x" end)
  assertNil(rpc:handle('{"jsonrpc":"2.0","method":"echo","params":["x"]}'))
  assertTrue(called)
end)
