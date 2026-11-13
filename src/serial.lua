--turning Lua values into strings and back, for sending a game over the network. Handles
--nested and shared tables (a player referenced from several places stays one table), cycles,
--and objects with a metatable from a list of known classes. Pure Lua: no LÖVE calls.
--
--Decoding never runs the text as code (it may come from anyone on the network): it reads
--only numbers, strings, booleans and tables, and fails cleanly on anything else.
--
--format: a value is one of
--  n<number>;         a number (inf, -inf and nan spelled out)
--  s<length>:<bytes>  a string
--  T / F              true / false
--  r<id>;             a table already given (by its id, counting from 1 in order of appearance)
--  {<class>;<key><value>...}   a new table; class is "" for a plain table

local lib = {}

---classes an encoded value may hold, by name: name -> metatable
---@alias SERIAL.CLASSES {[string]:table}

lib.VERSION = "drakon1"

local MAX_DEPTH = 200

---@param v number
---@return string
local function number(v)
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
end

---the value as a string
---@param value any numbers, strings, booleans and tables of them (no functions)
---@param classes? SERIAL.CLASSES metatables allowed, by name
---@return string
function lib.encode(value, classes)
    local names = {}
    for name, mt in pairs(classes or {}) do names[mt] = name end
    local ids, count = {}, 0
    local out = { lib.VERSION, ":" }
    ---@param v any
    ---@param depth integer
    local function put(v, depth)
        local t = type(v)
        if t == "number" then
            out[#out + 1] = "n" .. number(v) .. ";"
        elseif t == "string" then
            out[#out + 1] = "s" .. #v .. ":" .. v
        elseif t == "boolean" then
            out[#out + 1] = v and "T" or "F"
        elseif t == "table" then
            if ids[v] then out[#out + 1] = "r" .. ids[v] .. ";"; return end
            if depth > MAX_DEPTH then error("serial: tables nested too deeply") end
            count = count + 1
            ids[v] = count
            local mt = getmetatable(v)
            local class = ""
            if mt then
                class = names[mt]
                if not class then error("serial: a table with an unknown metatable") end
            end
            out[#out + 1] = "{" .. class .. ";"
            for k, x in pairs(v) do
                put(k, depth + 1)
                put(x, depth + 1)
            end
            out[#out + 1] = "}"
        else
            error("serial: cannot send a " .. t)
        end
    end
    put(value, 0)
    return table.concat(out)
end

---the value a string from serial.encode stands for, or nil and what is wrong with it
---@param text string
---@param classes? SERIAL.CLASSES metatables allowed, by name
---@return any value
---@return string? err
function lib.decode(text, classes)
    if type(text) ~= "string" then return nil, "not a string" end
    local head = lib.VERSION .. ":"
    if text:sub(1, #head) ~= head then return nil, "not a Drakon message (or another version)" end
    classes = classes or {}
    local pos = #head + 1
    local tables = {}
    ---@param msg string
    local function fail(msg) error({ serial = msg }, 0) end
    ---read up to `stop`, as a number
    ---@param stop string
    ---@return number
    local function readNumber(stop)
        local e = text:find(stop, pos, true)
        if not e then fail("unfinished number") end
        local s = text:sub(pos, e - 1)
        pos = e + 1
        if s == "inf" then return math.huge end
        if s == "-inf" then return -math.huge end
        if s == "nan" then return 0 / 0 end
        if not s:match("^%-?%d+%.?%d*[eE]?[%-+]?%d*$") then fail("bad number") end
        local n = tonumber(s)
        if not n then fail("bad number") end
        return n --[[@as number]]   --(fail doesn't return)
    end
    ---@param depth integer
    ---@return any
    local function get(depth)
        if depth > MAX_DEPTH then fail("nested too deeply") end
        local c = text:sub(pos, pos)
        pos = pos + 1
        if c == "n" then return readNumber(";")
        elseif c == "s" then
            local len = readNumber(":")
            if len < 0 or len ~= math.floor(len) or pos + len - 1 > #text then fail("bad string") end
            local s = text:sub(pos, pos + len - 1)
            pos = pos + len
            return s
        elseif c == "T" then return true
        elseif c == "F" then return false
        elseif c == "r" then
            local id = readNumber(";")
            local t = tables[id]
            if not t then fail("reference to an unknown table") end
            return t
        elseif c == "{" then
            local e = text:find(";", pos, true)
            if not e then fail("unfinished table") end
            local class = text:sub(pos, e - 1)
            pos = e + 1
            local t = {}
            if class ~= "" then
                local mt = classes[class]
                if not mt then fail("unknown class " .. class) end
                setmetatable(t, mt)
            end
            tables[#tables + 1] = t
            while text:sub(pos, pos) ~= "}" do
                if pos > #text then fail("unfinished table") end
                local k = get(depth + 1)
                local v = get(depth + 1)
                if k == nil or k ~= k then fail("bad key") end
                rawset(t, k, v)
            end
            pos = pos + 1
            return t
        end
        fail("unexpected " .. (c == "" and "end" or ("'" .. c .. "'")))
    end
    local ok, value = pcall(get, 0)
    if not ok then
        if type(value) == "table" and value.serial then return nil, value.serial end
        error(value, 0)
    end
    if pos ~= #text + 1 then return nil, "extra text at the end" end
    return value
end

return lib
