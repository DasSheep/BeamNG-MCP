require("support.beamng_stubs")
local veh = require("beammcp/tools/lib/veh")

test("resolveId passes a numeric args.id through", function()
  _G.be = { getPlayerVehicleID = function() error("must not be called") end }
  assertEqual(veh.resolveId({ id = 42 }, "some_tool"), 42)
end)

test("resolveId falls back to the player vehicle when id is absent", function()
  _G.be = { getPlayerVehicleID = function() return 7 end }
  assertEqual(veh.resolveId({}, "some_tool"), 7)
  assertEqual(veh.resolveId(nil, "some_tool"), 7)
end)

test("resolveId rejects a non-number id with the tool-labeled error", function()
  _G.be = { getPlayerVehicleID = function() return 7 end }
  local id, err = veh.resolveId({ id = "seven" }, "some_tool")
  assertNil(id)
  assertEqual(err, "some_tool: 'id' must be a number")
end)
