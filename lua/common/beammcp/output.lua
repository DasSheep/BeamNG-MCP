-- Shared result/print limits. Bounds our traversal and capture, not arbitrary user-code execution.
local M={}
function M.budget(value,fallback)
  if value==nil then return fallback or 4096 end
  if type(value)~='number' or value~=value or value%1~=0 or value<1024 or value>16384 then
    return nil,'maxBytes must be an integer from 1024 to 16384'
  end
  return value
end

-- Valid UTF-8 stays intact; invalid bytes become literal \xHH previews. Work and output are bounded.
function M.clip(s,cap)
  local out,used,i={},0,1
  while i<=#s and used<cap do
    local b=s:byte(i)
    local n=b<128 and 1 or (b>=194 and b<=223 and 2) or (b>=224 and b<=239 and 3)
      or (b>=240 and b<=244 and 4) or 0
    local valid=n>0 and i+n-1<=#s
    for j=1,n-1 do local c=s:byte(i+j); if not c or c<128 or c>191 then valid=false end end
    local c=s:byte(i+1)
    if n==3 and c and ((b==224 and c<160) or (b==237 and c>=160)) then valid=false end
    if n==4 and c and ((b==240 and c<144) or (b==244 and c>=144)) then valid=false end
    local piece=valid and s:sub(i,i+n-1) or string.format('\\x%02X',b)
    if used+#piece>cap then break end
    out[#out+1]=piece; used=used+#piece; i=i+(valid and n or 1)
  end
  local text=table.concat(out)
  return text,i<=#s or text~=s
end

function M.fit(payload,maxBytes)
  maxBytes=maxBytes or 4096
  local chars,nodes=maxBytes,2048
  for _=1,12 do
    local seen,remaining,changed={},nodes,false
    local textRemaining=math.min(maxBytes*2,524288)
    local function copy(v,depth)
      local t=type(v)
      if t=='string' then
        local s,cut=M.clip(v,math.min(chars,textRemaining))
        textRemaining=textRemaining-#s; changed=changed or cut; return s
      end
      if t=='number' then
        if v~=v or v==math.huge or v==-math.huge then changed=true; return tostring(v) end
        return v
      end
      if t=='nil' or t=='boolean' then return v end
      if t~='table' then changed=true; return '<'..t..'>' end
      if seen[v] then changed=true; return '<cycle>' end
      if depth>=8 or remaining<=0 then changed=true; return '<limit>' end
      seen[v]=true
      local r,count={},0
      for k,x in next,v do
        count=count+1
        if count>512 or (remaining<=0 and depth>0) then changed=true; break end
        remaining=remaining-1
        local kind=type(k)
        if (kind=='number' and k==k and k~=math.huge and k~=-math.huge) or
          (kind=='string' and #k<=256 and M.clip(k,1024)==k) then r[k]=copy(x,depth+1)
        else changed=true end
      end
      seen[v]=nil
      return r
    end
    local result=copy(payload,0)
    if type(result)~='table' then result={value=result} end
    if changed then result.truncated=true end
    local ok,encoded=pcall(jsonEncode,result)
    if ok and #encoded<=maxBytes then return result end
    chars=math.floor(chars/2); nodes=math.max(8,math.floor(nodes/2))
  end
  return {truncated=true,reason='result exceeds budget or is not JSON serializable'}
end

function M.capture(cap)
  local chunks,size,cut={},0,false
  local function append(s)
    if size>=cap then cut=true; return end
    local text,truncated=M.clip(s,cap-size)
    chunks[#chunks+1]=text; size=size+#text; cut=cut or truncated
  end
  local function capture(...)
    if size>=cap then cut=true; return end
    if #chunks>0 then append('\n') end
    local n=select('#',...)
    for i=1,math.min(n,64) do
      if size>=cap then cut=true; break end
      if i>1 then append('\t') end
      append(tostring((select(i,...))))
    end
    if n>64 then cut=true end
  end
  return capture,function() return table.concat(chunks),cut end
end

function M.execute(code,maxBytes,chunkName)
  local chunk,err=loadstring(code,chunkName or '=lua_eval')
  if not chunk then return M.fit({ok=false,err='compile error: '..tostring(err),output=''},maxBytes) end
  local realPrint=print
  local capture,finish=M.capture(maxBytes)
  _G.print=capture
  local ok,value=xpcall(chunk,debug.traceback)
  _G.print=realPrint
  local text,cut=finish()
  local payload={ok=ok,output=text}
  if ok then payload.value=value else payload.err=tostring(value) end
  if cut then payload.truncated=true end
  local result=M.fit(payload,maxBytes)
  result.ok=ok
  return result
end

function M.errorText(err,printed,maxBytes)
  local text=tostring(err)
  if printed and printed~='' then text=text..'\n--- output ---\n'..printed end
  local r=M.fit({message=text},maxBytes)
  return (r.message or 'error output exceeded budget')..(r.truncated and '\n[truncated]' or '')
end
require('beammcp/identity').stamp('beammcp/output',M)
return M
