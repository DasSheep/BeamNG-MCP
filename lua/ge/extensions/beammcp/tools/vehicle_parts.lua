-- vehicle_parts: expose a model's available parts by slot (incl. subparts) so an agent can synthesize a
-- part-config — WITHOUT spawning the model. Builds a standalone jbeam ioCtx (jbeam/io.startLoading) and reads
-- the slot->parts map + each part's sub-slots. Engine coupling lives in stubbable M.loadRaw; the shaping is
-- pure (M.buildScoped = one node; M.buildSummary = counts; M.buildFull = full reachable; M.buildReachable =
-- walk from mainPart, trim to reachable, cycle-guarded). Three handler modes: scoped (default), summary, full.
-- This is the discovery half of "AI builds a custom car"; spawning a synthesized config is spawn_vehicle's inline-config path (or set_config).
local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine): build a standalone ioCtx for the model and return
-- { mainPart, slotMap = {slot:[parts]}, partInfo = {part:{description, subSlots:[slotType...]}} }, or nil if
-- the model is unknown/unloadable (no mainPart or empty slot map). slotInfoUi keys are the part's sub-slots.
function M.loadRaw(model)
  local jio = require("jbeam/io")
  -- An unknown/empty model dir makes getAvailableSlotNameMap THROW (pairs(nil) internally), and other io
  -- calls can error too, so pcall-guard them and treat any failure as "unknown/unloadable model" (nil).
  local okCtx, ioCtx = pcall(jio.startLoading, { "/vehicles/" .. model .. "/", "/vehicles/common/" })
  if not okCtx or type(ioCtx) ~= "table" then return nil end
  local okMain, mainPart = pcall(jio.getMainPartName, ioCtx)
  local okSlot, slotMap = pcall(jio.getAvailableSlotNameMap, ioCtx)
  if not okMain or not mainPart or not okSlot or type(slotMap) ~= "table" or next(slotMap) == nil then
    return nil
  end
  local partInfo = {}
  local okAp, ap = pcall(jio.getAvailableParts, ioCtx)
  for part, info in pairs((okAp and type(ap) == "table" and ap) or {}) do
    local subSlots = {}
    if type(info.slotInfoUi) == "table" then
      for subSlot in pairs(info.slotInfoUi) do subSlots[#subSlots + 1] = subSlot end
      table.sort(subSlots)
    end
    partInfo[part] = { description = info.description, subSlots = subSlots }
  end
  return { mainPart = mainPart, slotMap = slotMap, partInfo = partInfo }
end

-- Pure: count entries in a (possibly non-array) table.
local function tcount(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- Pure: only the slots/parts reachable from mainPart (walk part -> its subSlots -> those slots' candidate
-- parts -> recurse). Cycle-guarded via a visited set; tolerant of missing parts/slots.
function M.buildReachable(raw)
  local slots, parts, visited = {}, {}, {}
  local function visitPart(part)
    if visited[part] then return end
    visited[part] = true
    local info = raw.partInfo[part]
    if not info then return end
    parts[part] = info
    for _, subSlot in ipairs(info.subSlots) do
      if not slots[subSlot] then
        local candidates = raw.slotMap[subSlot] or {}
        slots[subSlot] = candidates
        for _, candidate in ipairs(candidates) do visitPart(candidate) end
      end
    end
  end
  visitPart(raw.mainPart)
  return { slots = slots, parts = parts }
end

-- Pure: ONE node — the focused part's description + its direct sub-slots mapped to candidate part NAMES.
-- Returns nil for an unknown part (handler -> unknown-part error). Descriptions stay lazy: only the focused
-- part's own description is returned (candidates are names; descend with another scoped call).
function M.buildScoped(raw, part)
  local info = raw.partInfo[part]
  if not info then return nil end
  local slots = {}
  for _, subSlot in ipairs(info.subSlots) do
    slots[subSlot] = raw.slotMap[subSlot] or {}
  end
  return { part = part, description = info.description, slots = slots }
end

-- Pure: reachable slots -> candidate count, plus totals. Reuses the reachable walk.
function M.buildSummary(raw)
  local reachable = M.buildReachable(raw)
  local slots = {}
  for slot, candidates in pairs(reachable.slots) do
    slots[slot] = #candidates
  end
  return {
    slots = slots,
    counts = {
      reachableSlots = tcount(reachable.slots),
      totalSlots = tcount(raw.slotMap),
      totalParts = tcount(raw.partInfo),
    },
  }
end

-- Pure: the full reachable flat map + a size note. The opt-in escape hatch.
function M.buildFull(raw)
  local reachable = M.buildReachable(raw)
  local note = "full reachable map: " .. tcount(reachable.slots) .. " slots / " .. tcount(reachable.parts)
    .. " parts — large; prefer scoped/summary for navigation"
  return { slots = reachable.slots, parts = reachable.parts, note = note }
end

-- Pure: reachable slots whose slot-name OR any candidate part-name contains `needle` (case-insensitive
-- substring), each with ALL its candidate names. Reuses the reachable walk. Returns { slots, count }.
-- One call to jump to the slots relevant to a build area (e.g. "suspension"); a bounded subset of `full`.
function M.buildFilter(raw, needle)
  local reachable = M.buildReachable(raw)
  local ln = string.lower(needle)
  local slots, count = {}, 0
  for slot, candidates in pairs(reachable.slots) do
    local match = string.find(string.lower(slot), ln, 1, true) ~= nil
    if not match then
      for _, c in ipairs(candidates) do
        if string.find(string.lower(c), ln, 1, true) then match = true; break end
      end
    end
    if match then slots[slot] = candidates; count = count + 1 end
  end
  return { slots = slots, count = count }
end

local function handler(args)
  if type(args) ~= "table" or type(args.model) ~= "string" or args.model == "" then
    return nil, "get_vehicle_parts: 'model' must be a non-empty string"
  end
  local summary = args.summary == true
  local full = args.full == true
  if args.filter ~= nil and type(args.filter) ~= "string" then
    return nil, "get_vehicle_parts: 'filter' must be a string"
  end
  -- empty filter normalizes to nil (an empty substring would match every slot — a full dump)
  local filter = (type(args.filter) == "string" and args.filter ~= "") and args.filter or nil
  local modes = (summary and 1 or 0) + (full and 1 or 0) + (filter and 1 or 0)
  if modes > 1 then
    return nil, "get_vehicle_parts: pass at most one of summary / full / filter"
  end
  if args.part ~= nil and modes > 0 then
    return nil, "get_vehicle_parts: 'part' applies only to scoped mode (drop summary/full/filter)"
  end
  local raw = M.loadRaw(args.model)
  if not raw then
    return nil, "get_vehicle_parts: unknown or unloadable model '" .. args.model .. "'"
  end
  if filter then
    local built = M.buildFilter(raw, filter)
    local res = { model = args.model, mainPart = raw.mainPart, mode = "filter", filter = filter,
                  count = built.count, slots = built.slots }
    if built.count == 0 then
      res.note = "no reachable slots/parts match '" .. filter .. "'"
    end
    return res
  elseif summary then
    local built = M.buildSummary(raw)
    return { model = args.model, mainPart = raw.mainPart, mode = "summary",
             slots = built.slots, counts = built.counts }
  elseif full then
    local built = M.buildFull(raw)
    return { model = args.model, mainPart = raw.mainPart, mode = "full",
             note = built.note, slots = built.slots, parts = built.parts }
  else
    local part = args.part or raw.mainPart
    local built = M.buildScoped(raw, part)
    if not built then
      return nil, "get_vehicle_parts: unknown part '" .. tostring(part) .. "' for model '" .. args.model
        .. "' (use summary, or start from the main part)"
    end
    return { model = args.model, mainPart = raw.mainPart, mode = "scoped",
             part = built.part, description = built.description, slots = built.slots }
  end
end

M.def = {
  description = "Discover a model's parts to BUILD a part-config (not the active vehicle's parts — see "
    .. "get_vehicle_config / get_vehicle_powertrain; does not spawn). Pass at most one of summary/full/filter; "
    .. "the default is scoped navigation from the main part (pass a returned candidate name as `part` to "
    .. "descend one level). Prefer filter (jump to a build area like 'suspension') / scoped / summary; "
    .. "full is LARGE (tens of thousands of tokens).",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      model = { type = "string", description = "jbeam model name, e.g. 'pigeon', 'us_semi'" },
      part = { type = "string", description = "scoped mode: the part to inspect (default: the main part). "
        .. "Pass a candidate name from a previous scoped response to descend one level." },
      filter = { type = "string", description = "filter mode: case-insensitive substring; returns reachable "
        .. "slots whose name or a candidate part-name matches, each with its candidates (e.g. 'suspension')" },
      summary = { type = "boolean", description = "overview: reachable slots -> candidate counts + totals" },
      full = { type = "boolean", description = "opt-in: the whole reachable map (LARGE)" },
    },
    required = { "model" },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("get_vehicle_parts", M.def)
end

return M
