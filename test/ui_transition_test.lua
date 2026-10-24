local ui = require("beammcp/tools/lib/ui_state")
local lv = require("beammcp/tools/levels")
local mp = require("beammcp/tools/lib/mp")
test("level completion waits for fadeout, initialized world, then committed UI", function()
  local route, calls = "menu", 0
  local entry, pending = { request = { name = route } }
  _G.extensions = { ui_router = {
    getCurrent = function() return entry end,
    navigate = function(name)
      calls = calls + 1; pending = { request = { name = name } }
      return { success = true, data = pending }
    end,
  } }
  local oldList, oldFire, oldProbe = lv.fetchList, lv.fire, mp.probe
  lv.fetchList = function() return { { levelName = "gridmap_v2" } } end
  lv.fire = function() return true end
  mp.probe = function() return { modLoaded = false } end
  _G.getCurrentLevelIdentifier = function() return "gridmap_v2" end
  _G.freeroam_freeroam = { state = { freeroamActive = true } }
  _G.core_gamestate = { loading = function() return false end }
  _G.worldReadyState = 2
  lv.loadDef.handler({level = "gridmap_v2"})
  lv.update(0); assertEqual(calls, 0)
  lv.onLoadingScreenFadeout()
  lv.update(0); lv.update(0); assertEqual(calls, 1)
  assertEqual(lv.transitionSnapshot().status, "ui_pending")
  entry = pending
  lv.update(0); assertEqual(lv.transitionSnapshot().status, "ready")
  lv.fetchList, lv.fire, mp.probe = oldList, oldFire, oldProbe
  _G.extensions = nil
end)
test("UI requests authenticate same-route commit, supersession and missing acknowledgement", function()
  local entry = { request = { name = "play" } }
  local pending
  _G.extensions = { ui_router = {
    getCurrent = function() return entry end,
    navigate = function(name)
      pending = { request = { name = name } }
      return { success = true, data = pending }
    end,
  } }
  local res = ui.def.handler({uiState = "play"})
  assertEqual(res.uiState, "play"); assertEqual(res.uiTransition.status, "pending")
  entry = pending; ui.update(0)
  local _, req = ui.snapshot(); assertEqual(req.status, "ready")
  local _, _, old = ui.navigate("play")
  ui.navigate("menu")
  _, req = ui.snapshot(old); assertEqual(req.status, "failed"); assertMatch(req.error, "superseded")
  ui.update(15)
  _, req = ui.snapshot(); assertEqual(req.status, "failed")
  _G.extensions = nil
end)
