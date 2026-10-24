-- shape: pure, engine-free helpers for the "compact-by-default, opt-in detail" tool discipline.
-- capList trims a pre-sorted array to a top-N and reports the true total; capNote renders the standard
-- "Showing top N of M <items>." sentence (empty when not capped); breakdown counts items by a key function
-- (nil keys skipped). No BeamNG globals touched -- unit-testable off-engine. Follows the config_arg.lua/mp.lua
-- module pattern (local M = {}; pure functions; return M).
local M = {}

-- capList(arr, n) -> (capped, total). Keep the first n entries of a PRE-SORTED array; return the kept slice
-- and the TRUE total length. When #arr <= n the original array is returned unchanged. (Lifted verbatim from
-- the original part_condition.M.capList so existing behavior is byte-identical.)
function M.capList(arr, n)
  if #arr <= n then return arr, #arr end
  local out = {}
  for i = 1, n do out[i] = arr[i] end
  return out, #arr
end

-- capNote(shown, total, itemName) -> string. The standard truncation sentence, with a leading space so it
-- appends cleanly onto an existing note; returns "" (empty) when nothing was truncated (total <= shown).
function M.capNote(shown, total, itemName)
  if total > shown then
    return string.format(" Showing top %d of %d %s.", shown, total, itemName)
  end
  return ""
end

-- ciContains(haystack, needle) -> bool. Case-insensitive plain-substring test; an absent/empty
-- needle never constrains. The canonical copy of the filter predicate (logfmt/tuning share it).
function M.ciContains(haystack, needle)
  if needle == nil or needle == "" then return true end
  return string.find(string.lower(tostring(haystack)), string.lower(needle), 1, true) ~= nil
end

-- breakdown(items, keyFn) -> { [key] = count }. Count items grouped by keyFn(item). Items whose key is nil
-- are skipped (e.g. models without a Brand). keyFn is applied to each array element of `items`.
function M.breakdown(items, keyFn)
  local counts = {}
  for _, item in ipairs(items or {}) do
    local k = keyFn(item)
    if k ~= nil then
      counts[k] = (counts[k] or 0) + 1
    end
  end
  return counts
end

return M
