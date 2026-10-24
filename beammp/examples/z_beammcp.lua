-- Copy into the target plugin, replace Example with its resource folder name.
-- Existing plugins can opt out of evaluation with allowEval=false.
local path='Resources/Server/BeamMCP/lua/beammcp_server/bridge.lua'
local f=io.open(path,'rb')
if f then
  f:close()
  assert(loadfile(path))().attach({plugin='Example'})
end
