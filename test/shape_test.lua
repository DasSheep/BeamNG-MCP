local shape = require("beammcp/tools/lib/shape")

-- capList: keep first n of a pre-sorted array, report the true total.
test("capList: empty array -> empty + total 0", function()
  local c, t = shape.capList({}, 5)
  assertEqual(#c, 0)
  assertEqual(t, 0)
end)

test("capList: under n returns original + true total", function()
  local c, t = shape.capList({ "a", "b" }, 5)
  assertEqual(#c, 2)
  assertEqual(t, 2)
end)

test("capList: exactly n returns all + total n", function()
  local c, t = shape.capList({ 1, 2, 3 }, 3)
  assertEqual(#c, 3)
  assertEqual(t, 3)
end)

test("capList: over n truncates and reports true total", function()
  local a = {}
  for i = 1, 10 do a[i] = i end
  local c, t = shape.capList(a, 4)
  assertEqual(#c, 4)
  assertEqual(t, 10)
  assertEqual(c[1], 1)
  assertEqual(c[4], 4)
end)

-- capNote: standard truncation sentence, empty when nothing truncated.
test("capNote: total <= shown -> empty string", function()
  assertEqual(shape.capNote(3, 3, "things"), "")
  assertEqual(shape.capNote(5, 2, "things"), "")
end)

test("capNote: total > shown -> exact sentence (leading space)", function()
  assertEqual(shape.capNote(30, 40, "deform groups"), " Showing top 30 of 40 deform groups.")
end)

-- breakdown: count items by key, skipping nil keys.
test("breakdown: counts by key, skips nil keys", function()
  local items = { { t = "Car" }, { t = "Car" }, { t = "Truck" }, { other = 1 } }
  local b = shape.breakdown(items, function(x) return x.t end)
  assertEqual(b.Car, 2)
  assertEqual(b.Truck, 1)
  local n = 0
  for _ in pairs(b) do n = n + 1 end
  assertEqual(n, 2) -- the nil-key item is skipped
end)

test("breakdown: nil input -> empty table", function()
  local b = shape.breakdown(nil, function(x) return x end)
  local n = 0
  for _ in pairs(b) do n = n + 1 end
  assertEqual(n, 0)
end)

test("ciContains: case-insensitive plain substring; empty/absent needle matches all", function()
  assertTrue(shape.ciContains("Fender_L", "fend"))
  assertTrue(shape.ciContains("fender", "FEND"))
  assertTrue(shape.ciContains("anything", nil))
  assertTrue(shape.ciContains("anything", ""))
  assertEqual(shape.ciContains("door", "fend"), false)
end)
