local registry = require("core.registry")
local lv = require("beammcp/tools/levels")
local mp = require("beammcp/tools/lib/mp")
local realProbe = mp.probe   -- captured before tests stub mp.probe (shared lib, runner has no teardown)
-- Note: lv.fetchList/lv.fire are stubbed per-test without restore — leak-safe because `levels` is required by
-- no other test file (unlike the shared `mp` lib, whose probe IS captured/restored above).

-- curateLevel(l) -> agent-facing subset: always levelName/title/official; optionals only when present.
test("curateLevel: always-fields + present optionals; official coerced; heavy fields dropped", function()
  local raw = { levelName="gridmap_v2", title="Grid Map v2", official=true, size={1024,1024},
    biome="industrial", suitablefor="testing", supportsTraffic=true, supportsTimeOfDay=true,
    previews={"a.png"}, spawnPoints={{}}, dir="/levels/gridmap_v2/", misFilePath="x", description="long" }
  local c = lv.curateLevel(raw)
  assertEqual(c.levelName, "gridmap_v2")
  assertEqual(c.title, "Grid Map v2")
  assertEqual(c.official, true)
  assertEqual(c.size, raw.size)            -- size table passed through by reference
  assertEqual(c.biome, "industrial")
  assertEqual(c.suitablefor, "testing")
  assertEqual(c.supportsTraffic, true)
  assertEqual(c.supportsTimeOfDay, true)
  assertNil(c.previews); assertNil(c.spawnPoints); assertNil(c.dir); assertNil(c.description)
end)

test("curateLevel: optionals omitted when absent; official nil -> false", function()
  local c = lv.curateLevel({ levelName="bare", title="Bare" })
  assertEqual(c.levelName, "bare")
  assertEqual(c.official, false)
  assertNil(c.size); assertNil(c.biome); assertNil(c.suitablefor)
  assertNil(c.supportsTraffic); assertNil(c.supportsTimeOfDay)
end)

test("curateLevel: title falls back to levelName when absent", function()
  local c = lv.curateLevel({ levelName = "some_map" })   -- no title field
  assertEqual(c.title, "some_map")
end)

-- buildList(rawList) -> { count, levels=[curated...] } sorted by levelName.
test("buildList: curates, sorts by levelName, counts", function()
  local raw = {
    { levelName="west_coast_usa", title="WCUSA", official=true },
    { levelName="gridmap_v2", title="Grid", official=true },
  }
  local r = lv.buildList(raw)
  assertEqual(r.count, 2)
  assertEqual(r.levels[1].levelName, "gridmap_v2")
  assertEqual(r.levels[2].levelName, "west_coast_usa")
end)

test("buildList: empty -> count 0, empty levels", function()
  local r = lv.buildList({})
  assertEqual(r.count, 0)
  assertEqual(#r.levels, 0)
end)

-- levelNameSet(rawList) -> { [levelName]=true } membership set.
test("levelNameSet: membership set keyed by levelName", function()
  local set = lv.levelNameSet({ {levelName="a"}, {levelName="b"} })
  assertTrue(set["a"]); assertTrue(set["b"]); assertNil(set["c"])
end)

-- list_levels handler (stub M.fetchList) ----
test("list_levels: returns the built catalog", function()
  lv.fetchList = function() return {
    { levelName="gridmap_v2", title="Grid", official=true },
    { levelName="automation_test_track", title="ATT", official=true },
  } end
  local res, err = lv.listDef.handler({})
  assertNil(err)
  assertEqual(res.count, 2)
  assertEqual(res.levels[1].levelName, "automation_test_track")  -- sorted
end)

local RICH = {
  { levelName="gridmap_v2", title="Grid", official=true, biome="industrial", suitablefor="testing", supportsTraffic=true },
  { levelName="mymap", title="My Map", official=false, biome="rural" },
}

test("list_levels compact default: levelName/title/official only, no optionals, no total", function()
  lv.fetchList = function() return RICH end
  local res = lv.listDef.handler({})
  assertEqual(res.count, 2)
  assertEqual(res.levels[1].levelName, "gridmap_v2")
  assertEqual(res.levels[1].official, true)
  assertNil(res.levels[1].biome)        -- compact drops optionals
  assertNil(res.levels[1].suitablefor)
  assertNil(res.total)                  -- unfiltered
end)

test("list_levels detail=true: includes size/biome/suitablefor/traffic/timeOfDay", function()
  lv.fetchList = function() return RICH end
  local res = lv.listDef.handler({ detail = true })
  assertEqual(res.levels[1].biome, "industrial")
  assertEqual(res.levels[1].suitablefor, "testing")
  assertEqual(res.levels[1].supportsTraffic, true)
end)

test("list_levels official=true filter narrows + reports total", function()
  lv.fetchList = function() return RICH end
  local res = lv.listDef.handler({ official = true })
  assertEqual(res.count, 1)
  assertEqual(res.total, 2)
  assertEqual(res.levels[1].levelName, "gridmap_v2")
end)

test("list_levels official=false filter keeps non-official maps", function()
  lv.fetchList = function() return RICH end
  local res = lv.listDef.handler({ official = false })
  assertEqual(res.count, 1)
  assertEqual(res.total, 2)
  assertEqual(res.levels[1].levelName, "mymap")
end)

test("list_levels rejects non-boolean official/detail", function()
  lv.fetchList = function() return RICH end
  local r1, e1 = lv.listDef.handler({ official = "yes" })
  assertNil(r1); assertMatch(e1, "'official' must be a boolean")
  local r2, e2 = lv.listDef.handler({ detail = 7 })
  assertNil(r2); assertMatch(e2, "'detail' must be a boolean")
end)

test("list_levels: catalog read failure -> error", function()
  lv.fetchList = function() return nil end
  local res, err = lv.listDef.handler({})
  assertNil(res); assertMatch(err, "could not read the level catalog")
end)

test("register adds list_levels", function()
  local r = registry.new()
  lv.register(r)
  local names = {}
  for _, d in ipairs(r:list()) do names[d.name] = true end
  assertTrue(names["list_levels"])
end)

-- coverage gaps flagged in review (test-only):
test("levelNameSet: entries with nil levelName are skipped", function()
  local set = lv.levelNameSet({ {levelName="a"}, {}, {levelName=nil} })
  assertTrue(set["a"])
  local n = 0; for _ in pairs(set) do n = n + 1 end
  assertEqual(n, 1)
end)

test("curateLevel: drops misFilePath too", function()
  local c = lv.curateLevel({ levelName="x", title="X", misFilePath="/levels/x/y.json" })
  assertNil(c.misFilePath)
end)

-- load_level handler ----
local CATALOG = { { levelName="gridmap_v2", title="Grid", official=true },
                  { levelName="west_coast_usa", title="WCUSA", official=true } }

test("load_level: rejects non-table args", function()
  local res, err = lv.loadDef.handler("nope")
  assertNil(res); assertMatch(err, "must be an object")
end)

test("load_level: rejects missing/empty/non-string level", function()
  local _, e1 = lv.loadDef.handler({})
  assertMatch(e1, "'level' must be a non%-empty string")
  local _, e2 = lv.loadDef.handler({ level = "" })
  assertMatch(e2, "'level' must be a non%-empty string")
  local _, e3 = lv.loadDef.handler({ level = 5 })
  assertMatch(e3, "'level' must be a non%-empty string")
end)

test("load_level: unknown level -> error, M.fire not called", function()
  lv.fetchList = function() return CATALOG end
  local fired = false
  lv.fire = function() fired = true end
  local res, err = lv.loadDef.handler({ level = "nope_island" })
  assertNil(res); assertMatch(err, "unknown level 'nope_island'")
  assertEqual(fired, false)
end)

test("load_level: refused in a BeamMP session, M.fire not called", function()
  lv.fetchList = function() return CATALOG end
  mp.probe = function() return { modLoaded = true, sessionActive = true } end  -- force active session
  local fired = false
  lv.fire = function() fired = true end
  local res, err = lv.loadDef.handler({ level = "gridmap_v2" })
  assertNil(res); assertMatch(err, "BeamMP/multiplayer session")
  assertEqual(fired, false)
  mp.probe = realProbe
end)

test("load_level: refused when BeamMP mod present but session state unreadable (fail-safe)", function()
  lv.fetchList = function() return CATALOG end
  mp.probe = function() return { modLoaded = true, sessionActive = nil } end
  local fired = false
  lv.fire = function() fired = true end
  local res, err = lv.loadDef.handler({ level = "gridmap_v2" })
  assertNil(res); assertMatch(err, "BeamMP/multiplayer session")
  assertEqual(fired, false)
  mp.probe = realProbe
end)

test("load_level: success fires startFreeroamByName + returns loading echo", function()
  lv.fetchList = function() return CATALOG end
  mp.probe = function() return { modLoaded = false, sessionActive = false } end  -- not in MP
  local seen = {}
  lv.fire = function(level) seen.level = level end
  local res, err = lv.loadDef.handler({ level = "west_coast_usa" })
  assertNil(err)
  assertEqual(seen.level, "west_coast_usa")
  assertEqual(res.level, "west_coast_usa")
  assertEqual(res.loading, true)
  assertTrue(res.note ~= nil)
  mp.probe = realProbe
end)

test("load_level: loading the current level is allowed (not an error)", function()
  lv.fetchList = function() return CATALOG end
  mp.probe = function() return { modLoaded = false, sessionActive = false } end
  lv.fire = function() end
  local res, err = lv.loadDef.handler({ level = "gridmap_v2" })
  assertNil(err); assertEqual(res.loading, true)
  mp.probe = realProbe
end)

test("register adds load_level too", function()
  local r = registry.new()
  lv.register(r)
  local names = {}
  for _, d in ipairs(r:list()) do names[d.name] = true end
  assertTrue(names["list_levels"]); assertTrue(names["load_level"])
end)
