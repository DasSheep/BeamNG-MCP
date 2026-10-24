require('support.beamng_stubs')
local logs = require('beammcp/tools/console_logs')
local capture = require('beammcp/logcapture')
local function fresh(cap)
  capture.reset()
  capture.install({ cap = cap or 500, now = function() return 1 end })
end

test('caller cursors independently consume rows through filters and page limits', function()
  fresh()
  local cursor = logs.def.handler({}).cursor
  for i = 1, 8 do capture.push(i % 2 == 0 and 'E' or 'I', 't', 'm' .. i) end
  local a = logs.def.handler({ cursor = cursor, level = 'E', limit = 2 })
  local b = logs.def.handler({ cursor = cursor, limit = 1 })
  assertEqual(a.entries[1].msg, 'm2'); assertEqual(a.entries[2].msg, 'm4')
  assertEqual(b.entries[1].msg, 'm1')
  local next = logs.def.handler({ cursor = a.cursor, level = 'E', limit = 2 })
  assertEqual(next.entries[1].msg, 'm6'); assertEqual(next.entries[2].msg, 'm8')
end)

test('byte pages clip escaped content and never skip the next matching row', function()
  fresh()
  local cursor = logs.def.handler({}).cursor
  for i = 1, 6 do capture.push('E', 't', tostring(i) .. string.rep('\1', 3000)) end
  local seen = 0
  repeat
    local page = logs.def.handler({ cursor = cursor, maxBytes = 1024 })
    assertTrue(#jsonEncode(page) <= 1024)
    for _, entry in ipairs(page.entries) do
      seen = seen + 1
      assertEqual(entry.msg:sub(1, 1), tostring(seen))
      assertTrue(entry.truncated)
    end
    assertTrue(page.cursor ~= cursor)
    cursor = page.cursor
  until seen == 6
end)

test('ring overflow and reset are explicit', function()
  fresh(2)
  local cursor = logs.def.handler({}).cursor
  for i = 1, 5 do capture.push('I', 't', tostring(i)) end
  local page = logs.def.handler({ cursor = cursor })
  assertEqual(page.dropped, 3)
  assertEqual(#page.entries, 2)
  fresh(2)
  capture.push('I', 't', 'new generation')
  local reset = logs.def.handler({ cursor = page.cursor })
  assertTrue(reset.reset)
  assertEqual(reset.entries[1].msg, 'new generation')
end)

test('grouping counts consumed duplicates without losing following rows', function()
  fresh()
  local cursor = logs.def.handler({}).cursor
  for i = 1, 3 do capture.push('I', 't', 'same') end
  capture.push('I', 't', 'next')
  local page = logs.def.handler({ cursor = cursor, groupDuplicates = true, limit = 1 })
  assertEqual(#page.entries, 1); assertEqual(page.entries[1].count, 3)
  assertEqual(page.entries[1].firstTime, 1); assertEqual(page.entries[1].lastTime, 1)
  local next = logs.def.handler({ cursor = page.cursor, groupDuplicates = true })
  assertEqual(next.entries[1].msg, 'next')
end)

test('ingestion bounds fields and reports truncation', function()
  fresh()
  capture.push(string.rep('E', 10000), string.rep('t', 10000), string.rep('m', 100000))
  local e = capture.recent()[1]
  assertTrue(#e.msg <= 2048); assertTrue(#e.tag <= 256); assertTrue(#e.level <= 16)
  assertTrue(e.truncated)
end)
