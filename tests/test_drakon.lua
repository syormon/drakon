--tests for Drakon and the Escape move (src/game.lua). Runs under plain Lua, from the Love
--folder:
--lua tests/test_drakon.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect
local U, R, _, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
local set = TILES.arrowSet

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
---check that got == want
---@param name string
---@param got any
---@param want any
local function eq(name, got, want)
    check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end
---a tile with these exits
---@param effect TILES.EFFECT
---@param ... TILES.DIRECTION
---@return TILES.TILE
local function tile(effect, ...) return TILES.fromParts(effect, set(...)) end

---Ann (to play), Ben, Cat, all on Start (0, 0). A row of rooms to the right: (1,0) .. (5,0).
---@return GAME.STATE s
---@return GAME.PLAYER ann
---@return GAME.PLAYER ben
---@return GAME.PLAYER cat
local function setup()
    local cfg = GAME.newConfig()
    for _, n in ipairs({ "Ann", "Ben", "Cat" }) do GAME.addPlayer(cfg, n) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    for x = 1, 5 do s.board:set(x, 0, tile(E.Empty, L, R)) end
    return s, s.players[1], s.players[2], s.players[3]
end

---Ann places the first Drakon Moves tile above Start.
---@param s GAME.STATE
local function placeDrakonMoves(s)
    local dm = tile(E.DrakonMoves, U)
    s.activePlayer.hand.tiles[1] = dm
    assert(GAME.placeTile(s, dm, 0, -1))
end

---------------------------------------------------------------------------- placing Drakon

do
    local s = setup()
    check("nothing owed at first", not GAME.mustPlaceDrakon(s) and not GAME.canMoveDrakonTo(s, 3, 0))
    placeDrakonMoves(s)
    check("Drakon owed", GAME.mustPlaceDrakon(s))
    check("can't finish before placing him", not GAME.canEndTurn(s))
    check("not where heroes are", not GAME.canMoveDrakonTo(s, 0, 0))
    check("not an empty square", not GAME.canMoveDrakonTo(s, 9, 9))
    check("any empty room, however far", GAME.canMoveDrakonTo(s, 5, 0))
    s.board:set(5, 0, tile(E.SmallRoom, L, U))
    check("not a Small Room", not GAME.canMoveDrakonTo(s, 5, 0))
    eq("legal spots: rooms without heroes, no small room", #GAME.legalDrakonMoves(s), 5)  --(1..4,0) and (0,-1)
    local r, err = GAME.moveDrakon(s, 9, 9)
    check("refused", not r and err == "This is not a valid Drakon move", err)
    r = assert(GAME.moveDrakon(s, 3, 0))
    check("placed", r and s.drakonActive and s.drakonX == 3 and s.drakonY == 0)
    eq("nobody attacked", #r.attacked, 0)
    eq("debt paid", s.tileEffect, E.Empty)
    check("can finish now", GAME.canEndTurn(s))
    check("can't move him again", not GAME.canMoveDrakonTo(s, 4, 0))
end

---------------------------------------------------------------------------- moving Drakon

do --entering a Drakon Moves room: Drakon may move up to 3 rooms, ignoring arrows
    local s = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 5, 0
    s.board:set(1, 0, tile(E.DrakonMoves, L))
    assert(GAME.movePlayer(s, 1, 0))
    eq("Drakon Moves waiting", s.tileEffect, E.DrakonMoves)
    check("optional once Drakon is out", GAME.canEndTurn(s))
    check("may stay put", GAME.canMoveDrakonTo(s, 5, 0))
    check("1 step", GAME.canMoveDrakonTo(s, 4, 0))
    check("3 steps", GAME.canMoveDrakonTo(s, 2, 0))
    check("not 4", not GAME.canMoveDrakonTo(s, 1, 0))
    --arrows don't matter: a room above (4,0) with no exits at all
    s.board:set(4, -1, tile(E.Empty))
    check("ignores arrows", GAME.canMoveDrakonTo(s, 4, -1))
    s.board:set(3, 0, tile(E.SmallRoom, L, U))
    check("not through a Small Room", not GAME.canMoveDrakonTo(s, 2, 0))
    s.board:set(3, -1, tile(E.Empty)); s.board:set(2, -1, tile(E.Empty))
    check("around it is too far", not GAME.canMoveDrakonTo(s, 2, 0))
    check("the way round reaches (3,-1) in 3", GAME.canMoveDrakonTo(s, 3, -1))
    check("but (2,-1) is 4 away", not GAME.canMoveDrakonTo(s, 2, -1))
end

do --Drakon attacks the heroes in the room he enters
    local s, ann, ben, cat = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 5, 0
    s.board:set(1, 0, tile(E.DrakonMoves, L, R))
    ben.x, ben.y, ben.unlockedGold, ben.lockedGold = 3, 0, 2, 1
    cat.x, cat.y, cat.unlockedGold = 3, 0, 0
    assert(GAME.movePlayer(s, 1, 0))
    local r = assert(GAME.moveDrakon(s, 3, 0))
    eq("two heroes attacked", #r.attacked, 2)
    check("sent to Start", ben.x == 0 and ben.y == 0 and cat.x == 0 and cat.y == 0)
    eq("Ben lost an unlocked coin", ben.unlockedGold, 1)
    eq("locked coins are safe", ben.lockedGold, 1)
    eq("Cat had nothing to lose", cat.unlockedGold, 0)
    check("no coins on Start to pick up", not r.pickedUp)
    check("Ann not attacked", ann.x == 1)
end

do --coins on Start are picked up only if there are enough for everyone attacked
    local s, _, ben, cat = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 5, 0
    s.board:set(1, 0, tile(E.DrakonMoves, L, R))
    ben.x, ben.y, cat.x, cat.y = 4, 0, 4, 0
    s.goldOnStart = 2
    assert(GAME.movePlayer(s, 1, 0))
    local r = assert(GAME.moveDrakon(s, 4, 0))
    check("picked up", r.pickedUp)
    eq("Ben +1", ben.unlockedGold, 1)
    eq("Cat +1", cat.unlockedGold, 1)
    eq("Start emptied", s.goldOnStart, 0)

    s, _, ben, cat = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 5, 0
    s.board:set(1, 0, tile(E.DrakonMoves, L, R))
    ben.x, ben.y, cat.x, cat.y = 4, 0, 4, 0
    s.goldOnStart = 1
    assert(GAME.movePlayer(s, 1, 0))
    r = assert(GAME.moveDrakon(s, 4, 0))
    check("not enough for both: nobody picks up", not r.pickedUp and s.goldOnStart == 1 and ben.unlockedGold == 0)
end

do --a hero walking into Drakon's room (already ported with moving) is still attacked
    local s, ann = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 1, 0
    local r = assert(GAME.movePlayer(s, 1, 0))
    check("attacked on entering", r.attacked and ann.x == 0)
end

do --placing a second Drakon Moves tile owes nothing
    local s = setup()
    s.drakonActive, s.drakonX, s.drakonY = true, 5, 0
    placeDrakonMoves(s)
    check("nothing owed", not GAME.mustPlaceDrakon(s))
end

---------------------------------------------------------------------------- Escape

do
    local s, ann = setup()
    local esc = tile(E.Escape, U)
    ann.hand.tiles[1] = esc
    check("not before placing", not GAME.canMoveToEscape(s))
    assert(GAME.placeTile(s, esc, 0, -1))
    check("may move onto it", GAME.canMoveToEscape(s))
    check("move", GAME.moveToEscape(s))
    check("on the escape tile", ann.x == 0 and ann.y == -1)
    eq("used", s.tileEffect, E.Empty)
    check("not again", not GAME.canMoveToEscape(s))
    local r, err = GAME.moveToEscape(s)
    check("refused", not r and err == "You cannot move to an escape tile now", err)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
