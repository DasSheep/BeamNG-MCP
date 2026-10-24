-- reload/detect: pure classification of a post-reload load, comparing our own snapshot file (written in
-- onSerialize, independent of the engine blob) against the reloadId that rode in the engine blob.
--   cold   - no snapshot file: a fresh start, nothing to do
--   normal - blob restored and carries the file's reloadId
--   total  - fresh file for this level but NO blob id: importPersistentData failed and restored nothing
--   stale  - file too old / wrong level / mismatched id: report only, never repair from it
local M = {}

M.MAX_AGE = 300  -- seconds

function M.classify(fileSnap, blobId, now, mission)
  if type(fileSnap) ~= "table" then return "cold" end
  if type(fileSnap.at) ~= "number" or type(now) ~= "number" then return "stale" end
  local age = now - fileSnap.at
  if age < 0 or age > M.MAX_AGE then return "stale" end
  if fileSnap.level ~= mission then return "stale" end
  if blobId == nil then return "total" end
  if blobId == fileSnap.reloadId then return "normal" end
  return "stale"
end

return M
