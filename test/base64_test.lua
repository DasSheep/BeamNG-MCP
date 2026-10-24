local base64 = require("beammcp/tools/lib/base64")

test("encodes a 3-byte group with no padding", function()
  assertEqual(base64.encode("Man"), "TWFu")
end)

test("pads a single trailing byte with ==", function()
  assertEqual(base64.encode("M"), "TQ==")
end)

test("pads two trailing bytes with =", function()
  assertEqual(base64.encode("Ma"), "TWE=")
end)

test("encodes raw binary bytes (0x00 0xFF 0x00)", function()
  assertEqual(base64.encode(string.char(0, 255, 0)), "AP8A")
end)

test("encodes the empty string to empty", function()
  assertEqual(base64.encode(""), "")
end)

test("large input: correct length and only base64-alphabet output (no precision break)", function()
  -- 1000 bytes cycling 0..255; output length is 4*ceil(n/3) and every char is in the alphabet.
  local parts = {}
  for i = 1, 1000 do parts[i] = string.char((i - 1) % 256) end
  local enc = base64.encode(table.concat(parts))
  assertEqual(#enc, 4 * math.ceil(1000 / 3))           -- 1000 -> 1336
  assertTrue(enc:match("^[A-Za-z0-9+/]*=?=?$") ~= nil) -- only valid base64 chars + trailing padding
end)
