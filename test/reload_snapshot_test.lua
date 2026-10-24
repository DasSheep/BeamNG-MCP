require("support.beamng_stubs")
local stub = require("support.stub")
local snapshot = require("beammcp/reload/snapshot")

local ENGINE = { level = "/levels/a/main.level.json", levelLoaded = "/levels/a/",
  gamestate = { state = "freeroam", appLayout = "freeroam", menuItems = "freeroam" },
  camMode = "orbit", playerVid = 7, ui = { cef = true, imgui = true }, tod = { time = 0.2, play = true },
  extensions = { "core_camera", "beammcp" } }

test("capture adds version, id and timestamp to the engine read", function()
  stub.with(snapshot, { readEngine = function() return ENGINE end, newId = function() return "id1" end,
                        now = function() return 1234 end }, function()
    local s = snapshot.capture()
    assertEqual(s.v, snapshot.VERSION)
    assertEqual(s.reloadId, "id1")
    assertEqual(s.at, 1234)
    assertEqual(s.level, "/levels/a/main.level.json")
    assertEqual(s.camMode, "orbit")
  end)
end)

test("capture stays small (no per-vehicle payload)", function()
  stub.with(snapshot, { readEngine = function() return ENGINE end }, function()
    assertTrue(#jsonEncode(snapshot.capture()) < 4096, "snapshot should be under 4 KiB")
  end)
end)

test("write reports failure without throwing", function()
  stub.with(snapshot, { writeFile = function() error("disk full") end }, function()
    local ok, err = snapshot.write({ v = 1 })
    assertEqual(ok, false)
    assertMatch(err, "disk full")
  end)
  stub.with(snapshot, { writeFile = function() return false end }, function()
    local ok = snapshot.write({ v = 1 })
    assertEqual(ok, false)
  end)
end)

test("write succeeds and targets PATH", function()
  local seen
  stub.with(snapshot, { writeFile = function(p, d) seen = p; return true end }, function()
    assertEqual(snapshot.write({ v = 1 }), true)
    assertEqual(seen, snapshot.PATH)
  end)
end)

test("read returns nil when the file is absent (no read attempted)", function()
  local readCalled = false
  stub.with(snapshot, { exists = function() return false end,
                        readFile = function() readCalled = true end }, function()
    assertNil(snapshot.read())
    assertEqual(readCalled, false)
  end)
end)

test("read rejects garbled or wrong-version content", function()
  for _, content in ipairs({ "x", { v = 99, reloadId = "a" }, { v = 1 } }) do
    stub.with(snapshot, { exists = function() return true end, readFile = function() return content end }, function()
      assertNil(snapshot.read())
    end)
  end
  stub.with(snapshot, { exists = function() return true end, readFile = function() error("bad json") end }, function()
    assertNil(snapshot.read())
  end)
end)

test("read returns a valid snapshot", function()
  stub.with(snapshot, { exists = function() return true end,
                        readFile = function() return { v = 1, reloadId = "a", at = 5 } end }, function()
    assertEqual(snapshot.read().reloadId, "a")
  end)
end)

test("delete never throws", function()
  stub.with(snapshot, { removeFile = function() error("nope") end }, function()
    snapshot.delete()
    assertTrue(true)
  end)
end)
