local at = require("beammcp/tools/lib/authtoken")

test("equal: identical strings -> true", function()
  assertEqual(at.equal("abc123", "abc123"), true)
end)

test("equal: different same-length strings -> false", function()
  assertEqual(at.equal("abc123", "abc124"), false)
end)

test("equal: different-length strings -> false (length-safe)", function()
  assertEqual(at.equal("abc", "abcd"), false)
  assertEqual(at.equal("abcd", "abc"), false)
end)

test("equal: empty strings -> true", function()
  assertEqual(at.equal("", ""), true)
end)

test("equal: non-string args -> false", function()
  assertEqual(at.equal(nil, "x"), false)
  assertEqual(at.equal("x", nil), false)
  assertEqual(at.equal(123, "123"), false)
end)

-- The default uuidFn (Engine.generateUUID) path is exercised by the in-engine verify, not here — Engine is
-- nil in the off-engine runner. The 64-char assertion assumes standard 8-4-4-4-12 UUIDs (32 hex each).
test("generate: concatenates two dash-stripped UUIDs from the injected fn", function()
  local n = 0
  local uuids = { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "11111111-2222-3333-4444-555555555555" }
  local fn = function() n = n + 1; return uuids[n] end
  local tok = at.generate(fn)
  assertEqual(n, 2)  -- consumed two UUIDs
  assertEqual(tok, "aaaaaaaabbbbccccddddeeeeeeeeeeee11111111222233334444555555555555")
  assertEqual(#tok, 64)
end)
