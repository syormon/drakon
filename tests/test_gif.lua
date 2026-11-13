--tests for src/gif.lua. Runs under plain Lua (no LÖVE needed), from the repository's top folder:
--lua tests/test_gif.lua [images dir] [reference dir]
--
--part 1 builds small GIFs by hand to cover features the game's assets don't use
--(interlacing, local colour tables, animation, disposal).
--part 2 (optional) decodes every GIF in [images dir] and compares each pixel with
--reference dumps made by Windows' own decoder (see tools/gifref.ps1).

package.path = "./?.lua;./src/?.lua;" .. package.path
local GIF = require('src.gif')

local passed, failed = 0, 0
---count a check, printing it when it fails
---@param name string
---@param cond any
---@param detail? any shown when it fails
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

---------------------------------------------------------------------------- tiny GIF writer

---little-endian 16-bit number
---@param n integer
---@return string
local function u16(n) return string.char(n % 256, math.floor(n / 256)) end

---LZW-encode indices without compression: minimum code size 2, and a clear code after every
---two literals so the code size never grows past 3 bits.
---@param indices integer[]
---@return string sub-blocks
local function lzw(indices)
    local codes = { 4 }  --clear
    for i, v in ipairs(indices) do
        codes[#codes + 1] = v
        if i % 2 == 0 then codes[#codes + 1] = 4 end
    end
    codes[#codes + 1] = 5  --end
    local out, buf, bits = {}, 0, 0
    for _, c in ipairs(codes) do
        buf = buf + c * 2 ^ bits
        bits = bits + 3
        while bits >= 8 do
            out[#out + 1] = string.char(buf % 256)
            buf = math.floor(buf / 256); bits = bits - 8
        end
    end
    if bits > 0 then out[#out + 1] = string.char(buf) end
    local data = table.concat(out)
    local blocks = {}
    for i = 1, #data, 255 do
        local s = data:sub(i, i + 254)
        blocks[#blocks + 1] = string.char(#s) .. s
    end
    return string.char(2) .. table.concat(blocks) .. "\0"
end

--4-colour palette: 0 red, 1 green, 2 blue, 3 white
local PALETTE = "\255\0\0" .. "\0\255\0" .. "\0\0\255" .. "\255\255\255"

---one image block (with its graphic control extension)
---@param opts table x, y, w, h, pixels, palette?, interlaced?, gce?
---@return string
local function frame(opts)
    local s = ""
    if opts.gce then
        local pf = opts.gce.disposal * 4 + (opts.gce.transparent and 1 or 0)
        s = s .. "\33\249\4" .. string.char(pf) .. u16(opts.gce.delay or 0)
              .. string.char(opts.gce.transparent or 0) .. "\0"
    end
    local pf = (opts.palette and 0x81 or 0) + (opts.interlaced and 0x40 or 0)
    s = s .. "\44" .. u16(opts.x) .. u16(opts.y) .. u16(opts.w) .. u16(opts.h) .. string.char(pf)
    if opts.palette then s = s .. opts.palette end
    return s .. lzw(opts.pixels)
end

---a whole GIF with the 4-colour test palette
---@param w integer
---@param h integer
---@param frames string[]
---@param extra? string blocks before the images
---@return string
local function file(w, h, frames, extra)
    return "GIF89a" .. u16(w) .. u16(h) .. "\129\0\0" .. PALETTE .. (extra or "")
           .. table.concat(frames) .. ";"
end

---RGBA of a pixel
---@param g GIF.IMAGE
---@param f integer frame
---@param x integer
---@param y integer
---@return integer[]
local function px(g, f, x, y)
    local i = (y * g.width + x) * 4
    return { g.frames[f].rgba:byte(i + 1, i + 4) }
end
---@param p integer[]
---@param r integer
---@param g integer
---@param b integer
---@param a? integer default 255
---@return boolean
local function isColor(p, r, g, b, a)
    return p[1] == r and p[2] == g and p[3] == b and p[4] == (a or 255)
end

---------------------------------------------------------------------------- part 1

do --plain 2x2
    local g = GIF.decode(file(2, 2, { frame{ x = 0, y = 0, w = 2, h = 2, pixels = { 0, 1, 2, 3 } } }))
    check("size", g.width == 2 and g.height == 2)
    check("one frame", #g.frames == 1)
    check("rgba length", #g.frames[1].rgba == 16)
    check("pixel 0,0 red", isColor(px(g, 1, 0, 0), 255, 0, 0))
    check("pixel 1,0 green", isColor(px(g, 1, 1, 0), 0, 255, 0))
    check("pixel 0,1 blue", isColor(px(g, 1, 0, 1), 0, 0, 255))
    check("pixel 1,1 white", isColor(px(g, 1, 1, 1), 255, 255, 255))
end

do --transparency
    local g = GIF.decode(file(2, 1, { frame{ x = 0, y = 0, w = 2, h = 1, pixels = { 3, 0 },
                                             gce = { disposal = 0, transparent = 3 } } }))
    check("transparent pixel", px(g, 1, 0, 0)[4] == 0)
    check("opaque pixel", isColor(px(g, 1, 1, 0), 255, 0, 0))
end

do --interlaced: 1x5 image, rows stored in pass order 0, 4, 2, 1, 3
    --each row's pixel is its row number's colour: rows 0..4 -> 0,1,2,3,0
    local want = { 0, 1, 2, 3, 0 }
    local stored = { want[1], want[5], want[3], want[2], want[4] }
    local g = GIF.decode(file(1, 5, { frame{ x = 0, y = 0, w = 1, h = 5, pixels = stored, interlaced = true } }))
    local colors = { [0] = { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 255 } }
    for y = 0, 4 do
        local c = colors[want[y + 1]]
        check("interlaced row " .. y, isColor(px(g, 1, 0, y), c[1], c[2], c[3]))
    end
end

do --local colour table overrides the global one
    local localPal = "\10\20\30" .. "\40\50\60" .. "\0\0\0" .. "\0\0\0"
    local g = GIF.decode(file(1, 1, { frame{ x = 0, y = 0, w = 1, h = 1, pixels = { 1 }, palette = localPal } }))
    check("local colour table", isColor(px(g, 1, 0, 0), 40, 50, 60))
end

do --animation: frame 2 draws a sub-rectangle; disposal modes
    local loop = "\33\255\11NETSCAPE2.0\3\1" .. u16(0) .. "\0"
    local base = frame{ x = 0, y = 0, w = 2, h = 1, pixels = { 0, 0 }, gce = { disposal = 1, delay = 10 } }
    local over = frame{ x = 1, y = 0, w = 1, h = 1, pixels = { 1 }, gce = { disposal = 2, delay = 20 } }
    local last = frame{ x = 0, y = 0, w = 1, h = 1, pixels = { 2 }, gce = { disposal = 0, delay = 30 } }
    local g = GIF.decode(file(2, 1, { base, over, last }, loop))
    check("three frames", #g.frames == 3)
    check("loop forever", g.loopCount == 0)
    check("delay in seconds", math.abs(g.frames[2].delay - 0.2) < 1e-9)
    check("frame 1", isColor(px(g, 1, 0, 0), 255, 0, 0) and isColor(px(g, 1, 1, 0), 255, 0, 0))
    check("frame 2 composited", isColor(px(g, 2, 0, 0), 255, 0, 0) and isColor(px(g, 2, 1, 0), 0, 255, 0))
    check("disposal 2 cleared", isColor(px(g, 3, 0, 0), 0, 0, 255) and px(g, 3, 1, 0)[4] == 0)
end

do --restore-to-previous disposal
    local a = frame{ x = 0, y = 0, w = 1, h = 1, pixels = { 0 }, gce = { disposal = 1 } }
    local b = frame{ x = 0, y = 0, w = 1, h = 1, pixels = { 1 }, gce = { disposal = 3 } }
    local c = frame{ x = 0, y = 0, w = 0, h = 0, pixels = {}, gce = { disposal = 0 } }
    local g = GIF.decode(file(1, 1, { a, b, c }))
    check("disposal 3 restores", isColor(px(g, 3, 0, 0), 255, 0, 0))
end

do --errors
    check("rejects non-GIF", not pcall(GIF.decode, "PNG...."))
    check("rejects truncated", not pcall(GIF.decode, "GIF89a\1"))
end

---------------------------------------------------------------------------- part 2

local imagesDir, refDir = arg[1], arg[2]
if imagesDir and refDir then
    ---@param p string
    ---@return string
    local function readFile(p)
        local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
    end
    local files, badFiles, badPixels, totalPixels = 0, 0, 0, 0
    local t0 = os.clock()
    for line in io.lines(refDir .. "/index.txt") do
        local n, rel, w, h = line:match("^(%d+)|(.-)|(%d+)|(%d+)$")
        w, h = tonumber(w), tonumber(h)
        files = files + 1
        local ok, g = pcall(GIF.decode, readFile(imagesDir .. "/" .. rel))
        if not ok then
            badFiles = badFiles + 1
            print("FAIL  decode " .. rel .. ": " .. tostring(g))
        elseif g.width ~= w or g.height ~= h then
            badFiles = badFiles + 1
            print(("FAIL  size %s: %dx%d, want %dx%d"):format(rel, g.width, g.height, w, h))
        else
            local ref, mine = readFile(refDir .. "/" .. n .. ".bgra"), g.frames[1].rgba
            local wrong = 0
            for i = 0, w * h - 1 do
                local b, gg, r, a = ref:byte(i * 4 + 1, i * 4 + 4)
                local R, G, B, A = mine:byte(i * 4 + 1, i * 4 + 4)
                local same
                if a == 0 then same = (A == 0)   --colour of a fully transparent pixel doesn't matter
                else same = (R == r and G == gg and B == b and A == a) end
                if not same then wrong = wrong + 1 end
            end
            totalPixels = totalPixels + w * h
            if wrong > 0 then
                badFiles = badFiles + 1; badPixels = badPixels + wrong
                print(("FAIL  pixels %s: %d of %d differ"):format(rel, wrong, w * h))
            end
        end
    end
    check("all reference GIFs match", badFiles == 0, badFiles .. " files differ")
    print(("Compared %d GIFs (%d pixels) with Windows' decoder: %d files differ, %d pixels differ, %.2fs")
          :format(files, totalPixels, badFiles, badPixels, os.clock() - t0))
else
    print("(skipping reference comparison: pass the images and reference directories)")
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
