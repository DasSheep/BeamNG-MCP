local guardlist = require("beammcp/reload/guardlist")

test("list returns all guards in dependency order (levelflag before camera)", function()
  local l = guardlist.list()
  assertEqual(#l, 6)
  assertEqual(l[1].name, "levelflag")
  assertEqual(l[2].name, "camera")
  assertEqual(l[6].name, "extensions")
  for i, g in ipairs(l) do
    assertEqual(g.name, guardlist.ORDER[i])
    assertEqual(type(g.check), "function")
  end
end)

test("list(set) filters but keeps canonical order", function()
  local l = guardlist.list({ nightlights = true, levelflag = true })
  assertEqual(#l, 2)
  assertEqual(l[1].name, "levelflag")
  assertEqual(l[2].name, "nightlights")
end)

test("known", function()
  assertEqual(guardlist.known("camera"), true)
  assertEqual(guardlist.known("nope"), false)
end)
