-- reload/runner: applies an ordered guard list and builds the report. Each guard is
-- { name, check(ctx) -> nil | {issue=..., missing=...} | {skip=reason}, repair?(ctx) }. Every call is
-- pcall-isolated, so one failing guard never stops the rest. With apply, an issue is repaired and then
-- re-checked; only a clean re-check counts as "repaired" (no claiming success that did not happen).
-- repair may return false (declined in this context -> stays "issue") or {mitigated=note} (partial fix:
-- an unhealthy re-check then reports "mitigated" with the note instead of "repair_ineffective").
-- Outcomes: ok | issue | repaired | mitigated | repair_ineffective | skipped | error.
local M = {}

local function afterText(cok, r2)
  if not cok then return tostring(r2) end
  if type(r2) ~= "table" then return "check returned " .. type(r2) end
  return r2.issue or ("skipped: " .. tostring(r2.skip))
end

function M.run(guards, ctx, apply)
  ctx = ctx or {}
  local report = {
    mode = ctx.mode, classification = ctx.classification,
    reloadId = ctx.snap and ctx.snap.reloadId, at = ctx.now,
    apply = apply == true, guards = {}, repairedCount = 0, mitigatedCount = 0,
  }
  for _, g in ipairs(guards) do
    local e = { name = g.name }
    local ok, r = pcall(g.check, ctx)
    if not ok then
      e.outcome, e.error, e.phase = "error", tostring(r), "check"
    elseif not r then
      e.outcome = "ok"
    elseif type(r) ~= "table" then
      e.outcome, e.error, e.phase = "error", "check returned " .. type(r), "check"
    elseif r.skip then
      e.outcome, e.reason = "skipped", r.skip
    else
      e.issue, e.missing = r.issue, r.missing
      if not apply or type(g.repair) ~= "function" then
        e.outcome = "issue"
      else
        local rok, res = pcall(g.repair, ctx)
        if not rok then
          e.outcome, e.error, e.phase = "error", tostring(res), "repair"
        elseif res == false then
          e.outcome = "issue"                       -- declined in this context
        else
          local cok, r2 = pcall(g.check, ctx)
          if cok and not r2 then
            e.outcome = "repaired"
            report.repairedCount = report.repairedCount + 1
          elseif type(res) == "table" and res.mitigated then
            e.outcome, e.note, e.after = "mitigated", res.mitigated, afterText(cok, r2)
            report.mitigatedCount = report.mitigatedCount + 1
          else
            e.outcome, e.after = "repair_ineffective", afterText(cok, r2)
          end
        end
      end
    end
    report.guards[#report.guards + 1] = e
  end
  return report
end

function M.compact(report)
  if type(report) ~= "table" then return nil end
  local c = { at = report.at, classification = report.classification, timeout = report.timeout,
              repaired = {}, mitigated = {}, failed = {}, notes = {} }
  for _, e in ipairs(report.guards or {}) do
    if e.outcome == "repaired" then
      c.repaired[#c.repaired + 1] = e.name
    elseif e.outcome == "mitigated" then
      c.mitigated[#c.mitigated + 1] = e.name
      c.notes[#c.notes + 1] = e.name .. ": " .. tostring(e.note)
    elseif e.outcome == "error" or e.outcome == "repair_ineffective" then
      c.failed[#c.failed + 1] = e.name
    end
  end
  return c
end

function M.summary(report)
  if type(report) ~= "table" then report = {} end
  local c = M.compact(report) or { repaired = {}, mitigated = {}, failed = {} }
  local parts = { tostring(c.classification or report.mode or "manual") .. " reload" }
  if c.timeout then parts[#parts + 1] = "timed out waiting for the level" end
  if #c.repaired > 0 then parts[#parts + 1] = "repaired: " .. table.concat(c.repaired, ", ") end
  if #c.mitigated > 0 then
    local items = {}
    for _, e in ipairs(report.guards or {}) do
      if e.outcome == "mitigated" then items[#items + 1] = e.name .. " (" .. tostring(e.note) .. ")" end
    end
    parts[#parts + 1] = "mitigated: " .. table.concat(items, ", ")
  end
  if #c.failed > 0 then parts[#parts + 1] = "failed: " .. table.concat(c.failed, ", ") end
  if #c.repaired == 0 and #c.mitigated == 0 and #c.failed == 0 and not c.timeout then
    parts[#parts + 1] = "nothing to repair"
  end
  return table.concat(parts, "; ")
end

return M
