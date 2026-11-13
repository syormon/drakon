--tests for the chamber choices (src/game.lua). Runs under plain Lua, from the repository's top folder:
--lua tests/test_chambers.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect
local U, R, D, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
local set = TILES.arrowSet
local unpack = table.unpack or unpack

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

---Ann (to play), Ben and Cat. Start at (0, 0) exits R, D, L. Ann has just entered the
---chamber `effect` at (1, 0); `layout` adds tiles { x, y, effect, arrows... }.
---@param effect TILES.EFFECT
---@param layout? table[]
---@return GAME.STATE s
---@return GAME.PLAYER ann
---@return GAME.PLAYER ben
---@return GAME.PLAYER cat
local function setup(effect, layout)
    local cfg = GAME.newConfig()
    for _, n in ipairs({ "Ann", "Ben", "Cat" }) do GAME.addPlayer(cfg, n) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(1, 0, tile(effect, L))
    for _, t in ipairs(layout or {}) do s.board:set(t[1], t[2], tile(t[3], unpack(t, 4))) end
    assert(GAME.movePlayer(s, 1, 0))
    return s, s.players[1], s.players[2], s.players[3]
end

---------------------------------------------------------------------------- Destroy

do
    local s = setup(E.Destroy, { { 0, 1, E.Empty, U, R }, { -1, 0, E.Map, R } })
    eq("destroy waiting", s.tileEffect, E.Destroy)
    check("can destroy", GAME.canDestroy(s))
    eq("open choice", GAME.openChoice(s), E.Destroy)
    local ok, err = GAME.destroyRoom(s, 0, 0)
    check("not occupied rooms (Start has heroes)", not ok and err == "You cannot destroy the Start room", err)
    ok, err = GAME.destroyRoom(s, 1, 0)
    check("not where Ann is", not ok and err == "You cannot destroy a room that is occupied", err)
    ok, err = GAME.destroyRoom(s, 5, 5)
    check("not an empty square", not ok and err == "There is no tile here", err)
    check("destroy", GAME.destroyRoom(s, -1, 0))
    check("gone", not s.board:has(-1, 0))
    eq("choice used", s.tileEffect, E.Empty)
    check("only once", not GAME.canDestroy(s))

    s = setup(E.Destroy, { { -1, 0, E.Map, R }, { -2, 0, E.Base, R } })
    ok, err = GAME.destroyRoom(s, -1, 0)
    check("next to a Base", not ok and (err or ""):find("^Base Structures"), err)
end

---------------------------------------------------------------------------- Drakon's Bargain

do
    local s = setup(E.DrakonsBargain, { { -1, 0, E.Map, R } })
    eq("no gold, no bargain", s.tileEffect, E.Empty)
end

do
    local cfg = GAME.newConfig()
    for _, n in ipairs({ "Ann", "Ben" }) do GAME.addPlayer(cfg, n) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    local ann = s.players[1]
    ann.unlockedGold = 2
    s.board:set(1, 0, tile(E.DrakonsBargain, L))
    s.board:set(-1, 0, tile(E.Map, R))
    assert(GAME.movePlayer(s, 1, 0))
    eq("bargain waiting", s.tileEffect, E.DrakonsBargain)
    check("can bargain", GAME.canBargain(s))
    local limit = ann.hand.tileLimit
    local ok, err = GAME.bargainRoom(s, 0, 0)
    check("not occupied Start", not ok and err == "You cannot buy a tile that has players or Drakon on it", err)
    local map = s.board:get(-1, 0)
    check("buy", GAME.bargainRoom(s, -1, 0))
    eq("paid a coin", ann.unlockedGold, 1)
    check("in hand", ann.hand.tiles[#ann.hand.tiles] == map)
    eq("hand limit raised", ann.hand.tileLimit, limit + 1)
    check("off the board", not s.board:has(-1, 0))
    check("no discard needed", not GAME.mustDiscard(s))
end

---------------------------------------------------------------------------- Magic Shift

do
    local s, ann = setup(E.MagicShift, { { -1, 0, E.Map, R } })
    check("can shift", GAME.canMagicShift(s))
    local h = tile(E.TwoGold, R)
    ann.hand.tiles[1] = h
    local old = s.board:get(-1, 0)
    local ok, err = GAME.magicShift(s, tile(E.TwoGold, R), -1, 0)
    check("must be from the hand", not ok and err == "You cannot place a tile that is not in your hand", err)
    h:rotate(2)  --now points left: away from Start, fine; pointing right would face Start's Left exit
    check("legal as turned", GAME.magicShiftError(s, h, -1, 0) == nil)
    h:rotate(2)
    eq("illegal as turned", GAME.magicShiftError(s, h, -1, 0), "Arrows may not point at other arrows")
    h:rotate(2)
    local limit = ann.hand.tileLimit
    check("shift", GAME.magicShift(s, h, -1, 0))
    check("hand tile on the board", s.board:get(-1, 0) == h)
    check("board tile in hand", ann.hand.tiles[#ann.hand.tiles] == old)
    eq("hand size kept", #ann.hand.tiles, 4)
    eq("limit unchanged", ann.hand.tileLimit, limit)
    local why = GAME.magicShiftError(s, ann.hand.tiles[1], 0, 0)
    eq("not Start", why, "You cannot swap the Start chamber")
end

---------------------------------------------------------------------------- Moving Chambers

do
    local s = setup(E.MovingTiles, { { -1, 0, E.Map, R }, { 0, 1, E.OneGold, U }, { 0, -1, E.Rotate, U, D } })
    check("can swap", GAME.canSwapRooms(s))
    local map = s.board:get(-1, 0) --[[@as TILES.TILE]]
        local gold = s.board:get(0, 1) --[[@as TILES.TILE]]
    eq("different styles refused", GAME.swapRoomsError(s, -1, 0, 0, -1), "You must select tiles with the same arrow configuration")
    eq("occupied refused", GAME.swapRoomsError(s, -1, 0, 1, 0), "You cannot swap a tile with players or Drakon on it")
    check("swap", GAME.swapRooms(s, -1, 0, 0, 1))
    check("map moved", s.board:get(0, 1) == map and map:arrows() == set(U))
    check("gold moved", s.board:get(-1, 0) == gold and gold:arrows() == set(R))
    eq("effects kept", map:effect(), E.Map)
end

---------------------------------------------------------------------------- Rotate

do
    local s = setup(E.Rotate, { { -1, 0, E.Map, R } })
    check("can rotate", GAME.canRotateRoom(s))
    --Ann's own room (1,0) has a Left exit facing Start's Right exit... as placed by the test;
    --turning it twice points it right, away from Start
    check("legal rotation", GAME.rotateRoomError(s, 1, 0, 2) == nil)
    --the Map at (-1,0) points right at Start (whose Left exit points back): turning it so is illegal
    eq("illegal rotation", GAME.rotateRoomError(s, -1, 0, 0), "Arrows may not point at other arrows")
    check("rotate occupied Start", GAME.rotateRoomError(s, 0, 0, 1) == nil
          or GAME.rotateRoomError(s, 0, 0, 1) == "Arrows may not point at other arrows")
    check("rotate", GAME.rotateRoom(s, -1, 0, 2))
    eq("turned", s.board:get(-1, 0):arrows(), set(L))
    eq("choice used", s.tileEffect, E.Empty)
end

---------------------------------------------------------------------------- Map

do
    local s, ann, ben = setup(E.Map)
    check("can steal", GAME.canMapSteal(s))
    local ok, err = GAME.mapSteal(s, ann)
    check("not from yourself", not ok and err == "You cannot steal a tile from yourself", err)
    local first = ben.hand.tiles[1]
    local t = GAME.mapSteal(s, ben)          --the test random picks index 1
    check("stole Ben's first tile", t == first)
    eq("Ben down a tile", #ben.hand.tiles, 3)
    eq("Ben's limit lowered", ben.hand.tileLimit, 3)
    eq("Ann up a tile", #ann.hand.tiles, 5)
    eq("Ann's limit raised", ann.hand.tileLimit, 5)
    check("in Ann's hand", ann.hand.tiles[5] == first)
    check("no discard", not GAME.mustDiscard(s))
    eq("choice used", s.tileEffect, E.Empty)
end

do --nobody else has tiles
    local s, _, ben, cat = setup(E.Map)
    ben.hand.tiles, cat.hand.tiles = {}, {}
    check("nothing to steal", not GAME.canMapSteal(s))
end

---------------------------------------------------------------------------- Mind Control Orb

do
    local s, ann, ben = setup(E.MindOrb, { { -1, 0, E.OneGold, R } })
    check("can use the orb", GAME.canMindOrb(s))
    local ok, err = GAME.moveOtherPlayer(s, ann, 0, 0)
    check("not yourself", not ok and err == "You must pick another player to move", err)
    ok, err = GAME.moveOtherPlayer(s, ben, 5, 5)
    check("only valid moves", not ok and err == "This is not a valid move", err)
    local r = GAME.moveOtherPlayer(s, ben, -1, 0)
    check("moved Ben", r and ben.x == -1 and ben.y == 0)
    eq("Ben got the gold", ben.unlockedGold, 1)
    eq("orb used", s.tileEffect, E.Empty)
    check("Ann still where she was", ann.x == 1)
end

do --moving a hero into a choice chamber hands that choice to its player
    local s, _, ben = setup(E.MindOrb, { { -1, 0, E.Rotate, R } })
    GAME.moveOtherPlayer(s, ben, -1, 0)
    check("Ben has a choice pending", s.pendingActivePlayer == ben)
    eq("rotate waiting", s.tileEffect, E.Rotate)
    GAME.endTurn(s, true)
    check("Ben acts", s.activePlayer == ben)
    check("Ben can rotate", GAME.canRotateRoom(s))
end

do --heroes in the Void can't be moved
    local s, _, ben, cat = setup(E.MindOrb)
    for _, p in ipairs({ ben, cat }) do p.x, p.y = nil, nil end
    check("nobody to move", not GAME.canMindOrb(s))
end

---------------------------------------------------------------------------- Floating Room

do
    local s, ann, ben = setup(E.Float, { { -1, 0, E.Empty, R } })
    ben.x, ben.y = 1, 0
    check("can float", GAME.canFloat(s))
    local fl = s.board:get(1, 0)
    eq("must change something", GAME.floatError(s, 1, 0, 0), "The room hasn't moved")
    eq("not onto a room", GAME.floatError(s, -1, 0, 0), "You cannot move the Floating Room onto another room")
    --(0,1) below Start: the room's Left exit would be fine; turned to point up it'd face Start's Down
    check("legal spot", GAME.floatError(s, 0, 1, 0) == nil)
    eq("illegal turn", GAME.floatError(s, 0, 1, 1), "Arrows may not point at other arrows")
    check("float", GAME.floatRoom(s, 0, 1, 0))
    check("moved", s.board:get(0, 1) == fl and not s.board:has(1, 0))
    check("heroes ride along", ann.x == 0 and ann.y == 1 and ben.x == 0 and ben.y == 1)
    eq("choice used", s.tileEffect, E.Empty)
end

do --turning in place
    local s = setup(E.Float)
    check("turn in place", GAME.floatRoom(s, 1, 0, 2))
    eq("turned", s.board:get(1, 0):arrows(), set(R))
end

do --next to a Base, the room doesn't float at all
    local s = setup(E.Float, { { 2, 0, E.Base, L } })
    eq("protected: no float", s.tileEffect, E.Empty)
end

---------------------------------------------------------------------------- skipping a choice

do
    local s = setup(E.Destroy, { { -1, 0, E.Map, R } })
    check("a choice can be skipped by finishing", GAME.canEndTurn(s))
    GAME.endTurn(s)
    check("next player", s.activePlayer == s.players[2])
    eq("choice gone", s.tileEffect, E.Empty)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
