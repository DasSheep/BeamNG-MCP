-- panel: the in-game ImGui status window. Split into PURE logic (visibility decision + value
-- formatting) — exhaustively unit-tested below — and an IMPURE draw() that issues im.* calls (verified
-- in-engine). The imgui handle is fetched lazily via deps.getIm() so beammcp's early game-start auto-load
-- never depends on the UI stack being ready (draw no-ops until ui_imgui exists).
local M = {}
local bind = require("beammcp/bind")

-- visible = (pinned or menuOpen) and not occluded
function M.isVisible(menuOpen, occluded, pinned)
  if occluded then return false end
  return (pinned or menuOpen) and true or false
end

function M.formatDuration(sec)
  sec = math.max(0, math.floor(sec or 0))  -- clamp: a display formatter never shows negative time
  return string.format("%dm %02ds", math.floor(sec / 60), sec % 60)
end

function M.formatSinceLast(sinceLast)
  if sinceLast == nil then return "never" end
  return string.format("%ds ago", math.floor(sinceLast))
end

function M.formatCdp(active, count, port)
  port = tostring(port or 8080)
  if active then
    return string.format("CEF DevTools :%s  active (%d targets)", port, count or 0)
  end
  return "CEF DevTools :" .. port .. "  inactive - launch -cefdev"
end

-- parsePort(n): validate a port (number or numeric string) → integer in [1024, 65535], else (nil, msg).
-- Rejects non-numeric, non-integer, privileged (<1024), and >65535.
function M.parsePort(n)
  n = tonumber(n)
  if n == nil or n ~= math.floor(n) or n < 1024 or n > 65535 then
    return nil, "port must be 1024-65535"
  end
  return math.floor(n)
end

-- bufToString(buf): read an im.ArrayChar back to a Lua string. Isolated as a seam because the buffer is ffi
-- cdata in-engine (read via ffi.string) but a plain table in off-engine tests, which override this. The read
-- itself is verified in-engine.
function M.bufToString(buf) return require("ffi").string(buf) end

-- bindHint(persisted, live, authOn) -> (kind, message) for the bind-address field, or nil:
--   "downgrade" — persisted is non-loopback but auth is off, so it's forced to loopback (the fail-closed rule);
--   "restart"   — persisted differs from the live bind (changed; a restart is needed to apply it).
function M.bindHint(persisted, live, authOn)
  if not bind.isLoopback(persisted) and authOn ~= true then
    return "downgrade", "bind " .. persisted .. " needs Require auth - using loopback until enabled"
  end
  if persisted ~= live then
    return "restart", "restart to apply - bind " .. persisted
  end
  return nil
end

-- deps = {
--   getIm = function()->imguiHandle|nil,   -- lazy: ui_imgui (nil until the UI stack is up)
--   getPinned = function()->bool, setPinned = function(bool),
--   getPort = function()->number, setPort = function(number),
--   getBindHost = function()->string, setBindHost = function(string),
--   getCefPort = function()->number, setCefPort = function(number),
--   getSimControl = function()->bool, setSimControl = function(bool),
--   getReloadToast = function()->bool, setReloadToast = function(bool),
--   getRequireAuth = function()->bool, setRequireAuth = function(bool),
--   getAuthToken = function()->string, regenerateToken = function(),
--   getMissionFilename = function()->string,
--   bigMapActive = function()->bool, photoModeOpen = function()->bool,
-- }
function M.new(deps)
  -- bootstrap: an empty mission filename means the main menu (panel should show immediately on launch).
  local self = { deps = deps, menuOpen = (deps.getMissionFilename() == "") }

  function self:setMenuOpen(b) self.menuOpen = b and true or false end

  function self:occluded()
    local d = self.deps
    return (d.bigMapActive() == true) or (d.photoModeOpen() == true)
  end

  -- applyPort(raw): validate raw and, on success, persist via deps.setPort and clear the error;
  -- on failure record the message for the panel to render dimmed. Returns true on success.
  function self:applyPort(raw)
    local port, err = M.parsePort(raw)
    if port then
      self.deps.setPort(port)
      self.portError = nil
      return true
    end
    self.portError = err
    return false
  end

  -- applyBindHost(raw): validate the typed bind address; on success persist via deps.setBindHost and clear
  -- the error; on failure record the message for the panel to render dimmed. Returns true on success.
  function self:applyBindHost(raw)
    local host, err = bind.validate(raw)
    if host then
      self.deps.setBindHost(host)
      self.bindError = nil
      return true
    end
    self.bindError = err
    return false
  end

  -- applyCefPort(raw): validate the cef_eval CDP target port; on success persist via deps.setCefPort (which
  -- applies live) and clear the error; on failure record it for the panel to render dimmed.
  function self:applyCefPort(raw)
    local port, err = M.parsePort(raw)
    if port then
      self.deps.setCefPort(port)
      self.cefPortError = nil
      return true
    end
    self.cefPortError = err
    return false
  end

  function self:draw(snap)
    local im = self.deps.getIm()
    if im == nil then return end  -- ui_imgui not ready yet; skip this frame
    local pinned = self.deps.getPinned() == true
    if not M.isVisible(self.menuOpen, self:occluded(), pinned) then return end

    -- Precompute ALL strings before im.Begin so nothing between Begin/End can throw and leave the
    -- ImGui window stack unbalanced (e.g. a %d on a non-number). The caller also pcall-wraps draw().
    local hostPort  = string.format("%s:%s", tostring(snap.host), tostring(snap.port))
    local toolsStr  = string.format("tools    %d", snap.toolCount or 0)
    local uptimeStr = "uptime   " .. M.formatDuration(snap.uptime)
    local reqStr    = string.format("requests %d", snap.requestCount or 0)
    local lastStr   = "last     " .. M.formatSinceLast(snap.sinceLast)
    local methodStr = snap.lastMethod ~= nil and ("  " .. tostring(snap.lastMethod)) or nil
    local cdpActive = snap.cdpActive == true
    local cdpStr = M.formatCdp(cdpActive, snap.cdpTargets, self.deps.getCefPort())
    local green = im.ImVec4(0.45, 0.92, 0.45, 1.0)
    local warn  = im.ImVec4(0.95, 0.55, 0.25, 1.0)  -- amber: the regenerate-confirmation warning
    -- Auth fingerprint precomputed here (not inside Begin/End): reads the dep + assembles the string up
    -- front, per the precompute rule above. Generated tokens are always 64 hex chars; the >=8 guard is
    -- defensive (a short/nil token renders "(none)", which can't occur with the engine-entropy generator).
    local authOn = self.deps.getRequireAuth() == true
    local reloadToastOn = self.deps.getReloadToast() == true
    local authFp, authTok
    if authOn then
      authTok = self.deps.getAuthToken()
      authFp = (type(authTok) == "string" and #authTok >= 8) and (authTok:sub(1, 8) .. "...") or "(none)"
    end

    im.Begin("BeamMCP", nil, im.WindowFlags_AlwaysAutoResize)
    im.TextColored(green, "running")
    im.Text(hostPort)
    im.Separator()
    im.Text(toolsStr)
    im.Text(uptimeStr)
    im.Text(reqStr)
    im.Text(lastStr)
    if methodStr ~= nil then im.Text(methodStr) end
    im.Separator()
    if cdpActive then im.TextColored(green, cdpStr) else im.TextDisabled(cdpStr) end
    im.Separator()
    local p = im.BoolPtr(pinned)
    local toggledPin = im.Checkbox("Keep visible in gameplay", p)

    im.Separator()
    -- lazy draft init: ui_imgui is fetched lazily, so build the IntPtr on the first frame im is available.
    if self.portPtr == nil then self.portPtr = im.IntPtr(self.deps.getPort()) end
    im.Text("port")
    im.SameLine()
    im.SetNextItemWidth(90)
    im.InputInt("##port", self.portPtr, 0, 0)  -- step=0,step_fast=0 → no +/- buttons (fits the value)
    im.SameLine()
    local applyClicked = im.Button("Apply")
    local persisted = self.deps.getPort()
    if persisted ~= snap.port then
      im.TextDisabled("restart to apply - use :" .. tostring(persisted))
    end
    if self.portError ~= nil then im.TextDisabled(self.portError) end
    -- bind address (LAN access): editable like the port, takes effect on restart; bind.resolve fail-closes it
    -- to loopback unless auth is on (the downgrade hint below explains when that happens).
    if self.bindPtr == nil then self.bindPtr = im.ArrayChar(64, self.deps.getBindHost()) end
    im.Text("bind")
    im.SameLine()
    im.SetNextItemWidth(120)
    im.InputText("##bind", self.bindPtr, im.ArraySize(self.bindPtr))
    im.SameLine()
    local applyBindClicked = im.Button("Apply##bind")
    local bindKind, bindMsg = M.bindHint(self.deps.getBindHost(), tostring(snap.host), authOn)
    if bindKind == "downgrade" then im.TextColored(warn, bindMsg)
    elseif bindKind == "restart" then im.TextDisabled(bindMsg) end
    if self.bindError ~= nil then im.TextDisabled(self.bindError) end
    -- cef port: the CDP target port for cef_eval (default 8080). Applies LIVE (the probe is a fresh connection
    -- each tick) — point it at BeamNG's -cefdev port when another CEF app (e.g. Steam) squats 8080.
    if self.cefPortPtr == nil then self.cefPortPtr = im.IntPtr(self.deps.getCefPort()) end
    im.Text("cef port")
    im.SameLine()
    im.SetNextItemWidth(90)
    im.InputInt("##cefport", self.cefPortPtr, 0, 0)
    im.SameLine()
    local applyCefClicked = im.Button("Apply##cef")
    if self.cefPortError ~= nil then im.TextDisabled(self.cefPortError) end
    im.Separator()
    local scPtr = im.BoolPtr(self.deps.getSimControl() == true)
    local toggledSc = im.Checkbox("Allow sim-time control", scPtr)
    local rtPtr = im.BoolPtr(reloadToastOn)
    local toggledRt = im.Checkbox("Toast on reload recovery", rtPtr)
    im.Separator()
    local raPtr = im.BoolPtr(authOn)
    local toggledRa = im.Checkbox("Require auth (token)", raPtr)
    local armRegen, confirmRegen, cancelRegen, copyClicked = false, false, false, false
    if authOn then
      im.Text("token " .. authFp)
      im.SameLine()
      copyClicked = im.Button("Copy token")  -- copies the FULL token to the OS clipboard (below, after End)
      -- Regenerate needs a two-click confirm so a stray click can't invalidate the live token (which would
      -- 401 the operator's own client until the new token is copied into the client header).
      if self.regenArmed then
        im.TextColored(warn, "This will invalidate the current token.")
        confirmRegen = im.Button("Confirm regenerate")
        im.SameLine()
        cancelRegen = im.Button("Cancel regenerate")
      else
        armRegen = im.Button("Regenerate token")
      end
    end
    im.End()

    -- apply side-effects AFTER End so the store writes are outside the Begin/End span (throw-free span).
    if toggledPin then self.deps.setPinned(p[0]) end
    if applyClicked then self:applyPort(self.portPtr[0]) end
    if applyBindClicked then self:applyBindHost(M.bufToString(self.bindPtr)) end
    if applyCefClicked then self:applyCefPort(self.cefPortPtr[0]) end
    if toggledSc then self.deps.setSimControl(scPtr[0]) end
    if toggledRt then self.deps.setReloadToast(rtPtr[0]) end
    if toggledRa then self.deps.setRequireAuth(raPtr[0]) end
    if copyClicked then im.SetClipboardText(authTok or "") end  -- full token → clipboard (never on screen)
    if not authOn then
      self.regenArmed = false             -- clear any pending confirmation when auth is off
    elseif armRegen then
      self.regenArmed = true              -- first click: arm, don't regenerate yet
    elseif confirmRegen then
      self.deps.regenerateToken()
      self.regenArmed = false
    elseif cancelRegen then
      self.regenArmed = false
    end
  end

  return self
end

return M
