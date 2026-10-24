local identity = require('beammcp/identity')

test('deployment snapshot is copied and unavailable manifests stay unknown', function()
  local manifest = {schemaVersion=1, commit='abc', contentSha256=string.rep('a',64), dirty=true, fileCount=2}
  local snap = identity.captureDeployment(function() return manifest end)
  manifest.commit = 'changed'
  assertEqual(snap.commit, 'abc')
  assertEqual(snap.evidence, 'deployment_manifest_claim')
  assertEqual(identity.captureDeployment(function() error('missing') end).status, 'unknown')
end)

test('unstamped loaded module never acquires current deployment as loaded identity', function()
  local desc = identity.describe('older', {run=function() return 1 end})
  assertEqual(desc.loadedBuild.status, 'unknown')
  assertEqual(desc.functions[1].name, 'run')
  assertMatch(desc.functions[1].fingerprint, '^adler32:')
  assertMatch(desc.functions[1].source, 'identity_test')
end)

test('stamp freezes manifest claim and detects replaced loaded functions', function()
  local mod = {def={handler=function() return 1 end}}
  identity.stamp('fixture', mod, {status='known', commit='a', contentSha256='aaa'})
  local before = identity.describe('fixture', mod)
  assertEqual(before.loadedBuild.commit, 'a')
  assertEqual(before.functionsChangedSinceStamp, false)
  mod.def.handler = function() return 2 end
  assertEqual(identity.describe('fixture', mod).functionsChangedSinceStamp, true)
  assertEqual(identity.describe('fixture', {def=mod.def}).loadedBuild.status, 'unknown')
end)

test('deployment comparison reports unknown rather than equality for missing identities', function()
  assertEqual(identity.compare({status='unknown'}, {status='unknown'}), 'unknown')
  local a = {status='known', commit='a', dirty=false, contentSha256='x'}
  assertEqual(identity.compare(a, a), 'same_manifest_claim')
  assertEqual(identity.compare(a, {status='known', commit='b', contentSha256='y'}), 'different_manifest_claim')
end)

test('native function origins do not fabricate bytecode or source hashes', function()
  local out=identity.describe('native', {run=print})
  assertEqual(out.functions[1].kind,'C')
  assertNil(out.functions[1].fingerprint)
  assertEqual(out.functions[1].fingerprintUnavailable,'not_dumpable')
end)

test('fingerprint list is bounded and deterministically ordered', function()
  local mod={}
  for i=1,20 do mod[string.format('fn%02d',i)]=function() return i end end
  local out=identity.describe('large',mod)
  assertEqual(#out.functions,16)
  assertEqual(out.functionsTruncated,true)
  assertEqual(out.functions[1].name,'fn01')
end)

test('known nested tool handlers have loaded bytecode fingerprints', function()
  local mod={read={handler=function() return 1 end},observe={handler=function() return 2 end},
    inspect={handler=function() return 3 end},source={handler=function() return 4 end}}
  identity.stamp('nested',mod,{status='unknown'})
  local out=identity.describe('nested',mod)
  assertEqual(#out.functions,4)
  local seen={}
  for _,fn in ipairs(out.functions) do seen[fn.name]=fn; assertMatch(fn.fingerprint,'^adler32:') end
  for _,name in ipairs({'read','observe','inspect','source'}) do assertTrue(seen[name..'.handler']) end
  mod.observe.handler=function() return 'changed' end
  assertEqual(identity.describe('nested',mod).functionsChangedSinceStamp,true)
end)
