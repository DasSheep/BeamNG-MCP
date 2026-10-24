-- ui_visibility: get/set the visibility of BeamNG's UI layers (the CEF web UI/HUD and the ImGui layer).
-- Both tools are synchronous wrappers over the engine global `ui_visibility` (lua/ge/extensions/ui/
-- visibility.lua): setCef/setImgui flip a state flag and, only on change, fire a hook the render layer
-- subscribes to (so re-asserting the current value is an idempotent no-op). The engine calls live in
-- stubbable M fields (M.setCef/M.setImgui/M.readState), so the handlers are pure and unit-testable.
-- This is the one file in the project that registers two tools: get and set are two facets of one
-- capability sharing the same engine module and {cef, imgui} state shape.
local M = {}

-- Engine-coupled (stubbed in tests, verified in-engine).
function M.setCef(visible)   ui_visibility.setCef(visible)   end
function M.setImgui(visible) ui_visibility.setImgui(visible) end
function M.readState()
  return { cef = ui_visibility.getCef(), imgui = ui_visibility.getImgui() }
end

local function getHandler(_args)
  return M.readState()
end

local function setHandler(args)
  if type(args) ~= "table" then
    return nil, "set_ui_visibility: arguments must be an object"
  end
  -- distinguish "omitted" (nil) from "provided as false" — false means hide, so test against nil.
  if args.cef == nil and args.imgui == nil then
    return nil, "set_ui_visibility: provide cef and/or imgui as a boolean"
  end
  if args.cef ~= nil and type(args.cef) ~= "boolean" then
    return nil, "set_ui_visibility: 'cef' must be a boolean"
  end
  if args.imgui ~= nil and type(args.imgui) ~= "boolean" then
    return nil, "set_ui_visibility: 'imgui' must be a boolean"
  end
  if args.cef ~= nil then M.setCef(args.cef) end
  if args.imgui ~= nil then M.setImgui(args.imgui) end
  return M.readState()
end

M.getDef = {
  description = "Get the visibility of the UI layers. Returns { cef, imgui } booleans.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = {} },
  handler = getHandler,
}

M.setDef = {
  description = "Show/hide UI layers. Provide cef and/or imgui as booleans; an omitted layer is left "
    .. "unchanged. Returns the resulting { cef, imgui } state.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      cef = { type = "boolean", description = "show (true) / hide (false) the CEF web UI / HUD layer" },
      imgui = { type = "boolean", description = "show (true) / hide (false) the ImGui layer" },
    },
  },
  handler = setHandler,
}

function M.register(registry)
  registry:add("get_ui_visibility", M.getDef)
  registry:add("set_ui_visibility", M.setDef)
end

return M
