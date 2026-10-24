local common=require('beammcp/observe')
local output=require('beammcp/output')
local vehicle=require('beammcp/tools/lib/ve_read')
local sleep=require('beammcp/async/sleep')
local M={active=0,sleep=sleep}
function M.now() return require('socket').gettime() end
function M.resolve(a)
  if a.scope=='vehicle' then
    local id,err=vehicle.resolve(a,'read_lua')
    if not id then return nil,err end
    a.id=id -- Pin this request to one vehicle even if the player switches mid-observation.
  end
  return a
end
function M.fetch(a,timeout)
  if a.scope=='ge' then return common.snapshot(a) end
  local code='local r,e=require("beammcp/observe").snapshot(jsonDecode('..serialize(jsonEncode(a))
    ..')); if e then error(e,0) end; return r'
  return vehicle.run(a.id,code,'read_lua',timeout)
end
local function validate(args,observation)
  local a,names=common.validate(args)
  if not a then return nil,names end
  local allowed={fields=true,scope=true,id=true,preview=true,maxBytes=true}
  if observation then
    allowed.duration=true;allowed.interval=true;allowed.condition=true;allowed.samples=true
  end
  for k in pairs(args) do if not allowed[k] then return nil,'unknown argument' end end
  if not observation then return a end
  local function number(n,default,low,high)
    if n==nil then return default end
    if type(n)=='number' and n==n and n>=low and n<=high then return n end
  end
  a.duration=number(args.duration,1,0.05,10)
  a.interval=number(args.interval,0.1,0.05,2)
  if not a.duration or not a.interval then return nil,'duration must be 0.05..10s; interval 0.05..2s' end
  if args.samples~=nil and type(args.samples)~='boolean' then return nil,'samples must be boolean' end
  a.samples=args.samples==true
  local c=args.condition
  if c~=nil then
    local ops={eq=true,ne=true,gt=true,ge=true,lt=true,le=true,changed=true,exists=true,missing=true}
    if type(c)~='table' or not names[c.field] or not ops[c.op] then return nil,'invalid condition field/operator' end
    for k in pairs(c) do if k~='field' and k~='op' and k~='value' then return nil,'unknown condition option' end end
    if c.op=='eq' or c.op=='ne' then
      local t=type(c.value)
      if t~='boolean' and t~='string' and t~='number' then return nil,'condition requires a scalar value' end
      if t=='string' and #c.value>512 then return nil,'condition string exceeds 512 bytes' end
    elseif c.op~='exists' and c.op~='missing' and c.op~='changed' and type(c.value)~='number' then
      return nil,'ordered conditions require a number'
    end
    if type(c.value)=='number' and (c.value~=c.value or math.abs(c.value)==math.huge) then return nil,'condition requires a finite number' end
    a.condition=c
  end
  return a
end
local function matches(c,snapshot,initial)
  local v=snapshot.values[c.field]
  local absent=snapshot.unavailable and snapshot.unavailable[c.field]~=nil
  if c.op=='exists' then return not absent end
  if c.op=='missing' then return absent end
  if absent or (snapshot.truncatedFields and snapshot.truncatedFields[c.field]) then return false end
  if type(v)~='number' and type(v)~='string' and type(v)~='boolean' then return false end
  if c.op=='changed' then return initial~=nil and jsonEncode(v)~=initial end
  if c.op=='eq' then return type(v)==type(c.value) and v==c.value end
  if c.op=='ne' then return type(v)~=type(c.value) or v~=c.value end
  if type(v)~='number' then return false end
  if c.op=='gt' then return v>c.value elseif c.op=='ge' then return v>=c.value
  elseif c.op=='lt' then return v<c.value else return v<=c.value end
end
-- Machine-readable state must survive a budget reduction unchanged. Fit only user data.
local function fitResult(r,budget)
  local data={}
  local keys={'values','unavailable','truncatedFields','summary','samples'}
  for _,key in ipairs(keys) do data[key]=r[key];r[key]=nil end
  if r.error then r.error=output.fit({error=r.error},256).error end
  local available=budget-#jsonEncode(r)-64
  local fitted=output.fit(data,math.max(128,available))
  for _,key in ipairs(keys) do r[key]=fitted[key] end
  if fitted.truncated then r.truncated=true end
  if #jsonEncode(r)>budget then
    for _,key in ipairs(keys) do r[key]=nil end
    r.truncated=true
  end
  return r
end
local function read(args)
  local a,err=validate(args,false);if not a then return nil,err end
  a,err=M.resolve(a);if not a then return nil,err end
  local start=M.now()
  local r;r,err=M.fetch(a,5);if not r then return nil,err end
  r.scope=a.scope;r.vehicleId=a.scope=='vehicle' and a.id or nil;r.startedAt=start;r.completedAt=M.now()
  return fitResult(r,a.maxBytes)
end
local function observe(a)
  local start=M.now();local deadline=start+a.duration
  local r={scope=a.scope,vehicleId=a.scope=='vehicle' and a.id or nil,startedAt=start,count=0,summary={},status=a.condition and 'timeout' or 'complete'}
  if a.samples then r.samples={} end
  local previous,initial={},nil
  local sampleBytes=0
  while r.count<201 do
    local now=M.now()
    if r.count>0 and now>=deadline then break end
    local snap,err=M.fetch(a,math.max(0.001,deadline-now))
    if not snap then r.status='unavailable';r.error=output.clip(tostring(err),256);break end
    r.count=r.count+1
    for _,f in ipairs(a.fields) do
      local s=r.summary[f.name] or {changes=0,unavailable=0};r.summary[f.name]=s
      local v=snap.values[f.name]
      if snap.unavailable and snap.unavailable[f.name] then s.unavailable=s.unavailable+1
      else
        if s.first==nil then s.first=v end
        s.last=v
        if type(v)=='number' then s.min=math.min(s.min or v,v);s.max=math.max(s.max or v,v) end
      end
      local encoded=jsonEncode({value=v,unavailable=snap.unavailable and snap.unavailable[f.name]})
      if previous[f.name] and previous[f.name]~=encoded then s.changes=s.changes+1 end
      previous[f.name]=encoded
      if snap.truncatedFields and snap.truncatedFields[f.name] then s.previewTruncated=true end
    end
    if a.samples then
      local sample={elapsed=M.now()-start,values=snap.values,unavailable=snap.unavailable,truncatedFields=snap.truncatedFields}
      local size=#jsonEncode(sample)
      if sampleBytes+size<=math.floor(a.maxBytes/2) and not r.samplesTruncated then
        r.samples[#r.samples+1]=sample;sampleBytes=sampleBytes+size
      else r.samplesTruncated=true end
    end
    if a.condition then
      if r.count==1 then
        local field=a.condition.field
        local v=snap.values[field]
        if (type(v)=='number' or type(v)=='boolean' or type(v)=='string')
          and not (snap.truncatedFields and snap.truncatedFields[field])
          and not (snap.unavailable and snap.unavailable[field]) then initial=jsonEncode(v) end
      end
      if matches(a.condition,snap,initial) then r.status='matched';break end
    end
    local remaining=deadline-M.now()
    if remaining<=0 then break end
    M.sleep(math.min(a.interval,remaining))
  end
  r.elapsed=M.now()-start
  if r.count==201 and M.now()<deadline then r.sampleLimit=true end
  -- Drop optional history before allowing the shared fitter to shorten the essential summary.
  while r.samples and #r.samples>0 and #jsonEncode(r)>a.maxBytes do
    r.samples[#r.samples]=nil;r.samplesTruncated=true
  end
  return fitResult(r,a.maxBytes)
end
local function observeHandler(args)
  local a,err=validate(args,true);if not a then return nil,err end
  a,err=M.resolve(a);if not a then return nil,err end
  if M.active>=2 then return nil,'two observations already active; retry after one completes' end
  M.active=M.active+1
  local ok,result=pcall(observe,a)
  M.active=M.active-1
  if not ok then return nil,output.errorText(result,nil,a.maxBytes) end
  return result
end
local function schema(observation)
  local base=require('beammcp/tools/lua_inspect').inspect.inputSchema.properties
  local p={scope=base.scope,id=base.id,maxBytes=base.maxBytes,preview=base.preview,
    fields={type='array',minItems=1,maxItems=16,items={type='object',properties={name={type='string',maxLength=32},path=base.path},required={'name','path'},additionalProperties=false}}}
  if observation then
    p.duration={type='number',minimum=0.05,maximum=10,description='Wall seconds; default 1.'}
    p.interval={type='number',minimum=0.05,maximum=2,description='Minimum delay between reads; default 0.1s.'}
    p.samples={type='boolean',description='Include bounded sample history; default summary only.'}
    p.condition={type='object',properties={field={type='string'},op={enum={'eq','ne','gt','ge','lt','le','changed','exists','missing'}},
      value={anyOf={{type='string'},{type='number'},{type='boolean'}}}},required={'field','op'},additionalProperties=false}
  end
  return {type='object',properties=p,required={'fields'},additionalProperties=false}
end
M.read={description='Read up to 16 named raw Lua paths in one GE/vehicle VM. Returns selected values, per-field unavailable errors and timestamps; objects stay opaque. Default 128-byte previews/4096 result bytes. No getters executed.',
  annotations={readOnlyHint=true,destructiveHint=false,openWorldHint=false},inputSchema=schema(false),handler=read}
M.observe={description='Sample selected Lua paths for up to 10s (default 1s), or wait for a typed condition. Returns first/last/min/max/change counts and matched/timeout/unavailable status. Optional samples=true is byte-bounded. Pins one vehicle; two active observations maximum. Sampling can miss changes between reads.',
  annotations={readOnlyHint=true,destructiveHint=false,openWorldHint=false},inputSchema=schema(true),handler=observeHandler}
function M.register(reg) reg:add('read_lua',M.read);reg:add('observe_lua',M.observe) end
require('beammcp/identity').stamp('beammcp/tools/lua_observe',M)
return M
