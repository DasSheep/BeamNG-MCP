local bind = require("bind")

-- isLoopback -----------------------------------------------------------------------------------------
test("isLoopback: 127.x is loopback", function()
  assertEqual(bind.isLoopback("127.0.0.1"), true)
  assertEqual(bind.isLoopback("127.1.2.3"), true)
end)

test("isLoopback: 0.0.0.0 and LAN IPs are NOT loopback", function()
  assertEqual(bind.isLoopback("0.0.0.0"), false)
  assertEqual(bind.isLoopback("192.168.1.5"), false)
  assertEqual(bind.isLoopback("10.0.0.2"), false)
end)

-- validate -------------------------------------------------------------------------------------------
test("validate: accepts dotted-quad IPv4 incl. 0.0.0.0 and 127.0.0.1", function()
  assertEqual(bind.validate("0.0.0.0"), "0.0.0.0")
  assertEqual(bind.validate("127.0.0.1"), "127.0.0.1")
  assertEqual(bind.validate("192.168.1.50"), "192.168.1.50")
  assertEqual(bind.validate("255.255.255.255"), "255.255.255.255")
end)

test("validate: rejects out-of-range octets, wrong arity, and non-IP strings", function()
  for _, bad in ipairs({ "256.0.0.1", "1.2.3", "1.2.3.4.5", "localhost", "0.0.0", "abc", "1.2.3.x", "" }) do
    local v, err = bind.validate(bad)
    assertNil(v, "expected nil for [" .. bad .. "]")
    assertMatch(err, "IPv4")
  end
end)

test("validate: non-string -> nil + error", function()
  local v, err = bind.validate(nil)
  assertNil(v)
  assertMatch(err, "IPv4")
end)

-- resolve (the fail-closed core) ---------------------------------------------------------------------
test("resolve: loopback bind is used regardless of auth", function()
  local host, downgraded = bind.resolve("127.0.0.1", false)
  assertEqual(host, "127.0.0.1"); assertEqual(downgraded, false)
  host, downgraded = bind.resolve("127.0.0.1", true)
  assertEqual(host, "127.0.0.1"); assertEqual(downgraded, false)
end)

test("resolve: non-loopback + auth ON uses the requested bind", function()
  local host, downgraded = bind.resolve("0.0.0.0", true)
  assertEqual(host, "0.0.0.0"); assertEqual(downgraded, false)
  host, downgraded = bind.resolve("192.168.1.5", true)
  assertEqual(host, "192.168.1.5"); assertEqual(downgraded, false)
end)

test("resolve: non-loopback + auth OFF is forced back to loopback (fail-closed downgrade)", function()
  local host, downgraded = bind.resolve("0.0.0.0", false)
  assertEqual(host, "127.0.0.1"); assertEqual(downgraded, true)
end)
