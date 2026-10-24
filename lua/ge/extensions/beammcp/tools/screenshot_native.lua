-- screenshot_native: capture the PRESENTED frame -- ImGui/native overlays included -- by asking
-- Steam's own swapchain hook, then return it inline (the file Steam wrote is left in place; see below).
--
-- WHY THIS EXISTS
-- `screenshot` (createScreenshot2) is a SCENE RENDER-TARGET grab. Dear ImGui, and therefore every ImGui
-- overlay a mod draws (gauges, minimap, HUD panels), composites DOWNSTREAM of that target and is absent
-- from the image. A blank widget box there is the EXPECTED look of a perfectly working gauge. Steam's
-- overlay hooks the swapchain AFTER that composite, so its capture contains the whole presented frame:
-- dials, needles, minimap roads and LCD readouts that the engine capture cannot see.
--
-- WHY THE TRIGGER IS `OnlineServiceProvider.triggerScreenshot()` AND NOT `screenshot.doSteamScreenshot()`
-- doSteamScreenshot does BOTH `doScreenshot(...)` (an engine-side PNG, without ImGui, into the player's
-- own screenshots folder) AND the Steam trigger. The solo trigger produces the Steam JPG and leaves the
-- game-side screenshots folder untouched, so it is the same capture without the pollution.
--
-- WHY A JUNCTION IS REQUIRED (and why there is no pure-Lua alternative)
-- Steam writes into `<Steam>/userdata/<acct>/760/remote/284160/screenshots`, which is outside the game
-- VFS. Every route out of the sandbox is sealed -- all four:
--   * `FS:mount(osDir, ...)` returns -1 for any OS directory; FS rejects absolute OS paths outright.
--   * `io.open` / `io.popen` are VFS-redirected (popen hands back a nil handle for a command).
--   * `os.execute` is an inert stub: returns 0, does nothing.
--   * `ffi.cdef` REJECTS every function type ("invalid C type") -- plain vars and structs parse, so the
--     seal is deliberate and specific to the call path.
-- A directory junction from the userpath into Steam's folder is therefore the only way to give the VFS
-- read+delete reach. `scripts/link-steam-screenshots.ps1` creates it; preflight reports it when absent.
--
-- ⛔⛔ WHY THIS TOOL DOES NOT DELETE ITS OWN CAPTURES, though that was the first design
-- Steam records every capture in `<userdata>/760/screenshots.vdf` AT CAPTURE TIME. Deleting only the
-- .jpg leaves that metadata behind, and the screenshot then shows in Steam's own manager as a broken
-- "missing file" entry. Steam does NOT prune those: orphaned entries (including ones for other games)
-- survive Steam restarts indefinitely. Rewriting the .vdf live is not a fix either: Steam owns that
-- file in memory and rewrites it from its own state on exit, so a live edit is discarded.
-- ⇒ A capture is LEFT IN PLACE and the library stays consistent. Pruning is a separate maintenance
-- action that must remove the file, the thumbnail AND the .vdf entry together, with Steam closed --
-- `scripts/prune-steam-screenshots.ps1`. Deleting from in here cannot be made correct.
--
-- HAZARD: `/steamshots` IS A JUNCTION INTO THE PLAYER'S REAL STEAM LIBRARY. Never recursively delete
-- it -- that deletes their screenshots, not the link.
local await  = require("beammcp/async/await")
local base64 = require("beammcp/tools/lib/base64")
local sleep  = require("beammcp/async/sleep")

local M = {}

local SHOTS = "/steamshots"

local TIMEOUT_SEC   = 12    -- typical trigger->file latency is well under 1 s; this is slack, not a target
local FRAME_PROBE_S = 0.3   -- see M.framesAdvancing
-- steamID64 - base = the 32-bit account id the userdata path uses. Kept as a STRING: as a Lua number it
-- would be a double and the subtraction would be lossy (see M.accountId32).
local STEAM_ID_BASE_DEC = "76561197960265728"

-- Engine seams, in one table so tests can replace them wholesale. Nothing below touches a global directly.
M.deps = {
  provider      = function() return rawget(_G, "OnlineServiceProvider") end,
  steamGlobal   = function() return rawget(_G, "Steam") end,
  dirExists     = function(p) return FS:directoryExists(p) end,
  listShots     = function() return FS:findFiles(SHOTS, "*.jpg", 0, true, false) or {} end,
  fileSize      = function(p) local s = FS:stat(p); return type(s) == "table" and s.filesize or nil end,
  readFile      = function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end,
  frameId       = function() return Engine.Render.getFrameId() end,
  onlineFeature = function() return settings and settings.getValue and settings.getValue("onlineFeatures") end,
  sleep         = sleep,
}

-- steamID64 -> the 32-bit account id that names the userdata folder, as an EXACT decimal string.
-- ⚠️ MUST NOT go through tonumber(): getAccountId() returns a STRING because a steamID64 (~7.6e16)
-- exceeds 2^53, so converting it to a Lua double loses precision: tonumber() arithmetic yields an id
-- off by a few hundred, and wrong in a way that reads as a plausible id. Hence decimal subtraction on
-- the digits.
function M.accountId32(id)
  if type(id) ~= "string" or not id:match("^%d+$") then return nil end
  local ra, rb = id:reverse(), tostring(STEAM_ID_BASE_DEC):reverse()
  if #ra < #rb then return nil end
  local digits, borrow = {}, 0
  for i = 1, #ra do
    local da = ra:byte(i) - 48
    local db = (i <= #rb) and (rb:byte(i) - 48) or 0
    local d = da - db - borrow
    if d < 0 then d, borrow = d + 10, 1 else borrow = 0 end
    digits[i] = string.char(48 + d)
  end
  if borrow ~= 0 then return nil end   -- id was below the base: not a steamID64
  local s = (table.concat(digits):reverse():gsub("^0+", ""))
  return s == "" and "0" or s
end

-- Is the game actually PRESENTING? GE Lua keeps ticking while the window is minimised, but D3D stops
-- presenting, so Steam's hook has no frame to grab and the capture silently never arrives. That is the
-- failure mode that reads as "the tool is broken"; detect it positively instead of timing out.
-- MUST sleep (yield) rather than busy-wait: a busy-wait blocks the very thread that renders, so it
-- measures zero frames on a perfectly healthy game.
function M.framesAdvancing(deps)
  local a = deps.frameId()
  deps.sleep(FRAME_PROBE_S)
  return deps.frameId() ~= a
end

-- Pure over `deps`: can a Steam capture work right now? Returns true, or false + an ACTIONABLE reason.
-- Split out from capture() so every refusal path is unit-testable without an engine.
function M.preflight(deps)
  local p = deps.provider()
  if type(p) ~= "table" then
    return false, "no OnlineServiceProvider: this build has no online service, so Steam cannot capture."
  end
  -- The game's own photomode guard (ui/photomode/shared.lua) tests exactly this before offering the button.
  if type(p.triggerScreenshot) ~= "function" then
    return false, "OnlineServiceProvider.triggerScreenshot is missing: the engine entry point was renamed or removed."
  end

  -- "Running via Steam" -- the account-id PREFIX is the provider's own self-identification, and it keeps
  -- working if the provider table gains siblings (Epic/GOG) later.
  local okPrefix, prefix = pcall(p.getAccountIdPrefix)
  if not okPrefix or tostring(prefix) ~= "steamid:" then
    return false, "online provider is not Steam (account prefix: "
      .. (okPrefix and tostring(prefix) or "unavailable")
      .. "). The Steam overlay is what performs this capture, so it cannot work here."
  end
  if type(deps.steamGlobal()) ~= "table" then
    return false, "the Steam API is not initialised in this process (no `Steam` global): launch the game through Steam."
  end
  local okLogin, loggedIn = pcall(p.getLoggedInStatus)
  if not okLogin or loggedIn ~= true then
    return false, "Steam reports no logged-in account, so the overlay will not save a screenshot."
  end

  if not deps.dirExists(SHOTS) then
    local okId, id = pcall(p.getAccountId)
    local acct = (okId and M.accountId32(id)) or "<account>"
    return false, "`" .. SHOTS .. "` is not reachable. Steam writes to <Steam>/userdata/" .. acct
      .. "/760/remote/284160/screenshots, which is outside the game VFS -- run"
      .. " scripts/link-steam-screenshots.ps1 once to junction it in."
  end

  if not M.framesAdvancing(deps) then
    return false, "the game is not presenting frames (window minimised?), so Steam has nothing to capture."
      .. " Restore the window -- it does NOT need focus, only to be un-minimised."
  end
  return true
end

-- The set of capture filenames present right now, as a lookup.
local function snapshot(deps)
  local seen = {}
  for _, path in ipairs(deps.listShots()) do
    seen[path:match("[^/\\]+$") or path] = true
  end
  return seen
end

-- The first filename in listShots() that is not in `before`.
local function firstNew(deps, before)
  for _, path in ipairs(deps.listShots()) do
    local name = path:match("[^/\\]+$") or path
    if not before[name] then return name end
  end
  return nil
end

-- capture() -> bytes, name  |  nil, reason
-- The capture is deliberately LEFT ON DISK; see the header for why deleting it cannot be made correct.
function M.capture()
  local deps = M.deps

  local ok, why = M.preflight(deps)
  if not ok then return nil, why end

  local before = snapshot(deps)
  local p = deps.provider()
  local okTrig, errTrig = pcall(p.triggerScreenshot)
  if not okTrig then return nil, "triggerScreenshot failed: " .. tostring(errTrig) end

  local name
  local arrived = await.await(function()
    name = firstNew(deps, before)
    return name ~= nil
  end, { timeoutSec = TIMEOUT_SEC, sleep = deps.sleep })

  if not arrived then
    local hint = ""
    -- Deliberately NOT a blocking precondition: doSteamScreenshot refuses when this is off, but the raw
    -- trigger's behaviour with it off is UNVERIFIED, so this is a hint on failure, never a refusal.
    if tostring(deps.onlineFeature()) ~= "enable" then
      hint = " (BeamNG's `onlineFeatures` setting is not 'enable', which may be suppressing it)"
    end
    return nil, "timed out waiting for Steam to write the screenshot" .. hint
  end

  local main = SHOTS .. "/" .. name

  -- Steam writes progressively; a read that wins the race returns a truncated JPEG. Wait for the size to
  -- stop changing rather than trusting the file's mere existence.
  local last = -1
  await.await(function()
    local n = deps.fileSize(main)
    if n and n > 0 and n == last then return true end
    last = n or -1
    return false
  end, { timeoutSec = TIMEOUT_SEC, sleep = deps.sleep })

  local bytes = deps.readFile(main)
  if not bytes or #bytes == 0 then return nil, "Steam wrote " .. name .. " but it could not be read" end

  return bytes, name
end

local function handler(_args)
  local bytes, nameOrErr = M.capture()
  if not bytes then return nil, "screenshot_native: " .. tostring(nameOrErr) end
  return { __mcpContent = { { type = "image", data = base64.encode(bytes), mimeType = "image/jpeg" } } }
end

M.def = {
  description = "Capture the PRESENTED frame via Steam's overlay, including the ImGui/native overlays "
    .. "that `screenshot` cannot see, and return it inline as a JPEG. Requires the game to be launched "
    .. "through Steam and un-minimised (focus is NOT required). The capture stays in the player's Steam "
    .. "screenshot library; prune it with scripts/prune-steam-screenshots.ps1 (Steam closed), never by "
    .. "deleting the file alone.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = handler,
}

function M.register(registry)
  registry:add("screenshot_native", M.def)
end

return M
