local gate = require("beammcp/reload/gate")

local READY = { mission = "/levels/a/main.level.json", loading = false, hasVehicle = true }

local function tickN(g, n, dt, probe)
  local st
  for _ = 1, n do st = g:tick(dt, probe) end
  return st
end

test("waits for MIN_FRAMES even when everything is ready", function()
  local g = gate.new()
  assertEqual(tickN(g, gate.MIN_FRAMES - 1, 0.016, READY), "wait")
  assertEqual(g:tick(0.016, READY), "ready")
end)

test("waits while no level or while loading", function()
  local g = gate.new()
  assertEqual(tickN(g, 20, 0.016, { mission = "", loading = false, hasVehicle = true }), "wait")
  assertEqual(tickN(g, 5, 0.016, { mission = "/x", loading = true, hasVehicle = true }), "wait")
  assertEqual(g:tick(0.016, READY), "ready")
end)

test("without a vehicle, waits for VEHICLE_GRACE seconds then proceeds", function()
  local g = gate.new()
  local noVeh = { mission = "/x", loading = false, hasVehicle = false }
  assertEqual(tickN(g, 20, 0.1, noVeh), "wait")        -- 2.0 s elapsed
  assertEqual(tickN(g, 11, 0.1, noVeh), "ready")       -- 3.1 s elapsed
end)

test("times out after TIMEOUT seconds", function()
  local g = gate.new()
  assertEqual(tickN(g, 99, 0.1, { mission = "", loading = false, hasVehicle = false }), "wait")
  assertEqual(g:tick(0.2, { mission = "", loading = false, hasVehicle = false }), "timeout")
end)

test("a nil dt is treated as zero", function()
  local g = gate.new()
  assertEqual(tickN(g, gate.MIN_FRAMES, nil, READY), "ready")
end)
