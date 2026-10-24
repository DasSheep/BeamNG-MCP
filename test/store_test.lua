local store = require("store")

-- In-memory fake of BeamNG's file IO. `files[path]` holds the last-written table.
local function fakeIo(initial)
  local files = { ["settings/beammcp.json"] = initial }  -- nil ⇒ "file missing"
  local io = {
    path = "settings/beammcp.json",
    read = function(path) return files[path] end,
    -- shallow-copy so the fake "file" is independent of the store's live data table
    -- (models a real serialise/deserialise round-trip; keeps set-then-load honest).
    write = function(path, tbl, pretty)
      local copy = {}; for k, v in pairs(tbl) do copy[k] = v end
      files[path] = copy; return true
    end,
  }
  return io, files
end

test("get returns default when key absent", function()
  local io = fakeIo(nil)
  local s = store.new(io):load()
  assertEqual(s:get("port", 23512), 23512)
  assertEqual(s:get("pinned", false), false)
end)

test("get returns stored value over default", function()
  local io = fakeIo({ port = 9000, pinned = true })
  local s = store.new(io):load()
  assertEqual(s:get("port", 23512), 9000)
  assertEqual(s:get("pinned", false), true)
end)

test("load tolerates a missing/garbage file (non-table) as empty", function()
  local io = fakeIo("not a table")
  local s = store.new(io):load()
  assertEqual(s:get("anything", "dflt"), "dflt")
end)

test("set writes through the full document, preserving other keys", function()
  local io, files = fakeIo({ port = 9000 })
  local s = store.new(io):load()
  local ok = s:set("pinned", true)
  assertTrue(ok)
  assertEqual(files["settings/beammcp.json"].pinned, true)
  assertEqual(files["settings/beammcp.json"].port, 9000)   -- not clobbered
  assertEqual(s:get("pinned", false), true)                 -- reflected in memory
end)

test("set false is distinct from absent (stores the literal false)", function()
  local io, files = fakeIo(nil)
  local s = store.new(io):load()
  s:set("pinned", false)
  assertEqual(files["settings/beammcp.json"].pinned, false)
  assertEqual(s:get("pinned", "DEFAULT"), false)            -- false present, not default
end)
