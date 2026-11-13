--tests for the computer players (src/ai.lua) and copying a game (game.cloneState).
--runs under plain Lua, from the repository's top folder:
--lua tests/test_ai.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local AI = require('src.ai')
local E = TILES.Effect
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

---a repeatable random function (Park-Miller)
---@param seed integer
---@return GAME.RANDOM
local function rng(seed)
    return function(lo, hi)
        seed = seed * 16807 % 2147483647
        return lo + seed % (hi - lo + 1)
    end
end

---a game of computer players
---@param levels string[] AI level per player
---@param seed integer
---@param heroes? GAME.HERO[] default: random heroes
---@return GAME.STATE
local function newGame(levels, seed, heroes)
    local random = rng(seed)
    local cfg = GAME.newConfig()
    for i, level in ipairs(levels) do
        local pc = GAME.addPlayer(cfg, "P" .. i)
        pc.ai = level
        pc.hero = heroes and heroes[i] or random(1, 6)
    end
    return GAME.newGame(cfg, random)
end

---------------------------------------------------------------------------- copying

do
    local s = newGame({ "greedy", "random" }, 11)
    local c = GAME.cloneState(s)
    check("players copied", c.players[1] ~= s.players[1] and c.players[1].name == s.players[1].name)
    check("active player mapped", c.activePlayer == c.players[1] or c.activePlayer == c.players[2])
    eq("active is the same seat", c.activePlayer.name, s.activePlayer.name)
    check("hands copied", c.players[1].hand ~= s.players[1].hand and #c.players[1].hand.tiles == #s.players[1].hand.tiles)
    check("tiles copied", c.players[1].hand.tiles[1] ~= s.players[1].hand.tiles[1]
          and c.players[1].hand.tiles[1].kind == s.players[1].hand.tiles[1].kind)
    check("board copied", c.board ~= s.board and c.board:get(0, 0) ~= s.board:get(0, 0))
    --playing on the copy leaves the original alone
    local before = s.board.count
    local p = c.activePlayer --[[@as GAME.PLAYER]]
    local t = p.hand.tiles[1]
    local spot = GAME.legalPlacements(c, t)[1]
    t:rotate(spot.turns)
    assert(GAME.placeTile(c, t, spot.x, spot.y))
    eq("original board untouched", s.board.count, before)
    eq("original hand untouched", #s.activePlayer.hand.tiles, 4)
    check("original turn untouched", not s.placedTile)
end

do --shared hands stay shared in the copy; Knight records are mapped
    local cfg = GAME.newConfig()
    local a = GAME.addPlayer(cfg, "Ann")
    local b = GAME.addPlayer(cfg, "Ben")
    b.hand = a.hand
    local s = GAME.newGame(cfg, rng(3))
    s.savedGoldState = { player = s.players[2], lostTo = s.players[1], next = nil }
    local c = GAME.cloneState(s)
    check("shared hand stays shared", c.players[1].hand == c.players[2].hand)
    check("knight record mapped", c.savedGoldState.player == c.players[2] and c.savedGoldState.lostTo == c.players[1])
end

---------------------------------------------------------------------------- scoring

do
    local s = newGame({ "greedy", "greedy" }, 5, { GAME.Hero.None, GAME.Hero.None })
    local me = 1
    local base = AI.evaluate(s, me)
    s.players[1].unlockedGold = 1
    check("gold is good", AI.evaluate(s, me) > base)
    local one = AI.evaluate(s, me)
    s.players[1].unlockedGold, s.players[1].lockedGold = 0, 1
    check("locked gold is better", AI.evaluate(s, me) > one)
    s.players[1].lockedGold = 0
    s.players[2].unlockedGold = 2
    check("opponent's gold is bad", AI.evaluate(s, me) < base)
    s.players[1].unlockedGold = 5
    eq("winning", AI.evaluate(s, me), 1e6)
end

---------------------------------------------------------------------------- playing single decisions

do --greedy walks into the gold room next door rather than an empty one
    local s = newGame({ "greedy", "random" }, 9, { GAME.Hero.None, GAME.Hero.None })
    s.turnPlayer = s.players[1]
    GAME.beginTurn(s)
    s.board:set(1, 0, TILES.fromParts(E.TwoGold, set(TILES.LEFT)))
    s.board:set(-1, 0, TILES.fromParts(E.Empty, set(TILES.RIGHT)))
    local log = AI.act(s)
    eq("took the gold", s.players[1].unlockedGold, 2)
    check("and finished", s.activePlayer ~= s.players[1])
    check("logged", log[1] and log[1]:find("moved to the Find Two Gold"), log[1])
end

do --greedy puts Drakon on an opponent with gold
    local s = newGame({ "greedy", "random", "random" }, 13, { GAME.Hero.None, GAME.Hero.None, GAME.Hero.None })
    s.turnPlayer = s.players[1]
    GAME.beginTurn(s)
    s.board:set(0, -1, TILES.fromParts(E.Empty, set(TILES.DOWN)))
    s.board:set(1, 0, TILES.fromParts(E.Empty, set(TILES.LEFT)))
    s.board:set(-1, 0, TILES.fromParts(E.Empty, set(TILES.RIGHT)))
    s.players[1].x, s.players[1].y = 0, -1
    s.players[2].x, s.players[2].y, s.players[2].unlockedGold = 1, 0, 3
    s.players[3].x, s.players[3].y = -1, 0
    s.drakonActive, s.drakonX, s.drakonY = true, 0, 0
    s.tileEffect = E.DrakonMoves
    s.moved = true
    AI.act(s)
    check("Drakon attacked the rich opponent", s.drakonX == 1 and s.drakonY == 0 and s.players[2].unlockedGold == 2,
          ("%s,%s"):format(tostring(s.drakonX), tostring(s.drakonY)))
end

do --random places Drakon somewhere legal when it must
    local s = newGame({ "random", "random" }, 17)
    s.turnPlayer = s.players[1]
    GAME.beginTurn(s)
    local dm = TILES.fromParts(E.DrakonMoves, set(TILES.UP))
    s.players[1].hand.tiles[1] = dm
    assert(GAME.placeTile(s, dm, 0, -1))
    AI.act(s)
    check("Drakon placed", s.drakonActive)
    check("turn passed", s.activePlayer == s.players[2])
end

---------------------------------------------------------------------------- whole games

---play a whole game, checking the rules hold after each action
---@param levels string[]
---@param seed integer
---@param maxTurns? integer
---@return GAME.STATE s
---@return boolean ok
---@return any err what went wrong (an error from the AI, or a rule broken)
---@return integer turns
local function play(levels, seed, maxTurns)
    local s = newGame(levels, seed)
    local ok, err = true, nil
    local turns = 0
    while not GAME.isOver(s) and turns < (maxTurns or 600) do
        ok, err = pcall(AI.act, s)
        if not ok then break end
        turns = turns + 1
        for _, p in ipairs(s.players) do
            if p.unlockedGold < 0 or p.lockedGold < 0 then ok, err = false, "negative gold" end
            if #p.hand.tiles > p.hand.tileLimit then ok, err = false, "hand over its limit" end
        end
        if s.goldOnStart < 0 then ok, err = false, "negative gold on Start" end
        if not ok then break end
    end
    return s, ok, err, turns
end

--(Board iteration order varies between runs, so these games differ a little each time: the
--checks leave some margin.)
do
    local errors, finished, greedyWins, games = 0, 0, 0, 0
    for seed = 1, 16 do
        local s, ok, err = play({ "greedy", "random", "greedy", "random" }, seed * 7919, 300)
        games = games + 1
        if not ok then errors = errors + 1; print("game " .. seed .. ": " .. tostring(err)) end
        if GAME.isOver(s) then finished = finished + 1 end
        local w = GAME.winners(s)[1]
        if w and (w.name == "P1" or w.name == "P3") then greedyWins = greedyWins + 1 end
    end
    eq("greedy vs random: no errors", errors, 0)
    check(("most games finish within 300 turns (%d of %d)"):format(finished, games), finished >= games * 0.8)
    check(("greedy wins most games (%d of %d)"):format(greedyWins, games), greedyWins >= games * 0.7)
end

do
    local errors = 0
    for seed = 1, 3 do
        local _, ok, err = play({ "random", "random", "random" }, seed * 104729, 120)
        if not ok then errors = errors + 1; print("random game " .. seed .. ": " .. tostring(err)) end
        local _, ok2, err2 = play({ "greedy", "greedy" }, seed * 15485863, 200)
        if not ok2 then errors = errors + 1; print("greedy game " .. seed .. ": " .. tostring(err2)) end
    end
    eq("random-only and greedy-only games: no errors", errors, 0)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
