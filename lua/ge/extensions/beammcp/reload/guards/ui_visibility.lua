-- guard ui_visibility: ui/visibility.lua does not persist its cef/imgui flags across a reload. Restores the
-- pre-reload flags (snapshot only; a manual run has no "before" to compare with). Engine calls go through
-- the ui_visibility tool module's stubbable seams.
local uiv = require("beammcp/tools/ui_visibility")
local M = { name = "ui_visibility" }

local function diffs(want, cur)
  local d = {}
  if type(want.cef) == "boolean" and want.cef ~= cur.cef then d[#d + 1] = "cef" end
  if type(want.imgui) == "boolean" and want.imgui ~= cur.imgui then d[#d + 1] = "imgui" end
  return d
end

function M.check(ctx)
  local want = ctx and ctx.snap and ctx.snap.ui
  if type(want) ~= "table" then return { skip = "no snapshot" } end
  local d = diffs(want, uiv.readState())
  if #d > 0 then return { issue = "UI layer flags differ from before the reload: " .. table.concat(d, ", ") } end
  return nil
end

function M.repair(ctx)
  local want = ctx.snap.ui
  local cur = uiv.readState()
  if type(want.cef) == "boolean" and want.cef ~= cur.cef then uiv.setCef(want.cef) end
  if type(want.imgui) == "boolean" and want.imgui ~= cur.imgui then uiv.setImgui(want.imgui) end
end

return M
