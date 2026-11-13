--base64 (RFC 4648, with padding), so any message can travel as plain text: in network
--play's WebSocket text frames and through the web build's bridge to JavaScript. Pure Lua: works the
--same in LuaJIT, Lua 5.1 (the web build) and later.

local lib = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
---@type string[] 0..63 -> character
local ENC = {}
---@type {[integer]:integer} byte of a character -> 0..63
local DEC = {}
for i = 1, 64 do
    local c = ALPHABET:sub(i, i)
    ENC[i - 1] = c
    DEC[c:byte()] = i - 1
end

---@param s string any bytes
---@return string
function lib.encode(s)
    local out = {}
    local n = #s
    for i = 1, n - 2, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = ENC[math.floor(v / 262144)] .. ENC[math.floor(v / 4096) % 64]
            .. ENC[math.floor(v / 64) % 64] .. ENC[v % 64]
    end
    local rest = n % 3
    if rest == 1 then
        local v = s:byte(n) * 65536
        out[#out + 1] = ENC[math.floor(v / 262144)] .. ENC[math.floor(v / 4096) % 64] .. "=="
    elseif rest == 2 then
        local a, b = s:byte(n - 1, n)
        local v = a * 65536 + b * 256
        out[#out + 1] = ENC[math.floor(v / 262144)] .. ENC[math.floor(v / 4096) % 64] .. ENC[math.floor(v / 64) % 64] .. "="
    end
    return table.concat(out)
end

---the bytes base64 text stands for, or nil if it isn't base64
---@param s string
---@return string|nil
function lib.decode(s)
    if #s % 4 ~= 0 then return nil end
    local out = {}
    local char = string.char
    for i = 1, #s, 4 do
        local c1, c2, c3, c4 = s:byte(i, i + 3)
        local a, b = DEC[c1], DEC[c2]
        if not (a and b) then return nil end
        local last = i + 3 == #s
        if c3 == 61 and c4 == 61 and last then           --"=="
            local v = a * 262144 + b * 4096
            out[#out + 1] = char(math.floor(v / 65536))
        elseif c4 == 61 and last then                       --"="
            local c = DEC[c3]
            if not c then return nil end
            local v = a * 262144 + b * 4096 + c * 64
            out[#out + 1] = char(math.floor(v / 65536), math.floor(v / 256) % 256)
        else
            local c, d = DEC[c3], DEC[c4]
            if not (c and d) then return nil end
            local v = a * 262144 + b * 4096 + c * 64 + d
            out[#out + 1] = char(math.floor(v / 65536), math.floor(v / 256) % 256, v % 256)
        end
    end
    return table.concat(out)
end

return lib
