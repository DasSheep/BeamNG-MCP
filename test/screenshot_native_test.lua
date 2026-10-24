local native   = require("beammcp/tools/screenshot_native")
local base64   = require("beammcp/tools/lib/base64")
local registry = require("core.registry")

-- A healthy engine, as a deps table. Each test degrades ONE field, so a refusal message can only come
-- from the thing that test broke.
local function goodDeps(over)
  local files = { "/steamshots/A.jpg" }
  local frame = 0
  local d = {
    files = files,                        -- test-visible: nothing may disappear from here
    provider = function()
      return {
        triggerScreenshot  = function() files[#files + 1] = "/steamshots/NEW.jpg" end,
        getAccountIdPrefix = function() return "steamid:" end,
        getLoggedInStatus  = function() return true end,
        -- STRING, as the engine returns it: a steamID64 exceeds 2^53 and cannot be a Lua number.
        getAccountId       = function() return "76561198000000123" end,
      }
    end,
    steamGlobal   = function() return {} end,
    dirExists     = function() return true end,
    listShots     = function() return files end,
    fileSize      = function() return 100 end,     -- constant => "stable" on the second poll
    readFile      = function() return "JPEGBYTES" end,
    frameId       = function() frame = frame + 1; return frame end,
    onlineFeature = function() return "enable" end,
    sleep         = function() end,
  }
  for k, v in pairs(over or {}) do d[k] = v end
  return d
end

-- accountId32: exact decimal subtraction, because the double route is silently wrong. Going through
-- tonumber() yields 39734400 for this id instead of 39734395 -- plausible-looking and off by 5.
test("accountId32 subtracts the steam base exactly, beyond 2^53", function()
  assertEqual(native.accountId32("76561198000000123"), "39734395")
  assertEqual(native.accountId32("76561197960265729"), "1")
  assertEqual(native.accountId32("76561197960265728"), "0")
end)

test("accountId32 borrows across digits", function()
  assertEqual(native.accountId32("76561198960265728"), "1000000000")
end)

test("accountId32 rejects a non-id rather than inventing one", function()
  assertNil(native.accountId32(76561198000000123))   -- a number: already lossy, refuse it
  assertNil(native.accountId32("not-an-id"))
  assertNil(native.accountId32("123"))               -- below the base
end)

-- PREFLIGHT: a decision table over engine state. Each refusal must name the thing the operator can fix.
test("preflight passes on a healthy Steam session", function()
  assertTrue(native.preflight(goodDeps()))
end)

test("preflight refuses when the provider is not Steam", function()
  local d = goodDeps()
  local p = d.provider()
  p.getAccountIdPrefix = function() return "epic:" end
  d.provider = function() return p end
  local ok, why = native.preflight(d)
  assertEqual(ok, false)
  assertMatch(why, "not Steam")
end)

test("preflight refuses when the Steam API is absent from the process", function()
  local ok, why = native.preflight(goodDeps({ steamGlobal = function() return nil end }))
  assertEqual(ok, false)
  assertMatch(why, "launch the game through Steam")
end)

test("preflight refuses when no account is logged in", function()
  local d = goodDeps()
  local p = d.provider()
  p.getLoggedInStatus = function() return false end
  d.provider = function() return p end
  local ok, why = native.preflight(d)
  assertEqual(ok, false)
  assertMatch(why, "logged%-in")
end)

-- The junction is the one host-side prerequisite, so its refusal has to carry the account id the
-- operator needs; a bare "not found" would send them path-hunting.
test("preflight refuses without the junction, naming the derived 32-bit account id", function()
  local ok, why = native.preflight(goodDeps({ dirExists = function() return false end }))
  assertEqual(ok, false)
  assertMatch(why, "39734395")
  assertMatch(why, "link%-steam%-screenshots")
end)

-- A minimised window keeps GE Lua ticking but stops presenting, so the capture never arrives and the
-- tool looks broken. This is the branch that turns that silence into an answer.
test("preflight refuses when frames are not advancing", function()
  local ok, why = native.preflight(goodDeps({ frameId = function() return 7 end }))
  assertEqual(ok, false)
  assertMatch(why, "minimised")
end)

-- CAPTURE: set-difference identification, which matters because two captures in the same SECOND share a
-- timestamp and differ only by suffix -- newest-by-name or newest-by-mtime would pick the wrong one.
test("capture identifies the new file by set difference, not by ordering", function()
  local files = { "/steamshots/20260910232153_2.jpg" }   -- sorts ABOVE the one we are about to make
  local d = goodDeps({ listShots = function() return files end })
  d.provider = function()
    return {
      triggerScreenshot  = function() files[#files + 1] = "/steamshots/20260910232153_10.jpg" end,
      getAccountIdPrefix = function() return "steamid:" end,
      getLoggedInStatus  = function() return true end,
      getAccountId       = function() return "76561198000000123" end,
    }
  end
  native.deps = d
  local bytes, name = native.capture()
  assertEqual(bytes, "JPEGBYTES")
  assertEqual(name, "20260910232153_10.jpg")
end)

-- ⛔ Deleting a capture orphans its entry in Steam's screenshots.vdf, and Steam never prunes those
-- (orphaned entries stay listed as "missing file"). So the tool must leave the library exactly as it
-- found it, plus the one new capture. This test is the guard on that rule.
test("capture removes nothing from the Steam folder", function()
  local d = goodDeps()
  native.deps = d
  assertEqual(#d.files, 1)
  native.capture()
  assertEqual(#d.files, 2)                       -- the new capture, and nothing taken away
  assertEqual(d.files[1], "/steamshots/A.jpg")   -- the pre-existing one is untouched
end)

test("capture surfaces the preflight reason instead of triggering", function()
  native.deps = goodDeps({ dirExists = function() return false end })
  local bytes, why = native.capture()
  assertNil(bytes)
  assertMatch(why, "not reachable")
end)

test("handler returns a JPEG image block", function()
  native.capture = function() return "BYTES", "X.jpg" end
  local res, err = native.def.handler({})
  assertNil(err)
  local block = res.__mcpContent[1]
  assertEqual(block.type, "image")
  assertEqual(block.mimeType, "image/jpeg")
  assertEqual(block.data, base64.encode("BYTES"))
end)

test("handler reports the failure reason", function()
  native.capture = function() return nil, "no frames" end
  local res, err = native.def.handler({})
  assertNil(res)
  assertMatch(err, "no frames")
end)

test("register adds it under 'screenshot_native'", function()
  local r = registry.new()
  native.register(r)
  assertEqual(r:list()[1].name, "screenshot_native")
end)
