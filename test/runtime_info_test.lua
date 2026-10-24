require('support.beamng_stubs')
local runtime = require('beammcp/tools/runtime_info')
local targets = require('beammcp/cdp/targets')
local vle = require('beammcp/tools/vehicle_lua_eval')

local function setup()
  _G.be = {getPlayerVehicleID=function() return 45 end, getObjectByID=function(_,id) return id==45 and {} or nil end}
  _G.getMissionFilename = function() return 'levels/gridmap/main.level.json' end
  runtime.configure({clock=function() return 100 end, getCefStatus=function() return {active=true,targets=2,checkedAt=94,port=8080} end,
    serverIdentity={status='unknown'}, modules=function() return {older={fn=function() return 1 end}} end})
end

test('runtime default reuses CEF cache and performs no eval or network request', function()
  setup()
  local prevHttp, prevVE = targets.realHttpGet, vle.evalVE
  targets.realHttpGet = function() error('unexpected network') end
  vle.evalVE = function() error('unexpected eval') end
  local out = runtime.def.handler({})
  targets.realHttpGet, vle.evalVE = prevHttp, prevVE
  assertEqual(out.cef.source, 'panel_cache')
  assertEqual(out.cef.ageSec, 6)
  assertEqual(out.ge.playerVehicleAvailable, true)
  assertEqual(out.vehicle.status, 'not_requested')
  assertEqual(out.modules[1].loadedBuild.status, 'unknown')
end)

test('runtime reports absent player and engine APIs without throwing', function()
  setup(); _G.be=nil; _G.getMissionFilename=nil
  runtime.configure({clock=function() return 100 end})
  local out = runtime.def.handler({vehicle=true})
  assertEqual(out.ge.available, false)
  assertEqual(out.cef.status, 'unknown')
  assertEqual(out.vehicle.status, 'unavailable')
end)

test('fresh CEF discovery rejects foreign targets as BeamNG availability', function()
  setup()
  local prev=targets.realHttpGet
  targets.realHttpGet=function() return jsonEncode({{type='page',url='https://example.org'}}) end
  local out=runtime.def.handler({probe=true})
  targets.realHttpGet=prev
  assertEqual(out.cef.source,'fresh_discovery')
  assertEqual(out.cef.endpointReachable,true)
  assertEqual(out.cef.beamngTargets,0)
  assertEqual(out.cef.status,'no_beamng_targets')
end)
test('fresh CEF probe reports the port actually queried if configuration changes mid-request',function()
  setup()
  local prev,port=targets.realHttpGet,targets.CDP_PORT
  targets.realHttpGet=function() targets.CDP_PORT=9001;return jsonEncode({}) end
  local out=runtime.def.handler({probe=true})
  targets.realHttpGet=prev;targets.CDP_PORT=port
  assertEqual(out.cef.port,port)
end)

test('vehicle proof uses selected VM and checks returned vehicle identity', function()
  setup()
  local prev=vle.evalVE
  vle.evalVE=function(_, code)
    assertMatch(code, 'getID')
    return {ok=true,value={vm='vehicle',vehicleId=45},output=''}
  end
  local out=runtime.def.handler({vehicle=true,id=45})
  assertEqual(out.vehicle.status,'roundtrip_ok')
  vle.evalVE=function() return {ok=true,value={vm='vehicle',vehicleId=99},output=''} end
  assertEqual(runtime.def.handler({vehicle=true,id=45}).vehicle.status,'unexpected_response')
  vle.evalVE=prev
end)

test('runtime validates arguments before doing probes', function()
  setup()
  for _,args in ipairs({{probe='yes'},{vehicle=1},{id=0/0},{id=1.5},{id=-1},{id=2147483648},
      {maxBytes='4096'},{maxBytes=1023},{maxBytes=16385},{maxBytes=0/0},{maxBytes=math.huge}}) do
    local out,err=runtime.def.handler(args)
    assertNil(out); assertMatch(err,'runtime_info')
  end
end)

test('vehicle failures remain structured without claiming availability', function()
  setup()
  local prev=vle.evalVE
  for _,stub in ipairs({function() return nil end,function() error('bridge failed') end,
      function() return {ok=false,err='VM failed'} end}) do
    vle.evalVE=stub
    local out=runtime.def.handler({vehicle=true})
    assertEqual(out.vehicle.status,'roundtrip_failed')
    assertTrue(type(out.vehicle.error)=='string')
  end
  vle.evalVE=prev
end)

test('missing player does not block explicit vehicle proof', function()
  setup()
  _G.be.getPlayerVehicleID=function() return -1 end
  local prev=vle.evalVE
  vle.evalVE=function() return {ok=true,value={vm='vehicle',vehicleId=45}} end
  local out=runtime.def.handler({vehicle=true,id=45})
  vle.evalVE=prev
  assertEqual(out.ge.playerVehicleAvailable,false)
  assertEqual(out.vehicle.status,'roundtrip_ok')
end)

test('deployment change remains separate from stamped and unknown loaded modules', function()
  setup()
  local prev=rawget(_G,'jsonReadFile')
  _G.jsonReadFile=function() return {schemaVersion=1,commit='new',contentSha256=string.rep('b',64)} end
  runtime.configure({serverIdentity={status='known',commit='old',contentSha256=string.rep('a',64)},
    modules=function() return {old={handler=function() return 1 end}} end})
  local out=runtime.def.handler({})
  _G.jsonReadFile=prev
  assertEqual(out.build.comparison,'different_manifest_claim')
  assertEqual(out.build.serverLoadClaim.commit,'old')
  assertEqual(out.build.currentDeploymentClaim.commit,'new')
  assertEqual(out.modules[1].loadedBuild.status,'unknown')
  assertEqual(out.build.diskContentsVerified,false)
end)

test('runtime sheds module details and rows while preserving health within encoded budgets', function()
  setup()
  local identity=require('beammcp/identity')
  local claim={status='known',commit=string.rep('a',40),contentSha256=string.rep('b',64),dirty=true}
  local mods={}
  for i=1,12 do
    local mod={}
    for j=1,16 do mod['fn'..j]=function() return j end end
    identity.stamp('module'..i,mod,claim)
    mods['module'..i]=mod
  end
  local prev=rawget(_G,'jsonReadFile')
  _G.jsonReadFile=function() return {schemaVersion=1,commit=string.rep('c',40),contentSha256=string.rep('d',64),dirty=true} end
  runtime.configure({serverIdentity=claim,modules=function() return mods end,
    clock=function() return 100 end,getCefStatus=function() return {active=true,targets=2,checkedAt=95,port=8080} end})
  for _,budget in ipairs({1024,2048,4096,16384}) do
    local out=runtime.def.handler({detail=true,maxBytes=budget})
    assertTrue(#jsonEncode(out)<=budget)
    assertEqual(out.vm,'GE')
    assertEqual(out.ge.playerVehicleAvailable,true)
    assertEqual(out.cef.status,'discovered')
    assertEqual(out.vehicle.status,'not_requested')
    assertEqual(out.build.comparison,'different_manifest_claim')
    assertEqual(out.build.serverLoadClaim.contentSha256,claim.contentSha256)
    assertTrue(out.modulesTruncated)
  end
  local out=runtime.def.handler({})
  assertTrue(#jsonEncode(out)<=4096)
  _G.jsonReadFile=prev
end)

test('compact modules reference shared build claims without repeating fingerprint caveats', function()
  setup()
  local identity=require('beammcp/identity')
  local claim={status='known',commit='abc',contentSha256=string.rep('b',64),dirty=true}
  local mod={fn=function() return 1 end}
  identity.stamp('mod',mod,claim)
  runtime.configure({serverIdentity=claim,modules=function() return {mod=mod} end})
  local out=runtime.def.handler({})
  assertEqual(out.modules[1].loadedBuild.reference,'serverLoadClaim')
  assertNil(out.modules[1].loadedBuild.contentSha256)
  assertNil(out.modules[1].fingerprintMeaning)
  assertMatch(out.build.fingerprintMeaning,'excludes_upvalues')
end)

test('failed fresh discovery returns unavailable and no JavaScript claim', function()
  setup()
  local prev=targets.realHttpGet
  targets.realHttpGet=function() error('offline') end
  local out=runtime.def.handler({probe=true})
  targets.realHttpGet=prev
  assertEqual(out.cef.status,'unreachable')
  assertEqual(out.cef.endpointReachable,false)
  assertEqual(out.cef.javascriptRoundtrip,'not_probed')
end)
