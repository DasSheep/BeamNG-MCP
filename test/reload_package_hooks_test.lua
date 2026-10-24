require("support.beamng_stubs")

-- Regression: BeamNG's common/utils.lua serializePackages()/deserializePackages() walk ALL of
-- package.loaded and treat ANY table exposing onSerialize/onDeserialize/onDeserialized as a persistence
-- participant -- calling onSerialize on every reload and, after the extensions pass runs, calling
-- onDeserialized again with whatever it captured (or tableMerge-ing raw data into the module table when
-- neither onDeserialize nor .state exists). Only the beammcp extension module itself may own those hook
-- names (beammcp.lua's M.onSerialize/M.onDeserialized are the sole, intentional participant). If any
-- plain module under beammcp/reload or beammcp/tools/recover_game_state exports one of these names, the
-- engine's blind package pass fires it a second time and stomps state the extension hook just set --
-- exactly how a normal reload was silently misclassified as "stale" and never healed.
local MODULES = {
  "beammcp/reload/env",
  "beammcp/reload/detect",
  "beammcp/reload/snapshot",
  "beammcp/reload/gate",
  "beammcp/reload/runner",
  "beammcp/reload/guardlist",
  "beammcp/reload/autoheal",
  "beammcp/reload/guards/levelflag",
  "beammcp/reload/guards/camera",
  "beammcp/reload/guards/gamestate",
  "beammcp/reload/guards/nightlights",
  "beammcp/reload/guards/ui_visibility",
  "beammcp/reload/guards/extensions",
  "beammcp/tools/recover_game_state",
}

local FORBIDDEN = { "onSerialize", "onDeserialize", "onDeserialized" }

for _, name in ipairs(MODULES) do
  test("package-serializer hazard: " .. name .. " does not export engine persistence hooks", function()
    local mod = require(name)
    assertTrue(type(mod) == "table", name .. " did not return a table")
    for _, hook in ipairs(FORBIDDEN) do
      assertTrue(mod[hook] == nil,
        name .. "." .. hook .. " must not exist: it would be a false persistence participant to " ..
        "common/utils.lua's serializePackages()/deserializePackages(), fired again after the extension's own hook")
    end
  end)
end
