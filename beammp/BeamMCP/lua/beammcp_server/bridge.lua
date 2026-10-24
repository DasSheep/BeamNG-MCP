-- Each plugin polls its own private file queue. No network-triggerable eval handler exists.
local M = {}
local ROOT = 'Resources/Server/BeamMCP/'
local function read(path, limit)
  local f=io.open(path,'rb');if not f then return nil end
  local data=f:read((limit or 65536)+1);f:close()
  if not data or #data>(limit or 65536) then return nil end
  return data
end
local function write(path, data)
  local f,err=io.open(path..'.tmp','wb');if not f then return nil,err end
  local ok,why=f:write(data);local closed=f:close()
  if not ok or not closed then os.remove(path..'.tmp');return nil,why or 'write failed' end
  local renamed,why=os.rename(path..'.tmp',path)
  if renamed then return renamed end
  if package.config:sub(1,1)=='\\' then
    os.remove(path)
    return os.rename(path..'.tmp',path)
  end
  return nil,why
end
M.read,M.write=read,write
function M.execute(request, generation, now, call)
  if type(request)~='table' or type(request.id)~='string' or not request.id:match('^%x+$')
      or #request.id>64 or request.generation~=generation then return {error='stale or invalid request generation'} end
  if type(request.expiresAt)~='number' or request.expiresAt<=now then return {error='request expired before execution; execution=not_started'} end
  if type(request.method)~='string' or type(request.args)~='table' then return {error='invalid request'} end
  local ok,result,err=pcall(call,request.method,request.args)
  if not ok then return {error='plugin error: '..tostring(result):sub(1,1024)} end
  if not result then return {error=tostring(err or 'no result'):sub(1,16384)} end
  return {result=result}
end
function M.attach(options)
  options=options or {}
  local plugin=assert(options.plugin,'plugin name required')
  assert(type(plugin)=='string' and #plugin<=64 and plugin:match('^[%w_-]+$'),'invalid plugin name')
  local root=options.resource or ROOT
  if BeamMCPBridge and BeamMCPBridge.shutdown then BeamMCPBridge.shutdown() end
  -- Keep one wrapper across generations, including reattachment from inside a captured eval.
  if not _G.BeamMCPPrintWrapper then
    local original=print
    _G.BeamMCPOriginalPrint=original
    _G.BeamMCPPrintWrapper=function(...)
      local current=_G.BeamMCPBridge
      local values={};for i=1,math.min(select('#',...),16) do values[#values+1]=tostring(select(i,...)):sub(1,1024) end
      if current and current.runtime then current.runtime:record('log',{text=table.concat(values,'\t')}) end
      return original(...)
    end
  end
  local mp=MP
  local timer=mp.CreateTimer()
  local epoch=os.time()
  local function now() return epoch+timer:GetCurrent() end
  local state={stopped=false,serial=0,logsPrint=_G.BeamMCPOriginalPrint}
  local function decode(text)
    if not text then return nil end
    local ok,value=pcall(Util.JsonDecode,text)
    return ok and value or nil
  end
  local function active()
    local a=decode(read(root..'.runtime/active.json',4096))
    if type(a)=='table' and type(a.session)=='string' and #a.session<=96 and a.session:match('^[%w_-]+$') then return a.session end
  end
  local function detach()
    if state.registration then os.remove(state.registration) end
    if state.wrapper and print==state.wrapper then _G.print=state.logsPrint end
    state.session,state.runtime,state.registration,state.wrapper=nil,nil,nil,nil
  end
  local function connect(session)
    detach()
    state.serial=state.serial+1
    _G.BeamMCPBridgeSerial=(_G.BeamMCPBridgeSerial or 0)+1
    local generation=string.format('%d-%d-%d',os.time(),_G.BeamMCPBridgeSerial,math.floor(timer:GetCurrent()*1000000))
    local base=root..'.runtime/'..session..'/plugins/'
    FS.CreateDirectory(base)
    base=base..plugin..'/'
    FS.CreateDirectory(base)
    FS.CreateDirectory(base..generation)
    local config=decode(read(root..'config.json',4096)) or {}
    local runtime=assert(loadfile(root..'lua/beammcp_server/runtime.lua'))()
    state.runtime=runtime.new({plugin=plugin,generation=generation,root=_G,encode=Util.JsonEncode,
      decode=Util.JsonDecode,common=root..'lua/common/beammcp/',allowEval=config.allowEval==true and options.allowEval~=false,
      clock=now,mp=mp,deployment=decode(read(root..'build.json',16384))})
    state.session,state.generation,state.queue=session,generation,base..generation..'/'
    state.registration=base..'registration.json'
    state.beatPath=base..'heartbeat'
    state.record=Util.JsonEncode({plugin=plugin,generation=generation,allowEval=state.runtime.allowEval,luaVersion=_VERSION})
    assert(write(state.registration,state.record))
    state.lastBeat=-math.huge
    state.wrapper=_G.BeamMCPPrintWrapper
    _G.print=state.wrapper
  end
  function state.poll()
    if state.stopped or state.busy then return end
    local session=active()
    if session~=state.session then
      if session then connect(session) else detach() end
    end
    if not state.runtime then return end
    if now()-state.lastBeat>=1 then
      -- Only mtime matters. Keep the heartbeat inode in place on every platform.
      local f=io.open(state.beatPath,'wb')
      if not f then detach();return end
      f:write('1');f:close()
      state.lastBeat=now()
    end
    local files=FS.ListFiles(state.queue) or {}
    table.sort(files)
    for _,file in ipairs(files) do
      local name=file:match('([^/\\]+)$')
      local id=name and name:match('^(%x+)%.request$')
      if id and #id<=64 then
        local base=state.queue..id
        if os.rename(base..'.request',base..'.running') then
          state.busy=true
          local request=decode(read(base..'.running'))
          local reply=M.execute(request,state.generation,now()*1000,function(method,args) return state.runtime:call(method,args) end)
          -- A cancelled/timed-out request loses its running marker. Never resurrect its reply.
          if read(base..'.running') then write(base..'.response',Util.JsonEncode(reply)) end
          os.remove(base..'.running')
          state.busy=false
          break -- one bounded request per tick, with other plugin events between requests
        end
      end
    end
  end
  function state.shutdown()
    state.stopped=true
    mp.CancelEventTimer('BeamMCPBridgeTick')
    detach()
  end
  _G.BeamMCPBridge=state
  _G.BeamMCPBridgeTick=function() if _G.BeamMCPBridge then _G.BeamMCPBridge.poll() end end
  _G.BeamMCPBridgeShutdown=function() if _G.BeamMCPBridge then _G.BeamMCPBridge.shutdown() end end
  _G.BeamMCPBridgeInit=function()
    local current=_G.BeamMCPBridge
    if current and not current.stopped then detach();current.poll() end
  end
  mp.RegisterEvent('BeamMCPBridgeTick','BeamMCPBridgeTick')
  mp.RegisterEvent('onShutdown','BeamMCPBridgeShutdown')
  mp.RegisterEvent('onInit','BeamMCPBridgeInit')
  for _,event in ipairs({'onPlayerJoin','onPlayerDisconnect','onVehicleSpawn','onVehicleEdited','onVehicleDeleted','onVehicleReset'}) do
    local handler='BeamMCPTrace_'..event
    _G[handler]=function(...)
      local current=_G.BeamMCPBridge
      if current and current.runtime then current.runtime:record('event',{name=event,args={...}}) end
    end
    mp.RegisterEvent(event,handler)
  end
  mp.CreateEventTimer('BeamMCPBridgeTick',50,mp.CallStrategy and mp.CallStrategy.BestEffort)
  state.poll()
  return state
end
return M
