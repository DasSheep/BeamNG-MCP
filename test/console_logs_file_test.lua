require('support.beamng_stubs')
local logs = require('beammcp/tools/console_logs')
local function withFile(initial, fn)
  local data, reads = initial, {}
  local original = io.open
  io.open = function(path, mode)
    assertEqual(path, 'beamng.log'); assertEqual(mode, 'rb')
    local pos = 0
    return {
      seek = function(_, whence, offset)
        pos = (whence == 'end' and #data or 0) + (offset or 0)
        return pos
      end,
      read = function(_, count)
        assertEqual(type(count), 'number'); assertTrue(count <= 65536)
        reads[#reads + 1] = count
        local result = data:sub(pos + 1, pos + count)
        pos = pos + #result
        return result
      end,
      close = function() end,
    }
  end
  local ok, err = xpcall(function() fn(function(s) data = s end, reads) end, debug.traceback)
  io.open = original
  if not ok then error(err) end
end

test('file cursors page independent readers without entire file reads', function()
  withFile('', function(set)
    local cursor = logs.def.handler({ source = 'file' }).cursor
    set('1|I|t| one\n2|E|t| two\n3|E|t| three\n')
    local a = logs.def.handler({ source = 'file', cursor = cursor, level = 'E', limit = 1 })
    assertEqual(a.entries[1].msg, 'two')
    local b = logs.def.handler({ source = 'file', cursor = cursor, limit = 1 })
    assertEqual(b.entries[1].msg, 'one')
    local next = logs.def.handler({ source = 'file', cursor = a.cursor })
    assertEqual(next.entries[1].msg, 'three'); assertEqual(#next.entries, 1)
  end)
end)

test('file tail scans a bounded window and returns newest rows', function()
  local data = string.rep('1|I|t| older\n', 20000) .. '2|E|t| newest\n'
  withFile(data, function(_, reads)
    local page = logs.def.handler({ source = 'file', limit = 1 })
    assertTrue(page.windowTruncated); assertEqual(page.entries[1].msg, 'newest')
    local total = 0
    for _, n in ipairs(reads) do total = total + n end
    assertTrue(total <= 65536 + 192)
  end)
end)

test('file reset detects truncation and changed sampled bytes', function()
  withFile('1|I|t| first\n2|I|t| second\n', function(set)
    local cursor = logs.def.handler({ source = 'file' }).cursor
    set('3|E|t| new\n')
    local reset = logs.def.handler({ source = 'file', cursor = cursor })
    assertTrue(reset.reset); assertEqual(reset.entries[1].msg, 'new')
    set('4|E|t| NEW\n')
    local replacement = logs.def.handler({ source = 'file', cursor = reset.cursor })
    assertTrue(replacement.reset); assertEqual(replacement.entries[1].msg, 'NEW')
  end)
end)

test('escaped string timestamps and grouped fields obey minimum encoded budget', function()
  withFile(string.rep('\1', 100) .. '|E|t| msg\n', function()
    local page = logs.def.handler({ source = 'file', groupDuplicates = true, maxBytes = 1024 })
    assertTrue(#jsonEncode(page) <= 1024)
    assertTrue(page.entries[1].truncated)
  end)
end)

test('partial EOF line is not consumed before completion', function()
  withFile('1|I|t| complete\n2|E|t| par', function(set)
    local page = logs.def.handler({ source = 'file' })
    assertEqual(#page.entries, 1); assertTrue(page.pendingPartial)
    set('1|I|t| complete\n2|E|t| partial done\n')
    local next = logs.def.handler({ source = 'file', cursor = page.cursor })
    assertEqual(#next.entries, 1); assertEqual(next.entries[1].msg, 'partial done')
  end)
end)

test('chunk boundary preserves ordinary lines and oversized line continuation', function()
  withFile('', function(set)
    local cursor = logs.def.handler({ source = 'file' }).cursor
    local lines = {}
    for i = 1, 100 do lines[i] = '1|I|t| ' .. i .. string.rep('x', 990) .. '\n' end
    set(table.concat(lines))
    local seen = 0
    for _ = 1, 200 do
      local page = logs.def.handler({ source = 'file', cursor = cursor, maxBytes = 1024 })
      assertTrue(#jsonEncode(page) <= 1024)
      for _, e in ipairs(page.entries) do seen = seen + 1; assertMatch(e.msg, '^' .. seen .. 'x') end
      cursor = page.cursor
      if not page.hasMore then break end
    end
    assertEqual(seen, 100)
  end)
  withFile('', function(set)
    local cursor = logs.def.handler({ source = 'file' }).cursor
    set('1|E|t| ' .. string.rep('x', 150000) .. '\n2|I|t| after\n')
    local count, after = 0, false
    for _ = 1, 10 do
      local page = logs.def.handler({ source = 'file', cursor = cursor, maxBytes = 1024 })
      for _, e in ipairs(page.entries) do
        count = count + 1
        if e.msg == 'after' then after = true else assertTrue(e.truncated) end
      end
      cursor = page.cursor
      if not page.hasMore then break end
    end
    assertEqual(count, 2); assertTrue(after)
  end)
end)
