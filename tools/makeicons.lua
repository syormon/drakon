--makes the app icons from the Drakon Moves chamber icon (the green dragon head,
--assets/images/128/Icon_DrakonMoves.gif), upscaled on a transparent background:
--android/love48.png ... love192.png (the Android launcher), assets/icon.png (the desktop
--window's icon), wasm/favicon.ico (16, 32 and 48 pixels) and windows/drakon.ico (16-256, put
--into the Windows .exe by tools/exeicon.js). Run from the source folder:
--love . --run tools/makeicons.lua

local GIF = require('src.gif')

local SOURCE = "assets/images/128/Icon_DrakonMoves.gif"
local FILL = 0.94       --how much of the icon the dragon fills
local BIG = 8           --pixel-art upscale before smooth downscaling

---the GIF's first frame, cropped to its non-transparent pixels
---@return love.ImageData
local function dragon()
    local g = GIF.decode(assert(love.filesystem.read(SOURCE)))
    local d = love.image.newImageData(g.width, g.height, "rgba8", g.frames[1].rgba)
    local x0, y0, x1, y1 = g.width, g.height, -1, -1
    for y = 0, g.height - 1 do
        for x = 0, g.width - 1 do
            local _, _, _, a = d:getPixel(x, y)
            if a > 0 then
                x0, y0 = math.min(x0, x), math.min(y0, y)
                x1, y1 = math.max(x1, x), math.max(y1, y)
            end
        end
    end
    local out = love.image.newImageData(x1 - x0 + 1, y1 - y0 + 1)
    out:paste(d, 0, 0, x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    return out
end

local art = dragon()
local w, h = art:getDimensions()
local side = math.max(w, h)

--the dragon upscaled pixel for pixel (crisp), centred on a transparent square; smaller
--icons are drawn from this with mipmaps, so edges stay smooth at any size
local bigSide = side * BIG
local big = love.graphics.newCanvas(bigSide, bigSide, { mipmaps = "manual" })
local artImage = love.graphics.newImage(art)
artImage:setFilter("nearest", "nearest")
love.graphics.setCanvas(big)
love.graphics.clear(0, 0, 0, 0)
love.graphics.setColor(1, 1, 1)
love.graphics.draw(artImage, (side - w) / 2 * BIG, (side - h) / 2 * BIG, 0, BIG, BIG)
love.graphics.setCanvas()
big:generateMipmaps()
big:setFilter("linear", "linear")
big:setMipmapFilter("linear")

---the icon at `size` pixels: a whole-number upscale when that fills it well, else smooth
---@param size integer
---@return love.ImageData
local function icon(size)
    local c = love.graphics.newCanvas(size, size)
    love.graphics.setCanvas(c)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setBlendMode("alpha", "premultiplied")
    local k = math.floor(size * FILL / side)
    if k >= 1 and k * side >= size * 0.85 then
        local off = math.floor((size - k * side) / 2)
        love.graphics.draw(artImage, off + math.floor((side - w) / 2) * k, off + math.floor((side - h) / 2) * k, 0, k, k)
    else
        local inner = size * FILL
        love.graphics.draw(big, (size - inner) / 2, (size - inner) / 2, 0, inner / bigSide)
    end
    love.graphics.setBlendMode("alpha")
    love.graphics.setCanvas()
    return c:newImageData()
end

local root = love.filesystem.getSource()

---write bytes to a file in the source folder
---@param path string relative to the source folder
---@param bytes string
local function save(path, bytes)
    local f = assert(io.open(root .. "/" .. path, "wb"))
    f:write(bytes)
    f:close()
    print("wrote " .. path)
end

---@param size integer
---@return string
local function png(size) return icon(size):encode("png"):getString() end

for _, size in ipairs({ 48, 72, 96, 144, 192 }) do
    save(("android/love%d.png"):format(size), png(size))
end
save("assets/icon.png", png(256))

---an .ico file of PNG images: an ICONDIR header, one 16-byte entry per size, then the PNGs
---@param sizes integer[]
---@return string
local function ico(sizes)
    local pngs = {}
    for i, size in ipairs(sizes) do pngs[i] = png(size) end
    local parts = { love.data.pack("string", "<I2I2I2", 0, 1, #sizes) }
    local offset = 6 + 16 * #sizes
    for i, size in ipairs(sizes) do
        --(a width or height of 256 is written as 0)
        parts[#parts + 1] = love.data.pack("string", "<BBBBI2I2I4I4", size % 256, size % 256, 0, 0, 1, 32, #pngs[i], offset)
        offset = offset + #pngs[i]
    end
    for _, p in ipairs(pngs) do parts[#parts + 1] = p end
    return table.concat(parts)
end

save("wasm/favicon.ico", ico({ 16, 32, 48 }))
save("windows/drakon.ico", ico({ 16, 32, 48, 64, 128, 256 }))
