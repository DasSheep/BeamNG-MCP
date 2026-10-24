-- stub: temporarily override fields on a table (module or _G) for the duration of fn, restoring the
-- originals afterwards even if fn errors. Test files share one process, so stubs must never leak.
-- To REMOVE a field for the duration, pass stub.NIL (a literal nil in a table constructor is skipped by pairs).
local M = {}

M.NIL = setmetatable({}, { __tostring = function() return "stub.NIL" end })

function M.with(tbl, overrides, fn)
  local saved = {}
  for k, v in pairs(overrides) do
    saved[#saved + 1] = { k = k, v = rawget(tbl, k) }
    if v == M.NIL then rawset(tbl, k, nil) else rawset(tbl, k, v) end
  end
  local ok, err = pcall(fn)
  for i = #saved, 1, -1 do rawset(tbl, saved[i].k, saved[i].v) end
  if not ok then error(err, 0) end
end

return M
