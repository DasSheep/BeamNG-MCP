local runner = require("beammcp/reload/runner")

-- a fake guard whose state is a boolean "broken"; repair fixes it unless `stuck`
local function fake(name, opts)
  opts = opts or {}
  local g = { name = name, broken = opts.broken or false, repairs = 0 }
  g.check = function()
    if opts.throwCheck then error("check boom") end
    if opts.skip then return { skip = opts.skip } end
    if g.broken then return { issue = name .. " broken" } end
    return nil
  end
  if not opts.reportOnly then
    g.repair = function()
      if opts.throwRepair then error("repair boom") end
      g.repairs = g.repairs + 1
      if not opts.stuck then g.broken = false end
    end
  end
  return g
end

local function byName(report, name)
  for _, e in ipairs(report.guards) do if e.name == name then return e end end
end

test("healthy guard -> ok, no repair", function()
  local g = fake("a")
  local r = runner.run({ g }, { mode = "manual" }, true)
  assertEqual(byName(r, "a").outcome, "ok")
  assertEqual(g.repairs, 0)
  assertEqual(r.repairedCount, 0)
end)

test("dry run reports the issue and never repairs", function()
  local g = fake("a", { broken = true })
  local r = runner.run({ g }, { mode = "manual" }, false)
  assertEqual(byName(r, "a").outcome, "issue")
  assertEqual(byName(r, "a").issue, "a broken")
  assertEqual(g.repairs, 0)
  assertEqual(r.apply, false)
end)

test("apply repairs and re-checks", function()
  local g = fake("a", { broken = true })
  local r = runner.run({ g }, { mode = "auto", classification = "normal" }, true)
  assertEqual(byName(r, "a").outcome, "repaired")
  assertEqual(r.repairedCount, 1)
  assertEqual(r.classification, "normal")
end)

test("repair that does not take -> repair_ineffective", function()
  local r = runner.run({ fake("a", { broken = true, stuck = true }) }, {}, true)
  assertEqual(byName(r, "a").outcome, "repair_ineffective")
  assertEqual(byName(r, "a").after, "a broken")
  assertEqual(r.repairedCount, 0)
end)

test("skip is reported with its reason", function()
  local r = runner.run({ fake("a", { skip = "no level loaded" }) }, {}, true)
  assertEqual(byName(r, "a").outcome, "skipped")
  assertEqual(byName(r, "a").reason, "no level loaded")
end)

test("a throwing guard is isolated; later guards still run", function()
  local r = runner.run({ fake("a", { throwCheck = true }), fake("b", { broken = true, throwRepair = true }),
                         fake("c", { broken = true }) }, {}, true)
  assertEqual(byName(r, "a").outcome, "error")
  assertEqual(byName(r, "a").phase, "check")
  assertEqual(byName(r, "b").outcome, "error")
  assertEqual(byName(r, "b").phase, "repair")
  assertEqual(byName(r, "c").outcome, "repaired")
end)

test("report-only guard (no repair fn) stays 'issue' under apply", function()
  local r = runner.run({ fake("x", { broken = true, reportOnly = true }) }, {}, true)
  assertEqual(byName(r, "x").outcome, "issue")
end)

test("guards run in the given order", function()
  local r = runner.run({ fake("first"), fake("second"), fake("third") }, {}, true)
  assertEqual(r.guards[1].name, "first")
  assertEqual(r.guards[3].name, "third")
end)

test("compact lists repaired and failed names", function()
  local r = runner.run({ fake("a", { broken = true }), fake("b", { broken = true, stuck = true }),
                         fake("c", { throwCheck = true }), fake("d") }, { classification = "total", now = 9 }, true)
  local c = runner.compact(r)
  assertEqual(c.classification, "total")
  assertEqual(c.at, 9)
  assertEqual(#c.repaired, 1)
  assertEqual(c.repaired[1], "a")
  assertEqual(#c.failed, 2)
end)

test("repair returning false (declined) keeps outcome 'issue' and skips the re-check", function()
  local checks = 0
  local g = { name = "x" }
  g.check = function() checks = checks + 1; return { issue = "still" } end
  g.repair = function() return false end
  local r = runner.run({ g }, {}, true)
  assertEqual(byName(r, "x").outcome, "issue")
  assertEqual(checks, 1)
end)

test("repair returning {mitigated} with a still-unhealthy re-check -> 'mitigated' with the note", function()
  local g = { name = "camera" }
  g.check = function() return { issue = "registry empty" } end
  g.repair = function() return { mitigated = "press Ctrl+R" } end
  local r = runner.run({ g }, {}, true)
  assertEqual(byName(r, "camera").outcome, "mitigated")
  assertEqual(byName(r, "camera").note, "press Ctrl+R")
  assertEqual(r.mitigatedCount, 1)
  assertEqual(r.repairedCount, 0)
  local c = runner.compact(r)
  assertEqual(c.mitigated[1], "camera")
  assertEqual(#c.failed, 0)
  assertMatch(runner.summary(r), "mitigated: camera %(press Ctrl%+R%)")
end)

test("repair returning {mitigated} but a clean re-check counts as repaired", function()
  local fixed = false
  local g = { name = "extensions" }
  g.check = function() if not fixed then return { issue = "missing" } end end
  g.repair = function() fixed = true; return { mitigated = "partial" } end
  local r = runner.run({ g }, {}, true)
  assertEqual(byName(r, "extensions").outcome, "repaired")
end)

test("summary is human-readable", function()
  local r = runner.run({ fake("nightlights", { broken = true }) }, { classification = "normal" }, true)
  assertMatch(runner.summary(r), "^normal reload; repaired: nightlights")
  local quiet = runner.run({ fake("a") }, { classification = "normal" }, true)
  assertMatch(runner.summary(quiet), "nothing to repair")
  assertMatch(runner.summary({ classification = "total", timeout = true, guards = {}, repairedCount = 0 }),
    "timed out")
end)

test("check returning false counts as healthy, not an issue; later guards still run", function()
  local ran = false
  local g1 = { name = "a", check = function() return false end }
  local g2 = { name = "b", check = function() ran = true; return nil end }
  local r = runner.run({ g1, g2 }, {}, true)
  assertEqual(byName(r, "a").outcome, "ok")
  assertEqual(ran, true)
  assertEqual(byName(r, "b").outcome, "ok")
end)

test("check returning a non-table truthy value is an error; later guards still run", function()
  local g1 = { name = "a", check = function() return true end }
  local g2 = { name = "b", check = function() return nil end }
  local r = runner.run({ g1, g2 }, {}, true)
  assertEqual(byName(r, "a").outcome, "error")
  assertEqual(byName(r, "a").phase, "check")
  assertMatch(byName(r, "a").error, "check returned boolean")
  assertEqual(byName(r, "b").outcome, "ok")
end)

test("repair fixes the guard and the re-check returns false -> repaired", function()
  local fixed = false
  local g = { name = "x" }
  g.check = function()
    if fixed then return false end
    return { issue = "broken" }
  end
  g.repair = function() fixed = true end
  local r = runner.run({ g }, {}, true)
  assertEqual(byName(r, "x").outcome, "repaired")
  assertEqual(r.repairedCount, 1)
end)

test("summary tolerates a nil report", function()
  assertEqual(type(runner.summary(nil)), "string")
end)
