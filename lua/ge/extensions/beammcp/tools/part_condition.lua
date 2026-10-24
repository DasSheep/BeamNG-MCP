-- part_condition: read the PHYSICAL result of vehicle damage. A curated VE eval reusing vehicle_lua_eval.evalVE
-- (the damage.lua/2h pattern). Aggregation runs INSIDE the VE chunk over BeamNG's already-cached per-frame
-- structures — beamstate.getPartDamageData (per-part {name, damage 0..1} for damaged parts), beamstate.deformedBeams
-- (sparse cid->ratio map; entry count = damaged-beam total), beamstate.deformGroupDamage (per-deform-group damage) —
-- so only a small curated table crosses the bridge, never the raw 4000+-beam mesh. Engine coupling lives in
-- stubbable M.fetch; M.shapeSummary/M.shapeDetail/M.capList are pure. The geometry complement to get_damage_data
-- (which reads dashboard FLAGS).
-- NOTE (in-engine finding): overall integrity / per-part integrity-visual conditions are intentionally
-- NOT read here. partCondition.getConditions() returns false until a side-effecting init that snapshots the current
-- (possibly damaged) state as the baseline — which a read-only tool must not call. A part's damage score (0..1)
-- already conveys its condition. A reliable broken-vs-deformed beam split isn't available either (group-breaks,
-- including damage_vehicle's, saturate beam ratios to 1), so only the deformed-beam count is reported.
local vehicle_lua_eval = require("beammcp/tools/vehicle_lua_eval")
local shape = require("beammcp/tools/lib/shape")

local M = {}

local DETAIL_CAP = 30   -- top-N cap on the detail deformGroups list (the 2o "no silent caps" discipline)
local HINT = " detail=true for the per-deform-group breakdown."

-- last path segment as a friendly name ("pigeon/pigeon_body" -> "pigeon_body")
local function basename(p) return (type(p) == "string" and p:match("[^/]+$")) or p end
-- round to 2 decimals (stable for 2dp inputs; see the float-equality note in the plan conventions)
local function round2(x) return math.floor(x * 100 + 0.5) / 100 end

-- Core damage sentence + a "is there damage" flag. Pure.
local function summaryNote(parts, deformed)
  if #parts == 0 and (deformed or 0) == 0 then
    return "vehicle undamaged.", false
  end
  return string.format("%d damaged part(s), %d deformed beams.", #parts, deformed or 0), true
end

-- Pure (TDD'd): raw VE payload { parts = {path -> {name, damage}}, beamsDeformed = n } -> the summary contract.
function M.shapeSummary(raw)
  raw = raw or {}
  local parts = {}
  for path, info in pairs(raw.parts or {}) do
    local dmg = (type(info) == "table" and info.damage) or info
    if type(dmg) == "number" and dmg > 0 then
      parts[#parts + 1] = {
        part = path,
        name = (type(info) == "table" and type(info.name) == "string" and info.name) or basename(path),
        damage = round2(dmg),
      }
    end
  end
  table.sort(parts, function(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    return tostring(a.part) < tostring(b.part)
  end)

  local deformed = raw.beamsDeformed or 0
  local core, damaged = summaryNote(parts, deformed)
  return { parts = parts, beams = { deformed = deformed }, note = damaged and (core .. HINT) or core }
end

-- Re-export the shared cap helper (kept under M.capList for existing callers/tests; source of truth is shape.lua).
M.capList = shape.capList

-- Pure (TDD'd): the summary contract PLUS per-deform-group damage (semantic, bounded, capped).
function M.shapeDetail(raw)
  raw = raw or {}
  local out = M.shapeSummary(raw)

  -- deformGroups: group -> damage scalar, damaged-only, sorted by damage desc.
  local dgroups = {}
  for g, dmg in pairs(raw.deformGroups or {}) do
    if type(dmg) == "number" and dmg > 0 then
      dgroups[#dgroups + 1] = { group = g, damage = round2(dmg) }
    end
  end
  table.sort(dgroups, function(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    return tostring(a.group) < tostring(b.group)
  end)

  local dgCapped, dgTotal = M.capList(dgroups, DETAIL_CAP)
  if #dgCapped > 0 then out.deformGroups = dgCapped end
  out.note = out.note .. shape.capNote(#dgCapped, dgTotal, "deform groups")
  return out
end

-- Shared VE computation (no return): leaves `parts` and `deformed` as locals. Reads BeamNG's already-cached
-- per-frame damage structures; each access is guarded so a missing accessor degrades to an empty/zero value
-- rather than erroring. Field names confirmed in-engine.
local SUMMARY_BODY = [[
local parts = {}
if beamstate and beamstate.getPartDamageData then
  local ok, d = pcall(beamstate.getPartDamageData)
  if ok and type(d) == "table" then parts = d end
end
-- deformedBeams is a sparse map (cid -> ratio) of only the damaged beams; entry count = deformed-beam total.
local deformed = 0
if beamstate and type(beamstate.deformedBeams) == "table" then
  for _ in pairs(beamstate.deformedBeams) do deformed = deformed + 1 end
end
]]

local SUMMARY_CHUNK = SUMMARY_BODY ..
  "return { parts = parts, beamsDeformed = deformed }"

local DETAIL_CHUNK = SUMMARY_BODY .. [[
local dgroups = nil
if beamstate and type(beamstate.deformGroupDamage) == "table" then
  dgroups = {}
  for g, info in pairs(beamstate.deformGroupDamage) do
    local dmg = (type(info) == "table" and info.damage) or info
    if type(dmg) == "number" then dgroups[g] = dmg end
  end
end
return { parts = parts, beamsDeformed = deformed, deformGroups = dgroups }
]]

-- Engine-coupled (stubbed in tests, verified in-engine): run the summary/detail aggregation chunk in the VE.
function M.fetch(id, detail)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "get_part_condition: unknown vehicle id " .. tostring(id) end
  local payload = vehicle_lua_eval.evalVE(veh, detail and DETAIL_CHUNK or SUMMARY_CHUNK)
  if not payload then return nil, "get_part_condition: no response from vehicle VM" end
  if not payload.ok then return nil, "get_part_condition: " .. tostring(payload.err) end
  return payload.value or {}
end

local function handler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "get_part_condition: arguments must be an object"
  end
  args = args or {}
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "get_part_condition: 'id' must be a number"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "get_part_condition: 'detail' must be a boolean"
  end
  local detail = args.detail == true
  local id = args.id or be:getPlayerVehicleID(0)
  local raw, err = M.fetch(id, detail)
  if not raw then return nil, err end
  local out = detail and M.shapeDetail(raw) or M.shapeSummary(raw)
  out.id = id
  return out
end

M.def = {
  description = "Read a vehicle's PHYSICAL damage: per-part damage scores (deformed parts only, 0..1) and the "
    .. "total deformed-beam count. detail=true adds per-deform-group damage (capped; accrues from progressive "
    .. "collision deformation, so it may be empty for instantaneous damage_vehicle group-breaks). The geometry "
    .. "complement to get_damage_data (which reads dashboard FLAGS/telltales). Apply damage with damage_vehicle "
    .. "or a real crash; effects manifest over the next physics steps, so read after stepping. Defaults to the "
    .. "player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (default: player)" },
      detail = { type = "boolean", description = "include the per-deform-group damage breakdown" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_part_condition", M.def)
end

return M
