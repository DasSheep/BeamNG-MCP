require("support.beamng_stubs")
local stub      = require("support.stub")
local rgs       = require("beammcp/tools/recover_game_state")
local guardlist = require("beammcp/reload/guardlist")
local registry  = require("core.registry")

local function fakeGuard(name, broken)
  local g = { name = name, broken = broken }
  g.check = function() if g.broken then return { issue = name .. " broken" } end end
  g.repair = function() g.broken = false end
  return g
end

local function withGuards(guards, fn)
  stub.with(guardlist, { list = function(set)
    local out = {}
    for _, g in ipairs(guards) do if set == nil or set[g.name] then out[#out + 1] = g end end
    return out
  end }, fn)
end

test("dry run by default: reports issues, repairs nothing", function()
  local g = fakeGuard("camera", true)
  withGuards({ g }, function()
    local res = rgs.def.handler({})
    assertEqual(res.report.apply, false)
    assertEqual(res.report.mode, "manual")
    assertEqual(res.report.guards[1].outcome, "issue")
    assertEqual(g.broken, true)
  end)
end)

test("apply=true repairs", function()
  local g = fakeGuard("camera", true)
  withGuards({ g }, function()
    local res = rgs.def.handler({ apply = true })
    assertEqual(res.report.guards[1].outcome, "repaired")
    assertEqual(g.broken, false)
  end)
end)

test("guards subset runs only the named guards", function()
  withGuards({ fakeGuard("camera", true), fakeGuard("nightlights", true) }, function()
    local res = rgs.def.handler({ guards = { "nightlights" } })
    assertEqual(#res.report.guards, 1)
    assertEqual(res.report.guards[1].name, "nightlights")
  end)
end)

test("argument validation", function()
  local _, e1 = rgs.def.handler({ apply = "yes" })
  assertMatch(e1, "'apply' must be a boolean")
  local _, e2 = rgs.def.handler({ guards = "camera" })
  assertMatch(e2, "'guards' must be")
  local _, e3 = rgs.def.handler({ guards = {} })
  assertMatch(e3, "'guards' must be")
  local _, e4 = rgs.def.handler({ guards = { "bogus" } })
  assertMatch(e4, "unknown guard 'bogus'")
end)

test("includes lastReloadRecovery from the injected source", function()
  withGuards({}, function()
    stub.with(rgs, { lastSource = function() return { classification = "normal" } end }, function()
      assertEqual(rgs.def.handler({}).lastReloadRecovery.classification, "normal")
    end)
  end)
end)

test("register adds it under 'recover_game_state'", function()
  local r = registry.new()
  rgs.register(r)
  assertEqual(r:list()[1].name, "recover_game_state")
end)
