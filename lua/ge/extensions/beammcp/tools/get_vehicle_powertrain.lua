-- get_vehicle_powertrain: the active/given vehicle's drivetrain device tree (GE-synchronous,
-- core_vehicle_manager.getVehicleData, read-only). Compact by default (token-reduction):
--   default          -> per-device {name, type, inputName?} + wheel names + a guidance note
--   detail=true      -> the full verbatim device rows + wheels with vehicle-local hub-node positions
--   device=<name>    -> one device's full verbatim row (scoped)
-- Node positions are vehicle-local (no veh:getPosition() subtraction needed). Engine reads live in stubbable M.fetch; the M.build*/M.findDevice shapers are pure.
local veh = require("beammcp/tools/lib/veh")

local M = {}

-- Copy only plain serializable fields (string/number/boolean) from a powertrain row, so jsonEncode
-- can never choke on an embedded function/userdata.
local function plainRow(row)
  local out = {}
  for k, v in pairs(row) do
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then out[k] = v end
  end
  return out
end

-- ---- pure shapers ------------------------------------------------------------------------

-- Compact device identity: name/type always; inputName only when present and non-empty (root devices
-- like the engine carry inputName="").
function M.compactDevice(row)
  local d = { name = row.name, type = row.type }
  if row.inputName ~= nil and row.inputName ~= "" then d.inputName = row.inputName end
  return d
end

-- Compact view: device {name,type,inputName?} list + wheel NAMES + a guidance note. Pure.
-- Wheel names use an indexed write with a fallback so a nameless wheel never leaves an array hole (which
-- would silently drop it AND corrupt the length); counts come from the SOURCE arrays, never the built ones.
function M.buildCompact(rows, wheels)
  local devices = {}
  for _, row in ipairs(rows) do devices[#devices + 1] = M.compactDevice(row) end
  local names = {}
  for i, w in ipairs(wheels) do names[i] = w.name or ("wheel" .. i) end
  local note = string.format(
    "%d devices, %d wheels. detail=true for full device fields + wheel geometry; device=<name> for one device.",
    #rows, #wheels)
  return { devices = devices, wheels = names, note = note }
end

-- Detail view: full verbatim device rows + wheels with hub-node positions (nposFn injected for purity). Pure.
function M.buildDetail(rows, wheels, nposFn)
  local devices = {}
  for _, row in ipairs(rows) do devices[#devices + 1] = plainRow(row) end
  local out = {}
  for _, w in ipairs(wheels) do
    out[#out + 1] = {
      name = w.name, node1 = w.node1, node2 = w.node2,
      p1 = nposFn(w.node1), p2 = nposFn(w.node2),
    }
  end
  return { devices = devices, wheels = out }
end

-- Scoped: the first device whose name matches (names are unique per vehicle), as a full plain row, or nil. Pure.
function M.findDevice(rows, name)
  for _, row in ipairs(rows) do
    if row.name == name then return plainRow(row) end
  end
  return nil
end

-- ---- engine seam (stubbed in tests) ------------------------------------------------------
-- Returns { model, rows[], wheels[], npos } (densified arrays so the pure shapers can ipairs), or nil + err.
function M.fetch(id)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "get_vehicle_powertrain: unknown vehicle id " .. tostring(id) end
  local vData = core_vehicle_manager.getVehicleData(id)
  local vd = vData and vData.vdata
  if not vd then return nil, "get_vehicle_powertrain: no vehicle data for id " .. tostring(id) end

  local rows = {}
  for _, row in pairs(vd.powertrain or {}) do rows[#rows + 1] = row end
  local wheels = {}
  for _, w in pairs(vd.wheels or {}) do wheels[#wheels + 1] = w end

  local function npos(n)
    if n == nil then return nil end
    local p = veh:getNodePosition(n)
    return p and { x = p.x, y = p.y, z = p.z } or nil
  end

  return { model = veh:getJBeamFilename(), rows = rows, wheels = wheels, npos = npos }
end

local function handler(args)
  args = args or {}
  if args.device ~= nil and type(args.device) ~= "string" then
    return nil, "get_vehicle_powertrain: 'device' must be a string"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "get_vehicle_powertrain: 'detail' must be a boolean"
  end
  local detail = args.detail == true
  local device = args.device
  if device ~= nil and detail then
    return nil, "get_vehicle_powertrain: 'device' applies only to scoped mode (drop detail)"
  end

  local id, iderr = veh.resolveId(args, "get_vehicle_powertrain")
  if not id then return nil, iderr end
  local data, err = M.fetch(id)
  if not data then return nil, err end

  if device ~= nil then
    local row = M.findDevice(data.rows, device)
    if not row then
      return nil, "get_vehicle_powertrain: unknown device '" .. device .. "' for vehicle id " .. tostring(id)
    end
    return { vehicleId = id, model = data.model, device = row }
  elseif detail then
    local built = M.buildDetail(data.rows, data.wheels, data.npos)
    return { vehicleId = id, model = data.model, devices = built.devices, wheels = built.wheels }
  else
    local built = M.buildCompact(data.rows, data.wheels)
    return { vehicleId = id, model = data.model, devices = built.devices, wheels = built.wheels, note = built.note }
  end
end

M.def = {
  description = "Active vehicle's drivetrain device tree. DEFAULT (compact): per-device {name,type,inputName} "
    .. "+ wheel names + a note. detail=true: full verbatim device rows + wheels with vehicle-local hub-node "
    .. "positions. device=<name>: one device's full row (scoped). This is the live powertrain (engines/shafts/"
    .. "gearboxes/diffs) -- not buildable jbeam parts (see get_vehicle_parts). Defaults to the player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id     = { type = "number",  description = "vehicle id (default: player)" },
      detail = { type = "boolean", description = "return full device rows + wheel hub geometry instead of the compact view" },
      device = { type = "string",  description = "scope to one device by name (full row); mutually exclusive with detail" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_vehicle_powertrain", M.def)
end

return M
