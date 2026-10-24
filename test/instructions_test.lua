local instructions = require("beammcp/instructions")

test("build(true): teaches slow/pause + restore + the never-in-MP warning", function()
  local s = instructions.build(true)
  assertMatch(s, "set_sim_speed")
  assertMatch(s, "pause")
  assertMatch(s, "factor=1.0")
  assertMatch(s, "pause=false")        -- the resume step is explicit, not just buried in shorthand
  assertMatch(s, "BeamMP")
  assertMatch(s, "refuse")             -- pins the hard "will refuse in MP" warning, not a soft "avoid"
  assertMatch(s, "compact by default") -- the token-reduction guidance is always present
  assertMatch(s, "detail=true")
end)

test("build(false): states real-time + disabled, no slow/pause guidance", function()
  local s = instructions.build(false)
  assertMatch(s, "real time")
  assertMatch(s, "disabled")
  assertEqual(s:find("set_sim_speed"), nil)  -- must not point at a tool that will just refuse
  assertMatch(s, "compact by default")       -- token-reduction guidance shows regardless of sim-control gate
end)

test("auth enabled: instructions mention the Bearer header", function()
  local s = instructions.build(false, true)
  assertMatch(s, "Authorization: Bearer")
end)

test("auth disabled: no Bearer mention", function()
  local s = instructions.build(false, false)
  assertEqual(s:find("Bearer"), nil)  -- no auth sentence when the gate is off
end)

test("sim-control and auth can both be reflected", function()
  local s = instructions.build(true, true)
  assertMatch(s, "set_sim_speed")
  assertMatch(s, "Authorization: Bearer")
end)

test("instructions mention reload recovery in both sim-control modes", function()
  assertMatch(instructions.build(false), "recover_game_state")
  assertMatch(instructions.build(true, true), "lastReloadRecovery")
end)
