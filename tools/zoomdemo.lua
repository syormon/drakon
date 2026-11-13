--zooms and drags the game board (+ / -, the wheel, 0, dragging) and checks that the board
--stays where it should and clicks still land on the right squares; saves zoom_*.png to the
--save folder.
--love . --run tools/zoomdemo.lua

local m = ...
local GAME, SETUP, GAMEVIEW = m.game, m.setup, m.gameview
local TOP = 40

local failures = 0
---print a check and count failures
---@param name string
---@param cond any
local function check(name, cond)
    print((cond and "ok    " or "FAIL  ") .. name)
    if not cond then failures = failures + 1 end
end

local canvas = love.graphics.newCanvas(love.graphics.getDimensions())
---draw the view (laying it out for clicks), and save it if named
---@param v GAMEVIEW
---@param save? string
local function render(v, save)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.11, 0.10, 0.09)
    v:draw(TOP)
    love.graphics.setCanvas()
    if save then canvas:newImageData():encode("png", save .. ".png") end
end

--Alice (a person) against a computer player, with a few rooms on the board
local cfg = SETUP.defaultConfig()
for i = #cfg.players, 3, -1 do table.remove(cfg.players, i) end
local s = GAME.newGame(cfg, GAME.newRandom(5))
for _ = 1, 12 do
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    for _, t in ipairs(p.hand.tiles) do
        local opts = GAME.legalPlacements(s, t)
        if #opts > 0 then
            t:rotate(opts[1].turns)
            GAME.placeTile(s, t, opts[1].x, opts[1].y)
            break
        end
    end
    GAME.endTurn(s, true)
end
while s.activePlayer ~= s.players[1] do GAME.endTurn(s, true) end
local v = GAMEVIEW:new(s)
render(v, "zoom_fit")
local fit = v.layout --[[@as GAMEVIEW.LAYOUT]]
check("starts fitted to the window", v.zoom == nil and fit.size >= 32)

--zoom in at the middle of the board area: the square under that point stays under it
local cx, cy = fit.left + fit.width / 2, fit.top + fit.height / 2
local gx, gy = v:toGrid(cx, cy)
v:keypressed("=")
render(v)
local l = v.layout --[[@as GAMEVIEW.LAYOUT]]
check("+ zooms in a step", v.zoom and l.size > fit.size)
local hx, hy = v:toGrid(cx, cy)
check("the square in the middle stays in the middle", hx == gx and hy == gy)

--all the way in, then past the end: nothing more happens
for _ = 1, 5 do v:keypressed("=") end
render(v, "zoom_in")
l = v.layout --[[@as GAMEVIEW.LAYOUT]]
check("zooms in as far as 256 pixels", l.size == 256)
check("the board is bigger than its area now", (l.maxX - l.minX + 1) * 256 > l.width)

--the board is cut off at its area: nothing outside it counts as a square
check("no square under the side panel", v:toGrid(l.left + l.width + 5, cy) == nil)
check("no square under the message bar", v:toGrid(cx, l.top + l.height + 5) == nil)

--drag with the left button: a small wobble isn't a drag, a longer pull moves the board
local ox, oy = l.ox, l.oy
local fakeDown = true
local realIsDown = love.mouse.isDown
---@diagnostic disable-next-line: duplicate-set-field
love.mouse.isDown = function() return fakeDown end
v:mousepressed(cx, cy, 1)
v:mousemoved(cx + 3, cy, 3, 0)
render(v)
check("a 3-pixel wobble doesn't move the board", v.layout.ox == ox)
v:mousemoved(cx - 200, cy - 150, -203, -150)
render(v)
check("dragging moves the board", v.layout.ox < ox and v.layout.oy < oy)
--dragging far past the edge stops with the board's edge in view
v:mousemoved(cx - 20000, cy - 20000, -19800, -19850)
render(v, "zoom_dragged")
l = v.layout --[[@as GAMEVIEW.LAYOUT]]
local right = l.ox + (l.maxX - l.minX + 1) * l.size
local bottom = l.oy + (l.maxY - l.minY + 1) * l.size
check("the board's right edge stays in view", right >= l.left + l.width - 10 and right <= l.left + l.width)
check("and its bottom edge", bottom >= l.top + l.height - 10 and bottom <= l.top + l.height)
v:mousereleased(1)
fakeDown = false
v:mousemoved(cx, cy, 0, 0)
check("letting go ends the drag", v.drag == nil)
love.mouse.isDown = realIsDown

--a click on a square still finds that square: toScreen and toGrid agree when zoomed
local ok = true
for x, y in s.board:each() do
    local sx, sy = v:toScreen(x, y)
    if v:onBoard(sx + 5, sy + 5) then
        local bx, by = v:toGrid(sx + l.size / 2, sy + l.size / 2)
        if bx ~= x or by ~= y then ok = false end
    end
end
check("every visible room is found under its own pixels", ok)

--placing by clicking still works when zoomed in: click a hand tile, then a green square
v:zoomFit()
render(v)
v:keypressed("=")
render(v)
local placed = false
for _, r in ipairs(v.handRects) do
    for _, p in ipairs(GAME.legalPlacements(s, r.tile)) do
        local sx, sy = v:toScreen(p.x, p.y)
        local px, py = sx + v.layout.size / 2, sy + v.layout.size / 2
        if not placed and p.turns == 0 and v:onBoard(px, py) then
            v:mousepressed(r.x + 10, r.y + 10, 1)
            render(v)
            v:mousepressed(px, py, 1)
            v:mousereleased(1)
            check("a click on a green square places the tile, zoomed in", s.board:get(p.x, p.y) == r.tile)
            placed = true
        end
    end
end
check("found a tile to place on screen (for the click check)", placed)

--zoom out below the fitted size, and back to fitting with 0
v:keypressed("0")
render(v)
check("0 fits the board again", v.zoom == nil and v.layout.size == fit.size and v.panX == 0 and v.panY == 0)
for _ = 1, 5 do v:keypressed("-") end
render(v, "zoom_out")
check("- zooms out as far as 16 pixels", v.layout.size == 16)

--the wheel zooms when there is nothing to turn, and turns a selected tile otherwise
v:keypressed("0")
render(v)
local before = v.layout.size
v:wheelmoved(1)
render(v)
check("the wheel zooms with nothing selected", v.layout.size > before)
--(a tile that looks different turned: not one with four exits or none)
for _, t in ipairs(s.players[1].hand.tiles) do
    if m.tiles.rotateKind(t.kind, 1) ~= t.kind then v.selected = t end
end
local kind = v.selected.kind
local size = v.layout.size
v:wheelmoved(1)
render(v)
check("the wheel turns a selected tile instead", v.selected.kind ~= kind and v.layout.size == size)

--the - / + / Fit buttons in the board's top-right corner
v.selected = nil
v:keypressed("0")
render(v)
---click the zoom button with this label
---@param label string
local function press(label)
    for _, r in ipairs(v.zoomRects) do
        if r.label == label then v:mousepressed(r.x + r.w / 2, r.y + r.h / 2, 1); v:mousereleased(1) end
    end
    render(v)
end
before = v.layout.size
check("the board shows - and + buttons", #v.zoomRects == 2 and v.zoomRects[2].label == "+")
press("+")
check("the + button zooms in", v.layout.size > before)
check("and a Fit button shows up", #v.zoomRects == 3 and v.zoomRects[3].label == "Fit")
local r1 = v.zoomRects[1]
check("no square under the buttons", v:toGrid(r1.x + 2, r1.y + 2) == nil)
press("+")
render(v, "zoom_buttons")
local zoomed = v.layout.size
press("-")
check("the - button zooms out", v.layout.size < zoomed)
press("Fit")
check("Fit fits the board again", v.zoom == nil and v.layout.size == fit.size)

--a close look at the Start room, where the heroes are
v.selected = nil
v:keypressed("0")
render(v)
local sx, sy = v:toScreen(0, 0)
for _ = 1, 4 do v:zoomBy(1, sx + v.layout.size / 2, sy + v.layout.size / 2); sx, sy = v:toScreen(0, 0) end
render(v, "zoom_start")
check("zooming at the Start room keeps it in view", v:onBoard(sx + v.layout.size / 2, sy + v.layout.size / 2))

if failures == 0 then print("all zoom checks passed") else print(failures .. " zoom checks FAILED") end
print("pictures saved to " .. love.filesystem.getSaveDirectory())
if failures > 0 then error(failures .. " zoom checks failed") end
