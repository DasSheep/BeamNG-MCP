-- Non-destructively wraps the global log() into a bounded ring of structured entries, so the
-- console_logs tool can serve recent in-memory logs cheaply. Chains to the original log.
local logfmt = require("beammcp/tools/lib/logfmt")

local M = {}

local DEFAULT_CAP = 500
-- Circular buffer: O(1) push (a plain array + table.remove(1) shifts all 500 slots on EVERY line
-- once full — a level load logs hundreds of lines in one frame). head = slot of the newest entry.
local ring = {}
local head = 0
local count = 0
local capacity = DEFAULT_CAP
local installed = false
local original = nil
local nowFn = os.clock
local sequence = 0
local generation = 0
local nonce = tostring({}):gsub('[^%w]', '')

-- install([opts]): wrap _G.log. opts.cap = ring size (default 500); opts.now = clock fn (tests).
-- Idempotent — a second call is a no-op.
function M.install(opts)
  if installed then return end
  opts = opts or {}
  capacity = math.max(1, math.min(DEFAULT_CAP, math.floor(tonumber(opts.cap) or DEFAULT_CAP)))
  nowFn = opts.now or os.clock
  original = _G.log
  _G.log = function(level, tag, msg)
    M.push(level, tag, msg)
    if original then return original(level, tag, msg) end
  end
  installed = true
end

-- push records one entry, overwriting the oldest slot beyond capacity. O(1).
function M.push(level, tag, msg)
  head = head % capacity + 1
  sequence = sequence + 1
  ring[head] = logfmt.bound({
    time = nowFn(), level = tostring(level), tag = tostring(tag), msg = tostring(msg),
  })
  ring[head].seq = sequence
  if count < capacity then count = count + 1 end
end

-- Snapshot sequence numbers are local to a generation. Callers own their cursors.
function M.snapshot()
  local entries = {}
  for i = 1, count do entries[i] = ring[(head - count + i - 1) % capacity + 1] end
  return entries, nonce .. tostring(generation), sequence - count + 1, sequence
end

-- recent(opts) -> (entries, total). Linearizes the ring oldest-first (cheap: only on tool calls,
-- never in the log hot path) and filters via logfmt.select (shared with the file source):
-- opts { limit, level, tag, match }. Returns the kept slice (newest last) + the true matching total.
function M.recent(opts)
  local entries = {}
  for i = 1, count do
    entries[i] = ring[(head - count + i - 1) % capacity + 1]
  end
  return logfmt.select(entries, opts)
end

-- reset() restores the original log and clears state (tests + clean re-init).
function M.reset()
  if installed then _G.log = original end
  ring = {}; head = 0; count = 0
  generation = generation + 1; sequence = 0
  installed = false; original = nil; capacity = DEFAULT_CAP; nowFn = os.clock
end

return M
