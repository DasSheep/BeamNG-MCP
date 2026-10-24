local registry = require("core.registry")
local man = require("beammcp/tools/manipulations")

-- buildIndex: compact catalog index, grouped by category, items are {key,title} only.
test("buildIndex: groups by category; items are key+title only; counts; 4 categories present", function()
  local idx = man.buildIndex()
  assertTrue(type(idx.categories) == "table")
  local byCat = {}
  for _, c in ipairs(idx.categories) do byCat[c.category] = c end
  for _, cat in ipairs({ "physics", "world", "visuals", "geometry" }) do
    assertTrue(byCat[cat] ~= nil, "category " .. cat .. " present")
    assertTrue(byCat[cat].count >= 1)
    local item = byCat[cat].items[1]
    assertTrue(type(item.key) == "string" and type(item.title) == "string")
    assertNil(item.recipe)
    assertNil(item.caveats)
  end
end)

test("buildCategory: returns compact rows (key/title/description, NO recipe) + a key= pointer; unknown category errors", function()
  local res = man.buildCategory("physics")
  assertEqual(res.category, "physics")
  assertTrue(res.count >= 1)
  assertTrue(type(res.items[1].key) == "string")
  assertTrue(type(res.items[1].title) == "string")
  assertTrue(type(res.items[1].description) == "string")
  assertNil(res.items[1].recipe)   -- recipes stay behind key= (a category is ~half the 34 KB catalog)
  assertNil(res.items[1].caveats)
  assertMatch(res.note, "key=")
  local r2, err = man.buildCategory("nope")
  assertNil(r2); assertMatch(err, "unknown category 'nope'")
end)

test("buildEntry: returns one full entry; unknown key errors", function()
  local e = man.buildEntry("power")
  assertEqual(e.key, "power"); assertEqual(e.category, "physics")
  assertEqual(e.tool, "vehicle_lua_eval")
  assertTrue(type(e.recipe) == "string" and e.recipe ~= "")
  local r2, err = man.buildEntry("nope")
  assertNil(r2); assertMatch(err, "unknown manipulation 'nope'")
end)

test("handler: no args -> index; category -> category; key -> entry; key beats category", function()
  assertTrue(man.def.handler({}).categories ~= nil)
  assertEqual(man.def.handler({ category = "physics" }).category, "physics")
  assertEqual(man.def.handler({ key = "power" }).key, "power")
  assertEqual(man.def.handler({ category = "world", key = "power" }).key, "power")
end)

test("handler: bad arg types -> errors", function()
  local _, e1 = man.def.handler("nope"); assertMatch(e1, "must be an object")
  local _, e2 = man.def.handler({ category = 5 }); assertMatch(e2, "'category' must be a string")
  local _, e3 = man.def.handler({ key = 5 }); assertMatch(e3, "'key' must be a string")
end)

test("catalog integrity: every entry well-formed; keys unique; valid category/tool", function()
  local validCat = { physics = true, world = true, visuals = true, geometry = true }
  local validTool = { vehicle_lua_eval = true, lua_eval = true }
  local seen = {}
  assertTrue(#man.CATALOG >= 4, "at least the 4 seeds")
  for _, e in ipairs(man.CATALOG) do
    assertTrue(type(e.key) == "string" and e.key ~= "", "key non-empty")
    assertTrue(not seen[e.key], "duplicate key " .. tostring(e.key)); seen[e.key] = true
    assertTrue(validCat[e.category] == true, "valid category for " .. tostring(e.key))
    assertTrue(type(e.title) == "string" and e.title ~= "", "title for " .. e.key)
    assertTrue(type(e.description) == "string" and e.description ~= "", "description for " .. e.key)
    assertTrue(validTool[e.tool] == true, "valid tool for " .. e.key)
    assertTrue(type(e.recipe) == "string" and e.recipe ~= "", "recipe for " .. e.key)
    assertTrue(type(e.caveats) == "string" and e.caveats ~= "", "caveats for " .. e.key)
    assertTrue(type(e.restore) == "string" and e.restore ~= "", "restore for " .. e.key)
  end
end)

test("physics category has the full set", function()
  local res = man.buildCategory("physics")
  assertTrue(res.count >= 14, "physics has >=14 entries, got " .. res.count)
  assertTrue(man.buildEntry("grip").key == "grip")
  assertTrue(man.buildEntry("invulnerable").key == "invulnerable")
end)

test("world + geometry categories are filled", function()
  assertTrue(man.buildCategory("world").count >= 4, "world >=4")
  assertTrue(man.buildCategory("geometry").count >= 4, "geometry >=4")
  assertEqual(man.buildEntry("weather").category, "world")
  assertEqual(man.buildEntry("node_position").category, "geometry")
end)

test("register adds list_manipulations", function()
  local r = registry.new()
  man.register(r)
  assertEqual(r:list()[1].name, "list_manipulations")
end)

test("'category' schema carries the closed enum the handler enforces", function()
  local e = man.def.inputSchema.properties.category.enum
  assertTrue(type(e) == "table")
  assertEqual(#e, 4)
  assertEqual(e[1], "physics")
end)
