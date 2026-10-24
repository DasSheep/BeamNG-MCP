-- beam_damage: stage PHYSICAL soft-body damage on a vehicle + discover what's damageable. Both tools are
-- curated VE evals reusing vehicle_lua_eval.evalVE (the proven ve_bridge + await round-trip) — the damage.lua
-- (2h) pattern. list_damage_groups reads the jbeam's break/deform groups + wheels (the catalog of targets);
-- damage_vehicle calls beamstate.* (break/deflate/deform/destroy). Repair is the existing reset_vehicle.
-- Engine coupling lives in stubbable M.fetch/M.apply; M.buildApplyChunk is pure. Registers two tools (the
-- ui_visibility/damage precedent: read+mutate facets of one capability).
local vehicle_lua_eval = require("beammcp/tools/vehicle_lua_eval")
local shape = require("beammcp/tools/lib/shape")
local veh   = require("beammcp/tools/lib/veh")

local M = {}

M.MAX_LIST = 100  -- per-list cap; complex vehicles (us_semi + trailers) have hundreds of groups

local VALID_KINDS = {
  break_group = true, break_hinges = true, deflate_tire = true, deform_group = true, destroy = true,
}

-- Pure (TDD'd): build the VE Lua chunk for one damage op. The caller validates kind/group/wheel first.
-- Injection-safe: group quoted with %q, wheel formatted as an integer, kind selects a fixed template.
function M.buildApplyChunk(kind, group, wheel)
  if kind == "break_group" then
    return string.format("beamstate.breakBreakGroup(%q) return true", group)
  elseif kind == "break_hinges" then
    return "beamstate.breakHinges() return true"
  elseif kind == "deflate_tire" then
    if wheel == nil then return "beamstate.deflateTires() return true" end
    return string.format("beamstate.deflateTire(%d) return true", wheel)
  elseif kind == "deform_group" then
    return string.format("beamstate.triggerDeformGroup(%q) return true", group)
  elseif kind == "destroy" then
    return "beamstate.breakAllBreakgroups() return true"
  end
  return nil
end

-- VE chunk: flatten v.data.beams[*].breakGroup/.deformGroup (each a string OR a table of strings) into
-- deduped sorted sets, enumerate v.data.wheels -> {id,name}. Returns the catalog of damageable targets.
local LIST_CHUNK = [[
local function addGroup(set, g)
  if type(g) == "string" then set[g] = true
  elseif type(g) == "table" then for _, x in ipairs(g) do if type(x) == "string" then set[x] = true end end end
end
local bg, dg = {}, {}
if v and v.data and v.data.beams then
  for _, b in pairs(v.data.beams) do addGroup(bg, b.breakGroup); addGroup(dg, b.deformGroup) end
end
local function sortedKeys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end
local wheels = {}
if v and v.data and v.data.wheels then
  for id, w in pairs(v.data.wheels) do wheels[#wheels + 1] = { id = id, name = w.name } end
end
return { breakGroups = sortedKeys(bg), deformGroups = sortedKeys(dg), wheels = wheels }
]]

-- Engine-coupled (stubbed in tests, verified in-engine): read the damageable-groups catalog from the VE.
function M.fetch(id)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "list_damage_groups: unknown vehicle id " .. tostring(id) end
  local payload = vehicle_lua_eval.evalVE(veh, LIST_CHUNK)
  if not payload then return nil, "list_damage_groups: no response from vehicle VM" end
  if not payload.ok then return nil, "list_damage_groups: " .. tostring(payload.err) end
  return payload.value or {}
end

-- Pure: apply the ci-substring filter to each list, cap each at MAX_LIST, and report truncation.
function M.shapeList(data, filter)
  local function keep(items, nameOf)
    local out = {}
    for _, item in ipairs(items or {}) do
      if shape.ciContains(nameOf(item), filter) then out[#out + 1] = item end
    end
    return out
  end
  local asIs = tostring
  local bg, bgTotal = shape.capList(keep(data.breakGroups, asIs), M.MAX_LIST)
  local dg, dgTotal = shape.capList(keep(data.deformGroups, asIs), M.MAX_LIST)
  local wh, whTotal = shape.capList(keep(data.wheels, function(w) return w.name end), M.MAX_LIST)
  local res = { breakGroups = bg, deformGroups = dg, wheels = wh }
  local note = shape.capNote(#bg, bgTotal, "breakGroups")
    .. shape.capNote(#dg, dgTotal, "deformGroups")
    .. shape.capNote(#wh, whTotal, "wheels")
  if note ~= "" then
    res.note = note:gsub("^%s+", "") .. " Narrow with filter=."
  end
  return res
end

local function listHandler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "list_damage_groups: arguments must be an object"
  end
  args = args or {}
  if args.filter ~= nil and type(args.filter) ~= "string" then
    return nil, "list_damage_groups: 'filter' must be a string"
  end
  local id, iderr = veh.resolveId(args, "list_damage_groups")
  if not id then return nil, iderr end
  local data, err = M.fetch(id)
  if not data then return nil, err end
  return M.shapeList(data, args.filter)
end

M.listDef = {
  description = "List a vehicle's damageable targets: breakGroups + deformGroups (semantic jbeam group names) "
    .. "and deflatable wheels [{id,name}]. The catalog to pass to damage_vehicle — distinct from get_damage_data "
    .. "(which reads CURRENT damage flags). Each list is capped at 100 (a note reports truncation); narrow with "
    .. "filter=. Defaults to the player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id = { type = "number", description = "vehicle id (default: player)" },
      filter = { type = "string", description = "case-insensitive substring on group/wheel names" },
    },
  },
  handler = listHandler,
}

-- Engine-coupled (stubbed in tests, verified in-engine): issue one beamstate damage op in the VE.
function M.apply(id, kind, group, wheel)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "damage_vehicle: unknown vehicle id " .. tostring(id) end
  local payload = vehicle_lua_eval.evalVE(veh, M.buildApplyChunk(kind, group, wheel))
  if not payload then return nil, "damage_vehicle: no response from vehicle VM" end
  if not payload.ok then return nil, "damage_vehicle: " .. tostring(payload.err) end
  return true
end

local function damageHandler(args)
  if type(args) ~= "table" then
    return nil, "damage_vehicle: arguments must be an object"
  end
  if not VALID_KINDS[args.kind] then
    return nil, "damage_vehicle: 'kind' must be one of break_group, break_hinges, deflate_tire, deform_group, destroy"
  end
  if args.kind == "break_group" or args.kind == "deform_group" then
    if type(args.group) ~= "string" or args.group == "" then
      return nil, "damage_vehicle: '" .. args.kind .. "' requires a non-empty 'group' string (see list_damage_groups)"
    end
  end
  if args.kind == "deflate_tire" and args.wheel ~= nil and type(args.wheel) ~= "number" then
    return nil, "damage_vehicle: 'wheel' must be a number (see list_damage_groups)"
  end
  local id, iderr = veh.resolveId(args, "damage_vehicle")
  if not id then return nil, iderr end
  local ok, err = M.apply(id, args.kind, args.group, args.wheel)
  if not ok then return nil, err end
  return { kind = args.kind, ok = true }
end

M.damageDef = {
  description = "Apply one PHYSICAL damage op to a vehicle (beamstate): kind = break_group (needs group), "
    .. "break_hinges, deflate_tire (wheel id; omit = all tires), deform_group (needs group), or destroy (total). "
    .. "Use list_damage_groups for valid group/wheel values. Physical complement to trigger_damage (flags). "
    .. "Effect manifests over the next physics steps — observe via screenshot/get_damage_data. Repair with "
    .. "reset_vehicle. Defaults to the player vehicle.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = true },
  inputSchema = {
    type = "object",
    properties = {
      kind = { type = "string",
               enum = { "break_group", "break_hinges", "deflate_tire", "deform_group", "destroy" },
               description = "the damage op (see tool description)" },
      group = { type = "string", description = "break/deform group name (for break_group/deform_group)" },
      wheel = { type = "number", description = "wheel id for deflate_tire (omit = all tires)" },
      id = { type = "number", description = "vehicle id (default: player)" },
    },
    required = { "kind" },
  },
  handler = damageHandler,
}

function M.register(registry)
  registry:add("list_damage_groups", M.listDef)
  registry:add("damage_vehicle", M.damageDef)
end

return M
