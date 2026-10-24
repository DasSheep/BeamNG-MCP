require("support.beamng_stubs")
local gvp      = require("beammcp/tools/get_vehicle_powertrain")
local registry = require("core.registry")

-- ---- pure builders (no engine) -----------------------------------------------------------

test("compactDevice keeps name/type, includes a present inputName", function()
  local d = gvp.compactDevice({ type = "shaft", name = "driveshaft", inputName = "gearbox", inputIndex = 1 })
  assertEqual(d.name, "driveshaft")
  assertEqual(d.type, "shaft")
  assertEqual(d.inputName, "gearbox")
  assertNil(d.inputIndex) -- compact drops everything but name/type/inputName
end)

test("compactDevice omits inputName when nil or empty string", function()
  local a = gvp.compactDevice({ type = "combustionEngine", name = "mainEngine" })
  assertEqual(a.name, "mainEngine")
  assertNil(a.inputName)
  local b = gvp.compactDevice({ type = "combustionEngine", name = "mainEngine", inputName = "" })
  assertNil(b.inputName)
end)

test("buildCompact returns compact devices, wheel names, and a guidance note", function()
  local rows = {
    { type = "combustionEngine", name = "mainEngine", inputName = "" },
    { type = "gearbox", name = "gearbox", inputName = "mainEngine" },
  }
  local wheels = { { name = "FL", node1 = 1, node2 = 2 }, { name = "FR", node1 = 3, node2 = 4 } }
  local b = gvp.buildCompact(rows, wheels)
  assertEqual(#b.devices, 2)
  assertEqual(b.devices[1].name, "mainEngine")
  assertNil(b.devices[1].inputName)      -- "" omitted
  assertEqual(b.devices[2].inputName, "mainEngine")
  assertEqual(#b.wheels, 2)
  assertEqual(b.wheels[1], "FL")         -- wheels are just names in compact mode
  assertEqual(b.wheels[2], "FR")
  assertMatch(b.note, "2 devices")
  assertMatch(b.note, "2 wheels")
  assertMatch(b.note, "detail=true")
  assertMatch(b.note, "device=")
end)

test("buildCompact: a nameless wheel still appears (fallback) and the count stays accurate", function()
  local wheels = { { name = "FL", node1 = 1 }, { node1 = 3 }, { name = "RR", node1 = 5 } }
  local b = gvp.buildCompact({}, wheels)
  assertEqual(#b.wheels, 3)        -- the nameless wheel is NOT silently dropped
  assertEqual(b.wheels[1], "FL")
  assertEqual(b.wheels[3], "RR")
  assertTrue(b.wheels[2] ~= nil)   -- it gets a stable fallback identifier, not a hole
  assertMatch(b.note, "3 wheels")  -- note counts the source array, not the names emitted
end)

test("buildCompact: empty inputs -> empty lists + sane note", function()
  local b = gvp.buildCompact({}, {})
  assertEqual(#b.devices, 0)
  assertEqual(#b.wheels, 0)
  assertMatch(b.note, "0 devices")
  assertMatch(b.note, "0 wheels")
end)

test("buildDetail returns full rows (non-plain fields stripped) + wheel node geometry", function()
  local rows = { { type = "shaft", name = "driveshaft", inputName = "gearbox", inputIndex = 1,
                   partOrigin = "pickup_driveshaft", fn = function() end } }
  local wheels = { { name = "RL", node1 = 169, node2 = 168 } }
  local function npos(n)
    local t = { [168] = { x = 1, y = 2, z = 3 }, [169] = { x = 4, y = 5, z = 6 } }
    return t[n]
  end
  local b = gvp.buildDetail(rows, wheels, npos)
  assertEqual(b.devices[1].type, "shaft")
  assertEqual(b.devices[1].partOrigin, "pickup_driveshaft")
  assertEqual(b.devices[1].inputIndex, 1)
  assertNil(b.devices[1].fn)             -- plainRow strips functions
  assertEqual(b.wheels[1].name, "RL")
  assertEqual(b.wheels[1].node1, 169)
  assertEqual(b.wheels[1].p1.x, 4)       -- node 169
  assertEqual(b.wheels[1].p2.z, 3)       -- node 168
end)

test("findDevice returns the first matching row (plain) or nil", function()
  local rows = {
    { type = "combustionEngine", name = "mainEngine", inputIndex = 0, fn = function() end },
    { type = "gearbox", name = "gearbox" },
  }
  local d = gvp.findDevice(rows, "mainEngine")
  assertEqual(d.type, "combustionEngine")
  assertEqual(d.inputIndex, 0)
  assertNil(d.fn)                        -- plainRow strips functions
  assertNil(gvp.findDevice(rows, "nope"))
end)

-- ---- handler dispatch (stubbed engine) ---------------------------------------------------

local function stubEngine(vdata)
  _G.be = {
    getPlayerVehicleID = function(self, n) return 45 end,
    getObjectByID = function(self, id)
      return {
        getJBeamFilename = function(self2) return "roamer" end,
        getNodePosition = function(self2, n)
          local t = { [168] = { x = 1, y = 2, z = 3 }, [169] = { x = 4, y = 5, z = 6 } }
          return t[n]
        end,
      }
    end,
  }
  _G.core_vehicle_manager = { getVehicleData = function(id) return { vdata = vdata } end }
end

local SAMPLE = {
  powertrain = {
    { type = "combustionEngine", name = "mainEngine", inputName = "", inputIndex = 0, partOrigin = "pickup_engine_v8" },
    { type = "gearbox", name = "gearbox", inputName = "mainEngine", inputIndex = 1 },
  },
  wheels = { { name = "RL", node1 = 169, node2 = 168 } },
}

test("compact default: device {name,type}, wheel names, note", function()
  stubEngine(SAMPLE)
  local res = gvp.def.handler({})
  assertEqual(res.vehicleId, 45)
  assertEqual(res.model, "roamer")
  assertEqual(#res.devices, 2)
  assertEqual(res.devices[1].type, "combustionEngine")
  assertNil(res.devices[1].partOrigin) -- compact omits it
  assertEqual(res.wheels[1], "RL")
  assertMatch(res.note, "%d devices")
end)

test("detail=true: full device rows + wheel hub geometry", function()
  stubEngine(SAMPLE)
  local res = gvp.def.handler({ detail = true })
  assertEqual(res.devices[1].partOrigin, "pickup_engine_v8")
  assertEqual(res.wheels[1].name, "RL")
  assertEqual(res.wheels[1].p1.x, 4) -- node 169
  assertNil(res.note)                -- detail mode has no guidance note
end)

test("device=<name>: one device's full row", function()
  stubEngine(SAMPLE)
  local res = gvp.def.handler({ device = "gearbox" })
  assertEqual(res.vehicleId, 45)
  assertEqual(res.device.type, "gearbox")
  assertEqual(res.device.inputName, "mainEngine")
  assertNil(res.devices) -- scoped mode returns a single `device`, not a list
end)

test("device + detail together -> gate error", function()
  stubEngine(SAMPLE)
  local res, err = gvp.def.handler({ device = "gearbox", detail = true })
  assertNil(res)
  assertMatch(err, "applies only to scoped mode")
end)

test("unknown device -> clean error", function()
  stubEngine(SAMPLE)
  local res, err = gvp.def.handler({ device = "zzz" })
  assertNil(res)
  assertMatch(err, "unknown device 'zzz'")
end)

test("non-string device / non-boolean detail -> type errors", function()
  stubEngine(SAMPLE)
  local r1, e1 = gvp.def.handler({ device = 7 })
  assertNil(r1); assertMatch(e1, "'device' must be a string")
  local r2, e2 = gvp.def.handler({ detail = "yes" })
  assertNil(r2); assertMatch(e2, "'detail' must be a boolean")
end)

test("missing vdata returns nil + message", function()
  _G.be = { getPlayerVehicleID = function(self, n) return 45 end,
            getObjectByID = function(self, id) return { getJBeamFilename = function() return "x" end } end }
  _G.core_vehicle_manager = { getVehicleData = function(id) return nil end }
  local res, err = gvp.def.handler({})
  assertNil(res)
  assertMatch(err, "no vehicle data")
end)

test("unknown vehicle id returns nil + message", function()
  _G.be = { getPlayerVehicleID = function(self, n) return 45 end,
            getObjectByID = function(self, id) return nil end }
  local res, err = gvp.def.handler({ id = 999 })
  assertNil(res)
  assertMatch(err, "unknown vehicle id 999")
end)

test("register adds it under 'get_vehicle_powertrain'", function()
  local r = registry.new()
  gvp.register(r)
  assertEqual(r:list()[1].name, "get_vehicle_powertrain")
end)
