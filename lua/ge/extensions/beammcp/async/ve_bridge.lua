-- ve_bridge: VE→GE correlation protocol. A vehicle-VM eval can't return synchronously, so the tool
-- allocates a correlation id (begin), fires VE code that calls back via
-- obj:queueGameEngineLua("require('beammcp/async/ve_bridge').resolve(id, json)"), and awaits the slot.
-- Pure/engine-free (serialize is injected into wrapVE) so it is fully unit-testable. State lives on the
-- module table so the tool's require and the callback's require share one instance (package.loaded).
local M = { pending = {}, seq = 0 }

-- Allocate a fresh correlation id and an unresolved pending slot.
function M.begin()
  M.seq = M.seq + 1
  local id = M.seq
  M.pending[id] = { done = false }
  return id
end

-- Called by the queued VE callback (in the GE VM). Stores the raw JSON only if the slot is still
-- pending and unresolved; unknown ids and stragglers (after take) are dropped, first response wins.
function M.resolve(id, jsonStr)
  local slot = M.pending[id]
  if slot and not slot.done then
    slot.done = true
    slot.json = jsonStr
  end
end

-- await predicate: has this slot been resolved?
function M.isReady(id)
  local slot = M.pending[id]
  return slot ~= nil and slot.done == true
end

-- Return the resolved JSON and clear the slot. Also used to abandon a slot on timeout (returns nil).
function M.take(id)
  local slot = M.pending[id]
  M.pending[id] = nil
  if slot and slot.done then return slot.json end
  return nil
end

-- Build the VE-VM source that runs `code`, captures its first return value + print output, and calls
-- back into GE to resolve slot `id`. `serializeFn` (the engine's serialize, injected for testability)
-- quotes `code` into a safe string literal so loadstring can compile it VE-side — that way a *compile*
-- error surfaces through the callback (as a payload) instead of silently breaking queueLuaCommand.
-- The inner serialize/jsonEncode in the emitted string are the VE runtime's own globals (literal text).
function M.wrapVE(id, code, serializeFn, maxBytes)
  local codeLit = serializeFn(code)
  return ([[
-- execute performs loadstring + xpcall with bounded output capture in this VM.
local _payload = require('beammcp/output').execute(%s, %d, '=vehicle_lua_eval')
if %s and _payload.truncated then
  _payload = {ok=false,err='internal vehicle result exceeds limits; narrow the query',output=''}
end
local _json = jsonEncode(_payload)                       -- encode the result table, then...
obj:queueGameEngineLua("require('beammcp/async/ve_bridge').resolve(%d, " .. serialize(_json) .. ")")  -- ...quote the JSON for embedding
]]):format(codeLit, maxBytes or 262144, tostring(maxBytes==nil), id)
end

return M
