-- Deployment metadata is a claim captured at load time, never proof that cached Lua matches disk.
-- Fingerprints describe actual loaded function bytecode (not source or upvalues, and not cryptographic).
local M = {}
local stamps = setmetatable({}, {__mode='k'})
local MANIFEST = '/scripts/beammcp/build.json'

local function bounded(s, n)
  return tostring(s or ''):gsub('%c', '?'):sub(1, n or 256)
end

function M.captureDeployment(reader)
  reader = reader or rawget(_G, 'jsonReadFile')
  if type(reader) ~= 'function' then return {status='unknown', reason='manifest_reader_unavailable'} end
  local ok, v = pcall(reader, MANIFEST)
  if not ok or type(v) ~= 'table' or v.schemaVersion ~= 1
      or type(v.contentSha256) ~= 'string' or not v.contentSha256:match('^%x+$') or #v.contentSha256 ~= 64 then
    return {status='unknown', reason='manifest_missing_or_invalid'}
  end
  return {status='known', evidence='deployment_manifest_claim', commit=bounded(v.commit,64),
    contentSha256=v.contentSha256, dirty=v.dirty == true,
    fileCount=type(v.fileCount)=='number' and v.fileCount or nil,
    diskContentsVerified=false}
end

function M.compare(a,b)
  if not a or not b or a.status~='known' or b.status~='known' then return 'unknown' end
  return a.commit==b.commit and a.contentSha256==b.contentSha256 and a.dirty==b.dirty
    and 'same_manifest_claim' or 'different_manifest_claim'
end

local function fingerprint(fn)
  local ok, dump = pcall(string.dump, fn, true)
  if not ok then return nil, 'not_dumpable' end
  if #dump > 262144 then return nil, 'bytecode_exceeds_256KiB' end
  local a,b=1,0
  for i=1,#dump do a=(a+dump:byte(i))%65521; b=(b+a)%65521 end
  return string.format('adler32:%08x:%d',b*65536+a,#dump)
end

local function functions(mod)
  local names, refs = {}, {}
  if type(mod)~='table' then return {} end
  for key,value in next,mod do
    if type(key)=='string' and type(value)=='function' then names[#names+1]=key; refs[key]=value end
  end
  for _,key in ipairs({'def','read','observe','inspect','source'}) do
    local def=rawget(mod,key)
    if type(def)=='table' and type(rawget(def,'handler'))=='function' then
      local name=key..'.handler'
      if not refs[name] then names[#names+1]=name end
      refs[name]=rawget(def,'handler')
    end
  end
  table.sort(names)
  local out={}
  for i=1,math.min(#names,16) do
    local name,fn=names[i],refs[names[i]]
    local info=debug and debug.getinfo and debug.getinfo(fn,'S') or {}
    local fp,reason=fingerprint(fn)
    out[#out+1]={name=bounded(name),source=bounded(info.source),line=info.linedefined,
      kind=info.what,fingerprint=fp,fingerprintUnavailable=reason}
  end
  return out,#names>16
end

-- Call at the end of a module chunk, not each server restart. The table identity guards against
-- accidentally attributing a newly replaced/cached module to a different table's load stamp.
function M.stamp(name,mod,claim)
  if type(mod)~='table' then return end
  local copy={}
  for k,v in pairs(claim or M.captureDeployment()) do copy[k]=v end
  stamps[mod]={name=name,claim=copy,functions=functions(mod)}
end

function M.describe(name,mod)
  local stamp=stamps[mod]
  local list,truncated=functions(mod)
  local out={name=bounded(name),loadedBuild=stamp and stamp.claim or
    {status='unknown',reason='module_has_no_load_stamp'},functions=list,functionsTruncated=truncated,
    fingerprintMeaning='loaded_bytecode_only_noncryptographic_excludes_upvalues'}
  if stamp then
    local changed=#list~=#stamp.functions
    for i,row in ipairs(list) do
      local old=stamp.functions[i]
      if not old or old.name~=row.name or old.fingerprint~=row.fingerprint or old.source~=row.source then changed=true end
    end
    out.functionsChangedSinceStamp=changed
  end
  return out
end

return M
