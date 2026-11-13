--tests for moving heroes (src/game.lua). Runs under plain Lua, from the repository's top folder:
--lua tests/test_move.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect
local H = GAME.Hero
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

---a game with players Ann, Ben, Cat (Ann to play) and the given heroes. The Start tile is at
---(0, 0) with exits Right, Down and Left; `layout` adds tiles: { {x, y, effect, arrows...}, ... }.
---@param layout? table[]
---@param heroes? GAME.HERO[]
---@return GAME.STATE
local function setup(layout, heroes)
    local cfg = GAME.newConfig()
    for i, name in ipairs({ "Ann", "Ben", "Cat" }) do
        local pc = GAME.addPlayer(cfg, name)
        pc.hero = heroes and heroes[i] or H.None
    end
    local s = GAME.newGame(cfg, function(lo) return lo end)
    for _, t in ipairs(layout or {}) do
        s.board:set(t[1], t[2], TILES.fromParts(t[3], set(unpack(t, 4))))
    end
    return s
end
---@param s GAME.STATE
---@param x integer
---@param y integer
---@return boolean
local function can(s, x, y) return (GAME.canMove(s, x, y)) end
---@param p GAME.PLAYER
---@param x integer
---@param y integer
---@return boolean
local function at(p, x, y) return p.x == x and p.y == y end

---------------------------------------------------------------------------- basic moves

do
    --Start exits R, D, L. (1,0) and (-1,0) are rooms; (0,-1) is above Start's wall.
    local s = setup({ { 1, 0, E.Empty, L }, { -1, 0, E.Empty, R }, { 0, -1, E.Empty, D }, { 2, 0, E.Empty, L } })
    local ann = s.activePlayer --[[@as GAME.PLAYER]]
    eq("turn number starts at 1", s.turnNumber, 1)
    check("can move at start of turn", GAME.canMoveNow(s))
    check("through an exit (right)", can(s, 1, 0))
    check("through an exit (left)", can(s, -1, 0))
    check("not through a wall (up)", not can(s, 0, -1))
    check("not two squares", not can(s, 2, 0))
    check("not onto an empty square", not can(s, 0, 1))
    check("not staying put", not can(s, 0, 0))
    eq("legal moves", #GAME.legalMoves(s), 2)

    local r, err = GAME.movePlayer(s, 1, 0)
    check("move", r, err)
    check("hero moved", at(ann, 1, 0))
    check("moved flag", s.moved)
    check("no second move", not GAME.canMoveNow(s))
    check("no placing after moving", not GAME.canPlaceTile(s))
    r, err = GAME.movePlayer(s, 0, 0)
    check("second move refused", not r and err == "This is not a valid move", err)
end

do --moving is the turn player's, and not after placing, nor during the opening rounds
    local s = setup({ { 1, 0, E.Empty, L } })
    s.placedTile = true
    check("not after placing", not GAME.canMoveNow(s))
    s = setup({ { 1, 0, E.Empty, L } })
    s.activePlayer = s.players[2]
    check("only the turn player", not GAME.canMoveNow(s))
    s = setup({ { 1, 0, E.Empty, L } })
    s.config.options.bigDungeonRounds = 1
    check("not during BigDungeonRounds", not GAME.canMoveNow(s))
    s.turnNumber = 4
    check("after BigDungeonRounds", GAME.canMoveNow(s))
    s = setup({ { 1, 0, E.Empty, L } })
    s.pendingActivePlayer = s.players[2]
    check("not while another player has a decision", not GAME.canMoveNow(s))
    s = setup({})
    check("nowhere to go", not GAME.canMoveNow(s))
end

do --leaving a room without exits: any direction, unless the neighbour's exit points back
    local s = setup({ { 1, 0, E.Empty }, { 2, 0, E.Empty, U }, { 1, -1, E.Empty, D }, { 1, 1, E.Empty, R } })
    s.activePlayer.x, s.activePlayer.y = 1, 0
    check("no-exit room: not back to Start (its exit points here)", not can(s, 0, 0))
    check("no-exit room: right", can(s, 2, 0))
    check("no-exit room: not up (exit points back)", not can(s, 1, -1))
    check("no-exit room: down", can(s, 1, 1))
end

---------------------------------------------------------------------------- leaving effects

do --Heavy Gale: exactly 3 steps; Strong Wind: exactly 2; Tornado: up to 4
    --a corridor of left-right rooms from (1,0) to (5,0)
    local row = {}
    for x = 1, 5 do row[#row + 1] = { x, 0, E.Empty, L, R } end
    local s = setup(row)
    s.board:set(0, 0, TILES.fromParts(E.HeavyGale, set(R, L)))
    --three steps can end next door, by going there, back and there again
    check("gale: 1 (there and back)", can(s, 1, 0))
    check("gale: not 2", not can(s, 2, 0))
    check("gale: 3", can(s, 3, 0))
    check("gale: not 4", not can(s, 4, 0))
    s.board:set(0, 0, TILES.fromParts(E.StrongWind, set(R, L)))
    check("wind: 2", can(s, 2, 0))
    check("wind: not 1", not can(s, 1, 0))
    check("wind: not back home", not can(s, 0, 0))
    s.board:set(0, 0, TILES.fromParts(E.Tornado, set(R, L)))
    for x = 1, 4 do check("tornado: " .. x, can(s, x, 0)) end
    check("tornado: not 5", not can(s, 5, 0))
end

do --steps go through the rooms in between, by their exits
    local s = setup({ { 1, 0, E.Empty, L }, { 2, 0, E.Empty, L } })
    s.board:set(0, 0, TILES.fromParts(E.StrongWind, set(R)))
    check("wind: room in between has no way on", not can(s, 2, 0))
end

do --Magic Vortex: anywhere. Master Key: any adjacent room. Friendly Visit: to another hero
    local s = setup({ { 1, 0, E.Empty, L }, { 5, 5, E.Empty, U }, { 0, -1, E.Empty, U } })
    local ann, ben = s.players[1], s.players[2]
    s.board:set(0, 0, TILES.fromParts(E.MagicVortex, set(R)))
    check("vortex: far away", can(s, 5, 5))
    s.board:set(0, 0, TILES.fromParts(E.MasterKey, set(R)))
    check("master key: through the wall above", can(s, 0, -1))
    check("master key: not far", not can(s, 5, 5))
    s.board:set(0, 0, TILES.fromParts(E.FriendlyVisit, set(R)))
    ben.x, ben.y = 5, 5
    s.players[3].x, s.players[3].y = 5, 5
    check("friendly visit: to another hero far away", can(s, 5, 5))
    check("friendly visit: not to an empty room", not can(s, 1, 0))
    check("Ann still on start", at(ann, 0, 0))
end

do --Secret Passage: to another Secret Passage, and Escape/Start with the options
    local s = setup({ { 1, 0, E.Empty, L }, { 4, 4, E.Passage, U }, { 6, 6, E.Escape, U }, { 7, 7, E.Start, U } })
    s.board:set(0, 0, TILES.fromParts(E.Passage, set(R)))
    check("passage to passage", can(s, 4, 4))
    check("passage: not to escape by default", not can(s, 6, 6))
    check("passage: still a normal move", can(s, 1, 0))
    s.config.options.secretEscape = true
    check("passage to escape with SecretEscape", can(s, 6, 6))
    check("passage: not to start by default", not can(s, 7, 7))
    s.config.options.secretStart = true
    check("passage to start with SecretStart", can(s, 7, 7))
    --a Harp next door pulls the hero in instead
    s.board:set(1, 0, TILES.fromParts(E.MagicHarp, set(L)))
    check("passage: harp wins", not can(s, 4, 4))
end

do --Magic Harp: an exit leading into a Harp must be taken
    local s = setup({ { 1, 0, E.MagicHarp, U }, { -1, 0, E.Empty, R } })
    check("harp: must go into it", can(s, 1, 0))
    check("harp: not elsewhere", not can(s, -1, 0))
end

do --Small Room: only one hero
    local s = setup({ { 1, 0, E.SmallRoom, L, U } })
    local ben = s.players[2]
    check("small room: empty", can(s, 1, 0))
    ben.x, ben.y = 1, 0
    check("small room: occupied", not can(s, 1, 0))
end

---------------------------------------------------------------------------- hero abilities

do --Wizard: once per game, one step through a wall
    local s = setup({ { 0, -1, E.Empty, D }, { 0, -2, E.Empty, D } }, { H.Wizard })
    local ann = s.activePlayer --[[@as GAME.PLAYER]]
    local ok, wizard = GAME.canMove(s, 0, -1)
    check("wizard through the wall", ok and wizard)
    check("wizard: only one wall", not can(s, 0, -2))
    local r = GAME.movePlayer(s, 0, -1)
    check("wizard move", r and r.wizard)
    check("wizard ability used", ann.usedHero)

    local s2 = setup({ { 0, -1, E.Empty, D }, { 1, 0, E.Empty, L } }, { H.Wizard })
    ok, wizard = GAME.canMove(s2, 1, 0)
    check("wizard: normal moves don't use the ability", ok and not wizard)
    GAME.movePlayer(s2, 1, 0)
    check("wizard ability kept", not s2.activePlayer.usedHero)

    local s3 = setup({ { 0, -1, E.Empty, D } }, { H.Knight })
    check("non-wizard can't", not can(s3, 0, -1))
end

do --Amazon: once per game, a second move in a turn
    local s = setup({ { 1, 0, E.Empty, L, R }, { 2, 0, E.Empty, L } }, { H.Amazon })
    local ann = s.activePlayer --[[@as GAME.PLAYER]]
    check("amazon first move", GAME.movePlayer(s, 1, 0))
    check("amazon may move again", GAME.canMoveNow(s))
    local ok, _, second = GAME.canMove(s, 2, 0)
    check("second move flagged", ok and second)
    local r = GAME.movePlayer(s, 2, 0)
    check("amazon second move", r and r.second)
    check("amazon ability used", ann.usedHero)
    check("no third move", not GAME.canMoveNow(s))
end

---------------------------------------------------------------------------- entering effects

---Ann walks right into a room with this effect
---@param effect TILES.EFFECT
---@param prep? fun(s:GAME.STATE) changes made before she moves
---@return GAME.STATE s
---@return GAME.MOVERESULT r
---@return GAME.PLAYER ann
local function enter(effect, prep)
    local s = setup({ { 1, 0, effect, L } })
    if prep then prep(s) end
    local r, err = GAME.movePlayer(s, 1, 0)
    assert(r, err)
    return s, r, s.activePlayer --[[@as GAME.PLAYER]]
end

do
    local s, r, ann = enter(E.OneGold)
    eq("one gold", ann.unlockedGold, 1)
    eq("one gold reported", r.gold, 1)
    s, r, ann = enter(E.TwoGold)
    eq("two gold", ann.unlockedGold, 2)

    s, r, ann = enter(E.LockedChest, function(g) g.activePlayer.unlockedGold = 3 end)
    eq("locked chest: unlocked", ann.unlockedGold, 0)
    eq("locked chest: locked", ann.lockedGold, 3)

    s, r, ann = enter(E.WishingWell, function(g) g.activePlayer.unlockedGold = 2 end)
    eq("wishing well", ann.unlockedGold, 1)
    s, r, ann = enter(E.WishingWell)
    eq("wishing well with nothing to lose", ann.unlockedGold, 0)

    s, r, ann = enter(E.DrakonsDue, function(g) g.activePlayer.unlockedGold = 1 end)
    eq("drakon's due: paid", ann.unlockedGold, 0)
    eq("drakon's due: onto Start", s.goldOnStart, 1)

    --Start: pick up a coin left there
    local s2 = setup({ { 1, 0, E.Empty, L } })
    s2.activePlayer.x = 1
    s2.goldOnStart = 2
    GAME.movePlayer(s2, 0, 0)
    eq("start: picked up", s2.activePlayer.unlockedGold, 1)
    eq("start: one left", s2.goldOnStart, 1)
end

do --steals: left = next player, right = previous
    local s, r, ann = enter(E.StealLeft, function(s) s.players[2].unlockedGold = 2; s.players[3].unlockedGold = 2 end)
    eq("steal left: gained", ann.unlockedGold, 1)
    eq("steal left: from Ben", s.players[2].unlockedGold, 1)
    check("steal left reported", r.stole == s.players[2])
    s, r, ann = enter(E.StealRight, function(g) g.players[2].unlockedGold = 2; g.players[3].unlockedGold = 2 end)
    eq("steal right: from Cat (wraps round)", s.players[3].unlockedGold, 1)
    s, r, ann = enter(E.StealLeft, function(g) g.config.options.stealAsLocked = true; g.players[2].unlockedGold = 1 end)
    eq("steal as locked", ann.lockedGold, 1)
    s, r, ann = enter(E.StealLeft)
    check("nothing to steal", r.stole == nil and ann.unlockedGold == 0)
end

do --the Void
    local s, r, ann = enter(E.Void)
    check("void: off the board", ann.x == nil and r.void)
    check("void: next turn lost", ann.skipTurn)
    --after the lost turn, a hero in the Void may go to any chamber
    ann.skipTurn = false
    s.moved = false
    check("from the void: anywhere", can(s, 0, 0) and can(s, 1, 0))
    ann.skipTurn = true
    check("void with turn to skip raises", not pcall(GAME.canMovePlayerTo, s, ann, 0, 0, false))
end

do --chambers that need a decision are recorded in tileEffect
    for _, e in ipairs({ E.Map, E.Rotate, E.Destroy, E.MagicShift, E.MindOrb, E.MovingTiles }) do
        local s = enter(e)
        eq("decision recorded: " .. TILES.EffectName[e], s.tileEffect, e)
        check("no pending for own move: " .. TILES.EffectName[e], s.pendingActivePlayer == nil)
    end
    local s = enter(E.DrakonsBargain)
    eq("bargain needs gold", s.tileEffect, E.Empty)
    s = enter(E.DrakonsBargain, function(g) g.activePlayer.unlockedGold = 1 end)
    eq("bargain with gold", s.tileEffect, E.DrakonsBargain)
    s = enter(E.Float)
    eq("float", s.tileEffect, E.Float)
    s = enter(E.Float, function(g) g.board:set(2, 0, TILES.fromParts(E.Base, 0)) end)
    eq("float next to a base doesn't float", s.tileEffect, E.Empty)
end

do --another player's hero moved into a decision chamber: that player must resolve it
    local s = setup({ { 1, 0, E.Map, L } })
    local ben = s.players[2]
    GAME.doMovePlayer(s, ben, 1, 0, false)
    check("pending for the moved hero's player", s.pendingActivePlayer == ben)
    check("active player hasn't moved", not s.moved)
end

do --Drakon attacks: back to the Start chamber, losing a coin
    local s = setup({ { 1, 0, E.OneGold, L, R }, { 2, 0, E.Empty, L } })
    local ann = s.activePlayer --[[@as GAME.PLAYER]]
    ann.unlockedGold = 2
    s.drakonActive, s.drakonX, s.drakonY = true, 1, 0
    s.goldOnStart = 1
    local r = assert(GAME.movePlayer(s, 1, 0))
    check("attacked", r.attacked)
    check("sent to Start", at(ann, 0, 0))
    --lost one coin, then picked up the one lying on Start; the gold tile wasn't entered
    eq("gold after the attack", ann.unlockedGold, 2)
    eq("start emptied", s.goldOnStart, 0)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
