--tests for ending a turn (src/game.lua). Runs under plain Lua, from the repository's top folder:
--lua tests/test_turn.lua

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

---Ann, Ben, Cat; Ann to play. Rooms right and left of Start so everyone can move.
---@param n? integer players, default 3
---@return GAME.STATE
local function setup(n)
    local cfg = GAME.newConfig()
    local names = { "Ann", "Ben", "Cat", "Dan" }
    for i = 1, n or 3 do GAME.addPlayer(cfg, names[i]) end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(1, 0, TILES.fromParts(E.Empty, set(L)))
    s.board:set(-1, 0, TILES.fromParts(E.Empty, set(R)))
    return s
end
---a tile with these exits
---@param effect TILES.EFFECT
---@param ... TILES.DIRECTION
---@return TILES.TILE
local function tile(effect, ...) return TILES.fromParts(effect, set(...)) end

---------------------------------------------------------------------------- when a turn can end

do
    local s = setup()
    check("not before doing anything", not GAME.canEndTurn(s))
    local r, err = GAME.endTurn(s)
    check("refused", not r and err == "You cannot finish an action right now", err)
    check("forced end is allowed", GAME.endTurn(s, true))
    s = setup()
    GAME.movePlayer(s, 1, 0)
    check("after moving", GAME.canEndTurn(s))
    s = setup()
    local t = s.activePlayer.hand.tiles[1]
    local spot = GAME.legalPlacements(s, t)[1]
    t:rotate(spot.turns)
    GAME.placeTile(s, t, spot.x, spot.y)
    check("after placing", GAME.canEndTurn(s))
    s = setup()
    s.pushedHero = true
    check("after pushing a hero", GAME.canEndTurn(s))
    s = setup()
    s.activePlayer = s.players[2]
    check("acting out of turn needs nothing done", GAME.canEndTurn(s))
    s = setup()
    s.moved = true
    s.activePlayer.hand.tiles[5] = tile(E.Map, U)
    check("not while over the hand limit", not GAME.canEndTurn(s))
    s = setup()
    s.moved, s.tileEffect = true, E.DrakonMoves
    check("not with Drakon to place", not GAME.canEndTurn(s))
    s.drakonActive = true
    check("Drakon already out", GAME.canEndTurn(s))
    s = setup()
    s.activePlayer = nil
    check("not when the game is over", not GAME.canEndTurn(s))
end

---------------------------------------------------------------------------- passing play on

do
    local s = setup()
    local ann, ben, cat = s.players[1], s.players[2], s.players[3]
    local t = ann.hand.tiles[1]
    local spot = GAME.legalPlacements(s, t)[1]
    t:rotate(spot.turns)
    GAME.placeTile(s, t, spot.x, spot.y)
    eq("hand down to 3", #ann.hand.tiles, 3)
    local r = assert(GAME.endTurn(s))
    check("ended", r)
    eq("hand refilled", #ann.hand.tiles, 4)
    eq("one tile drawn", #r.drawn, 1)
    check("next player is Ben (left)", s.turnPlayer == ben and s.activePlayer == ben)
    eq("turn number", s.turnNumber, 2)
    check("flags reset", not s.moved and not s.placedTile and s.tileEffect == E.Empty)
    GAME.movePlayer(s, 1, 0)
    GAME.endTurn(s)
    check("then Cat", s.activePlayer == cat)
    GAME.movePlayer(s, -1, 0)
    GAME.endTurn(s)
    check("then round to Ann", s.activePlayer == ann)
    eq("turn number after a round", s.turnNumber, 4)
end

do --a player who fell into the Void loses their next turn
    local s = setup()
    local ben, cat = s.players[2], s.players[3]
    ben.x, ben.y, ben.skipTurn = nil, nil, true
    GAME.movePlayer(s, 1, 0)
    local r = assert(GAME.endTurn(s))
    check("Ben skipped", s.activePlayer == cat)
    check("skip reported", r.skipped[1] == ben)
    check("skip used up", not ben.skipTurn)
    GAME.movePlayer(s, -1, 0)
    GAME.endTurn(s)
    GAME.movePlayer(s, 0, 0)
    GAME.endTurn(s)
    check("Ben plays next time round", s.activePlayer == ben)
    check("from the Void he may move anywhere", GAME.canMove(s, 1, 0))
    check("but not place", not GAME.canPlaceTile(s))
end

do --a decision pending for another player: they act, then play returns to the turn player
    local s = setup()
    local ann, ben = s.players[1], s.players[2]
    s.board:set(2, 0, tile(E.Map, L))
    GAME.movePlayer(s, 1, 0)
    GAME.doMovePlayer(s, ben, 2, 0, false)       --as if Ann had moved Ben (Mind Control Orb)
    check("Ben has a decision", s.pendingActivePlayer == ben)
    GAME.endTurn(s, true)                        --(Ann can't end with a pending decision)
    check("Ben acts", s.activePlayer == ben and s.turnPlayer == ann)
    check("pending cleared", s.pendingActivePlayer == nil)
    check("Ben may end without doing anything", GAME.canEndTurn(s))
    local turn = s.turnNumber
    GAME.endTurn(s)
    --Ann has already moved, so she can't do anything more: play passes on
    check("back to Ann, then on to Ben's turn", s.turnPlayer == ben and s.activePlayer == ben)
    eq("turn counted", s.turnNumber, turn + 1)
    eq("Ann's hand refilled", #ann.hand.tiles, 4)
end

do --players who can't do anything are passed over
    local s = setup()
    local cat = s.players[3]
    GAME.movePlayer(s, 1, 0)
    --Ben: in the Void-free but stuck: no tiles and nowhere to go
    local ben = s.players[2]
    ben.hand = { tileLimit = 0, tiles = {}, name = "empty" }
    ben.x, ben.y = 5, 5
    s.board:set(5, 5, tile(E.Empty))
    GAME.endTurn(s)
    check("Ben can't act: Cat plays", s.activePlayer == cat)
    eq("only one turn counted", s.turnNumber, 2)
end

do --nobody can act: the game ends
    local s = setup(2)
    for _, p in ipairs(s.players) do
        p.hand = { tileLimit = 0, tiles = {}, name = p.name }
        p.x, p.y = 9, 9
    end
    s.board:set(9, 9, tile(E.Empty))
    local r = assert(GAME.endTurn(s, true))
    check("stuck", r.stuck)
    check("game over", GAME.isOver(s))
end

---------------------------------------------------------------------------- winning

do
    local s = setup()
    local ann = s.players[1]
    ann.unlockedGold, ann.lockedGold = 3, 2
    GAME.movePlayer(s, 1, 0)
    local r = assert(GAME.endTurn(s))
    check("Ann's team wins", r.winners and #r.winners == 1 and r.winners[1].name == "Ann")
    check("game over", GAME.isOver(s))
    eq("winning gold counted", r.winners[1].gold, 5)
    check("no tiles drawn on winning", r.drawn == nil)
end

do --teams pool their gold
    local cfg = GAME.newConfig()
    local a = GAME.addPlayer(cfg, "Ann")
    local b = GAME.addPlayer(cfg, "Ben")
    GAME.addPlayer(cfg, "Cat")
    b.team = a.team
    local s = GAME.newGame(cfg, function(lo) return lo end)
    s.board:set(1, 0, TILES.fromParts(E.Empty, set(L)))
    s.players[1].unlockedGold, s.players[2].lockedGold = 2, 3
    GAME.movePlayer(s, 1, 0)
    local r = assert(GAME.endTurn(s))
    check("team of two wins", r.winners and #r.winners[1].players == 2)
    s = setup()
    s.players[1].unlockedGold = 4
    GAME.movePlayer(s, 1, 0)
    check("4 of 5 isn't enough", not GAME.endTurn(s).winners)
end

---------------------------------------------------------------------------- opening rounds

do --BigDungeonRounds: placing only, then a random player starts the game proper
    local cfg = GAME.newConfig()
    cfg.options.bigDungeonRounds = 1
    for _, n in ipairs({ "Ann", "Ben" }) do GAME.addPlayer(cfg, n) end
    local picks = {}
    local s = GAME.newGame(cfg, function(_, hi) picks[#picks + 1] = hi; return hi end)
    ---place the first hand tile that fits anywhere
    ---@return true|nil ok
    ---@return string? err
    local function placeAny()
        for _, t in ipairs(s.activePlayer.hand.tiles) do
            local spot = GAME.legalPlacements(s, t)[1]
            if spot then t:rotate(spot.turns); return GAME.placeTile(s, t, spot.x, spot.y) end
        end
    end
    check("first player Ben (random picks the last)", s.turnPlayer == s.players[2])
    check("no moving in the opening", not GAME.canMoveNow(s))
    placeAny(); GAME.endTurn(s)
    check("Ann places", s.turnPlayer == s.players[1] and not GAME.canMoveNow(s))
    eq("turn 2", s.turnNumber, 2)
    placeAny(); GAME.endTurn(s)
    --turn number 2 == 1 round x 2 players: a random player (the last) starts
    check("random start after the opening", s.turnPlayer == s.players[2])
    eq("turn 3", s.turnNumber, 3)
    check("moving allowed now", GAME.canMoveNow(s) or #GAME.legalMoves(s) == 0)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
