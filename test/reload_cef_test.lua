require("support.beamng_stubs")
local rc       = require("beammcp/tools/reload_cef")
local registry = require("core.registry")

test("handler calls reloadUI once and returns {reloaded=true}", function()
  local calls = 0
  rc.reloadUI = function() calls = calls + 1 end
  local res, err = rc.def.handler({})
  assertNil(err)
  assertEqual(calls, 1)
  assertEqual(res.reloaded, true)
end)

test("register adds it under 'reload_cef'", function()
  local r = registry.new()
  rc.register(r)
  assertEqual(r:list()[1].name, "reload_cef")
end)
