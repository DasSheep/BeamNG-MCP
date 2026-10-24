-- Read-only runtime diagnostics. Discovery and VE roundtrips are explicitly opt-in.
local identity=require('beammcp/identity')
local output=require('beammcp/output')
local targets=require('beammcp/cdp/targets')
local vehicleEval=require('beammcp/tools/vehicle_lua_eval')
local M={}
local deps={}
local function short(v) return (output.clip(tostring(v or ''):gsub('%c','?'),256)) end
local function call(fn,...)
  if type(fn)~='function' then return nil end
  local ok,v=pcall(fn,...)
  if ok then return v end
end
function M.configure(options) deps=options or {} end
local function now() return call(deps.clock) or os.clock() end

local function compactClaim(claim)
  if not claim or claim.status~='known' then return {status='unknown'} end
  return {status='known',commit=claim.commit,contentSha256=claim.contentSha256,dirty=claim.dirty}
end

local function entrypoint(row)
  local first=row.functions[1]
  for _,fn in ipairs(row.functions) do if fn.name:match('%.handler$') then first=fn; break end end
  row.functions=first and {first} or {}
end

-- Shed diagnostic detail deterministically before the generic sanitizer. Essential status and
-- deployment identities remain intact even at the minimum budget; no arbitrary table-order loss.
local function fit(out,maxBytes)
  local function fits()
    local ok,json=pcall(jsonEncode,out)
    return ok and #json<=maxBytes
  end
  if not fits() then
    out.truncated=true; out.modulesTruncated=true
    for _,row in ipairs(out.modules) do entrypoint(row) end
  end
  if not fits() then
    for _,row in ipairs(out.modules) do
      row.functionCount=nil; row.functionsTruncated=true
      for _,fn in ipairs(row.functions) do fn.kind=nil; fn.line=nil end
    end
  end
  while not fits() and #out.modules>0 do
    table.remove(out.modules)
    if #out.modules==0 then out.build.fingerprintMeaning=nil end
  end
  if not fits() then
    out.ge.mission=nil; out.cef.error=nil; out.vehicle.error=nil
  end
  return output.fit(out,maxBytes)
end

local function cef(probe)
  if probe then
    local port=targets.CDP_PORT
    local list,err=targets.discover(targets.realHttpGet)
    local count=list and #targets.curate(list) or 0
    return {source='fresh_discovery',status=not list and 'unreachable' or count>0 and 'discovered' or 'no_beamng_targets',
      endpointReachable=list~=nil,beamngTargets=count,port=port,ageSec=0,
      error=err and short(err),javascriptRoundtrip='not_probed'}
  end
  local cached=call(deps.getCefStatus)
  if type(cached)~='table' or type(cached.checkedAt)~='number' then
    return {source='panel_cache',status='unknown',port=targets.CDP_PORT,javascriptRoundtrip='not_probed'}
  end
  return {source='panel_cache',status=cached.active and (cached.targets or 0)>0 and 'discovered' or
      cached.active and 'no_beamng_targets' or 'unreachable',endpointReachable=cached.active==true,
    beamngTargets=cached.targets or 0,port=cached.port or targets.CDP_PORT,
    ageSec=math.max(0,now()-cached.checkedAt),javascriptRoundtrip='not_probed'}
end

local function handler(args)
  if args==nil then args={} end
  if type(args)~='table' then return nil,'runtime_info: arguments must be an object' end
  local maxBytes,budgetErr=output.budget(args.maxBytes,4096)
  if not maxBytes then return nil,'runtime_info: '..budgetErr end
  for _,key in ipairs({'probe','vehicle','detail'}) do
    if args[key]~=nil and type(args[key])~='boolean' then return nil,"runtime_info: '"..key.."' must be a boolean" end
  end
  if args.id~=nil and (type(args.id)~='number' or args.id~=args.id or args.id<0 or args.id>2147483647 or args.id%1~=0) then
    return nil,"runtime_info: 'id' must be an integer from 0 to 2147483647"
  end
  local engine=rawget(_G,'be')
  local player=engine and call(function() return engine:getPlayerVehicleID(0) end)
  local playerObj=player and player>=0 and engine and call(function() return engine:getObjectByID(player) end)
  local current=identity.captureDeployment()
  local out={vm='GE',luaVersion=_VERSION,ge={available=engine~=nil,
      mission=short(call(rawget(_G,'getMissionFilename'))),playerVehicleId=player,
      playerVehicleAvailable=playerObj~=nil and playerObj~=false},
    build={serverLoadClaim=compactClaim(deps.serverIdentity),
      currentDeploymentClaim=compactClaim(current),
      comparison=identity.compare(deps.serverIdentity,current),
      evidence='deployment_manifest_claims_only',diskContentsVerified=false,
      fingerprintMeaning='loaded_bytecode_only_noncryptographic_excludes_upvalues'},
    cef=cef(args.probe),vehicle={status='not_requested'},modules={}}
  local mods=call(deps.modules) or {['beammcp/tools/runtime_info']=M}
  local names={}
  for name in pairs(mods) do if type(name)=='string' then names[#names+1]=name end end
  table.sort(names)
  for i=1,math.min(#names,12) do
    local row=identity.describe(names[i],mods[names[i]])
    row.functionCount=#row.functions
    row.fingerprintMeaning=nil -- shared caveat appears once in build
    if identity.compare(row.loadedBuild,deps.serverIdentity)=='same_manifest_claim' then
      row.loadedBuild={status='known',reference='serverLoadClaim'}
    elseif identity.compare(row.loadedBuild,current)=='same_manifest_claim' then
      row.loadedBuild={status='known',reference='currentDeploymentClaim'}
    else row.loadedBuild=compactClaim(row.loadedBuild) end
    if not args.detail then
      -- Keep one actionable entry point in the compact default.
      entrypoint(row)
    end
    out.modules[#out.modules+1]=row
  end
  out.modulesTruncated=#names>12
  if args.vehicle then
    local id=args.id or player
    local obj=id and id>=0 and engine and call(function() return engine:getObjectByID(id) end)
    out.vehicle={status='unavailable',id=id}
    if obj then
      local ok,payload=pcall(vehicleEval.evalVE,obj,"return {vm='vehicle', vehicleId=obj:getID()}")
      if not ok or not payload then out.vehicle.status='roundtrip_failed'; out.vehicle.error=not ok and short(payload) or 'No response from vehicle VM'
      elseif not payload.ok then out.vehicle.status='roundtrip_failed'; out.vehicle.error=short(payload.err)
      elseif type(payload.value)~='table' or payload.value.vm~='vehicle' or payload.value.vehicleId~=id then out.vehicle.status='unexpected_response'
      else out.vehicle.status='roundtrip_ok'; out.vehicle.vm='vehicle' end
    end
  end
  return fit(out,maxBytes)
end

M.def={description='Report GE availability, loaded Lua origins/fingerprints, deployment claims, and cached CEF discovery. Optional probes verify CEF discovery and a selected vehicle VM roundtrip.',
  annotations={readOnlyHint=true,openWorldHint=false},inputSchema={type='object',properties={
    probe={type='boolean',description='Perform fresh CEF target discovery (no JavaScript execution)'},
    vehicle={type='boolean',description='Prove a selected vehicle VM roundtrip'},
    id={type='integer',minimum=0,maximum=2147483647,description='Vehicle ID for optional proof; defaults to player'},
    detail={type='boolean',description='Include up to 16 loaded function origins per module'},
    maxBytes={type='integer',minimum=1024,maximum=16384,description='Encoded JSON response budget (default 4096)'}
  }},handler=handler}
function M.register(registry) registry:add('runtime_info',M.def) end
identity.stamp('beammcp/tools/runtime_info',M)
return M
