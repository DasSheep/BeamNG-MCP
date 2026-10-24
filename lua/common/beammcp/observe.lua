-- One-VM, selected-value snapshots. Tables/objects stay opaque; user getters are never invoked.
local inspector=require('beammcp/inspect')
local output=require('beammcp/output')
local M={}
function M.validate(args)
  if type(args)~='table' or type(args.fields)~='table' or #args.fields<1 or #args.fields>16 then
    return nil,'fields must contain 1..16 named paths'
  end
  local a,err=inspector.validate({scope=args.scope,id=args.id,preview=args.preview,maxBytes=args.maxBytes})
  if not a then return nil,err end
  local fields,names,count={},{},0
  for k in pairs(args.fields) do
    if type(k)~='number' or k%1~=0 or k<1 or k>#args.fields then return nil,'fields must be a dense array' end
    count=count+1
  end
  if count~=#args.fields then return nil,'fields must be a dense array' end
  for _,f in ipairs(args.fields) do
    if type(f)~='table' or type(f.name)~='string' or #f.name>32 or not f.name:match('^[%w_.-]+$') or names[f.name] then
      return nil,'field names must be unique identifiers of 1..32 bytes'
    end
    if f.path==nil then return nil,'each field requires a path' end
    for k in pairs(f) do if k~='name' and k~='path' then return nil,'unknown field option' end end
    local valid,pathErr=inspector.validate({path=f.path})
    if not valid then return nil,pathErr end
    names[f.name]=true; fields[#fields+1]={name=f.name,path=valid.path}
  end
  return {fields=fields,scope=a.scope,id=a.id,preview=a.preview,maxBytes=a.maxBytes},names
end
function M.snapshot(args,root)
  local a,err=M.validate(args); if not a then return nil,err end
  local r={values={}}
  for _,field in ipairs(a.fields) do
    local leaf,why=inspector.readValue(field.path,root,a.preview)
    if leaf and leaf.type=='number' and type(leaf.value)~='number' then
      leaf=nil;why='number is not finite'
    end
    if not leaf then
      r.unavailable=r.unavailable or {};r.unavailable[field.name]=output.clip(why,128)
    else
      if leaf.value~=nil then r.values[field.name]=leaf.value else r.values[field.name]={type=leaf.type} end
      if leaf.truncated then r.truncatedFields=r.truncatedFields or {};r.truncatedFields[field.name]=true end
    end
  end
  return r
end
require('beammcp/identity').stamp('beammcp/observe',M)
return M
