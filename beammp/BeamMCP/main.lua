-- BeamMP target: starts one resource-local helper; every plugin keeps its own Lua state.
local ROOT='Resources/Server/BeamMCP/'
if BeamMCPShutdown then BeamMCPShutdown() end
local bridge=assert(loadfile(ROOT..'lua/beammcp_server/bridge.lua'))()
local epoch,timer=os.time(),MP.CreateTimer()
local function now() return epoch+timer:GetCurrent() end
local configText=bridge.read(ROOT..'config.json',4096)
local ok,config=pcall(Util.JsonDecode,configText or '')
if not ok or type(config)~='table' or config.enabled~=true then print('[BeamMCP] disabled; configure config.json to enable');return end
FS.CreateDirectory(ROOT..'.runtime')
BeamMCPSessionSerial=(BeamMCPSessionSerial or 0)+1
local session=string.format('%d-%d-%d',os.time(),BeamMCPSessionSerial,math.random(100000,999999))
local dir=ROOT..'.runtime/'..session
FS.CreateDirectory(dir)
assert(bridge.write(dir..'/heartbeat','1'))
assert(bridge.write(ROOT..'.runtime/active.json',Util.JsonEncode({session=session})))
local windows=package.config:sub(1,1)=='\\'
local command
if windows then
  command='start "" /b "Resources\\Server\\BeamMCP\\lib\\beammcp-helper.exe" serve "'..ROOT..'" "'..dir..'" >NUL 2>NUL'
else
  command='"'..ROOT..'lib/beammcp-helper" serve "'..ROOT..'" "'..dir..'" >>"'..dir..'/helper.log" 2>&1 &'
end
local started=os.execute(command)
if not started then bridge.write(dir..'/stop','1');error('could not start BeamMCP helper') end
local stopped=false
local lastAlive,seen=nil,now()
function BeamMCPHeartbeat()
  if stopped then return end
  if not bridge.write(dir..'/heartbeat','1') then
    print('[BeamMCP] session directory unavailable; stopping')
    BeamMCPShutdown();return
  end
  local alive=bridge.read(dir..'/alive',128)
  if alive and alive~=lastAlive then lastAlive,seen=alive,now() end
  if now()-seen>20 then
    print('[BeamMCP] helper heartbeat lost; stopping; reload main.lua after inspecting the resource')
    BeamMCPShutdown()
  end
end
function BeamMCPShutdown()
  if stopped then return end
  stopped=true
  MP.CancelEventTimer('BeamMCPHeartbeat')
  bridge.write(dir..'/stop','1')
  local active=bridge.read(ROOT..'.runtime/active.json',4096)
  if active and active:find(session,1,true) then os.remove(ROOT..'.runtime/active.json') end
  if BeamMCPBridge and BeamMCPBridge.shutdown then BeamMCPBridge.shutdown() end
end
MP.RegisterEvent('BeamMCPHeartbeat','BeamMCPHeartbeat')
MP.RegisterEvent('onShutdown','BeamMCPShutdown')
MP.CreateEventTimer('BeamMCPHeartbeat',1000,MP.CallStrategy.BestEffort)
bridge.attach({plugin='BeamMCP'})
print('[BeamMCP] helper starting; private loopback endpoint; use helper stdio over SSH for remote access')
