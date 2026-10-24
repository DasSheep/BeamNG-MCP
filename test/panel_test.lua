local panel = require("panel")
-- The bind-address ArrayChar is ffi cdata in-engine (panel.bufToString = ffi.string); off-engine the fake
-- ArrayChar is a table whose draft lives in [0], so read it directly.
panel.bufToString = function(buf) return buf[0] end

test("isVisible: hidden during gameplay (not menu, not pinned)", function()
  assertEqual(panel.isVisible(false, false, false), false)
end)

test("isVisible: shown in a menu", function()
  assertEqual(panel.isVisible(true, false, false), true)
end)

test("isVisible: shown when pinned even outside a menu", function()
  assertEqual(panel.isVisible(false, false, true), true)
end)

test("isVisible: occlusion hides it even when pinned or in a menu", function()
  assertEqual(panel.isVisible(true, true, true), false)
  assertEqual(panel.isVisible(true, true, false), false)
  assertEqual(panel.isVisible(false, true, false), false)  -- occluded, nothing competing
end)

test("formatDuration clamps negative input to zero", function()
  assertEqual(panel.formatDuration(-5), "0m 00s")
end)

test("formatDuration renders mm ss with zero-padded seconds", function()
  assertEqual(panel.formatDuration(0), "0m 00s")
  assertEqual(panel.formatDuration(5), "0m 05s")
  assertEqual(panel.formatDuration(64), "1m 04s")
  assertEqual(panel.formatDuration(724), "12m 04s")
end)

test("formatSinceLast: nil -> never, else floored seconds ago", function()
  assertEqual(panel.formatSinceLast(nil), "never")
  assertEqual(panel.formatSinceLast(0), "0s ago")
  assertEqual(panel.formatSinceLast(3.9), "3s ago")
end)

-- A recording stub of ui_imgui. clickCheckbox flips every BoolPtr; rec.clicks[label]=bool drives a button
-- by label (falling back to rec.clickApply for the unlabelled legacy "Apply" tests).
local function fakeIm(clickCheckbox, clickApply)
  local rec = { begins = 0, ends = 0, texts = {}, disabled = {}, clicks = {},
                clickCheckbox = clickCheckbox or false, clickApply = clickApply or false }
  local im = {
    WindowFlags_AlwaysAutoResize = 1,
    ImVec4 = function() return {} end,
    Begin = function() rec.begins = rec.begins + 1; return true end,
    End = function() rec.ends = rec.ends + 1 end,
    Text = function(s) rec.texts[#rec.texts + 1] = s end,
    TextColored = function(_, s) rec.texts[#rec.texts + 1] = s end,
    TextDisabled = function(s) rec.disabled[#rec.disabled + 1] = s end,
    Separator = function() end,
    SameLine = function() end,
    SetNextItemWidth = function() end,
    BoolPtr = function(v) return { [0] = v } end,
    IntPtr = function(v) return { [0] = v } end,
    InputInt = function(_, p) return false end,            -- draft persists in p; no-op
    Checkbox = function(_, p) if rec.clickCheckbox then p[0] = not p[0]; return true end return false end,
    Button = function(label)
      if rec.clicks[label] ~= nil then return rec.clicks[label] end
      if label == "Apply" then return rec.clickApply end  -- back-compat: only the legacy port "Apply"
      return false
    end,
    SetClipboardText = function(s) rec.clipboard = s end,
    ArrayChar = function(size, init) return { [0] = init, _size = size } end,  -- draft persists in [0]
    ArraySize = function(buf) return buf._size or 64 end,
    InputText = function(_, buf) return false end,  -- no-op; tests set buf[0] to simulate typing
  }
  return im, rec
end

local function deps(over)
  over = over or {}
  local pinned = over.pinned or false
  local port = over.port or 23512
  local simControl = over.simControl or false
  local requireAuth = over.requireAuth or false
  local authToken = over.authToken or "abcdefgh0000000000000000"
  local bindHost = over.bindHost or "127.0.0.1"
  local cefPort = over.cefPort or 8080
  local reloadToast = true
  if over.reloadToast ~= nil then reloadToast = over.reloadToast end
  local d  -- declared before the table so the setPinned/setPort closures capture it as an upvalue
  d = {
    getIm = over.getIm or function() return nil end,
    getPinned = function() return pinned end,
    setPinned = function(v) pinned = v; d._pinned = v end,
    getPort = function() return port end,
    setPort = function(n) port = n; d._port = n end,
    getBindHost = function() return bindHost end,
    setBindHost = function(v) bindHost = v; d._bindHost = v end,
    getCefPort = function() return cefPort end,
    setCefPort = function(n) cefPort = n; d._cefPort = n end,
    getSimControl = function() return simControl end,
    setSimControl = function(v) simControl = v; d._simControl = v end,
    getReloadToast = function() return reloadToast end,
    setReloadToast = function(v) reloadToast = v; d._reloadToast = v end,
    getRequireAuth = function() return requireAuth end,
    setRequireAuth = function(v) requireAuth = v; d._requireAuth = v end,
    getAuthToken = function() return authToken end,
    regenerateToken = function() d._regen = true; authToken = "REGENERATED" end,
    getMissionFilename = over.getMissionFilename or function() return "/levels/x/main.level.json" end,
    bigMapActive = over.bigMapActive or function() return false end,
    photoModeOpen = over.photoModeOpen or function() return false end,
  }
  return d
end

local SNAP = { running = true, host = "127.0.0.1", port = 23512, toolCount = 14,
               uptime = 724, requestCount = 37, lastMethod = "spawn_vehicle", sinceLast = 3 }

test("new bootstraps menuOpen from getMissionFilename: in-level -> false (hidden)", function()
  local p = panel.new(deps())
  assertEqual(p.menuOpen, false)
end)

test("new bootstraps menuOpen true when no mission is loaded (main menu)", function()
  local p = panel.new(deps({ getMissionFilename = function() return "" end }))
  assertEqual(p.menuOpen, true)
end)

test("draw no-ops (no Begin) when not visible", function()
  local im, rec = fakeIm(false)
  local p = panel.new(deps({ getIm = function() return im end }))  -- in-level ⇒ menuOpen false, not pinned
  p:draw(SNAP)
  assertEqual(rec.begins, 0)
end)

test("draw no-ops when getIm() is nil (ui_imgui not ready)", function()
  local p = panel.new(deps())  -- getIm returns nil
  p:setMenuOpen(true)
  p:draw(SNAP)  -- must not error
  assertTrue(true)
end)

test("draw issues a balanced Begin/End when visible (menu open)", function()
  local im, rec = fakeIm(false)
  local p = panel.new(deps({ getIm = function() return im end }))
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(rec.begins, 1)
  assertEqual(rec.ends, 1)
  -- verify real content was rendered, not just that the window opened
  local joined = table.concat(rec.texts, "|")
  assertMatch(joined, "127%.0%.0%.1:23512")  -- host:port
  assertMatch(joined, "spawn_vehicle")        -- last method
  assertMatch(joined, "12m 04s")              -- formatted uptime
end)

test("ticking the pin checkbox calls setPinned with the toggled value", function()
  local im = fakeIm(true)  -- Checkbox reports a click and flips the ptr
  local d = deps({ getIm = function() return im end })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(d._pinned, true)  -- started false, checkbox flipped it to true
end)

test("ticking the sim-control checkbox calls setSimControl with the toggled value", function()
  local im = fakeIm(true)  -- the fake Checkbox flips every ptr and reports a click
  local d = deps({ getIm = function() return im end })  -- getSimControl starts false
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(d._simControl, true)  -- the gate toggle persisted via setSimControl(true)
end)

test("occlusion suppresses the window even when pinned", function()
  local im, rec = fakeIm(false)
  local p = panel.new(deps({ getIm = function() return im end,
                             pinned = true,
                             bigMapActive = function() return true end }))
  p:draw(SNAP)
  assertEqual(rec.begins, 0)
end)

test("parsePort accepts valid ports and the boundaries", function()
  assertEqual(panel.parsePort(1024), 1024)
  assertEqual(panel.parsePort(23512), 23512)
  assertEqual(panel.parsePort(65535), 65535)
  assertEqual(panel.parsePort("23513"), 23513)   -- numeric string from a text field
end)

test("parsePort rejects out-of-range, non-integer, and non-numeric input", function()
  for _, bad in ipairs({1023, 65536, 0, -1, 80.5}) do
    local v, err = panel.parsePort(bad)
    assertNil(v)
    assertMatch(err, "1024")
  end
  assertNil(panel.parsePort("abc"))
  assertNil(panel.parsePort(nil))
end)

test("applyPort with a valid port persists it via setPort and clears any error", function()
  local d = deps()
  local p = panel.new(d)
  assertTrue(p:applyPort(23513))
  assertEqual(d._port, 23513)
  assertNil(p.portError)
end)

test("applyPort with an invalid port does not persist and records an error", function()
  local d = deps()
  local p = panel.new(d)
  assertEqual(p:applyPort(70000), false)
  assertNil(d._port)              -- setPort never called
  assertMatch(p.portError, "1024")
end)

test("port field initializes the draft from getPort on first draw", function()
  local im = fakeIm(false, false)
  local p = panel.new(deps({ getIm = function() return im end, port = 23512 }))
  p:setMenuOpen(true)   -- make the panel visible so draw runs the widgets
  p:draw(SNAP)
  assertEqual(p.portPtr[0], 23512)
end)

test("clicking Apply with an edited draft persists the new port", function()
  local im, rec = fakeIm(false, false)
  local d = deps({ getIm = function() return im end, port = 23512 })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)              -- first draw: inits the draft to 23512
  p.portPtr[0] = 23513      -- simulate the operator typing 23513
  rec.clickApply = true     -- next frame: Apply is clicked
  p:draw(SNAP)
  assertEqual(d._port, 23513)
end)

test("Apply with an invalid draft records an error and does not persist; error renders dimmed", function()
  local im, rec = fakeIm(false, false)
  local d = deps({ getIm = function() return im end, port = 23512 })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  p.portPtr[0] = 70000
  rec.clickApply = true
  p:draw(SNAP)              -- Apply fires applyPort(70000) AFTER im.End()
  assertNil(d._port)        -- never persisted
  assertMatch(p.portError, "1024")
  -- one more frame (no Apply) renders the error dimmed
  rec.clickApply = false
  rec.disabled = {}
  p:draw(SNAP)
  assertMatch(table.concat(rec.disabled, "|"), "1024")
end)

test("restart hint renders dimmed when the persisted port differs from the live port", function()
  local im, rec = fakeIm(false, false)
  -- persisted/next = 23513, live (snapshot) = 23512
  local p = panel.new(deps({ getIm = function() return im end, port = 23513 }))
  p:setMenuOpen(true)
  p:draw(SNAP)              -- SNAP.port = 23512
  local joined = table.concat(rec.disabled, "|")
  assertMatch(joined, "restart to apply")
  assertMatch(joined, "23513")
end)

test("formatCdp: active shows target count", function()
  assertEqual(panel.formatCdp(true, 2), "CEF DevTools :8080  active (2 targets)")
end)

test("formatCdp: inactive shows the -cefdev hint", function()
  assertEqual(panel.formatCdp(false, 0), "CEF DevTools :8080  inactive - launch -cefdev")
end)

test("ticking the require-auth checkbox calls setRequireAuth with the toggled value", function()
  local im = fakeIm(true)  -- the fake Checkbox flips every ptr and reports a click
  local d = deps({ getIm = function() return im end })  -- getRequireAuth starts false
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(d._requireAuth, true)
end)

test("auth on: token fingerprint is rendered (not the full token)", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true, authToken = "abcdefgh0000000000000000" })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  local joined = table.concat(rec.texts, "|")
  assertMatch(joined, "abcdefgh")  -- fingerprint shown
  -- full token NOT shown (plain=true: literal search, robust if a token ever holds pattern-magic chars)
  assertNil(joined:find("abcdefgh0000000000000000", 1, true), "panel must not render the full token")
end)

test("Regenerate token first click ARMS a confirmation, does NOT regenerate yet", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)                          -- first draw so the button exists
  rec.clicks["Regenerate token"] = true
  p:draw(SNAP)
  assertNil(d._regen)                   -- first click must NOT regenerate
  assertEqual(p.regenArmed, true)       -- it armed the confirmation instead
end)

test("Confirm regenerate (after arming) calls regenerateToken and disarms", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  rec.clicks["Regenerate token"] = true
  p:draw(SNAP)                          -- arm
  rec.clicks["Regenerate token"] = nil
  rec.clicks["Confirm regenerate"] = true
  p:draw(SNAP)                          -- confirm
  assertEqual(d._regen, true)
  assertEqual(p.regenArmed, false)      -- disarms after confirming
end)

test("Cancel disarms the confirmation without regenerating", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  rec.clicks["Regenerate token"] = true
  p:draw(SNAP)                          -- arm
  rec.clicks["Regenerate token"] = nil
  rec.clicks["Cancel regenerate"] = true
  p:draw(SNAP)                          -- cancel
  assertNil(d._regen)                   -- never regenerated
  assertEqual(p.regenArmed, false)      -- disarmed
end)

test("turning auth off disarms a pending regenerate confirmation", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  rec.clicks["Regenerate token"] = true
  p:draw(SNAP)                          -- arm
  assertEqual(p.regenArmed, true)
  rec.clicks["Regenerate token"] = nil
  p.deps.getRequireAuth = function() return false end  -- operator unticks Require auth
  p:draw(SNAP)
  assertEqual(p.regenArmed, false)      -- the stale confirmation is cleared
end)

test("clicking Copy token copies the FULL token to the clipboard (only when auth on)", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true, authToken = "abcdefgh0000000000000000" })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)                       -- first draw so the button exists
  rec.clicks["Copy token"] = true
  p:draw(SNAP)
  assertEqual(rec.clipboard, "abcdefgh0000000000000000")  -- the FULL token, not the fingerprint
end)

test("Copy token does nothing when not clicked (no spurious clipboard write)", function()
  local im, rec = fakeIm(false)
  local d = deps({ getIm = function() return im end, requireAuth = true, authToken = "abcdefgh0000000000000000" })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertNil(rec.clipboard)
end)

-- bind-address field --------------------------------------------------------------------------------
test("bindHint: non-loopback + auth off -> downgrade message", function()
  local kind, msg = panel.bindHint("0.0.0.0", "127.0.0.1", false)
  assertEqual(kind, "downgrade")
  assertMatch(msg, "needs Require auth")
end)

test("bindHint: changed persisted vs live (auth on) -> restart message", function()
  local kind, msg = panel.bindHint("0.0.0.0", "127.0.0.1", true)  -- auth on => not a downgrade
  assertEqual(kind, "restart")
  assertMatch(msg, "restart to apply")
end)

test("bindHint: loopback and matching live -> nil", function()
  assertNil(panel.bindHint("127.0.0.1", "127.0.0.1", false))
end)

test("applyBindHost: valid IPv4 persists via setBindHost and clears any error", function()
  local d = deps()
  local p = panel.new(d)
  assertTrue(p:applyBindHost("0.0.0.0"))
  assertEqual(d._bindHost, "0.0.0.0")
  assertNil(p.bindError)
end)

test("applyBindHost: invalid value does not persist and records an error", function()
  local d = deps()
  local p = panel.new(d)
  assertEqual(p:applyBindHost("not.an.ip"), false)
  assertNil(d._bindHost)
  assertMatch(p.bindError, "IPv4")
end)

test("bind field initializes its draft from getBindHost on first draw", function()
  local im = fakeIm(false, false)
  local p = panel.new(deps({ getIm = function() return im end, bindHost = "192.168.1.7" }))
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(p.bindPtr[0], "192.168.1.7")
end)

test("clicking Apply##bind with an edited draft persists the new bind host", function()
  local im, rec = fakeIm(false, false)
  local d = deps({ getIm = function() return im end, bindHost = "127.0.0.1" })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)                 -- inits the draft from getBindHost
  p.bindPtr[0] = "0.0.0.0"     -- simulate typing
  rec.clicks["Apply##bind"] = true
  p:draw(SNAP)
  assertEqual(d._bindHost, "0.0.0.0")
end)

test("downgrade warning renders when bind is non-loopback and auth is off", function()
  local im, rec = fakeIm(false, false)
  local p = panel.new(deps({ getIm = function() return im end, bindHost = "0.0.0.0", requireAuth = false }))
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertMatch(table.concat(rec.texts, "|"), "needs Require auth")  -- amber warning (TextColored)
end)

-- cef port field ------------------------------------------------------------------------------------
test("formatCdp shows the configured cef port (not a hardcoded 8080)", function()
  assertEqual(panel.formatCdp(true, 1, 8088), "CEF DevTools :8088  active (1 targets)")
  assertEqual(panel.formatCdp(false, 0, 8088), "CEF DevTools :8088  inactive - launch -cefdev")
end)

test("applyCefPort: valid port persists via setCefPort and clears any error", function()
  local d = deps()
  local p = panel.new(d)
  assertTrue(p:applyCefPort(8088))
  assertEqual(d._cefPort, 8088)
  assertNil(p.cefPortError)
end)

test("applyCefPort: invalid port does not persist and records an error", function()
  local d = deps()
  local p = panel.new(d)
  assertEqual(p:applyCefPort(70000), false)
  assertNil(d._cefPort)
  assertMatch(p.cefPortError, "1024")
end)

test("cef port field initializes its draft from getCefPort on first draw", function()
  local im = fakeIm(false, false)
  local p = panel.new(deps({ getIm = function() return im end, cefPort = 8088 }))
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(p.cefPortPtr[0], 8088)
end)

test("clicking Apply##cef with an edited draft persists the new cef port", function()
  local im, rec = fakeIm(false, false)
  local d = deps({ getIm = function() return im end, cefPort = 8080 })
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)                 -- inits the draft
  p.cefPortPtr[0] = 8088       -- simulate typing
  rec.clicks["Apply##cef"] = true
  p:draw(SNAP)
  assertEqual(d._cefPort, 8088)
end)

test("ticking the reload-toast checkbox calls setReloadToast with the toggled value", function()
  local im = fakeIm(true)  -- the fake Checkbox flips every ptr and reports a click
  local d = deps({ getIm = function() return im end })  -- getReloadToast starts true
  local p = panel.new(d)
  p:setMenuOpen(true)
  p:draw(SNAP)
  assertEqual(d._reloadToast, false)
end)
