-- guard extensions: lists extensions that were loaded before the reload but are not now. After a TOTAL
-- blob failure the extension manager cannot reload the blob's module list (in-engine repro: 91 of 267 gone -
-- drag/drift/crawl/walk/achievements, quickAccess, weather, traffic signals, gas stations, third-party mod
-- HUDs, BeamMP GE modules). In total mode the repair:
--   1. batch-loads the missing names in ONE extensions.load(list) call, so dependencies resolve together;
--   2. replays the level-start hooks (Pre/Post/Start, engine order and arguments - server.lua:114/350/355)
--      ONLY on the modules that just came back: they were loaded mid-level and missed the hooks where they
--      read their level data. They are fresh (stateless), so there is nothing to clobber.
-- Verified in-engine: 43 still-missing loaded in one call, 8 hook-bearing modules replayed, no errors.
-- Names from non-standard roots (e.g. a mod's /scripts/<name>/ module) still fail and are reported as a
-- mitigation. Outside total mode the repair declines (returns false): report-only.
local env = require("beammcp/reload/env")
local M = { name = "extensions" }

M.SELF = "beammcp"
M.LEVEL_HOOKS = { "onClientPreStartMission", "onClientPostStartMission", "onClientStartMission" }

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.loadedNames() return extensions.getLoadedExtensionsNames(true) end   -- excludeVirtual
function M.loadBatch(names) extensions.load(names) end
function M.module(name) return rawget(_G, name) end

-- flowgraph "<prefix>_virtual_N" proxies are never serialized/reloadable; ignore them on both sides
-- (belt-and-braces alongside the excludeVirtual arg to loadedNames()).
local function isVirtual(n) return type(n) == "string" and n:find("_virtual_", 1, true) ~= nil end

function M.replayLevelHooks(names, mission)
  for i, hook in ipairs(M.LEVEL_HOOKS) do
    local arg = (i < #M.LEVEL_HOOKS) and mission:lower() or mission   -- Pre/Post: lowered path; Start: mission
    for _, n in ipairs(names) do
      local m = M.module(n)
      if type(m) == "table" and type(m[hook]) == "function" then pcall(m[hook], arg) end
    end
  end
end

function M.check(ctx)
  local before = ctx and ctx.snap and ctx.snap.extensions
  if type(before) ~= "table" then return { skip = "no snapshot" } end
  local now = {}
  for _, n in ipairs(M.loadedNames() or {}) do
    if not isVirtual(n) then now[n] = true end
  end
  local missing = {}
  for _, n in ipairs(before) do
    if n ~= M.SELF and not isVirtual(n) and not now[n] then missing[#missing + 1] = n end
  end
  if #missing == 0 then return nil end
  table.sort(missing)
  return { issue = #missing .. " extension(s) did not come back after the reload", missing = missing }
end

function M.repair(ctx)
  if not ctx or ctx.classification ~= "total" then return false end
  local before = M.check(ctx)
  if not (before and before.missing) then return nil end
  pcall(M.loadBatch, before.missing)
  local after = M.check(ctx)
  local still = {}
  for _, n in ipairs(after and after.missing or {}) do still[n] = true end
  local cameBack = {}
  for _, n in ipairs(before.missing) do if not still[n] then cameBack[#cameBack + 1] = n end end
  if env.mission() ~= "" then M.replayLevelHooks(cameBack, env.mission()) end
  if after and after.missing then
    return { mitigated = string.format("reloaded %d of %d; still missing: %s",
      #before.missing - #after.missing, #before.missing, table.concat(after.missing, ", ")) }
  end
  return nil
end

return M
