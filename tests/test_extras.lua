--tests for undo, the SeparateTeamStart dungeons and the EmptyHand draw (src/game.lua).
--runs under plain Lua, from the repository's top folder:
--lua tests/test_extras.lua

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

---a game of n players (Ann, Ben...) with these options
---@param n? integer default 3
---@param options? table
---@return GAME.STATE
---@return GAME.CONFIG
local function setup(n, options)
    local cfg = GAME.newConfig()
    for k, v in pairs(options or {}) do cfg.options[k] = v end
    for i = 1, n or 3 do GAME.addPlayer(cfg, ({ "Ann", "Ben", "Cat", "Dan", "Eve", "Fay" })[i]) end
    return GAME.newGame(cfg, function(lo) return lo end), cfg
end

---------------------------------------------------------------------------- separate team starts

for teams = 2, 6 do
    local s = setup(teams, { separateTeamStart = true })
    local layout = GAME.TEAM_STARTS[teams]
    eq(teams .. " teams: rooms built", s.board.count, 1 + #layout.rooms)
    check(teams .. " teams: Start still at (0,0)", s.board:get(0, 0):effect() == E.Start)
    for i, p in ipairs(s.players) do
        local sq = layout.starts[i]
        check(("%d teams: %s on their start"):format(teams, p.name), p.x == sq[1] and p.y == sq[2])
        check(("%d teams: %s's start is a room"):format(teams, p.name), s.board:has(p.x, p.y))
    end
    --the dungeon is legal: no exit faces another exit
    local facing = 0
    for x, y, t in s.board:each() do
        for d = 0, 3 do
            local o = s.board:get(TILES.neighbor(x, y, d))
            if o and t:hasExit(d) and o:hasExit(TILES.opposite(d)) then facing = facing + 1 end
        end
    end
    eq(teams .. " teams: no facing exits", facing, 0)
end

do --players sharing a team share a start; one team or seven get nothing special
    local cfg = GAME.newConfig()
    cfg.options.separateTeamStart = true
    local a = GAME.addPlayer(cfg, "Ann")
    local b = GAME.addPlayer(cfg, "Ben")
    GAME.addPlayer(cfg, "Cat")
    b.team = a.team
    local s = GAME.newGame(cfg, function(lo) return lo end)
    check("team of two together", s.players[1].x == s.players[2].x and s.players[1].y == s.players[2].y)
    check("two teams: second team apart", s.players[3].x == 2)

    local s1 = setup(1, { separateTeamStart = true })
    eq("one team: just Start", s1.board.count, 1)
    local cfg7 = GAME.newConfig()
    cfg7.options.separateTeamStart = true
    for i = 1, 7 do GAME.addPlayer(cfg7, "P" .. i) end
    local s7 = GAME.newGame(cfg7, function(lo) return lo end)
    eq("seven teams: just Start", s7.board.count, 1)
end

do --with 2 teams both start rooms open onto empty squares: the first action is a placement
    local s = setup(2, { separateTeamStart = true })
    check("can place from a team start", GAME.canPlaceTile(s) and not GAME.canMoveNow(s))
end

---------------------------------------------------------------------------- EmptyHand draw

do
    local s = setup(2)
    local ann = s.players[1]
    ann.hand.tiles, ann.hand.tileLimit = {}, 0
    check("needs the option", not GAME.canDrawTileAction(s))
    s.config.options.emptyHand = true
    check("empty hand, no limit: may draw", GAME.canDrawTileAction(s))
    local drawn = GAME.drawTileAction(s)
    eq("one tile", drawn and #drawn, 1)
    eq("limit raised to one", ann.hand.tileLimit, 1)
    check("counts as placing", s.placedTile and not GAME.canPlaceTile(s) and not GAME.canMoveNow(s))
    check("may finish", GAME.canEndTurn(s))
    check("no undo past a draw", not GAME.canUndo(s))

    local s2 = setup(2, { emptyHand = true })
    check("not with tiles in hand", not GAME.canDrawTileAction(s2))
    s2.players[1].hand.tiles = {}
    check("not with a limit left (refilled at turn end)", not GAME.canDrawTileAction(s2))
    local s3 = setup(2, { emptyHand = true })
    s3.players[1].hand.tiles, s3.players[1].hand.tileLimit = {}, 0
    s3.moved = true
    check("not after moving", not GAME.canDrawTileAction(s3))
    local r, err = GAME.drawTileAction(s3)
    check("refused", not r and err == "You cannot draw a tile now", err)
end

---------------------------------------------------------------------------- undo

do --undo a move, then a placement
    local s = setup(2)
    local ann = s.players[1]
    s.board:set(1, 0, tile(E.OneGold, L, R))
    check("nothing to undo yet", not GAME.canUndo(s))
    assert(GAME.movePlayer(s, 1, 0))
    eq("gold", ann.unlockedGold, 1)
    check("can undo", GAME.canUndo(s))
    check("undo", GAME.undo(s))
    check("back on Start", ann.x == 0 and ann.y == 0)
    eq("gold gone", ann.unlockedGold, 0)
    check("may move again", not s.moved and GAME.canMoveNow(s))
    check("same player table", s.players[1] == ann and s.activePlayer == ann)
    check("nothing more to undo", not GAME.canUndo(s))

    local t = ann.hand.tiles[1]
    local spot = GAME.legalPlacements(s, t)[1]
    t:rotate(spot.turns)
    local count = s.board.count
    assert(GAME.placeTile(s, t, spot.x, spot.y))
    GAME.undo(s)
    eq("placement undone", s.board.count, count)
    eq("tile back in hand", #ann.hand.tiles, 4)
    check("same hand table", s.players[1].hand == ann.hand)
end

do --step by step through several actions in one turn
    local s = setup(2)
    local ann = s.players[1]
    ann.hero = GAME.Hero.Amazon
    s.board:set(1, 0, tile(E.OneGold, L, R))
    s.board:set(2, 0, tile(E.TwoGold, L))
    assert(GAME.movePlayer(s, 1, 0))
    assert(GAME.movePlayer(s, 2, 0))   --the Amazon's second move
    eq("3 gold", ann.unlockedGold, 3)
    GAME.undo(s)
    check("back to after the first move", ann.x == 1 and ann.unlockedGold == 1 and not ann.usedHero)
    GAME.undo(s)
    check("back to the start of the turn", ann.x == 0 and ann.unlockedGold == 0)
end

do --a Drakon placement and a chamber choice can be undone
    local s = setup(2)
    local dm = tile(E.DrakonMoves, U)
    s.players[1].hand.tiles[1] = dm
    assert(GAME.placeTile(s, dm, 0, -1))
    assert(GAME.moveDrakon(s, 0, -1))
    GAME.undo(s)
    check("Drakon taken back", not s.drakonActive and GAME.mustPlaceDrakon(s))
    GAME.undo(s)
    check("tile taken back", not s.board:has(0, -1))
end

do --passing play on clears undo; so does seeing a hidden tile
    local s = setup(2)
    s.board:set(1, 0, tile(E.Empty, L))
    assert(GAME.movePlayer(s, 1, 0))
    GAME.endTurn(s)
    check("no undo into the previous player's turn", not GAME.canUndo(s))

    local s2 = setup(2)
    s2.board:set(1, 0, tile(E.Map, L))
    assert(GAME.movePlayer(s2, 1, 0))
    check("can undo the move", GAME.canUndo(s2))
    assert(GAME.mapSteal(s2, s2.players[2]))
    check("not after a Map steal", not GAME.canUndo(s2))
end

do --the AI's trial copies keep no undo points (and copies carry none)
    local s = setup(2)
    s.board:set(1, 0, tile(E.Empty, L))
    assert(GAME.movePlayer(s, 1, 0))
    local c = GAME.cloneState(s)
    check("copy has no undo chain", c.savedState == nil)
    c.noUndo = true
    local _ = (c.activePlayer --[[@as GAME.PLAYER]]).hand.tiles[1]
    check("copy stays without undo points", c.savedState == nil)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
