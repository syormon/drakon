--clicks the game screen's Finish turn (green, Enter), Undo (red, U) and Quit (Esc, asks first) buttons and checks
--what they do; saves buttons.png to the save folder.
--love . --run tools/buttondemo.lua

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
---the button of a kind, as drawn now
---@param v GAMEVIEW
---@param kind string
---@return table|nil
local function button(v, kind)
    render(v)
    for _, b in ipairs(v.buttonRects) do if b.kind == kind then return b end end
end
---click a button (if it was found)
---@param v GAMEVIEW
---@param b table|nil
local function click(v, b) if b then v:mousepressed(b.x + 10, b.y + 10, 1) end end

--Alice (a person) first, against a computer player
local cfg = SETUP.defaultConfig()
for i = #cfg.players, 3, -1 do table.remove(cfg.players, i) end
local s = GAME.newGame(cfg, GAME.newRandom(31))
while s.activePlayer ~= s.players[1] do GAME.endTurn(s, true) end
local v = GAMEVIEW:new(s)

local undo, finish = button(v, "cancel"), button(v, "confirm")
check("both buttons shown on alice's turn", undo and finish)
check("undo dimmed before anything is done", undo and not undo.enabled)
click(v, undo)
check("clicking dimmed undo does nothing", s.activePlayer == s.players[1] and not GAME.canUndo(s))

---place a tile with clicks
local function placeOne()
    render(v)
    for _, r in ipairs(v.handRects) do
        local opts = GAME.legalPlacements(s, r.tile)
        if #opts > 0 then
            v:mousepressed(r.x + 4, r.y + 4, 1)
            for _ = 1, opts[1].turns do v:keypressed("r") end
            render(v)
            local sx, sy = v:toScreen(opts[1].x, opts[1].y)
            v:mousepressed(sx + 6, sy + 6, 1)
            return
        end
    end
end
local handBefore = #s.players[1].hand.tiles
finish = button(v, "confirm")
check("finish dimmed before anything is done", finish and not finish.enabled)
placeOne()
check("a tile was placed", #s.players[1].hand.tiles == handBefore - 1)
undo = button(v, "cancel")
check("undo lit after placing", undo and undo.enabled)
render(v, "buttons")
click(v, undo)
check("the red button took the tile back", #s.players[1].hand.tiles == handBefore and v.message.text:find("Took back"))

--place again; finish: the green button passes the turn
placeOne()
finish = button(v, "confirm")
check("finish lit", finish and finish.enabled)
click(v, finish)
check("the green button finished alice's turn", s.activePlayer ~= s.players[1])
check("no buttons on the computer's turn", not button(v, "confirm"))

--Quit: shown whoever's turn it is; clicking it asks main.lua to quit
render(v, "buttons_quit")
local q = v.quitRect
check("quit button shown", q ~= nil)
---the dialog answer of a kind, as drawn now
---@param kind string
---@return table|nil
local function answer(kind)
    render(v)
    for _, r in ipairs(v.dialogRects) do if r.kind == kind then return r end end
end
if q then v:mousepressed(q.x + 5, q.y + 5, 1) end
check("quit asks first", v.confirmQuit and v.request == nil)
render(v, "quit_dialog")
local no = answer("no")
if no then v:mousepressed(no.x + 5, no.y + 5, 1) end
check("keep playing closes the question", not v.confirmQuit and v.request == nil)
v:askQuit()
v:keypressed("escape")
check("Esc closes the question", not v.confirmQuit and v.request == nil)
v:askQuit()
v:keypressed("n")
check("other keys do nothing while asking", v.confirmQuit and v.request == nil)
v:keypressed("return")
check("Enter confirms", not v.confirmQuit and v.request == "quit")
v.request = nil
v:askQuit()
local yes = answer("yes")
if yes then v:mousepressed(yes.x + 5, yes.y + 5, 1) end
check("the Quit game button confirms", v.request == "quit")

print(failures == 0 and "all button checks passed" or (failures .. " button checks FAILED"))
if failures > 0 then error("button checks failed") end
