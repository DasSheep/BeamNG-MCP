-- Bounded recent tails and caller-owned incremental pages from the ring or disk.
local logcapture = require('beammcp/logcapture')
local logfmt = require('beammcp/tools/lib/logfmt')
local output = require('beammcp/output')
local M = {}
local LOG_FILE, CHUNK = 'beamng.log', 65536
local function hash(s)
  local n = 0
  for i = 1, #s do n = (n * 31 + s:byte(i)) % 2147483647 end
  return string.format('%.0f', n)
end
local function fileCursor(meta, relative, skip)
  local before = meta.before .. meta.data:sub(math.max(1, relative - 63), relative)
  return table.concat({ 'f', meta.prefixLength, meta.prefixHash, meta.start + relative,
    hash(before:sub(-64)), skip and 1 or 0 }, ':')
end
-- Bounded IO seam. Fingerprints detect observable changes, not file identity.
function M.readLogFile(cursor)
  local f = io.open(LOG_FILE, 'rb')
  if not f then return nil end
  local size = f:seek('end')
  if not size then f:close(); return nil end
  local prefixLength, prefixHash, offset, anchor, skip
  if cursor then
    prefixLength, prefixHash, offset, anchor, skip = cursor:match('^f:(%d+):(%d+):(%d+):(%d+):([01])$')
    if not prefixLength then f:close(); return nil, 'invalid file cursor' end
    prefixLength, offset = tonumber(prefixLength), tonumber(offset)
    if prefixLength > 64 or offset > 9007199254740991 then f:close(); return nil, 'invalid file cursor' end
  end
  local function readAt(pos, n)
    if n == 0 then return '' end
    f:seek('set', pos)
    return f:read(n) or ''
  end
  local reset = false
  if cursor then
    reset = size < offset or size < prefixLength or hash(readAt(0, prefixLength)) ~= prefixHash
    if not reset then reset = hash(readAt(math.max(0, offset - 64), math.min(64, offset))) ~= anchor end
  end
  local start = cursor and (reset and 0 or offset) or math.max(0, size - CHUNK)
  local prefixN = math.min(size, 64)
  local meta = { start = start, size = size, reset = reset,
    prefixLength = prefixN, prefixHash = hash(readAt(0, prefixN)),
    before = readAt(math.max(0, start - 64), math.min(64, start)),
    skip = cursor and not reset and skip == '1' or not cursor and start > 0 }
  meta.data = readAt(start, CHUNK)
  f:close()
  return meta.data, meta
end
local function copy(e, group)
  local out = { time = e.time, level = e.level, tag = e.tag, msg = e.msg, truncated = e.truncated }
  if group then out.count = 1; out.firstTime = e.time; out.lastTime = e.time end
  return out
end
local function same(a, b)
  -- Clipped messages can share prefixes without being duplicates.
  return a and not a.truncated and not b.truncated and a.level == b.level and a.tag == b.tag and a.msg == b.msg
end
-- Reserve cursor growth while filtered rows are consumed after the last emitted entry.
local function fits(res, maxBytes) return #jsonEncode(res) <= maxBytes - 128 end
local function shrink(entry, res, maxBytes)
  entry.truncated = true
  for _, key in ipairs({ 'msg', 'tag', 'level', 'time', 'firstTime', 'lastTime' }) do
    if type(entry[key]) == 'string' then
    local original = entry[key]
    local low, high = 0, #original
    entry[key] = ''
    while low < high do
      local mid = math.floor((low + high + 1) / 2)
      entry[key] = output.clip(original, mid)
      if fits(res, maxBytes) then low = mid else high = mid - 1 end
    end
    entry[key] = output.clip(original, low)
    if fits(res, maxBytes) then return end
    end
  end
end
local function handler(args)
  args = args or {}
  local source = args.source or 'buffer'
  if source ~= 'buffer' and source ~= 'file' then return nil, "console_logs: source must be 'buffer' or 'file'" end
  for _, key in ipairs({ 'tag', 'match', 'cursor', 'level' }) do
    if args[key] ~= nil and type(args[key]) ~= 'string' then return nil, "console_logs: '" .. key .. "' must be a string" end
  end
  if args.limit ~= nil and type(args.limit) ~= 'number' then return nil, "console_logs: 'limit' must be a number" end
  if args.limit and (args.limit ~= args.limit or math.abs(args.limit) == math.huge or args.limit < 1) then
    return nil, "console_logs: 'limit' must be >= 1 and finite"
  end
  if args.level and not ({ D = true, I = true, W = true, E = true })[args.level] then return nil, 'console_logs: invalid level' end
  if args.cursor and #args.cursor > 256 then return nil, 'console_logs: invalid cursor' end
  if args.groupDuplicates ~= nil and type(args.groupDuplicates) ~= 'boolean' then return nil, 'console_logs: groupDuplicates must be boolean' end
  local maxBytes, err = output.budget(args.maxBytes, 4096)
  if not maxBytes then return nil, err end
  local requested = args.limit or 50
  local limit = math.min(math.floor(requested), 200)
  local rows, initial, latest, total = {}, nil, nil, 0
  local res = { source = source, entries = {}, hasMore = false, truncated = false }
  if source == 'buffer' then
    local entries, generation, oldest, newest = logcapture.snapshot()
    local after = oldest - 1
    if args.cursor then
      local gen, seq = args.cursor:match('^b:([%w]+):(%d+)$')
      if not gen then return nil, 'console_logs: invalid buffer cursor' end
      after = tonumber(seq)
      if gen ~= generation or after > newest then res.reset = true; after = oldest - 1
      elseif after < oldest - 1 then res.dropped = oldest - 1 - after; after = oldest - 1 end
    end
    local function cursor(seq) return 'b:' .. generation .. ':' .. string.format('%.0f', seq) end
    initial, latest = cursor(after), cursor(newest)
    for _, e in ipairs(entries) do
      if e.seq > after then rows[#rows + 1] = { entry = e, cursor = cursor(e.seq) } end
    end
  else
    local contents, meta = M.readLogFile(args.cursor)
    if not contents then return nil, 'console_logs: ' .. (type(meta) == 'string' and meta or 'cannot read ' .. LOG_FILE) end
    -- Preserve the older injectable reader seam; production always supplies bounded offsets.
    local legacy = type(meta) ~= 'table'
    if legacy then meta = { start = 0, size = #contents, prefixLength = 0, prefixHash = '0', before = '', data = contents } end
    res.reset = meta.reset or nil
    res.windowTruncated = not args.cursor and meta.start > 0 or nil
    initial = fileCursor(meta, 0, meta.skip)
    local pos, skipping = 1, meta.skip
    while pos <= #contents do
      local nl = contents:find('\n', pos, true)
      local finish = nl or #contents
      local complete = nl ~= nil or legacy
      -- Incomplete EOF rows wait for newline; oversized rows consume bounded chunks with a skip bit.
      if not complete and (pos > 1 or #contents < CHUNK) then break end
      local e
      if not skipping then
        e = logfmt.parse(contents:sub(pos, nl and finish - 1 or finish):gsub('\r$', ''))
        if e and not complete then e.truncated = true end
      end
      skipping = not complete
      rows[#rows + 1] = { entry = e, cursor = fileCursor(meta, finish, skipping) }
      pos = finish + 1
    end
    latest = rows[#rows] and rows[#rows].cursor or initial
    res.hasMore = meta.start + #contents < meta.size
    res.pendingPartial = pos <= #contents or nil
  end
  res.cursor = initial
  -- No cursor selects a recent tail. Supplied cursors always walk forward through consumed rows.
  if not args.cursor then
    local groups = {}
    for _, row in ipairs(rows) do
      local e = row.entry
      if e and logfmt.matches(e, args) then
        total = total + 1
        local last = groups[#groups]
        if args.groupDuplicates and same(last, e) then last.count = last.count + 1; last.lastTime = e.time
        else groups[#groups + 1] = copy(e, args.groupDuplicates) end
      end
    end
    for i = math.max(1, #groups - limit + 1), #groups do res.entries[#res.entries + 1] = groups[i] end
    res.cursor = latest
    if #groups > #res.entries then res.truncated = true end
    local function note()
      if res.truncated then
        res.note = string.format('Showing last %d of %d matching entries; narrow with tag/match/level.', #res.entries, total)
        if requested > 200 then res.note = res.note .. ' (limit capped at 200.)' end
      end
    end
    note()
    while not fits(res, maxBytes) and #res.entries > 1 do
      table.remove(res.entries, 1); res.truncated = true; note()
    end
    if not fits(res, maxBytes) and #res.entries == 1 then res.truncated = true; note(); shrink(res.entries[1], res, maxBytes) end
  else
    local sourceMore = res.hasMore
    res.hasMore = true
    for index, row in ipairs(rows) do
      local e, previousCursor = row.entry, res.cursor
      if e and logfmt.matches(e, args) then
        local last = res.entries[#res.entries]
        local grouped = args.groupDuplicates and same(last, e)
        if not grouped and #res.entries >= limit then break end
        local oldCount, oldTime
        if grouped then oldCount, oldTime = last.count, last.lastTime; last.count = last.count + 1; last.lastTime = e.time
        else res.entries[#res.entries + 1] = copy(e, args.groupDuplicates) end
        res.cursor = row.cursor
        if not fits(res, maxBytes) then
          if #res.entries == 1 and not grouped then shrink(res.entries[1], res, maxBytes)
          else
            if grouped then last.count, last.lastTime = oldCount, oldTime else table.remove(res.entries) end
            res.cursor = previousCursor
            break
          end
        end
      else res.cursor = row.cursor end
      if index == #rows then res.hasMore = sourceMore end
    end
    if #rows == 0 then res.hasMore = sourceMore end
  end
  for _, e in ipairs(res.entries) do if e.truncated then res.truncated = true end end
  return res
end
M.def = {
  description = 'Bounded BeamNG logs from buffer (default) or file. Without cursor returns a recent tail; '
    .. 'pass the returned cursor for independent forward pages. Filters precede limits. Ring overflow reports dropped, '
    .. 'generation or detectable file changes report reset. File reads scan at most 64 KiB; partial EOF lines wait for newline. '
    .. 'File replacement detection uses sampled fingerprints, not file identity. maxBytes bounds encoded result JSON. '
    .. 'Grouping combines consecutive matching, untruncated duplicates within a page.',
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = 'object', properties = {
    source = { type = 'string', enum = { 'buffer', 'file' } },
    limit = { type = 'number', description = 'Maximum entries/groups, default 50, maximum 200' },
    maxBytes = { type = 'integer', minimum = 1024, maximum = 16384, description = 'Encoded JSON byte budget, default 4096' },
    cursor = { type = 'string', description = 'Opaque cursor from this source; omit for a recent tail' },
    groupDuplicates = { type = 'boolean', description = 'Group matching duplicates with count/firstTime/lastTime' },
    level = { type = 'string', enum = { 'D', 'I', 'W', 'E' } },
    tag = { type = 'string', description = 'Case-insensitive substring of tag' },
    match = { type = 'string', description = 'Case-insensitive substring of message' },
  } },
  handler = handler,
}
function M.register(registry) registry:add('console_logs', M.def) end
require('beammcp/identity').stamp('beammcp/tools/console_logs',M)
return M
