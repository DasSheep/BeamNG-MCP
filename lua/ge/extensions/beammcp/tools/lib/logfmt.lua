-- Pure parsing + tailing of BeamNG log lines for the console_logs tool. No engine deps.
-- Line format: "uptimeSecs|LEVEL|source.tag| message"  (message may itself contain '|').
local shape = require("beammcp/tools/lib/shape")
local output = require("beammcp/output")

local M = {}

local RANK = { D = 1, I = 2, W = 3, E = 4 }

-- Bound stored fields as well as response fields; the count-bounded ring has a byte bound too.
function M.bound(entry)
  for key, size in pairs({ level = 16, tag = 256, msg = 2048 }) do
    local clipped, truncated = output.clip(tostring(entry[key]), size)
    entry[key] = clipped
    if truncated then entry.truncated = true end
  end
  if type(entry.time) == 'string' then
    local truncated
    entry.time, truncated = output.clip(entry.time, 64)
    if truncated then entry.truncated = true end
  elseif type(entry.time) ~= 'number' or entry.time ~= entry.time or math.abs(entry.time) == math.huge then
    entry.time = 0
  end
  return entry
end

-- Severity rank for a level char; unknown levels rank 0 (kept out by any min-level filter).
function M.levelRank(ch)
  return RANK[ch] or 0
end

-- Parse one line -> { time, level, tag, msg } or nil if it does not match the format.
function M.parse(line)
  local time, level, tag, msg = line:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
  if not time then return nil end
  msg = msg:gsub("^ ", "")   -- strip the single leading space after the tag pipe
  return M.bound({ time = tonumber(time) or time, level = level, tag = tag, msg = msg })
end

local ciContains = shape.ciContains   -- the canonical case-insensitive substring predicate

-- matches(entry, opts) -> bool. opts: { level=minLevel, tag=substr, match=msgSubstr }; all optional and
-- AND-combined. tag/match are case-insensitive substrings. Pure. (Shared by the buffer + file sources.)
function M.matches(e, opts)
  opts = opts or {}
  if M.levelRank(e.level) < (opts.level and M.levelRank(opts.level) or 0) then return false end
  if not ciContains(e.tag, opts.tag) then return false end
  if not ciContains(e.msg, opts.match) then return false end
  return true
end

-- select(entries, opts) -> (kept, total). Filter `entries` by matches(opts), then keep the last
-- opts.limit (nil = all). Returns the kept slice and the TRUE matching total (pre-limit). Newest last. Pure.
function M.select(entries, opts)
  opts = opts or {}
  local filtered = {}
  for _, e in ipairs(entries) do
    if M.matches(e, opts) then filtered[#filtered + 1] = e end
  end
  local total = #filtered
  local limit = opts.limit
  if limit and total > limit then
    local out = {}
    for i = total - limit + 1, total do out[#out + 1] = filtered[i] end
    return out, total
  end
  return filtered, total
end

-- tail(contents, opts) -> (kept, total). Parse log lines (dropping unparseable ones, so a partial final
-- line is tolerated) then select(opts). opts: { limit, level, tag, match }.
function M.tail(contents, opts)
  local entries = {}
  for line in contents:gmatch("[^\r\n]+") do
    local e = M.parse(line)
    if e then entries[#entries + 1] = e end
  end
  return M.select(entries, opts)
end

return M
