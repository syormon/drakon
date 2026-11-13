--drives the game view through every chamber choice with simulated clicks, checks each one
--worked, and saves a picture of some to the save folder (%APPDATA%\LOVE\drakon).
--love . --run tools/choicedemo.lua

local m = ...
local GAME, GAMEVIEW, TILES = m.game, m.gameview, m.tiles
local E = TILES.Effect
local U, R, _, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
local set = TILES.arrowSet
local TOP = 40

local failures = 0
---print a check and count failures
---@param name string
---@param cond any
local function check(name, cond)
    print((cond and "ok    " or "FAIL  ") .. name)
    if not cond then failures = failures + 1 end
end

---Ann (to play), Ben, Cat. Start (0,0) exits R, D, L; Map at (-1,0), One Gold at (0,1),
---and the chamber `effect` at (1,0), which Ann has just walked into.
---@param effect TILES.EFFECT
---@param gold? integer Ann's unlocked gold
---@return GAME.STATE s
---@return GAMEVIEW v
local function scenario(effect, gold)
    local cfg = GAME.newConfig()
    for _, n in ipairs({ "Ann", "Ben", "Cat" }) do GAME.addPlayer(cfg, n) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(1, 0, TILES.fromParts(effect, set(L)))
    s.board:set(-1, 0, TILES.fromParts(E.Map, set(R)))
    s.board:set(0, 1, TILES.fromParts(E.OneGold, set(U)))
    s.players[1].unlockedGold = gold or 0
    assert(GAME.movePlayer(s, 1, 0))
    local v = GAMEVIEW:new(s)
    return s, v
end

local canvas = love.graphics.newCanvas(love.graphics.getDimensions())
---draw the view to a canvas, and save it as choice_<save>.png if given
---@param v GAMEVIEW
---@param save? string
local function render(v, save)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.17, 0.15, 0.14)
    v:draw(TOP)
    love.graphics.setCanvas()
    if save then canvas:newImageData():encode("png", "choice_" .. save .. ".png") end
end
---click a board square
---@param v GAMEVIEW
---@param x integer
---@param y integer
local function clickSquare(v, x, y)
    render(v)
    local sx, sy = v:toScreen(x, y)
    v:mousepressed(sx + 10, sy + 10, 1)
end
---click a player's row in the panel
---@param v GAMEVIEW
---@param player GAME.PLAYER
local function clickPlayer(v, player)
    render(v)
    for _, r in ipairs(v.playerRects) do
        if r.player == player then v:mousepressed(love.graphics.getWidth() - 300, r.y1 + 5, 1) end
    end
end
---@param v GAMEVIEW|SETUPVIEW
---@return string
local function said(v) return v.message and v.message.text or "" end

do
    local s, v = scenario(E.Destroy)
    check("destroy offered", GAME.openChoice(s) == E.Destroy)
    clickSquare(v, -1, 0)
    check("destroy: " .. said(v), not s.board:has(-1, 0))
end

do
    local s, v = scenario(E.DrakonsBargain, 1)
    local map = s.board:get(-1, 0)
    clickSquare(v, -1, 0)
    local hand = s.players[1].hand.tiles
    check("bargain: " .. said(v), hand[#hand] == map and s.players[1].unlockedGold == 0)
end

do
    local s, v = scenario(E.MagicShift)
    local h = s.players[1].hand.tiles[1]
    h.kind = TILES.makeKind(E.TwoGold, set(L))
    render(v)
    local r = v.handRects[1]
    v:mousepressed(r.x + 5, r.y + 5, 1)
    render(v, "magicshift")
    clickSquare(v, -1, 0)
    check("magic shift: " .. said(v), s.board:get(-1, 0) == h)
end

do
    local s, v = scenario(E.MovingTiles)
    local map, gold = s.board:get(-1, 0), s.board:get(0, 1)
    clickSquare(v, -1, 0)
    render(v, "movingchambers")
    clickSquare(v, 0, 1)
    check("moving chambers: " .. said(v), s.board:get(0, 1) == map and s.board:get(-1, 0) == gold)
end

do
    local s, v = scenario(E.Rotate)
    clickSquare(v, -1, 0)
    v:keypressed("r"); v:keypressed("r")
    render(v, "rotate")
    clickSquare(v, -1, 0)
    check("rotate: " .. said(v), s.board:get(-1, 0):arrows() == set(L))
end

do
    local s, v = scenario(E.Map)
    clickPlayer(v, s.players[2])
    check("map: " .. said(v), #s.players[1].hand.tiles == 5 and #s.players[2].hand.tiles == 3)
end

do
    local s, v = scenario(E.MindOrb)
    local ben = s.players[2]
    clickPlayer(v, ben)
    render(v, "mindorb")
    clickSquare(v, -1, 0)
    check("mind orb: " .. said(v), ben.x == -1 and s.pendingActivePlayer == ben)
end

do
    local s, v = scenario(E.Float)
    v:keypressed("r"); v:keypressed("r")
    love.mouse.setPosition(0, 0)
    render(v, "float")
    clickSquare(v, 1, 1)
    local ann = s.players[1]
    check("floating room: " .. said(v), ann.x == 1 and ann.y == 1 and s.board:get(1, 1):effect() == E.Float)
end

do --placing Drakon for the first time, then moving him onto a hero
    local s, v = scenario(E.Empty)
    s.moved = false
    local dm = TILES.fromParts(E.DrakonMoves, set(U))
    s.players[1].hand.tiles[1] = dm
    s.players[1].x, s.players[1].y = 0, 0
    assert(GAME.placeTile(s, dm, 0, -1))
    render(v, "drakon_place")
    clickSquare(v, 0, 0)
    check("Drakon not onto heroes: " .. said(v), not s.drakonActive)
    clickSquare(v, -1, 0)
    check("Drakon placed: " .. said(v), s.drakonActive and s.drakonX == -1)

    local s2, v2 = scenario(E.DrakonMoves)
    s2.drakonActive, s2.drakonX, s2.drakonY = true, 0, 1
    s2.players[2].unlockedGold = 1
    render(v2, "drakon_move")
    clickSquare(v2, 0, 0)
    local ben = s2.players[2]
    check("Drakon attacks: " .. said(v2), s2.drakonX == 0 and s2.drakonY == 0 and ben.unlockedGold == 0)
end

do --stepping onto a just-placed Escape tile
    local s, v = scenario(E.Empty)
    s.moved = false
    local esc = TILES.fromParts(E.Escape, set(U))
    s.players[1].hand.tiles[1] = esc
    s.players[1].x, s.players[1].y = 0, 0
    assert(GAME.placeTile(s, esc, 0, -1))
    clickSquare(v, 0, -1)
    check("escape: " .. said(v), s.players[1].y == -1)
end

---hero abilities: Ann has the given hero, everyone on Start, Map at (-1,0), gold at (0,1)
---@param hero GAME.HERO
---@return GAME.STATE s
---@return GAMEVIEW v
local function heroScenario(hero)
    local cfg = GAME.newConfig()
    for _, n in ipairs({ "Ann", "Ben", "Cat" }) do GAME.addPlayer(cfg, n) end
    cfg.players[1].hero = hero
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(-1, 0, TILES.fromParts(E.OneGold, set(R)))
    s.board:set(0, 1, TILES.fromParts(E.Empty, set(U)))
    return s, GAMEVIEW:new(s)
end

do
    local s, v = heroScenario(GAME.Hero.Thief)
    local ben = s.players[2]
    ben.unlockedGold = 2
    v:keypressed("t")
    clickPlayer(v, ben)
    check("thief: " .. said(v), s.players[1].unlockedGold == 1 and ben.unlockedGold == 1)
end

do
    local s, v = heroScenario(GAME.Hero.Barbarian)
    local ben = s.players[2]
    v:keypressed("b")
    clickPlayer(v, ben)
    render(v, "barbarian")
    clickSquare(v, -1, 0)
    check("barbarian: " .. said(v), ben.x == -1 and #s.players[1].hand.tiles == 5)
end

do
    local s, v = heroScenario(GAME.Hero.Dwarf)
    v:keypressed("d")
    check("dwarf: " .. said(v), #s.players[1].hand.tiles == 6)
    v:keypressed("d")
    check("dwarf only once", #s.players[1].hand.tiles == 6)
end

do --Knight: robbed by a Thief, then takes the coin back
    local s, v = heroScenario(GAME.Hero.Thief)
    local ann, ben = s.players[1], s.players[2]
    ben.hero, ben.unlockedGold = GAME.Hero.Knight, 1
    ben.x = -1                               --Ben waits in the gold room; Ann walks in (+1)
    clickSquare(v, -1, 0)
    v:keypressed("t")
    clickPlayer(v, ben)
    check("knight's loss noted: " .. said(v), s.savedGoldState and s.savedGoldState.player == ben and ann.unlockedGold == 2)
    v:keypressed("return")                   --Ann finishes; the Knight decides next
    render(v, "knight")
    check("knight acts", s.activePlayer == ben and GAME.canKnightReclaim(s))
    v:keypressed("k")
    check("knight: " .. said(v), ben.unlockedGold == 1 and ann.unlockedGold == 1)
end

do --computer players take their turns from the screen's update, and ignore clicks
    local cfg = GAME.newConfig()
    for i, n in ipairs({ "Ann", "Ben", "Cat" }) do
        local pc = GAME.addPlayer(cfg, n)
        if i > 1 then pc.ai = (i == 2) and "greedy" or "random" end
    end
    local s = GAME.newGame(cfg, function(lo, hi) return love.math.random(lo, hi) end)
    local v = GAMEVIEW:new(s)
    s.turnPlayer = s.players[2]
    GAME.beginTurn(s)
    v:keypressed("return")
    check("keys ignored on a computer turn", s.activePlayer == s.players[2])
    v:update(0.1)
    check("waits a moment first", s.activePlayer == s.players[2])
    v:update(1)
    check("Ben played", s.activePlayer ~= s.players[2] and #v.log > 0)
    v:update(1)
    check("Cat played, now Ann: " .. said(v), s.activePlayer == s.players[1] and said(v):find("your turn"))
    render(v, "ai")
end

do --U takes back a move
    local s, v = scenario(E.Empty)
    local ann = s.players[1]
    v:keypressed("u")
    check("undo: " .. said(v), ann.x == 0 and ann.y == 0 and not s.moved)
    v:keypressed("u")
    check("nothing more to undo: " .. said(v), v.message.error)
end

do --G draws a tile with an empty hand (EmptyHand option)
    local s, v = heroScenario(GAME.Hero.None)
    s.config.options.emptyHand = true
    local ann = s.players[1]
    ann.hand.tiles, ann.hand.tileLimit = {}, 0
    v:keypressed("g")
    check("draw: " .. said(v), #ann.hand.tiles == 1 and s.placedTile)
end

do --separate team starts for four teams
    local cfg = GAME.newConfig()
    cfg.options.separateTeamStart = true
    for _, n in ipairs({ "Ann", "Ben", "Cat", "Dan" }) do GAME.addPlayer(cfg, n) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    local v = GAMEVIEW:new(s)
    render(v, "teamstarts")
    check("four team starts", s.board.count == 11 and s.players[4].x == 2 and s.players[4].y == 3)
end

do --Esc drops a pick
    local _, v = scenario(E.Rotate)
    clickSquare(v, -1, 0)
    check("pick made", v.pick ~= nil)
    check("Esc cancels", v:cancel() and v.pick == nil)
end

print(failures == 0 and "all choice checks passed" or (failures .. " failed"))
if failures > 0 then error("choice demo failed") end
