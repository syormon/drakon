--loads images for LÖVE. GIFs go through our own decoder (src/gif.lua); other formats
--(JPG, PNG) use LÖVE's built-in loader. Results are cached by path.

local GIF = require('src.gif')

---@class ASSETS
local lib = {}
---@type {[string]:love.Image}
local images = {}

---@param path string
---@return boolean
local function isGif(path) return path:lower():sub(-4) == ".gif" end

---read and decode a GIF file; errors name the file
---@param path string
---@return GIF.IMAGE
local function decodeGif(path)
    local data, err = love.filesystem.read(path)
    if not data then error(("Cannot read %s: %s"):format(path, tostring(err)), 3) end
    local ok, result = pcall(GIF.decode, data)
    if not ok then error(("Cannot decode %s: %s"):format(path, tostring(result)), 3) end
    return result
end

---LÖVE image of one decoded frame, with nearest-neighbour filtering
---@param g GIF.IMAGE
---@param frame integer
---@return love.Image
local function toImage(g, frame)
    local data = love.image.newImageData(g.width, g.height, "rgba8", g.frames[frame].rgba)
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")  --small pixel art: keep edges crisp when scaled
    return img
end

---a single image (the first frame, for GIFs).
---@param path string
---@return love.Image
function lib.image(path)
    local img = images[path]
    if img then return img end
    if isGif(path) then
        img = toImage(decodeGif(path), 1)
    else
        img = love.graphics.newImage(path)
    end
    images[path] = img
    return img
end

return lib
