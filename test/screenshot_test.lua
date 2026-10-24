local screenshot = require("beammcp/tools/screenshot")
local base64     = require("beammcp/tools/lib/base64")
local registry   = require("core.registry")

test("handler returns an image content block built from the captured bytes", function()
  screenshot.capture = function() return "PNGBYTES" end   -- stub the engine capture
  local res, err = screenshot.def.handler({})
  assertNil(err)
  local block = res.__mcpContent[1]
  assertEqual(block.type, "image")
  assertEqual(block.mimeType, "image/png")
  assertEqual(block.data, base64.encode("PNGBYTES"))
end)

test("handler returns nil + message when capture fails/times out", function()
  screenshot.capture = function() return nil end
  local res, err = screenshot.def.handler({})
  assertNil(res)
  assertMatch(err, "timed out")
end)

test("register adds it under 'screenshot'", function()
  local r = registry.new()
  screenshot.register(r)
  assertEqual(r:list()[1].name, "screenshot")
end)
