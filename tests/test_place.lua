--tests for placing tiles (src/game.lua). Runs under plain Lua, from the repository's top folder:
--lua tests/test_place.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect
local U, R, D, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
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

---a two-player game whose first player holds the given tiles. The Start tile is at (0, 0)
---with exits Right, Down and Left.
---@param handTiles? TILES.TILE[]
---@return GAME.STATE
local function setup(handTiles)
    local cfg = GAME.newConfig()
    GAME.addPlayer(cfg, "Ann")
    GAME.addPlayer(cfg, "Ben")
    local s = GAME.newGame(cfg, function(lo) return lo end)  --first player = Ann
    s.activePlayer.hand.tiles = handTiles or {}
    return s
end
---a tile with these exits
---@param effect TILES.EFFECT
---@param ... TILES.DIRECTION
---@return TILES.TILE
local function tile(effect, ...) return TILES.fromParts(effect, set(...)) end

---------------------------------------------------------------------------- placement rules

do
    local s = setup()
    local up = tile(E.Empty, U)
    eq("occupied square", GAME.placementError(s, up, 0, 0, up:arrows()), "A tile already exists here")
    eq("not adjacent", GAME.placementError(s, up, 2, 0, up:arrows()),
       "Tiles must be placed adjacent to at least one other tile")
    eq("diagonal is not adjacent", GAME.placementError(s, up, 1, 1, up:arrows()),
       "Tiles must be placed adjacent to at least one other tile")
    --right of Start: Start has an exit Right, so a Left exit there would face it
    eq("facing arrows", GAME.placementError(s, up, 1, 0, set(L)), "Arrows may not point at other arrows")
    eq("arrow away from Start", GAME.placementError(s, up, 1, 0, set(R)), nil)
    eq("no arrows next to an exit", GAME.placementError(s, up, 1, 0, 0), nil)
    --above Start: Start has no Up exit, so pointing down at its wall is allowed
    eq("arrow at a wall is fine", GAME.placementError(s, up, 0, -1, set(D)), nil)
    eq("below Start, pointing up", GAME.placementError(s, up, 0, 1, set(U)), "Arrows may not point at other arrows")
    --a tile re-checked where it stands (as when rotating) doesn't block itself
    local start = s.board:get(0, 0) --[[@as TILES.TILE]]
    eq("own square isn't occupied", GAME.placementError(s, start, 0, 0, start:arrows()) ~= "A tile already exists here", true)
end

---------------------------------------------------------------------------- legal placements

do
    local s = setup()
    --one exit: 4 orientations on each of the 4 squares around Start, minus the 3 that
    --face one of Start's exits
    eq("legal spots for a one-exit tile", #GAME.legalPlacements(s, tile(E.Empty, U)), 13)
    eq("legal spots for a no-exit tile", #GAME.legalPlacements(s, tile(E.Void)), 4)
    --two opposite exits only have 2 distinct orientations: Up+Down, Right+Left
    --right of Start, Right+Left faces Start: only Up+Down. Same on the left and below
    --(Up+Down faces Start's Down exit there, so only Right+Left). Above: both.
    eq("legal spots for an opposite-exit tile", #GAME.legalPlacements(s, tile(E.Empty, U, D)), 5)
    for _, p in ipairs(GAME.legalPlacements(s, tile(E.Map, U, R))) do
        local t = tile(E.Map, U, R)
        t:rotate(p.turns)
        if GAME.placementError(s, t, p.x, p.y, t:arrows()) then
            check("every listed placement is legal", false, p.x .. "," .. p.y .. " turns " .. p.turns)
        end
    end
end

---------------------------------------------------------------------------- placing

do
    local a, b = tile(E.Map, R), tile(E.Empty, U)
    local s = setup({ a, b })
    local ann = s.activePlayer --[[@as GAME.PLAYER]]
    check("can place at start of turn", GAME.canPlaceTile(s))
    local ok, err = GAME.placeTile(s, a, 1, 0)
    check("place", ok, err)
    check("on the board", s.board:get(1, 0) == a)
    eq("removed from hand", #ann.hand.tiles, 1)
    check("hand keeps the other tile", ann.hand.tiles[1] == b)
    check("placed flag", s.placedTile)
    eq("plain tile leaves no effect", s.tileEffect, E.Empty)
    ok, err = GAME.placeTile(s, b, -1, 0)
    check("only one placement per turn", not ok and err == "You cannot place a tile now", err)
end

do
    local a = tile(E.Map, R)
    local s = setup({ a })
    local ok, err = GAME.placeTile(s, tile(E.Map, R), 1, 0)
    check("tile not in hand", not ok and err == "You cannot place a tile that is not in your hand", err)
    ok, err = GAME.placeTile(s, a, 1, 0)
    check("illegal spot is refused before anything changes", ok)  --(1,0) with Right is legal
    local s2 = setup({ tile(E.Map, L) })
    ok, err = GAME.placeTile(s2, s2.activePlayer.hand.tiles[1], 1, 0)
    check("illegal placement refused", not ok and err == "Arrows may not point at other arrows", err)
    eq("refused tile stays in hand", #s2.activePlayer.hand.tiles, 1)
    check("refused placement leaves the turn open", not s2.placedTile)
end

do --conditions that block placing
    local s = setup({ tile(E.Map, R) })
    s.moved = true
    check("not after moving", not GAME.canPlaceTile(s))
    s = setup({ tile(E.Map, R) })
    s.activePlayer = s.players[2]
    s.activePlayer.hand.tiles = { tile(E.Map, R) }
    check("only the turn player", not GAME.canPlaceTile(s))
    s = setup({})
    check("not with an empty hand", not GAME.canPlaceTile(s))
    s = setup({ tile(E.Map, R) })
    s.activePlayer.x, s.activePlayer.y = nil, nil
    check("not while in the Void", not GAME.canPlaceTile(s))
    s = setup({ tile(E.Map, R) })
    s.pendingActivePlayer = s.players[2]
    check("not while another player has a decision", not GAME.canPlaceTile(s))
    s = setup({ tile(E.Map, R), tile(E.Map, R), tile(E.Map, R), tile(E.Map, R), tile(E.Map, R) })
    check("must discard first when over the hand limit", GAME.mustDiscard(s) and not GAME.canPlaceTile(s))
    s = setup({ tile(E.Map, R) })
    s.activePlayer = nil
    check("not when the game is over", GAME.isOver(s) and not GAME.canPlaceTile(s))
end

---------------------------------------------------------------------------- effects on placing

do
    local dm = tile(E.DrakonMoves, U, R)
    local s = setup({ dm })
    check("place Drakon Moves", GAME.placeTile(s, dm, 0, -1))
    eq("first Drakon Moves: must place Drakon", s.tileEffect, E.DrakonMoves)
    check("mustPlaceDrakon", GAME.mustPlaceDrakon(s))

    local dm2 = tile(E.DrakonMoves, U, R)
    local s2 = setup({ dm2 })
    s2.drakonActive = true
    check("place Drakon Moves again", GAME.placeTile(s2, dm2, 0, -1))
    eq("Drakon already out: nothing owed", s2.tileEffect, E.Empty)

    local esc = tile(E.Escape, U, R)
    local s3 = setup({ esc })
    check("place Escape", GAME.placeTile(s3, esc, 0, -1))
    eq("Escape: may move onto it", s3.tileEffect, E.Escape)
    check("escape location recorded", s3.escapeX == 0 and s3.escapeY == -1)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
