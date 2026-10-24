local registry = require("core.registry")
local ss = require("beammcp/tools/sim_speed")
local mp = require("beammcp/tools/lib/mp")
local realProbe = mp.probe   -- capture before any stub (the mp lib table is shared across test files)

local function gateOn() return true end
local function gateOff() return false end

-- default probe off-engine -> modLoaded=false -> not refused. Tests that need a session stub mp.probe.

test("missing both factor and pause -> error", function()
  local res, err = ss.handler({}, gateOn)
  assertNil(res)
  assertMatch(err, "provide 'factor'")
end)

test("non-table args -> error", function()
  local res, err = ss.handler("x", gateOn)
  assertNil(res)
  assertMatch(err, "must be an object")
end)

test("bad factor (zero / negative / non-number) -> error", function()
  local _, e1 = ss.handler({ factor = 0 }, gateOn);   assertMatch(e1, "'factor' must be a positive number")
  local _, e2 = ss.handler({ factor = -1 }, gateOn);  assertMatch(e2, "'factor' must be a positive number")
  local _, e3 = ss.handler({ factor = "x" }, gateOn); assertMatch(e3, "'factor' must be a positive number")
end)

test("non-boolean pause -> error", function()
  local _, err = ss.handler({ pause = "yes" }, gateOn)
  assertMatch(err, "'pause' must be a boolean")
end)

test("gate disabled -> disabled error (no engine write)", function()
  ss.apply = function() error("apply must not be called when disabled") end
  local res, err = ss.handler({ factor = 0.05 }, gateOff)
  assertNil(res)
  assertMatch(err, "sim%-time control is disabled")
end)

test("active MP session -> refused even when gate is on", function()
  mp.probe = function() return { modLoaded = true, sessionActive = true } end
  ss.apply = function() error("apply must not be called during MP") end
  local res, err = ss.handler({ pause = true }, gateOn)
  mp.probe = realProbe   -- restore the shared lib's real probe (no package.loaded clearing)
  assertNil(res)
  assertMatch(err, "multiplayer")
end)

-- The real off-engine probe returns modLoaded=false (no BeamMP globals present) -> not refused, so these two
-- single-player tests need no probe stub.
test("enabled + single-player: factor and pause forwarded to apply; read-back returned", function()
  local seen = {}
  ss.apply = function(factor, pause) seen.factor = factor; seen.pause = pause
    return { simSpeed = factor or 1, paused = pause or false } end
  local res, err = ss.handler({ factor = 0.05, pause = true }, gateOn)
  assertNil(err)
  assertEqual(seen.factor, 0.05); assertEqual(seen.pause, true)
  assertEqual(res.simSpeed, 0.05); assertEqual(res.paused, true)
end)

test("pause-only leaves factor untouched (apply receives nil factor)", function()
  local seen = {}
  ss.apply = function(factor, pause) seen.factor = factor; seen.pause = pause; return { simSpeed = 1, paused = pause } end
  ss.handler({ pause = false }, gateOn)
  assertNil(seen.factor); assertEqual(seen.pause, false)
end)

test("register adds it under 'set_sim_speed'", function()
  local r = registry.new()
  ss.register(r, gateOn)
  assertEqual(r:list()[1].name, "set_sim_speed")
end)

test("register default gate is disabled (safe)", function()
  local r = registry.new()
  ss.register(r)  -- no gateEnabled -> defaults to disabled
  local res, err = r:invoke("set_sim_speed", { factor = 0.05 })
  assertNil(res)
  assertMatch(err, "disabled")
end)
