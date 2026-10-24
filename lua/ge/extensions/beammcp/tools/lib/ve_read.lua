-- Shared internal read route. Public eval budgets must not silently truncate another tool's result.
local evaluator=require('beammcp/tools/vehicle_lua_eval')
local veh=require('beammcp/tools/lib/veh')
local M={}
function M.resolve(args,label)
  if args.id~=nil and (type(args.id)~='number' or args.id~=args.id or args.id%1~=0 or args.id<0 or args.id>2147483647) then
    return nil,'invalid vehicle id'
  end
  local id,err=veh.resolveId(args,label)
  if not id then return nil,err end
  local object=be:getObjectByID(id)
  if not object then return nil,(label or 'read')..': unknown vehicle id '..tostring(id) end
  return id,object
end
function M.run(id,code,label,timeout)
  local resolved,object=M.resolve({id=id},label)
  if not resolved then return nil,object end
  local payload=evaluator.evalVE(object,code,nil,timeout)
  if not payload then return nil,(label or 'read')..': no response from vehicle VM' end
  if not payload.ok then return nil,tostring(payload.err or 'vehicle read failed') end
  return payload.value
end
return M
