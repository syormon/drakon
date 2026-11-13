--renders every chamber icon animation at six moments of its loop into one picture,
--anim_sheet.png in the save folder, to check them without watching the game.
--  love . --run tools/animsheet.lua

local m = ...
local TILES = m.tiles
local TILEART = require('src.tileart')
local UI = require('src.ui')

local SIZE, GAP, FRAMES, PER_COLUMN = 64, 6, 6, 14
local LABEL_W = 120

---@type TILES.EFFECT[]
local effects = {}
for e = 0, TILES.EFFECT_COUNT - 1 do
    if TILEART.ANIMATION[e] or TILEART.SPECIAL[e] then effects[#effects + 1] = e end
end

local colW = LABEL_W + FRAMES * (SIZE + GAP) + 20
local w = colW * math.ceil(#effects / PER_COLUMN)
local h = PER_COLUMN * (SIZE + GAP) + GAP
local canvas = love.graphics.newCanvas(w, h)
love.graphics.setCanvas(canvas)
love.graphics.clear(0.11, 0.10, 0.09)
for i, e in ipairs(effects) do
    local col, row = math.floor((i - 1) / PER_COLUMN), (i - 1) % PER_COLUMN
    local x, y = col * colW + 6, row * (SIZE + GAP) + GAP
    UI.text(TILES.EffectName[e], x, y + SIZE / 2 - 8, 12, UI.COLOR.text, LABEL_W - 8)
    local tile = TILES.fromParts(e, TILES.arrowSet(TILES.UP, TILES.RIGHT))
    for f = 0, FRAMES - 1 do
        love.graphics.setColor(1, 1, 1)
        TILEART.draw(tile, x + LABEL_W + f * (SIZE + GAP), y, SIZE, f * 0.27)
    end
end
love.graphics.setCanvas()
canvas:newImageData():encode("png", "anim_sheet.png")
print(("%d animated chambers drawn to %s/anim_sheet.png"):format(#effects, love.filesystem.getSaveDirectory()))
