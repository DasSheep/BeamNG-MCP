require("support.beamng_stubs")
local stub      = require("support.stub")
local autoheal  = require("beammcp/reload/autoheal")
local snapshot  = require("beammcp/reload/snapshot")
local guardlist = require("beammcp/reload/guardlist")
local env       = require("beammcp/reload/env")

local MISSION = "/levels/a/main.level.json"
local FILE = { v = 1, reloadId = "r1", at = 100, level = MISSION, camMode = "orbit" }

-- one fake guard that is broken until repaired
local function brokenGuard()
  local g = { name = "nightlights", broken = true }
  g.check = function() if g.broken then return { issue = "x" } end end
  g.repair = function() g.broken = false end
  return g
end

-- a guard that always reports an issue and whose repair always mitigates (never resolves), optionally
-- with a followUp for the post-heal window tests.
local function mitigatingGuard(followUp)
  local g = { name = "camera" }
  g.check = function() return { issue = "x" } end
  g.repair = function() return { mitigated = "press Ctrl+R" } end
  if followUp then g.followUp = followUp end
  return g
end

-- runs fn with the engine seams stubbed; returns the captured log/toast/delete record
-- opts.mission / opts.loading override env seams (default: MISSION / not-loading); opts.now / opts.newId /
-- opts.capture / opts.guardList override the corresponding snapshot/guardlist seams; rec.written captures
-- whatever table was last passed to snapshot.write.
local function scenario(opts, fn)
  local rec = { logs = {}, toasts = 0, deleted = 0 }
  local g = brokenGuard()
  stub.with(env, { mission = opts.mission or function() return MISSION end,
                   loading = opts.loading or function() return false end,
                   hasPlayerVehicle = function() return true end }, function()
    stub.with(snapshot, { read = function() return opts.file end, now = function() return opts.now or 110 end,
                          delete = function() rec.deleted = rec.deleted + 1 end,
                          capture = opts.capture or function() return { reloadId = "new1" } end,
                          newId = opts.newId or function() return "new1" end,
                          write = function(snap)
                            rec.written = snap
                            return opts.writeOk ~= false, "boom"
                          end }, function()
      stub.with(guardlist, { list = opts.guardList or function() return { g } end }, function()
        stub.with(autoheal, { log = function(lvl, msg) rec.logs[#rec.logs + 1] = lvl .. " " .. msg end,
                              toast = function() rec.toasts = rec.toasts + 1 end,
                              toastEnabled = function() return opts.toast ~= false end }, function()
          autoheal._reset()
          fn(rec, g)
        end)
      end)
    end)
  end)
  return rec
end

local function frames(n) for _ = 1, n do autoheal.update(0.016) end end

test("captureForReload writes the snapshot and returns its reloadId", function()
  scenario({}, function(rec)
    local out = autoheal.captureForReload()
    assertEqual(out.reloadId, "new1")
    assertEqual(#rec.logs, 0)
  end)
end)

test("captureForReload logs a failed write but still returns the id", function()
  scenario({ writeOk = false }, function(rec)
    assertEqual(autoheal.captureForReload().reloadId, "new1")
    assertMatch(rec.logs[1], "^W snapshot write failed")
  end)
end)

test("cold start (no file): never runs, nothing logged", function()
  scenario({ file = nil }, function(rec, g)
    autoheal.onLoaded()
    frames(30)
    assertEqual(g.broken, true)
    assertNil(autoheal.last)
    assertEqual(#rec.logs, 0)
  end)
end)

test("normal reload: repairs once after the gate, toasts, deletes the file", function()
  scenario({ file = FILE }, function(rec, g)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(5)
    assertEqual(g.broken, true, "must wait for the gate")
    frames(10)
    assertEqual(g.broken, false)
    assertEqual(autoheal.last.classification, "normal")
    assertEqual(rec.toasts, 1)
    assertEqual(rec.deleted, 1)
    assertMatch(rec.logs[1], "^I normal reload; repaired: nightlights")
    frames(30)
    assertEqual(rec.deleted, 1, "runs at most once")
  end)
end)

test("total failure (no blob id): classified total, repaired, logged at W", function()
  scenario({ file = FILE }, function(rec, g)
    autoheal.onLoaded()
    frames(15)
    assertEqual(autoheal.last.classification, "total")
    assertEqual(g.broken, false)
    assertMatch(rec.logs[1], "^W total reload")
  end)
end)

test("stale file: reported, no repair, file deleted, no toast", function()
  scenario({ file = { v = 1, reloadId = "r1", at = -1000, level = MISSION } }, function(rec, g)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(autoheal.last.classification, "stale")
    assertEqual(g.broken, true)
    assertEqual(rec.deleted, 1)
    assertEqual(rec.toasts, 0)
  end)
end)

test("reload in the main menu (file level ''): disarmed, file deleted", function()
  -- env.mission() is also "" in the main menu (not stubbed back to MISSION) -- both sides of the
  -- disarm check are the same string here, so only the explicit level=="" clause catches this case.
  scenario({ file = { v = 1, reloadId = "r1", at = 105, level = "" }, mission = function() return "" end },
    function(rec)
      autoheal.onLoaded()
      frames(30)
      assertNil(autoheal.last)
      assertEqual(rec.deleted, 1)
      assertEqual(#rec.logs, 0)
    end)
end)

test("a mitigation alone (nothing repaired) still toasts", function()
  scenario({ file = FILE }, function(rec, g)
    g.repair = function() return { mitigated = "press Ctrl+R" } end   -- stays broken, but mitigated
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(autoheal.last.mitigatedCount, 1)
    assertEqual(rec.toasts, 1)
    assertMatch(rec.logs[1], "mitigated: nightlights %(press Ctrl%+R%)")
  end)
end)

test("toast disabled -> no toast even when repaired", function()
  scenario({ file = FILE, toast = false }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(rec.toasts, 0)
  end)
end)

test("lastCompact exposes the compact report", function()
  scenario({ file = FILE }, function()
    assertNil(autoheal.lastCompact())
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    local c = autoheal.lastCompact()
    assertEqual(c.classification, "normal")
    assertEqual(c.repaired[1], "nightlights")
  end)
end)

test("fresh-boot misfire: leftover file's level does not match the current mission -> disarmed, deleted", function()
  scenario({ file = FILE, mission = function() return "" end }, function(rec, g)
    autoheal.onLoaded()
    frames(30)
    assertNil(autoheal.last)
    assertEqual(rec.deleted, 1)
    assertEqual(g.broken, true)
  end)
end)

test("re-reload before heal: captureForReload reuses the armed file with a fresh id, never calls capture()", function()
  scenario({ file = FILE, now = 200, newId = function() return "id2" end,
             capture = function() error("capture must not be called while armed and not done") end },
    function(rec)
      autoheal.onLoaded()
      local out = autoheal.captureForReload()
      assertEqual(out.reloadId, "id2")
      assertEqual(rec.written.level, MISSION)
      assertEqual(rec.written.camMode, "orbit")
      assertEqual(rec.written.reloadId, "id2")
      assertEqual(rec.written.at, 200)
    end)
end)

test("re-reload before heal but the armed file is stale: captureForReload captures fresh instead of reusing", function()
  local capturedCalled = false
  scenario({ file = FILE, now = 500,   -- FILE.at = 100; 500 - 100 = 400 > detect.MAX_AGE (300)
             capture = function() capturedCalled = true; return { reloadId = "fresh1" } end },
    function(rec)
      autoheal.onLoaded()
      local out = autoheal.captureForReload()
      assertTrue(capturedCalled, "capture() should run for a stale armed file")
      assertEqual(out.reloadId, "fresh1")
    end)
end)

test("isolated run: a guard-listing failure still deletes the file and records the error", function()
  scenario({ file = FILE, guardList = function() error("guardlist boom") end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(rec.deleted, 1)
    assertTrue(autoheal.last.error ~= nil)
    assertMatch(rec.logs[1], "^W")
  end)
end)

test("timeout: gate never becomes ready -> timeout reported, no repair, file deleted, W logged", function()
  scenario({ file = FILE, loading = function() return true end }, function(rec, g)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    for _ = 1, 11 do autoheal.update(1.0) end
    assertEqual(autoheal.last.timeout, true)
    assertEqual(g.broken, true)
    assertEqual(rec.deleted, 1)
    assertMatch(rec.logs[1], "^W")
  end)
end)

-- ============================== post-heal follow-up window ==============================
-- Some engine fallbacks (e.g. a freecam the engine drops in ~1 s after our levelflag repair re-opens the
-- camera-update gate) appear only after the heal frame. A `mitigated` guard that exports `followUp` gets
-- polled for a short window afterward.

test("follow-up: a mitigated guard's followUp is ticked each frame until it reports done, then never again", function()
  local calls = 0
  local results = { false, false, true }
  local mg = mitigatingGuard(function() calls = calls + 1; return results[calls] end)
  scenario({ file = FILE, guardList = function() return { mg } end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(10)   -- the gate becomes ready and the heal runs on exactly this frame
    assertEqual(autoheal.last.mitigatedCount, 1)
    assertEqual(calls, 0, "followUp is armed at the end of the heal frame, not ticked within it")
    frames(1); assertEqual(calls, 1)
    frames(1); assertEqual(calls, 2)
    frames(1); assertEqual(calls, 3)
    frames(10)
    assertEqual(calls, 3, "must not be called again once it reports done")
  end)
end)

test("follow-up: a followUp that never finishes stops after FOLLOWUP_SECONDS of dt", function()
  local calls = 0
  local mg = mitigatingGuard(function() calls = calls + 1; return false end)
  scenario({ file = FILE, guardList = function() return { mg } end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(10)
    assertEqual(calls, 0)
    autoheal.update(4.0)                 -- 4s of the 8s (M.FOLLOWUP_SECONDS) budget spent
    assertEqual(calls, 1)
    autoheal.update(4.5)                 -- budget exhausted mid-tick: cleared, no further call
    assertEqual(calls, 1)
    autoheal.update(1.0)
    assertEqual(calls, 1)
  end)
end)

test("follow-up: a throwing followUp is logged once at W and then dropped", function()
  local calls = 0
  local mg = mitigatingGuard(function() calls = calls + 1; error("followUp boom") end)
  scenario({ file = FILE, guardList = function() return { mg } end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(10)
    local logsBefore = #rec.logs
    frames(1)
    assertEqual(calls, 1)
    assertEqual(#rec.logs, logsBefore + 1)
    assertMatch(rec.logs[#rec.logs], "^W")
    frames(10)
    assertEqual(calls, 1, "dropped after the single failure")
  end)
end)

test("follow-up: a mitigated guard without followUp is simply never scheduled", function()
  local mg = mitigatingGuard()   -- no followUp exported
  scenario({ file = FILE, guardList = function() return { mg } end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(autoheal.last.mitigatedCount, 1)
    frames(10)   -- must not error with no follow-ups pending
  end)
end)

test("follow-up: a plainly-repaired (not mitigated) guard's followUp is never invoked", function()
  local calls = 0
  scenario({ file = FILE, guardList = function()
      local g = brokenGuard()
      g.followUp = function() calls = calls + 1; return true end
      return { g }
    end }, function(rec)
    autoheal.onLoaded()
    autoheal.receiveBlobId({ reloadId = "r1" })
    frames(15)
    assertEqual(autoheal.last.repairedCount, 1)
    frames(10)
    assertEqual(calls, 0)
  end)
end)
