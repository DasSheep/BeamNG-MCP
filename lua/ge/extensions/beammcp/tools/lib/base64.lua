-- Pure-Lua base64 encoder (standard alphabet). Processes 3 input bytes -> 4 output chars; no
-- intermediate value exceeds 2^8, so LuaJIT's double precision is never at risk. No luasocket
-- dependency.
local M = {}

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function ch(sixBits) return CHARS:sub(sixBits + 1, sixBits + 1) end

function M.encode(bytes)
  local out = {}
  local n = #bytes
  local i = 1
  while i <= n do
    local b1 = bytes:byte(i)
    local b2 = bytes:byte(i + 1)   -- nil past the end
    local b3 = bytes:byte(i + 2)   -- nil past the end

    local c1 = ch(math.floor(b1 / 4))                                   -- top 6 bits of b1
    local c2 = ch((b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0))    -- low 2 of b1 + top 4 of b2
    local c3 = b2 and ch((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or "="  -- low 4 b2 + top 2 b3
    local c4 = b3 and ch(b3 % 64) or "="                                -- low 6 of b3

    out[#out + 1] = c1 .. c2 .. c3 .. c4
    i = i + 3
  end
  return table.concat(out)
end

return M
