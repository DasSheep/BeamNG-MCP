-- recover_game_state: manual check/repair of engine state a Lua reload can lose (levelLoaded, camera, HUD
-- game state, night lights; UI layers and vanished extensions are snapshot-only and report skipped here).
-- Runs the same guards as the automatic post-reload heal, but in "manual" mode with no snapshot. Dry-run by
-- default; apply=true repairs. Also returns the last automatic recovery (injected via M.lastSource).
local runner    = require("beammcp/reload/runner")
local guardlist = require("beammcp/reload/guardlist")
local M = {}

-- Injected by beammcp.lua (autoheal.lastCompact). nil until wired.
M.lastSource = nil

function M.now() return os.time() end

local function handler(args)
  args = (type(args) == "table") and args or {}
  if args.apply ~= nil and type(args.apply) ~= "boolean" then
    return nil, "recover_game_state: 'apply' must be a boolean"
  end
  local names
  if args.guards ~= nil then
    if type(args.guards) ~= "table" or #args.guards == 0 then
      return nil, "recover_game_state: 'guards' must be a non-empty array of guard names"
    end
    names = {}
    for _, n in ipairs(args.guards) do
      if not guardlist.known(n) then
        return nil, "recover_game_state: unknown guard '" .. tostring(n) .. "' (known: "
          .. table.concat(guardlist.ORDER, ", ") .. ")"
      end
      names[n] = true
    end
  end
  local report = runner.run(guardlist.list(names), { mode = "manual", now = M.now() }, args.apply == true)
  return { report = report, lastReloadRecovery = M.lastSource and M.lastSource() or nil }
end

M.def = {
  description = "Check (default) or repair (apply=true) engine state a Lua reload can lose: levelLoaded, "
    .. "camera, HUD game state and night lights. The automatic post-reload heal also restores UI layers and "
    .. "reports extensions that did not come back (it reloads them only after a total persistence-blob "
    .. "failure); both need the pre-reload snapshot, so they report skipped here. See lastReloadRecovery for "
    .. "what it did. Use when the camera, HUD or street lights look wrong. Optional guards=[names] subset.",
  annotations = { readOnlyHint = false, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      apply = { type = "boolean", default = false, description = "repair issues (default: dry-run)" },
      guards = { type = "array", items = { type = "string", enum = guardlist.ORDER },
                 description = "run only these guards (default: all)" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("recover_game_state", M.def)
end

return M
