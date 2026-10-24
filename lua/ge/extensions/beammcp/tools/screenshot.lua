-- screenshot: capture the current game view and return it as an inline base64 PNG.
-- Async but single-call: createScreenshot2 writes the PNG a few frames later; we await the file via
-- copas.sleep, which yields the request coroutine so onUpdate's copas.step(0) keeps the frame alive
-- (validated in-engine). The engine capture is isolated in M.capture (a module field) so the handler's
-- base64/shaping/error logic is unit-testable with a stubbed capture.
--
-- ⚠️ BeamNG 0.39 RENAMED THE ENGINE ENTRY POINT AND CHANGED ITS SHAPE — calling the old name throws
-- `attempt to call global 'createScreenshot' (a nil value)`.
--   0.38 and earlier:  createScreenshot(base, "png", 1, 1, 0, false)      -- positional
--   0.39+:             createScreenshot2({ filename = …, writeJPG = …, superSampling = … })
-- `createScreenshot` is now nil (verified in-engine: type(createScreenshot)=="nil",
-- type(createScreenshot2)=="function"). The game's own MCP uses the same call and guards it with
-- `if type(createScreenshot2) ~= "function"` (lua/ge/extensions/mcp/tools/system.lua:67,73) — the
-- guard below mirrors that so a future rename degrades to a clean error rather than a Lua throw.
-- ⚠️ `filename` takes NO extension; `writeJPG=false` selects PNG, which is what the await path
-- below expects (`base .. ".png"`).
local await  = require("beammcp/async/await")
local base64 = require("beammcp/tools/lib/base64")
local sleep  = require("beammcp/async/sleep")

local M = {}

local seq = 0
local TIMEOUT_SEC = 5

-- capture(): trigger a screenshot, await the PNG file, return its raw bytes (or nil on timeout).
-- Engine-coupled; stubbed in tests.
function M.capture()
  seq = seq + 1
  local base = "temp/beammcp_shot_" .. seq
  local fp = base .. ".png"
  os.remove(fp)  -- drop any stale file (the counter resets on reload) so await sees a fresh capture
  if type(createScreenshot2) ~= "function" then return nil end   -- engine entry point missing/renamed
  createScreenshot2({ filename = base, writeJPG = false, superSampling = 1 })
  local ready = await.await(function() return FS:fileExists(fp) end,
    { timeoutSec = TIMEOUT_SEC, sleep = sleep })
  if not ready then return nil end
  local f = io.open(fp, "rb")
  if not f then os.remove(fp); return nil end   -- file exists but couldn't open: don't leave it on disk
  local data = f:read("*a"); f:close()
  os.remove(fp)  -- clean up so screenshots don't accumulate on disk
  return data
end

local function handler(_args)
  local bytes = M.capture()
  if not bytes then return nil, "screenshot: timed out capturing the view" end
  return { __mcpContent = { { type = "image", data = base64.encode(bytes), mimeType = "image/png" } } }
end

M.def = {
  description = "Capture the current game view and return it as an inline PNG image.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = handler,
}

function M.register(registry)
  registry:add("screenshot", M.def)
end

return M
