--records every animated chamber playing at once, in a grid with their names, as an animated
--GIF for showing off the game: the frames go to animgif/ in the save folder, and ffmpeg
--(which must be on the PATH) turns them into anim_tiles.gif there.
--  love . --run tools/animgif.lua   [DRAKON_SIZE=128 DRAKON_SECONDS=8 DRAKON_FPS=20 DRAKON_COLUMNS=7]
--The animations have different loop lengths, so the GIF jumps a little where it starts over.

local m = ...
local TILES = m.tiles
local TILEART = require('src.tileart')
local UI = require('src.ui')

local SIZE = tonumber(os.getenv("DRAKON_SIZE") or "") or 128          --tile size: 64, 128 or 256 stay sharp
local SECONDS = tonumber(os.getenv("DRAKON_SECONDS") or "") or 8
local FPS = tonumber(os.getenv("DRAKON_FPS") or "") or 20             --GIF delays are in 1/100 s: 20, 25 or 50
local COLUMNS = tonumber(os.getenv("DRAKON_COLUMNS") or "") or 7
local GAP, LABEL_H, MARGIN = 14, 22, 16
local FOLDER = "animgif"

---@type TILES.EFFECT[]
local effects = {}
for e = 0, TILES.EFFECT_COUNT - 1 do
    if TILEART.ANIMATION[e] or TILEART.SPECIAL[e] then effects[#effects + 1] = e end
end
--every tile with the same three exits (there is no picture for four), so they look alike
--apart from the chamber
local arrows = TILES.arrowSet(TILES.UP, TILES.RIGHT, TILES.LEFT)
---@type TILES.TILE[]
local tiles = {}
for i, e in ipairs(effects) do tiles[i] = TILES.fromParts(e, arrows) end

local rows = math.ceil(#tiles / COLUMNS)
local cellW, cellH = SIZE + GAP, SIZE + LABEL_H + GAP
local w = MARGIN * 2 + COLUMNS * cellW - GAP
local h = MARGIN * 2 + rows * cellH - GAP
local canvas = love.graphics.newCanvas(w, h)

--clear out frames from an earlier run
love.filesystem.createDirectory(FOLDER)
for _, name in ipairs(love.filesystem.getDirectoryItems(FOLDER)) do
    love.filesystem.remove(FOLDER .. "/" .. name)
end

local frames = math.floor(SECONDS * FPS + 0.5)
for f = 0, frames - 1 do
    local t = f / FPS
    love.graphics.setCanvas(canvas)
    love.graphics.clear(UI.COLOR.board[1], UI.COLOR.board[2], UI.COLOR.board[3], 1)
    for i, tile in ipairs(tiles) do
        local col, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        local x, y = MARGIN + col * cellW, MARGIN + row * cellH
        love.graphics.setColor(1, 1, 1)
        TILEART.draw(tile, x, y, SIZE, t)
        UI.text(tile:effectName(), x - GAP / 2, y + SIZE + 4, 13, UI.COLOR.text, SIZE + GAP, "center")
    end
    love.graphics.setCanvas()
    canvas:newImageData():encode("png", ("%s/%04d.png"):format(FOLDER, f + 1))
end
local dir = love.filesystem.getSaveDirectory()
print(("%d frames of %d x %d pixels saved to %s/%s"):format(frames, w, h, dir, FOLDER))

--one palette made from all the frames, with no dithering, so the pixel art stays clean
local out = dir .. "/anim_tiles.gif"
local cmd = ('ffmpeg -y -loglevel error -framerate %d -i "%s/%s/%%04d.png" -vf '
    .. '"split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=none" '
    .. '-loop 0 "%s"'):format(FPS, dir, FOLDER, out)
local ok = os.execute(cmd)
if ok == true or ok == 0 then
    print("GIF saved to " .. out)
else
    print("ffmpeg didn't run; with ffmpeg installed, make the GIF with:\n" .. cmd)
end
