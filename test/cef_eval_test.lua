require("support.beamng_stubs")
local cef      = require("beammcp/tools/cef_eval")
local registry = require("core.registry")

test('CEF tool limits oversized values and validates budget before evaluation',function()
  local old=cef.evalCEF
  cef.evalCEF=function() return true,string.rep('\001',5000) end
  local r=assert(cef.def.handler({code='1',maxBytes=1024}))
  assertTrue(#jsonEncode(r)<=1024); assertTrue(r.truncated)
  cef.evalCEF=function() error('must not execute') end
  local v,e=cef.def.handler({code='1',maxBytes=-1})
  cef.evalCEF=old
  assertNil(v); assertMatch(e,'maxBytes')
end)

test("success: returns {value} from evalCEF", function()
  cef.evalCEF = function(code, target) return true, "nav" end
  local res, err = cef.def.handler({ code = "localStorage.getItem('myMod:page')" })
  assertNil(err)
  assertEqual(res.value, "nav")
end)

test("success with nil value (undefined) -> {value=nil}", function()
  cef.evalCEF = function() return true, nil end
  local res, err = cef.def.handler({ code = "localStorage.setItem('x','1')" })
  assertNil(err)
  assertNil(res.value)
end)

test("evalCEF error -> nil + message", function()
  cef.evalCEF = function() return false, "cef_eval: ReferenceError: foo" end
  local res, err = cef.def.handler({ code = "foo()" })
  assertNil(res)
  assertMatch(err, "ReferenceError")
end)

test("target is forwarded to evalCEF", function()
  local seen
  cef.evalCEF = function(code, target) seen = target; return true, 1 end
  cef.def.handler({ code = "1", target = "@us_semi_gauges" })
  assertEqual(seen, "@us_semi_gauges")
end)

test("bad args: non-string code", function()
  local res, err = cef.def.handler({})
  assertNil(res)
  assertMatch(err, "'code' must be a non%-empty string")
end)

test("bad args: empty code", function()
  local res, err = cef.def.handler({ code = "" })
  assertNil(res)
  assertMatch(err, "'code' must be a non%-empty string")
end)

test("register adds it under 'cef_eval'", function()
  local r = registry.new()
  cef.register(r)
  assertEqual(r:list()[1].name, "cef_eval")
end)
