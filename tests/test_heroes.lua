--tests for the Thief, Barbarian, Knight and Dwarf abilities (src/game.lua). Runs under plain
--Lua, from the repository's top folder:
--lua tests/test_heroes.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect
local H = GAME.Hero
local _, R, _, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
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

---Ann (to play), Ben, Cat with the given heroes, all on Start (0, 0) (exits R, D, L).
---rooms: (1,0) Empty [L, R], (-1,0) One Gold [R].
---@param heroes GAME.HERO[]
---@return GAME.STATE s
---@return GAME.PLAYER ann
---@return GAME.PLAYER ben
---@return GAME.PLAYER cat
local function setup(heroes)
    local cfg = GAME.newConfig()
    for i, n in ipairs({ "Ann", "Ben", "Cat" }) do GAME.addPlayer(cfg, n).hero = heroes[i] or H.None end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(1, 0, tile(E.Empty, L, R))
    s.board:set(-1, 0, tile(E.OneGold, R))
    return s, s.players[1], s.players[2], s.players[3]
end

---------------------------------------------------------------------------- Thief

do
    local s, ann, ben, cat = setup({ H.Thief })
    check("nobody with gold", not GAME.canThiefSteal(s))
    ben.unlockedGold = 2
    check("can steal", GAME.canThiefSteal(s))
    local ok, err = GAME.thiefSteal(s, cat)
    check("not from someone without gold", not ok and err == "You cannot steal gold from a player with no gold", err)
    ben.x = 1
    check("must share the room", not GAME.canThiefSteal(s))
    ben.x = 0
    check("steal", GAME.thiefSteal(s, ben))
    eq("Ann +1", ann.unlockedGold, 1)
    eq("Ben -1", ben.unlockedGold, 1)
    check("ability used", ann.usedHero and not GAME.canThiefSteal(s))
    check("doesn't use up the turn", GAME.canMoveNow(s))

    s, ann, ben = setup({ H.Thief })
    s.config.options.stealAsLocked = true
    ben.unlockedGold = 1
    GAME.thiefSteal(s, ben)
    eq("stolen as locked", ann.lockedGold, 1)

    s, ann, ben = setup({ H.Knight })
    ben.unlockedGold = 1
    check("not without the Thief", not GAME.canThiefSteal(s))
end

---------------------------------------------------------------------------- Barbarian

do
    local s, ann, ben = setup({ H.Barbarian })
    check("can push", GAME.canBarbarianPush(s))
    local ok, err = GAME.barbarianPush(s, ann, 1, 0)
    check("not yourself", not ok and err == "You cannot push yourself", err)
    ok, err = GAME.barbarianPush(s, ben, 5, 5)
    check("only valid moves", not ok and err == "This is not a valid move", err)
    eq("refused push leaves nothing behind", s.tileEffect, E.Empty)
    local first = ben.hand.tiles[1]
    local r = assert(GAME.barbarianPush(s, ben, -1, 0))
    check("pushed", r and ben.x == -1 and ben.y == 0)
    eq("Ben entered the gold room", ben.unlockedGold, 1)
    check("took a tile from Ben", r.tookTile == first and #ben.hand.tiles == 3 and #ann.hand.tiles == 5)
    eq("limits shift", ann.hand.tileLimit, 5)
    check("ability used", ann.usedHero)
    check("counts as the turn's action", s.pushedHero and GAME.canEndTurn(s))
    check("as in the original, pushing doesn't stop placing", GAME.canPlaceTile(s))

    local cat
    s, ann, ben, cat = setup({ H.Barbarian })
    ben.x, cat.x = 1, 1
    check("nobody in the room", not GAME.canBarbarianPush(s))
end

---------------------------------------------------------------------------- Knight

do --a Knight robbed by a Steal room takes the coin back from the thief
    local s, ann, ben = setup({ H.None, H.Knight })
    s.board:set(1, 0, tile(E.StealLeft, L))      --left of Ann is Ben
    ben.unlockedGold = 1
    assert(GAME.movePlayer(s, 1, 0))
    eq("Ann stole", ann.unlockedGold, 1)
    check("loss recorded", s.savedGoldState and s.savedGoldState.player == ben and s.savedGoldState.lostTo == ann)
    check("Ben decides next", s.pendingActivePlayer == ben)
    check("Ann can still finish", GAME.canEndTurn(s))
    GAME.endTurn(s)
    check("Ben acts", s.activePlayer == ben and s.turnPlayer == ann)
    check("can reclaim", GAME.canKnightReclaim(s))
    check("reclaim", GAME.knightReclaim(s))
    eq("Ben has it back", ben.unlockedGold, 1)
    eq("Ann gives it back", ann.unlockedGold, 0)
    check("ability used", ben.usedHero)
    check("record cleared", s.savedGoldState == nil)
end

do --coins lost to Drakon's Due come back off the Start chamber
    local s, ann = setup({ H.Knight })
    s.board:set(1, 0, tile(E.DrakonsDue, L))
    ann.unlockedGold = 1
    assert(GAME.movePlayer(s, 1, 0))
    eq("paid onto Start", s.goldOnStart, 1)
    check("the Knight herself decides, after finishing", s.pendingActivePlayer == ann and not GAME.canKnightReclaim(s))
    GAME.endTurn(s)
    check("then Ann can reclaim", s.activePlayer == ann and GAME.canKnightReclaim(s))
    GAME.knightReclaim(s)
    check("back from Start", ann.unlockedGold == 1 and s.goldOnStart == 0)
end

do --a coin lost to a Wishing Well comes back from nowhere; declining lets it go
    local s, ann = setup({ H.Knight })
    s.board:set(1, 0, tile(E.WishingWell, L))
    ann.unlockedGold = 1
    assert(GAME.movePlayer(s, 1, 0))
    GAME.endTurn(s)
    check("decline", GAME.knightDecline(s))
    check("record cleared", s.savedGoldState == nil and ann.unlockedGold == 0 and not ann.usedHero)
end

do --an already-used Knight, or another hero, isn't asked
    local s, ann = setup({ H.Knight })
    ann.usedHero = true
    s.board:set(1, 0, tile(E.WishingWell, L))
    ann.unlockedGold = 1
    assert(GAME.movePlayer(s, 1, 0))
    check("no record", s.savedGoldState == nil and s.pendingActivePlayer == nil)
end

do --Drakon attacking a Knight records the loss too
    local s, _, ben = setup({ H.None, H.Knight })
    ben.x, ben.unlockedGold = 1, 1
    s.board:set(-1, 0, tile(E.DrakonMoves, R))
    s.drakonActive, s.drakonX, s.drakonY = true, 2, 0
    s.board:set(2, 0, tile(E.Empty, L))
    assert(GAME.movePlayer(s, -1, 0))
    GAME.moveDrakon(s, 1, 0)
    check("Ben's loss recorded", s.savedGoldState and s.savedGoldState.player == ben and ben.unlockedGold == 0)
end

do --(fix) a Thief robbing a Knight before moving can still move, and the Knight is asked after
    local s, ann, ben = setup({ H.Thief, H.Knight })
    ben.unlockedGold = 1
    assert(GAME.thiefSteal(s, ben))
    check("loss recorded", s.savedGoldState and s.savedGoldState.player == ben)
    check("Thief not blocked", s.pendingActivePlayer == nil and GAME.canMoveNow(s))
    assert(GAME.movePlayer(s, 1, 0))
    check("Knight decides once the Thief's move is done", s.pendingActivePlayer == ben)
    GAME.endTurn(s)
    check("Ben acts", s.activePlayer == ben and GAME.canKnightReclaim(s))
    GAME.knightReclaim(s)
    check("coin back", ben.unlockedGold == 1 and ann.unlockedGold == 0)

    s, ann, ben = setup({ H.Thief, H.Knight })
    ben.unlockedGold = 1
    GAME.thiefSteal(s, ben)
    s.board:set(1, 0, nil)                    --nowhere to move: place instead
    local t = ann.hand.tiles[1]
    local spot = GAME.legalPlacements(s, t)[1]
    t:rotate(spot.turns)
    assert(GAME.placeTile(s, t, spot.x, spot.y))
    GAME.endTurn(s)
    check("after placing, the Knight is asked at the end of the action", s.activePlayer == ben and GAME.canKnightReclaim(s))
end

---------------------------------------------------------------------------- Dwarf

do
    local s, ann = setup({ H.Dwarf })
    check("can draw", GAME.canDwarfDraw(s))
    table.remove(ann.hand.tiles)               --3 in hand
    local drawn = GAME.dwarfDraw(s)
    eq("filled, then two more", #drawn, 3)
    eq("hand", #ann.hand.tiles, 6)
    eq("limit raised by two", ann.hand.tileLimit, 6)
    check("no discard due", not GAME.mustDiscard(s))
    check("used up (fixed: the original let it repeat)", ann.usedHero and not GAME.canDwarfDraw(s))
    check("and it isn't the turn's action", not GAME.canEndTurn(s))
end

---------------------------------------------------------------------------- turn passing

do --a player whose only option is an ability still gets their turn
    local s, ann, ben = setup({ H.None, H.Thief })
    s.board = require('src.board'):new()
    s.board:set(0, 0, tile(E.Start))           --nowhere to move
    for _, p in ipairs(s.players) do p.hand = { tileLimit = 0, tiles = {}, name = p.name } end
    ann.unlockedGold = 1
    GAME.endTurn(s, true)
    check("Ben (Thief) plays", s.activePlayer == ben and GAME.canThiefSteal(s))
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
