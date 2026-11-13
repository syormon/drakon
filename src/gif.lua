--minimal GIF decoder in pure Lua (GIF87a / GIF89a).
--
--works under LuaJIT (LÖVE) and plain Lua 5.1+; no LÖVE calls, so it can be tested on its own.
--
--local gif = require("src.gif")
--local g = gif.decode(fileContents)
--g.width, g.height        -- logical screen size
--g.frames[i].rgba         -- width*height*4 bytes, RGBA, fully composited frame
--g.frames[i].delay        -- frame delay in seconds (0 if none)
--g.loopCount              -- NETSCAPE loop count (0 = forever), nil if not animated
--g.comment                -- text of the first comment block, if any
--
--supports global and local colour tables, transparency, interlacing, and animation with
--disposal methods 0-3. Each frame is returned as a whole canvas, ready to upload.

---one frame, composited onto the whole canvas
---@class GIF.FRAME
---@field rgba string width*height*4 bytes
---@field delay number seconds (0 if none)

---a decoded GIF
---@class GIF.IMAGE
---@field width integer
---@field height integer
---@field frames GIF.FRAME[]
---@field loopCount? integer NETSCAPE loop count (0 = forever), nil if not animated
---@field comment? string text of the first comment block
---@field background integer background colour index

---@class GIF.READER
---@field data string
---@field pos integer next byte, 1-based
---@field u8 fun():integer
---@field u16 fun():integer
---@field bytes fun(n:integer):string
---@field subBlocks fun():string

---@class GIF
local lib = {}

local byte, char, concat = string.byte, string.char, table.concat
local floor = math.floor

local POW = {}
for i = 0, 32 do POW[i] = 2 ^ i end

local TRANSPARENT = "\0\0\0\0"

---------------------------------------------------------------------------- reader

---byte reader over a string
---@param data string
---@return GIF.READER
local function reader(data)
    local r = { data = data, pos = 1 }
    ---@return integer
    function r.u8()
        local b = byte(data, r.pos)
        if not b then error("GIF: unexpected end of data", 3) end
        r.pos = r.pos + 1
        return b
    end
    ---little-endian 16-bit number
    ---@return integer
    function r.u16()
        local lo, hi = byte(data, r.pos, r.pos + 1)
        if not hi then error("GIF: unexpected end of data", 3) end
        r.pos = r.pos + 2
        return lo + hi * 256
    end
    ---@param n integer
    ---@return string
    function r.bytes(n)
        local s = data:sub(r.pos, r.pos + n - 1)
        if #s < n then error("GIF: unexpected end of data", 3) end
        r.pos = r.pos + n
        return s
    end
    ---a run of data sub-blocks (length byte + data), terminated by a zero-length block.
    ---@return string
    function r.subBlocks()
        local parts = {}
        while true do
            local n = r.u8()
            if n == 0 then break end
            parts[#parts + 1] = r.bytes(n)
        end
        return concat(parts)
    end
    return r
end

---colour table -> array of 4-byte RGBA strings, indexed from 0.
---@param r GIF.READER
---@param size integer number of colours
---@return {[integer]:string}
local function colorTable(r, size)
    local raw = r.bytes(size * 3)
    local t = {}
    for i = 0, size - 1 do
        local rr, gg, bb = byte(raw, i * 3 + 1, i * 3 + 3)
        t[i] = char(rr, gg, bb, 255)
    end
    return t
end

---------------------------------------------------------------------------- LZW

---decode GIF LZW data into an array of colour indices (1-based array, `count` entries).
---@param data string
---@param minCodeSize integer
---@param count integer
---@return integer[] indices
---@return integer n entries decoded (less than count if the data was cut short)
local function lzwDecode(data, minCodeSize, count)
    if minCodeSize < 1 or minCodeSize > 11 then
        error("GIF: invalid LZW minimum code size " .. minCodeSize, 3)
    end
    local clearCode = POW[minCodeSize]
    local endCode = clearCode + 1
    local codeSize = minCodeSize + 1
    local nextCode = endCode + 1
    local codeLimit = POW[codeSize]

    local prefix, suffix, first = {}, {}, {}
    for i = 0, clearCode - 1 do suffix[i] = i; first[i] = i end

    local out, n = {}, 0
    local stack = {}
    local buf, bits = 0, 0
    local pos, len = 1, #data
    local old

    while n < count do
        --refill the bit buffer, then take `codeSize` bits from the low end (LSB first)
        while bits < codeSize do
            if pos > len then return out, n end   --truncated data: keep what we have
            buf = buf + byte(data, pos) * POW[bits]
            pos = pos + 1
            bits = bits + 8
        end
        local code = buf % codeLimit
        buf = floor(buf / codeLimit)
        bits = bits - codeSize

        if code == clearCode then
            codeSize = minCodeSize + 1
            codeLimit = POW[codeSize]
            nextCode = endCode + 1
            old = nil
        elseif code == endCode then
            break
        else
            local k
            if old == nil then
                if code >= clearCode then error("GIF: invalid first LZW code", 3) end
                n = n + 1; out[n] = code
                old = code
            else
                local cur
                if code < nextCode then
                    cur = code
                    k = first[code]
                elseif code == nextCode then
                    --the KwKwK case: the code being defined is the old string plus its own first char
                    k = first[old]
                    cur = old
                else
                    error("GIF: invalid LZW code " .. code, 3)
                end
                --emit string(cur) by walking the prefix chain backwards
                local sp = 0
                local c = cur
                while c >= clearCode do
                    sp = sp + 1; stack[sp] = suffix[c]
                    c = prefix[c]
                end
                sp = sp + 1; stack[sp] = c
                for i = sp, 1, -1 do
                    n = n + 1; out[n] = stack[i]
                end
                if code == nextCode then
                    n = n + 1; out[n] = k
                end
                if nextCode < 4096 then
                    prefix[nextCode] = old
                    suffix[nextCode] = k
                    first[nextCode] = first[old]
                    nextCode = nextCode + 1
                    if nextCode == codeLimit and codeSize < 12 then
                        codeSize = codeSize + 1
                        codeLimit = POW[codeSize]
                    end
                end
                old = code
            end
        end
    end
    return out, n
end

---------------------------------------------------------------------------- decode

local INTERLACE_PASSES = { { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }

---decode a whole GIF file
---@param data string file contents
---@return GIF.IMAGE
function lib.decode(data)
    local r = reader(data)
    local sig = r.bytes(6)
    if sig ~= "GIF87a" and sig ~= "GIF89a" then error("GIF: not a GIF file", 2) end

    local width, height = r.u16(), r.u16()
    local flags = r.u8()
    local bgIndex = r.u8()
    r.u8()  --pixel aspect ratio
    local globalTable
    if flags >= 128 then
        globalTable = colorTable(r, POW[flags % 8 + 1])
    end

    local result = { width = width, height = height, frames = {} }
    local total = width * height

    --canvas: array of 4-byte RGBA strings, one per pixel. Starts transparent.
    local canvas = {}
    for i = 1, total do canvas[i] = TRANSPARENT end

    local gce = nil  --graphic control extension for the next image

    while true do
        local intro = r.u8()
        if intro == 0x3B then  --trailer
            break
        elseif intro == 0x21 then  --extension
            local label = r.u8()
            if label == 0xF9 then
                local blk = r.subBlocks()
                local pf = byte(blk, 1) or 0
                gce = {
                    disposal = floor(pf / 4) % 8,
                    transparent = (pf % 2 == 1) and byte(blk, 4) or nil,
                    delay = ((byte(blk, 2) or 0) + (byte(blk, 3) or 0) * 256) / 100,
                }
            elseif label == 0xFF then
                local blk = r.subBlocks()
                if blk:sub(1, 11) == "NETSCAPE2.0" or blk:sub(1, 11) == "ANIMEXTS1.0" then
                    local lo, hi = byte(blk, 13, 14)
                    result.loopCount = (lo or 0) + (hi or 0) * 256
                end
            elseif label == 0xFE then
                local text = r.subBlocks()
                result.comment = result.comment or text
            else
                r.subBlocks()  --plain text and unknown extensions are skipped
            end
        elseif intro == 0x2C then  --image descriptor
            local ix, iy, iw, ih = r.u16(), r.u16(), r.u16(), r.u16()
            local pf = r.u8()
            local palette = globalTable
            if pf >= 128 then palette = colorTable(r, POW[pf % 8 + 1]) end
            if not palette then error("GIF: image has no colour table", 2) end
            local interlaced = floor(pf / 64) % 2 == 1
            local minCodeSize = r.u8()
            local indices, count = lzwDecode(r.subBlocks(), minCodeSize, iw * ih)

            local disposal = gce and gce.disposal or 0
            local transparent = gce and gce.transparent
            local saved
            if disposal == 3 then
                saved = {}
                for i = 1, total do saved[i] = canvas[i] end
            end

            --row order: interlaced images store rows in four passes
            local rows = {}
            if interlaced then
                for _, pass in ipairs(INTERLACE_PASSES) do
                    for y = pass[1], ih - 1, pass[2] do rows[#rows + 1] = y end
                end
            else
                for y = 0, ih - 1 do rows[y + 1] = y end
            end

            --paint the frame onto the canvas (transparent pixels leave the canvas as it is)
            local p = 0
            for _, y in ipairs(rows) do
                local cy = iy + y
                for x = 0, iw - 1 do
                    p = p + 1
                    if p > count then break end
                    local idx = indices[p]
                    local cx = ix + x
                    if idx ~= transparent and cx < width and cy < height then
                        canvas[cy * width + cx + 1] = palette[idx] or TRANSPARENT
                    end
                end
            end

            result.frames[#result.frames + 1] = {
                rgba = concat(canvas),
                delay = gce and gce.delay or 0,
            }

            --disposal, applied before the next frame is drawn
            if disposal == 2 then
                for y = iy, math.min(iy + ih, height) - 1 do
                    for x = ix, math.min(ix + iw, width) - 1 do
                        canvas[y * width + x + 1] = TRANSPARENT
                    end
                end
            elseif disposal == 3 then
                canvas = saved
            end
            gce = nil
        else
            error(("GIF: unexpected block 0x%02X at byte %d"):format(intro, r.pos - 1), 2)
        end
    end

    if #result.frames == 0 then error("GIF: no images in file", 2) end
    result.background = bgIndex
    return result
end

return lib
