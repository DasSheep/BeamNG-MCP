-- reload/autoheal: the reload lifecycle. captureForReload (old VM) writes the snapshot file and returns its
-- reloadId for the extension's own onSerialize to fold into the engine blob; after the reload, onLoaded arms
-- from the file, receiveBlobId gets the blob id back from the extension's own onDeserialized (absent if the
-- blob import failed), and update() waits for the level gate, classifies, runs the guards once, deletes the
-- file, and emits: one log line, a toast when something was repaired (or the blob failed), and `last` for
-- get_game_state / recover_game_state.
-- NOTE: this module must never itself be named onSerialize/onDeserialize(d) -- BeamNG's common/utils.lua
-- serializePackages()/deserializePackages() treat ANY package.loaded table exposing those names as an
-- independent persistence participant and call them independently of the extension hooks (the package pass
-- runs BEFORE the extensions pass on serialize, AFTER it on deserialize; beammcp.lua's own
-- onSerialize/onDeserialized run in the extensions pass). That double-fire clobbers state this module's
-- extension hook just set (see test/reload_package_hooks_test.lua). Only lua/ge/extensions/beammcp.lua's
-- M.onSerialize/M.onDeserialized may use those names.
local M = {}
local snapshot  = require("beammcp/reload/snapshot")
local detect    = require("beammcp/reload/detect")
local gate      = require("beammcp/reload/gate")
local runner    = require("beammcp/reload/runner")
local guardlist = require("beammcp/reload/guardlist")
local env       = require("beammcp/reload/env")

local state = { armed = false, done = false }
M.last = nil

-- How long (seconds of real dt) to keep polling a `mitigated` guard's followUp after the heal, for engine
-- fallbacks that only appear a beat later (e.g. the freecam the engine drops ~1 s after our levelflag
-- repair re-opens the camera-update gate).
M.FOLLOWUP_SECONDS = 8

-- Injected by beammcp.lua from the store (panel toggle); default on.
M.toastEnabled = function() return true end

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.probe()
  return { mission = env.mission(), loading = env.loading(), hasVehicle = env.hasPlayerVehicle() }
end
function M.log(level, msg) log(level, "beammcp.reload", msg) end
function M.toast(report)
  guihooks.trigger("toastrMsg", {
    type = report.classification == "total" and "warning" or "info",
    title = "BeamMCP reload recovery",
    msg = runner.summary(report),
  })
end

function M.captureForReload()
  local ok, res = pcall(function()
    local snap
    local fresh = state.file and type(state.file.at) == "number"
      and (snapshot.now() - state.file.at) <= detect.MAX_AGE
    if state.armed and not state.done and state.file and fresh then
      -- A second reload landed before the first one finished healing: the live world right now is the
      -- UNHEALED one, so re-capturing it would overwrite the still-good file with a broken snapshot.
      -- Reuse the armed file's fields, just refreshed with a new id/timestamp. But only while it's still
      -- fresh enough for detect.classify to accept later -- an old armed file is as good as no file, so
      -- fall through to a normal capture instead of writing something that will just be classified stale.
      snap = {}
      for k, v in pairs(state.file) do snap[k] = v end
      snap.reloadId = snapshot.newId()
      snap.at = snapshot.now()
    else
      snap = snapshot.capture()
    end
    local wok, werr = snapshot.write(snap)
    if not wok then M.log("W", "snapshot write failed: " .. tostring(werr)) end
    return { reloadId = snap.reloadId }
  end)
  if ok then return res end
  M.log("W", "snapshot capture failed: " .. tostring(res))
  return nil
end

function M.receiveBlobId(data)
  if type(data) == "table" and type(data.reloadId) == "string" then state.blobId = data.reloadId end
end

function M.onLoaded()
  state.file = snapshot.read()
  state.done = false
  state.gate = gate.new()
  state.armed = state.file ~= nil
  -- A new reload cycle invalidates any follow-up window left over from the previous one.
  state.followUps, state.followUpCtx, state.followUpLeft = nil, nil, nil
  -- A reload in the main menu (file level "") is never something to heal. A genuine in-game Lua reload
  -- never changes the loaded mission either, so a leftover file whose level doesn't match what's loaded
  -- right now (crash after onSerialize, onSerialize fired outside a reload, a stale process, etc.) is not
  -- a reload we should act on. Either way: disarm and clear it silently.
  if state.file and (state.file.level == "" or state.file.level ~= env.mission()) then
    snapshot.delete()
    state.armed = false
  end
end

function M.emit(report)
  local c = runner.compact(report)
  local bad = report.classification == "total" or report.timeout or report.error ~= nil or #c.failed > 0
  local msg = runner.summary(report)
  if report.error then msg = msg .. "; error: " .. tostring(report.error) end
  M.log(bad and "W" or "I", msg)
  local acted = report.repairedCount > 0 or (report.mitigatedCount or 0) > 0
  if (acted or report.classification == "total") and M.toastEnabled() then
    pcall(M.toast, report)
  end
end

-- Polls any guards left pending from a prior heal's `mitigated` outcome (e.g. an engine fallback that only
-- shows up a beat later). Ticked every frame, independently of state.armed/state.done, until each guard's
-- followUp reports done, errors (logged once, then dropped), or the window's time budget runs out.
local function tickFollowUps(dt)
  if not state.followUps then return end
  state.followUpLeft = (state.followUpLeft or 0) - (tonumber(dt) or 0)
  if state.followUpLeft <= 0 then
    state.followUps, state.followUpCtx = nil, nil
    return
  end
  local remaining = {}
  for _, g in ipairs(state.followUps) do
    local ok, done = pcall(g.followUp, state.followUpCtx)
    if not ok then
      M.log("W", "reload follow-up '" .. tostring(g.name) .. "' failed: " .. tostring(done))
    elseif not done then
      remaining[#remaining + 1] = g
    end
  end
  if #remaining > 0 then state.followUps = remaining else state.followUps, state.followUpCtx = nil, nil end
end

function M.update(dt)
  tickFollowUps(dt)
  if not state.armed or state.done then return end
  local st = state.gate:tick(dt, M.probe())
  if st == "wait" then return end
  state.done = true
  local now = snapshot.now()
  -- Isolate classify+run: a guard (or the classifier) misbehaving must never skip the snapshot delete,
  -- `last`, or the emit — the reload lifecycle has to complete regardless.
  local cls, guards, ctx
  local ok, result = pcall(function()
    cls = detect.classify(state.file, state.blobId, now, env.mission())
    if st == "ready" and (cls == "normal" or cls == "total") then
      guards = guardlist.list()
      ctx = { snap = state.file, mode = "auto", classification = cls, now = now }
      return runner.run(guards, ctx, true)
    else
      return { mode = "auto", classification = cls, at = now, guards = {}, repairedCount = 0,
               timeout = (st == "timeout") or nil }
    end
  end)
  local report
  if ok then
    report = result
  else
    report = { mode = "auto", classification = cls or "error", at = now, guards = {}, repairedCount = 0,
               error = tostring(result) }
  end
  if ok and guards then
    -- Match report entries back to the guard modules that produced them and arm a follow-up window for
    -- any `mitigated` outcome whose guard opts in via `followUp`.
    local pending = {}
    for _, e in ipairs(report.guards or {}) do
      if e.outcome == "mitigated" then
        for _, g in ipairs(guards) do
          if g.name == e.name and type(g.followUp) == "function" then
            pending[#pending + 1] = g
            break
          end
        end
      end
    end
    if #pending > 0 then
      state.followUps, state.followUpCtx, state.followUpLeft = pending, ctx, M.FOLLOWUP_SECONDS
    end
  end
  snapshot.delete()
  M.last = report
  M.emit(report)
end

function M.lastCompact()
  return M.last and runner.compact(M.last) or nil
end

-- test hook: clear module state between scenarios
function M._reset()
  state = { armed = false, done = false }
  M.last = nil
end

return M
