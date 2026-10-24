-- get_vehicle_config: read a SPAWNED vehicle's INSTALLED parts (the build read-back) for AI car building.
-- GE-synchronous read of core_vehicle_manager.getVehicleData(id).config.partsTree (a hierarchical node tree;
-- each node: id [slot name] / path [unique] / chosenPartName [installed part or ""] / children [map]). The root
-- node is the main part. Compact by default:
--   default      -> flat { slot: chosenPartName } = the .pc-equivalent that round-trips into set_config
--   detail=true  -> + the nested `tree` (incl. empty slots) for the build hierarchy
-- The flat map REPLICATES BeamNG's own partmgmt.saveVehicle flatten: collect descendants by path, key by node
-- id, fall back to the full path when two slots share an id (collision), drop empty parts. The complement to
-- get_vehicle_parts (a model's AVAILABLE parts) and get_vehicle_tuning (the live tuning vars).
local M = {}

-- ---- pure shapers ------------------------------------------------------------------------

-- flatten(partsTree) -> { slot: chosenPartName }. Replicates partmgmt.saveVehicle's flattenPartsTreeRecursive
-- + simplify: walk children (root/main excluded), key by node id, on an id collision fall back to the full
-- path for BOTH colliding entries, then drop empty chosenPartName. Pure.
function M.flatten(partsTree)
  local byPath = {}
  local function walk(node)
    if type(node) ~= "table" or type(node.children) ~= "table" then return end
    for _, child in pairs(node.children) do
      byPath[child.path] = { id = child.id, path = child.path, part = child.chosenPartName }
      walk(child)
    end
  end
  walk(partsTree)

  local simple = {}
  for _, d in pairs(byPath) do
    if simple[d.id] == nil then
      simple[d.id] = d
    else
      local tmp = simple[d.id]
      if tmp ~= "COLLISION" then
        simple[tmp.path] = tmp
        simple[d.id] = "COLLISION"
      end
      simple[d.path] = d
    end
  end

  local parts = {}
  for key, d in pairs(simple) do
    if d ~= "COLLISION" and type(d.part) == "string" and d.part ~= "" then
      parts[key] = d.part
    end
  end
  return parts
end

-- buildTree(partsTree) -> nested { slot: { part, children? } } keyed by node id; includes empty slots; leaves
-- omit `children`. Pure.
function M.buildTree(partsTree)
  local function build(node)
    local out = {}
    -- Key by the children-map key (the authoritative slot for this parent; unique within it), not by
    -- child.id — they're equal in practice, but the map key can never clobber a sibling.
    for slot, child in pairs(node.children or {}) do
      local entry = { part = child.chosenPartName }
      if type(child.children) == "table" and next(child.children) ~= nil then
        entry.children = build(child)
      end
      out[slot] = entry
    end
    return out
  end
  if type(partsTree) ~= "table" then return {} end
  return build(partsTree)
end

local function countKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- ---- engine seam (stubbed in tests, verified in-engine) ----------------------------------
-- Returns { model, mainPart, partsTree } for the vehicle id, or nil + clean error.
function M.fetch(id)
  local veh = be:getObjectByID(id)
  if not veh then return nil, "get_vehicle_config: unknown vehicle id " .. tostring(id) end
  local vData = core_vehicle_manager.getVehicleData(id)
  local cfg = vData and vData.config
  if not cfg or type(cfg.partsTree) ~= "table" then
    return nil, "get_vehicle_config: no config/partsTree for id " .. tostring(id)
  end
  return { model = veh:getJBeamFilename(), mainPart = cfg.partsTree.chosenPartName, partsTree = cfg.partsTree }
end

local function handler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "get_vehicle_config: arguments must be an object"
  end
  args = args or {}
  if args.id ~= nil and type(args.id) ~= "number" then
    return nil, "get_vehicle_config: 'id' must be a number"
  end
  if args.detail ~= nil and type(args.detail) ~= "boolean" then
    return nil, "get_vehicle_config: 'detail' must be a boolean"
  end

  local id = args.id or be:getPlayerVehicleID(0)
  local data, err = M.fetch(id)
  if not data then return nil, err end

  local parts = M.flatten(data.partsTree)
  local res = { model = data.model, mainPart = data.mainPart, count = countKeys(parts), parts = parts }
  if args.detail == true then res.tree = M.buildTree(data.partsTree) end
  return res
end

M.def = {
  description = "Read a SPAWNED vehicle's INSTALLED parts (the build). DEFAULT (compact): a flat "
    .. "{ slot: part } map (the .pc-equivalent that round-trips into set_config's inline { parts }), plus "
    .. "model/mainPart/count. detail=true adds the nested `tree` (including empty/fillable slots). The "
    .. "complement to get_vehicle_parts (a model's AVAILABLE parts to choose from) and get_vehicle_tuning "
    .. "(the live tuning variables). Defaults to the player vehicle.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      id     = { type = "number",  description = "vehicle id (default: player)" },
      detail = { type = "boolean", description = "also return the nested part tree (incl. empty slots)" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_vehicle_config", M.def)
end

return M
