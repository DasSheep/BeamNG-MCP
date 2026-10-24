-- Bounded, raw Lua inspection shared by GE and vehicle VMs. No inspected code is executed.
-- Inspired by E32k's Lua Globals Explorer; implemented independently for structured MCP output.
local M = {}
local SCAN_LIMIT, FILE_LIMIT = 10000, 524288
local kinds = {table=true, userdata=true, cdata=true, ['function']=true, string=true,
  number=true, boolean=true, thread=true, ['nil']=true}

local function finite(n) return n == n and n ~= math.huge and n ~= -math.huge end
local function integer(n, lo, hi)
  return type(n) == 'number' and finite(n) and n == math.floor(n) and n >= lo and n <= hi
end
local function default(v,fallback) if v==nil then return fallback end; return v end

-- Keep a UTF-8 codepoint whole when clipping a byte string. Input may still contain binary bytes;
-- previews escape those below, while source pages reject invalid UTF-8 rather than corrupt it.
local function prefix(s, size)
  local n = math.min(#s, size)
  if n < #s then
    while n > 0 and s:byte(n+1) >= 128 and s:byte(n+1) < 192 do n = n-1 end
  end
  return s:sub(1,n)
end

local function clean(s)
  local out, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local n = b < 128 and 1 or (b >= 194 and b <= 223 and 2)
      or (b >= 224 and b <= 239 and 3) or (b >= 240 and b <= 244 and 4) or 0
    local valid = n > 0 and i+n-1 <= #s
    for j=1,n-1 do local c=s:byte(i+j); if not c or c<128 or c>191 then valid=false end end
    local c = s:byte(i+1)
    if n==3 and c and ((b==224 and c<160) or (b==237 and c>=160)) then valid=false end
    if n==4 and c and ((b==240 and c<144) or (b==244 and c>=144)) then valid=false end
    if valid then out[#out+1]=s:sub(i,i+n-1); i=i+n
    else out[#out+1]=string.format('\\x%02X',b); i=i+1 end
  end
  return table.concat(out)
end

local function validKey(k)
  local t=type(k)
  return t=='boolean' or (t=='number' and finite(k))
    or (t=='string' and #k<=256 and clean(k)==k)
end

function M.validate(args, source)
  if args==nil then args={} end
  if type(args)~='table' then return nil,'arguments must be an object' end
  local allowed = {path=true,scope=true,id=true,limit=true,offset=true,maxBytes=true}
  if not source then
    for _,k in ipairs({'filter','kind','sort','searchValues','detail','preview'}) do allowed[k]=true end
  end
  for k in pairs(args) do if not allowed[k] then return nil,'unknown argument' end end
  local a={path=default(args.path,{}), scope=default(args.scope,'ge'), id=args.id}
  if a.scope~='ge' and a.scope~='vehicle' then return nil,"scope must be 'ge' or 'vehicle'" end
  if a.id~=nil and (a.scope~='vehicle' or not integer(a.id,0,2147483647)) then
    return nil,'id requires vehicle scope and a nonnegative integer'
  end
  if type(a.path)~='table' or #a.path>24 then return nil,'path must be an array of at most 24 steps' end
  local count=0
  for k in pairs(a.path) do
    if not integer(k,1,#a.path) then return nil,'path must be a dense array' end
    count=count+1
  end
  if count~=#a.path then return nil,'path must be a dense array' end
  for _,step in ipairs(a.path) do
    if type(step)=='table' then
      if step.via~='metatable' and step.via~='index' then return nil,'invalid path navigation step' end
      for k in pairs(step) do if k~='via' then return nil,'navigation steps only accept via' end end
    elseif not validKey(step) then return nil,'path keys must be finite numbers, booleans or UTF-8 strings <=256 bytes' end
  end
  for _,spec in ipairs({{'limit',source and 40 or 20,1,100},{'offset',0,0,source and FILE_LIMIT or SCAN_LIMIT},
    {'maxBytes',4096,1024,16384}}) do
    local v=args[spec[1]]; if v==nil then v=spec[2] end
    if not integer(v,spec[3],spec[4]) then return nil,'invalid '..spec[1] end
    a[spec[1]]=v
  end
  if not source then
    a.filter=default(args.filter,''); a.kind=args.kind; a.sort=default(args.sort,'key')
    if type(a.filter)~='string' or #a.filter>128 then return nil,'filter must be a string <=128 bytes' end
    if a.kind~=nil and not kinds[a.kind] then return nil,'invalid kind' end
    if a.sort~='key' and a.sort~='type' and a.sort~='value' then return nil,'invalid sort' end
    for _,k in ipairs({'detail','searchValues'}) do
      if args[k]~=nil and type(args[k])~='boolean' then return nil,k..' must be boolean' end
      a[k]=args[k]==true
    end
    a.preview=default(args.preview,128)
    if not integer(a.preview,0,512) then return nil,'preview must be 0..512' end
  end
  return a
end

local function metatable(v)
  local mt=getmetatable(v)
  -- A table-valued __metatable sentinel must not be mistaken for the real metatable.
  local actual=debug and debug.getmetatable and debug.getmetatable(v)
  if actual and type(actual)=='table' and rawget(actual,'__metatable')~=nil then
    return nil,'protected metatable'
  end
  if mt==nil then return nil,'no metatable' end
  if type(mt)~='table' then return nil,'protected metatable' end
  return mt
end

local function indexOf(v)
  local mt,err=metatable(v)
  if err=='protected metatable' then return nil,err end
  local idx=mt and rawget(mt,'__index')
  if idx==nil and type(v)=='table' then idx=rawget(v,'__index') end
  return idx
end

local function resolve(path,root)
  local v=root or _G
  for i,step in ipairs(path) do
    if type(step)=='table' then
      local err
      if step.via=='metatable' then v,err=metatable(v)
      else
        v,err=indexOf(v)
        if v~=nil and type(v)~='table' then return nil,'__index is '..type(v)..'; only table indexes can be browsed' end
      end
      if v==nil then return nil,err or ('missing '..step.via) end
    else
      if type(v)~='table' then return nil,'path step '..i..' requires a table; use explicit metatable/index navigation' end
      v=rawget(v,step)
      if v==nil then return nil,'missing path step '..i end
    end
  end
  return v
end

local function functionInfo(fn)
  if not debug or type(debug.getinfo)~='function' then return {metadataUnavailable=true} end
  local ok,d=pcall(debug.getinfo,fn,'Su')
  if not ok or not d then return {metadataUnavailable=true} end
  if d.what=='C' then return {native=true} end
  local r={line=d.linedefined,endLine=d.lastlinedefined,vararg=d.isvararg}
  if d.source and #d.source<=256 and (d.source:sub(1,1)=='@' or d.source:sub(-4)=='.lua') then
    r.source=clean(d.source:gsub('^@',''))
  end
  if d.nparams then
    r.params={}
    for i=1,math.min(d.nparams,64) do
      local yes,name=pcall(debug.getlocal,fn,i)
      r.params[i]=yes and type(name)=='string' and clean(prefix(name,64)) or '?'
    end
    if d.nparams>64 then r.paramsTruncated=true end
  end
  return r
end

local function scalar(v,preview)
  local t=type(v)
  if t=='string' then return clean(prefix(v,preview)) end
  if t=='number' then return finite(v) and v or tostring(v) end
  if t=='boolean' then return v end
end

local function describe(v,a)
  local t=type(v)
  local r={type=t,value=scalar(v,a.preview)}
  if t=='string' and (r.value~=v) then r.bytes=#v; r.truncated=true end
  if t=='function' and a.detail then
    for k,x in pairs(functionInfo(v)) do r[k]=x end
  elseif t=='table' or t=='userdata' or t=='cdata' then
    local mt,err=metatable(v)
    if mt then r.metatable=true elseif err=='protected metatable' then r.metatable='protected' end
    local idx=indexOf(v)
    if idx~=nil then r.index=type(idx) end
  elseif t=='thread' then r.value=coroutine.status(v) end
  return r
end

local function fits(r,budget) return #jsonEncode(r)<=budget end

-- Read one leaf without enumerating child tables. Reuses the exact browsing path rules.
function M.readValue(path,root,preview)
  local a,err=M.validate({path=path,preview=preview},false)
  if not a then return nil,err end
  local value; value,err=resolve(a.path,root)
  if err then return nil,err end
  return describe(value,a)
end
local function keyLess(a,b)
  local ta,tb=type(a.key),type(b.key)
  if ta~=tb then return ta<tb end
  if ta=='boolean' then return a.key==false and b.key==true end
  return a.key<b.key
end

function M.inspect(args,root)
  local a,err=M.validate(args,false); if not a then return nil,err end
  local value; value,err=resolve(a.path,root); if err then return nil,err end
  if type(value)~='table' then
    local r={value=describe(value,a)}
    if not fits(r,a.maxBytes) then return nil,'value exceeds maxBytes; lower preview/detail or increase maxBytes' end
    return r
  end
  local rows,scanned,omitted={},0,0
  local filter=a.filter:lower()
  local function contains(s) return s:lower():find(filter,1,true)~=nil end
  local key,v=next(value)
  while key~=nil and scanned<SCAN_LIMIT do
    scanned=scanned+1
    if validKey(key) then
      local t=type(v)
      local preview
      if a.searchValues or a.sort=='value' then preview=scalar(v,a.preview) end
      if (not a.kind or a.kind==t) and (contains(tostring(key)) or
        (a.searchValues and preview~=nil and contains(tostring(preview)))) then
        rows[#rows+1]={key=key,value=v,kind=t,sortValue=a.sort=='value' and tostring(preview) or nil}
      end
    else omitted=omitted+1 end
    key,v=next(value,key)
  end
  local incomplete=key~=nil
  if incomplete and a.offset>0 then return nil,'scan limit reached; narrow path before paging' end
  table.sort(rows,function(x,y)
    if a.sort=='type' and x.kind~=y.kind then return x.kind<y.kind end
    if a.sort=='value' then
      local xv,yv=x.sortValue,y.sortValue
      if xv~=yv then return xv<yv end
    end
    return keyLess(x,y)
  end)
  local r={entries={},matched=#rows}
  if omitted>0 then r.omittedKeys=omitted end
  if incomplete then r.scanTruncated=true; r.scanned=scanned end
  local stop=math.min(#rows,a.offset+a.limit)
  for i=a.offset+1,stop do
    local row=describe(rows[i].value,a); row.key=rows[i].key
    r.entries[#r.entries+1]=row
    r.nextOffset=not incomplete and i<#rows and i or nil
    if not fits(r,a.maxBytes) then
      if #r.entries==1 then
        -- A large first value must not create an empty, non-progressing continuation page.
        while type(row.value)=='string' and #row.value>0 and not fits(r,a.maxBytes) do
          row.value=prefix(row.value,math.floor(#row.value/2)); row.truncated=true
        end
        if not fits(r,a.maxBytes) then
          row={key=rows[i].key,type=rows[i].kind,detailOmitted=true}; r.entries[1]=row
        end
        if not fits(r,a.maxBytes) then return nil,'entry exceeds maxBytes; increase maxBytes' end
      else
        r.entries[#r.entries]=nil
        r.nextOffset=not incomplete and i-1 or nil
      end
      break
    end
  end
  if not fits(r,a.maxBytes) then return nil,'result exceeds maxBytes' end
  return r
end

local function readSource(path,cap)
  local f=io.open(path,'rb')
  if not f then return nil,'missing file' end
  local ok,data=pcall(f.read,f,cap+1)
  f:close()
  if not ok or not data then return nil,'source read failed' end
  return data
end

function M.source(args,root,reader)
  local a,err=M.validate(args,true); if not a then return nil,err end
  local fn; fn,err=resolve(a.path,root); if err then return nil,err end
  if type(fn)~='function' then return nil,'path must resolve to a function' end
  local info=functionInfo(fn)
  if info.native then return {unavailable='native'} end
  if not info.source then return {unavailable=info.metadataUnavailable and 'debug metadata' or 'generated chunk'} end
  local r={source=info.source,line=info.line,endLine=info.endLine}
  local function unavailable(reason)
    r.unavailable=reason
    if not fits(r,a.maxBytes) then return nil,'source metadata exceeds maxBytes; increase maxBytes' end
    return r
  end
  local data,readErr=(reader or readSource)(info.source,FILE_LIMIT)
  if not data then return unavailable(readErr or 'source read failed') end
  if #data>FILE_LIMIT then return unavailable('source exceeds 512 KiB read limit') end
  local start,finish,pos,line=1,#data,1,1
  local first,last=math.max(1,info.line or 1),info.endLine or 0
  while pos<=#data do
    if line==first then start=pos end
    local nl=data:find('\n',pos,true)
    if last>0 and line==last then finish=nl or #data; break end
    if not nl then break end
    pos=nl+1; line=line+1
  end
  if first>line or (last>0 and last>line) then return unavailable('source line range no longer exists') end
  local body=data:sub(start,finish)
  if a.offset>#body then return nil,'offset exceeds function source size' end
  local b=body:byte(a.offset+1)
  if a.offset>0 and b and b>=128 and b<192 then return nil,'offset splits a UTF-8 codepoint' end
  local _,before=body:sub(1,a.offset):gsub('\n','')
  r.line=first+before; r.offset=a.offset
  local tail=body:sub(a.offset+1)
  local endPos,at=#tail,1
  for _=1,a.limit do
    local nl=tail:find('\n',at,true)
    if not nl then break end
    endPos=nl; at=nl+1
  end
  -- If fewer than limit lines remain, include the last line even without a trailing newline.
  if at<=#tail then
    local _,n=tail:gsub('\n','')
    if n<a.limit then endPos=#tail end
  end
  local lo,hi=0,math.min(endPos,a.maxBytes)
  while lo<hi do
    local mid=math.ceil((lo+hi)/2)
    r.text=prefix(tail,mid)
    r.nextOffset=a.offset+#r.text<#body and a.offset+#r.text or nil
    if fits(r,a.maxBytes) then lo=mid else hi=mid-1 end
  end
  r.text=prefix(tail,lo)
  if clean(r.text)~=r.text then return nil,'source contains non-UTF-8 bytes' end
  r.nextOffset=a.offset+#r.text<#body and a.offset+#r.text or nil
  if #r.text==0 and #tail>0 then return nil,'source metadata exceeds maxBytes; increase maxBytes' end
  if not fits(r,a.maxBytes) then return nil,'source metadata exceeds maxBytes; increase maxBytes' end
  return r
end

require('beammcp/identity').stamp('beammcp/inspect',M)
return M
