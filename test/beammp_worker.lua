-- Native Lua integration worker: models one BeamMP plugin state, not a game/server acceptance test.
local root,plugin,codec=arg[1]..'/',arg[2],arg[3]
local json=dofile(codec)
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
local function clock()
  local f=assert(io.open('/proc/uptime','r'));local n=tonumber(f:read('*n'));f:close();return n
end
local now=clock()
Util={JsonEncode=json.encode,JsonDecode=json.decode}
FS={CreateDirectory=function(path) assert(os.execute('mkdir -p '..quote(path))) end,
  ListFiles=function(path)
    local f=assert(io.popen('find '..quote(path)..' -maxdepth 1 -type f -printf "%f\\n" 2>/dev/null'))
    local list={};for line in f:lines() do list[#list+1]=line end;f:close();return list
  end}
MP={CreateTimer=function() local start=clock();return {GetCurrent=function() return clock()-start end} end,
  CreateEventTimer=function() end,CancelEventTimer=function() end,RegisterEvent=function() end,
  CallStrategy={BestEffort=0},GetServerVersion=function() return 3,9,3 end}
Counter=41
function FixtureFunction()
  return Counter + 5
end
local bridge=assert(loadfile(root..'lua/beammcp_server/bridge.lua'))().attach({plugin=plugin,resource=root})
while clock()-now<15 do
  bridge.poll()
  local reload=io.open(root..'reload-'..plugin,'rb')
  if reload then reload:close();os.remove(root..'reload-'..plugin);BeamMCPBridgeInit() end
  os.execute('sleep 0.01')
end
bridge.shutdown()
