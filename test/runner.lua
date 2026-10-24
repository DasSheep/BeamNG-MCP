-- Tiny pure-Lua test runner (LuaJIT / Lua 5.1). Usage:
--   luajit test/runner.lua test/a_test.lua test/b_test.lua ...
package.path = "lua/common/?.lua;lua/ge/extensions/beammcp/?.lua;lua/ge/extensions/?.lua;test/?.lua;test/vendor/?.lua;" .. package.path

local results = { pass = 0, fail = 0, failures = {} }
local currentFile = "?"

function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    io.write(".")
  else
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = currentFile .. " :: " .. name .. "\n" .. tostring(err)
    io.write("F")
  end
end

function assertEqual(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assertEqual") .. ": expected [" .. tostring(expected) .. "] got [" .. tostring(actual) .. "]", 2)
  end
end

function assertTrue(v, msg)
  if not v then error((msg or "assertTrue") .. ": value was falsy", 2) end
end

function assertNil(v, msg)
  if v ~= nil then error((msg or "assertNil") .. ": expected nil got [" .. tostring(v) .. "]", 2) end
end

-- pat is a Lua pattern, not a literal substring; escape magic chars with % (e.g. "%." for a literal dot).
function assertMatch(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    error((msg or "assertMatch") .. ": [" .. tostring(s) .. "] !~ /" .. tostring(pat) .. "/", 2)
  end
end

local files = { ... }
for _, f in ipairs(files) do
  currentFile = f
  local ok, err = pcall(dofile, f)
  if not ok then
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = f .. " :: <load error>\n" .. tostring(err)
    io.write("F")
  end
end

io.write("\n")
for _, f in ipairs(results.failures) do io.write("\nFAIL: " .. f .. "\n") end
io.write(string.format("\n%d passed, %d failed\n", results.pass, results.fail))
os.exit(results.fail == 0 and 0 or 1)
