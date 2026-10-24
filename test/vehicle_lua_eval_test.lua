require("support.beamng_stubs")               -- jsonEncode/jsonDecode/log
local vle      = require("beammcp/tools/vehicle_lua_eval")
local registry = require("core.registry")

local function stubBe()
  _G.be = {
    getPlayerVehicleID = function(self, n) return 45 end,
    getObjectByID = function(self, id) return (id == 45) and {} or nil end,
  }
end

test("success: returns {value, output} from the decoded payload", function()
  stubBe()
  vle.evalVE = function(veh, code) return { ok = true, value = 42, output = "hi" } end
  local res, err = vle.def.handler({ code = "return 42" })
  assertNil(err)
  assertEqual(res.value, 42)
  assertEqual(res.output, "hi")
end)

test("VE error: nil + message, appends captured output", function()
  stubBe()
  vle.evalVE = function() return { ok = false, err = "boom\nstack", output = "before" } end
  local res, err = vle.def.handler({ code = "error('boom')" })
  assertNil(res)
  assertMatch(err, "boom")
  assertMatch(err, "%-%-%- output %-%-%-")
  assertMatch(err, "before")
end)

test("VE error with empty output omits the output section", function()
  stubBe()
  vle.evalVE = function() return { ok = false, err = "nope", output = "" } end
  local res, err = vle.def.handler({ code = "x" })
  assertNil(res)
  assertMatch(err, "nope")
  assertTrue(not err:find("%-%-%- output %-%-%-"))   -- the separator (not the incidental word) is absent
end)

test("timeout: evalVE returns nil -> timeout message", function()
  stubBe()
  vle.evalVE = function() return nil end
  local res, err = vle.def.handler({ code = "return 1" })
  assertNil(res)
  assertMatch(err, "no response")
end)

test("bad args: non-string code", function()
  stubBe()
  local res, err = vle.def.handler({})
  assertNil(res)
  assertMatch(err, "'code' must be a string")
end)

test("unknown vehicle id", function()
  stubBe()
  local res, err = vle.def.handler({ code = "return 1", id = 999 })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 999")
end)

test("register adds it under 'vehicle_lua_eval'", function()
  local r = registry.new()
  vle.register(r)
  assertEqual(r:list()[1].name, "vehicle_lua_eval")
end)

test('public vehicle eval budget caps values and rejects invalid budget',function()
  stubBe()
  vle.evalVE=function() return {ok=true,value=string.rep('x',20000),output=''} end
  local r=assert(vle.def.handler({code='return 1',maxBytes=1024}))
  assertTrue(#jsonEncode(r)<=1024); assertTrue(r.truncated)
  local v,e=vle.def.handler({code='return 1',maxBytes=0})
  assertNil(v); assertMatch(e,'maxBytes')
end)
