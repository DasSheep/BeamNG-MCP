-- Reuse the bounded BeamNG inspection modules with a plugin-local environment.
local M = {}
local function compileFile(path, env)
  if setfenv then
    local fn, err = loadfile(path)
    if fn then setfenv(fn, env) end
    return fn, err
  end
  return loadfile(path, 't', env)
end
function M.new(options)
  local root, encode, decode = options.root or _G, options.encode, options.decode
  local self = { plugin=options.plugin, generation=options.generation, allowEval=options.allowEval,
    clock=options.clock or os.time, mp=options.mp or MP, logs={}, events={}, logSequence=0, eventSequence=0 }
  local modules = {}
  local env = setmetatable({_G=root, jsonEncode=encode, jsonDecode=decode}, {__index=_G})
  env.loadstring = function(code, name)
    if loadstring then
      local fn, err = loadstring(code, name)
      if fn then setfenv(fn, root) end
      return fn, err
    end
    return load(code, name, 't', root)
  end
  env.require = function(name)
    local short = name:match('^beammcp/([a-z_]+)$')
    if not short then error('unsupported shared module: '..tostring(name)) end
    if not modules[name] then
      local fn = assert(compileFile(options.common..short..'.lua', env))
      modules[name] = fn()
    end
    return modules[name]
  end
  local output = env.require('beammcp/output')
  local inspector = env.require('beammcp/inspect')
  local observer = env.require('beammcp/observe')
  local started = self.clock()
  local function whole(v, default, lo, hi)
    if v == nil then return default end
    if type(v)~='number' or v~=math.floor(v) or v<lo or v>hi then return nil end
    return v
  end
  function self:record(kind, value)
    local list = kind=='log' and self.logs or self.events
    local key = kind=='log' and 'logSequence' or 'eventSequence'
    self[key] = self[key]+1
    list[#list+1] = {cursor=self[key], at=self.clock(), data=output.fit(value,1024)}
    while #list>128 do table.remove(list,1) end
  end
  local function ring(list, sequence, args, limit, budget)
    local cursor=whole(args.cursor,0,0,9007199254740991)
    if not cursor or (args.match~=nil and type(args.match)~='string') then return nil,'invalid cursor or match' end
    local result={generation=self.generation, entries={}, cursor=cursor, newest=sequence,
      droppedBefore=#list>0 and list[1].cursor-1 or sequence}
    for _,entry in ipairs(list) do
      if entry.cursor>cursor then
        if not args.match or encode(entry.data):find(args.match,1,true) then
          local previous=result.cursor
          result.entries[#result.entries+1]=entry
          result.cursor=entry.cursor
          if #encode(result)>budget-64 then
            result.entries[#result.entries]=nil;result.cursor=previous
            if #result.entries==0 then
              result.entries[1]=output.fit(entry,math.max(128,budget-384))
              result.cursor=entry.cursor
            end
            result.truncated=true
            break
          end
          if #result.entries>=limit then break end
        else result.cursor=entry.cursor end
      end
    end
    return result
  end
  function self:call(method, args)
    if type(args)~='table' then return nil,'arguments must be an object' end
    local budget, err=output.budget(args.maxBytes)
    if not budget then return nil,err end
    local limit=whole(args.limit,25,1,100)
    if not limit then return nil,'limit must be an integer from 1 to 100' end
    local result
    if method=='lua_eval' then
      if not self.allowEval then return nil,'lua_eval is disabled for this plugin' end
      if type(args.code)~='string' or #args.code>32768 then return nil,'code must be a string of at most 32768 bytes' end
      result=output.execute(args.code,budget,'=beammcp:'..self.plugin)
      if not result.ok then return nil,output.errorText(result.err,result.output,budget) end
      result.ok=nil
    elseif method=='inspect_lua' or method=='get_lua_source' then
      result,err=(method=='inspect_lua' and inspector.inspect or inspector.source)(args,root)
    elseif method=='read_lua' then
      result,err=observer.snapshot(args,root)
      if result then result.generation=self.generation;result.readAt=self.clock() end
    elseif method=='runtime_info' then
      local a,b,c=self.mp.GetServerVersion()
      local names={}
      for name in pairs(package.loaded) do names[#names+1]=name end
      table.sort(names)
      result={plugin=self.plugin,generation=self.generation,luaVersion=_VERSION,serverVersion={a,b,c},
        bridgeUptime=self.clock()-started,allowEval=self.allowEval,loadedModules=names,
        deployment=options.deployment or {status='unknown'},globalInspection=true,closureLocals='require explicit debug exports'}
      if self.mp.GetStateMemoryUsage then result.memoryBytes=self.mp.GetStateMemoryUsage() end
    elseif method=='get_server_state' then
      result={players=self.mp.GetPlayerCount(),settings={}}
      for _,name in ipairs({'Name','Map','Private','MaxPlayers','MaxCars','Debug'}) do
        local id=self.mp.Settings and self.mp.Settings[name]
        if id~=nil then local ok,value=pcall(self.mp.Get,id);if ok then result.settings[name]=value end end
      end
    elseif method=='list_players' then
      local players={}
      for pid,name in pairs(self.mp.GetPlayers() or {}) do
        players[#players+1]={playerId=pid,name=name,guest=self.mp.IsPlayerGuest(pid),connected=self.mp.IsPlayerConnected(pid)}
      end
      table.sort(players,function(a,b) return a.playerId<b.playerId end)
      result={players={},total=#players}
      for i=1,math.min(limit,#players) do result.players[i]=players[i] end
      result.truncated=#players>limit or nil
    elseif method=='list_vehicles' then
      local pidFilter=whole(args.playerId,nil,0,2147483647)
      if args.playerId~=nil and not pidFilter then return nil,'playerId must be a nonnegative integer' end
      if args.detail~=nil and type(args.detail)~='boolean' then return nil,'detail must be boolean' end
      result={vehicles={},total=0,positionSource='latest_client_report'}
      local players=self.mp.GetPlayers() or {}
      for pid in pairs(players) do
        if not pidFilter or pid==pidFilter then
          for vid,data in pairs(self.mp.GetPlayerVehicles(pid) or {}) do
            result.total=result.total+1
            if #result.vehicles<limit then
              local row={playerId=pid,vehicleId=vid}
              local ok,config=pcall(decode,type(data)=='string' and data:match('({.*)$') or '')
              if ok and type(config)=='table' then
                row.model=config.jbm
                if args.detail then row.config=config end
              end
              local position,why=self.mp.GetPositionRaw(pid,vid)
              if type(position)=='table' then row.position=position else row.positionUnavailable=why end
              result.vehicles[#result.vehicles+1]=row
            end
          end
        end
      end
      table.sort(result.vehicles,function(a,b) return a.playerId==b.playerId and a.vehicleId<b.vehicleId or a.playerId<b.playerId end)
      result.truncated=result.total>#result.vehicles or nil
    elseif method=='console_logs' then result,err=ring(self.logs,self.logSequence,args,limit,budget)
    elseif method=='recent_events' then result,err=ring(self.events,self.eventSequence,args,limit,budget)
    else return nil,'unknown tool: '..tostring(method) end
    if not result then return nil,err end
    return output.fit(result,budget)
  end
  return self
end
return M
