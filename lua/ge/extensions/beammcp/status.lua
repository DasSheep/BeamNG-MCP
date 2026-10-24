-- status: the MCP server's live status + request-activity record. Pure data — no engine access.
-- The clock is a monotonic accumulator advanced by tick(dtReal) from the GE onUpdate, so uptime and
-- "seconds since last request" need no wall-clock API (os.clock is CPU time, wrong for this).
local M = {}

function M.new()
  local self = {
    running = false, host = nil, port = nil, toolCount = 0,
    now = 0, startedAt = 0,
    requestCount = 0, lastMethod = nil, lastRequestAt = nil,
    cdpActive = false, cdpTargets = 0,
    menuOpen = false,
  }

  function self:setServer(host, port, toolCount)
    self.running = true
    self.host, self.port, self.toolCount = host, port, toolCount
    self.startedAt = self.now
  end

  function self:tick(dt)
    self.now = self.now + (dt or 0)
  end

  function self:setCdp(active, count)
    self.cdpActive = active and true or false
    self.cdpTargets = count or 0
  end

  function self:setMenuOpen(b)
    self.menuOpen = b and true or false
  end

  function self:record(method)
    self.requestCount = self.requestCount + 1
    self.lastMethod = method
    self.lastRequestAt = self.now
  end

  function self:snapshot()
    return {
      running = self.running,
      host = self.host, port = self.port, toolCount = self.toolCount,
      -- uptime is meaningless before the server starts; nil until then (parallels sinceLast).
      uptime = self.running and (self.now - self.startedAt) or nil,
      requestCount = self.requestCount,
      lastMethod = self.lastMethod,
      sinceLast = self.lastRequestAt and (self.now - self.lastRequestAt) or nil,
      cdpActive = self.cdpActive,
      cdpTargets = self.cdpTargets,
      menuOpen = self.menuOpen,
    }
  end

  return self
end

return M
