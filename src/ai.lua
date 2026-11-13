--computer players.
--
--"random" follows the original game: its AI asked the game for every legal option and
--picked one at random ("AI: No legal moves" when there were none), then finished its action
--(TMainForm, around $00D15ED8). Like the original it never uses hero abilities. The
--original's option list (TDrakonGame.GetMoves) combines a move with what follows it; here the
--follow-up choices are picked at random one at a time, which plays the same way.
--
--"greedy" is new: it tries each option on a copy of the game, scores the result and plays
--the best one. The score counts its team's gold (locked coins a little more, as they are
--safe), its hand limit, gold rooms it could reach next turn (and how many steps away the
--nearest is) and Drakon's threat, against the best
--opposing team's gold. It also uses hero abilities.
--
--ai.act(state) plays the active player's whole action and finishes it. Returns a list of
--log lines. Pure Lua: no LÖVE calls.

local TILES = require('src.tiles')
local GAME = require('src.game')
local E = TILES.Effect

---one thing the AI can do; players and hand tiles are given by index so the option also
---works on a copy of the game
---@class AI.OPTION
---@field kind "place"|"move"|"escape"|"drakon"|"destroy"|"bargain"|"shift"|"swap"|"rotate"|"map"|"orb"|"float"|"thief"|"dwarf"|"push"|"reclaim"|"decline"|"skip"
---@field x? integer
---@field y? integer
---@field x2? integer second room (swap)
---@field y2? integer
---@field turns? integer clockwise quarter turns
---@field hand? integer index into the active player's hand
---@field player? integer index into state.players

---the parts of a score (missing parts count 0)
---@class AI.SCORE
---@field win? number
---@field lose? number
---@field gold? number
---@field locked? number
---@field hand? number
---@field opponents? number
---@field void? number
---@field reach? number
---@field pull? number
---@field stuck? number
---@field drakon? number

---@class AI
local lib = {}
---@type string[]
lib.LEVELS = { "greedy", "random" }

---------------------------------------------------------------------------- options
--an option is a small table that can be applied to the real state or to a copy: players
--and hand tiles are referred to by index.

---@param list table
---@param item any
---@return integer|nil
local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
end

---every legal tile placement
---@param s GAME.STATE
---@return AI.OPTION[]
local function placeOptions(s)
    local out = {}
    if not GAME.canPlaceTile(s) then return out end
    for i, t in ipairs(s.activePlayer.hand.tiles) do
        for _, p in ipairs(GAME.legalPlacements(s, t)) do
            out[#out + 1] = { kind = "place", hand = i, turns = p.turns, x = p.x, y = p.y }
        end
    end
    return out
end

---every legal move
---@param s GAME.STATE
---@return AI.OPTION[]
local function moveOptions(s)
    local out = {}
    for _, m in ipairs(GAME.legalMoves(s)) do out[#out + 1] = { kind = "move", x = m.x, y = m.y } end
    return out
end

---an unoccupied room other than Start
---@param s GAME.STATE
---@param x integer
---@param y integer
---@param t TILES.TILE
---@return boolean
local function free(s, x, y, t)
    return t:effect() ~= E.Start and not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y)
end

---every way to make the chamber choice that is open.
---@param s GAME.STATE
---@return AI.OPTION[]
local function choiceOptions(s)
    local e = GAME.openChoice(s)
    local out = {}
    local me = s.activePlayer --[[@as GAME.PLAYER]]
    ---@param o AI.OPTION
    local function add(o) out[#out + 1] = o end
    if e == E.Destroy then
        for x, y, t in s.board:each() do if free(s, x, y, t) then add({ kind = "destroy", x = x, y = y }) end end
    elseif e == E.DrakonsBargain then
        for x, y in s.board:each() do
            if not (x == 0 and y == 0) and not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y) then
                add({ kind = "bargain", x = x, y = y })
            end
        end
    elseif e == E.MagicShift then
        for i, h in ipairs(me.hand.tiles) do
            for turns = 0, 3 do
                h:rotate(turns)
                for x, y in s.board:each() do
                    if not GAME.magicShiftError(s, h, x, y) then add({ kind = "shift", hand = i, turns = turns, x = x, y = y }) end
                end
                h:rotate(4 - turns)
            end
        end
    elseif e == E.MovingTiles then
        local sq = {}
        for x, y in s.board:each() do
            if not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y) then sq[#sq + 1] = { x, y } end
        end
        for i = 1, #sq do
            for j = i + 1, #sq do
                local a, b = sq[i], sq[j]
                if not GAME.swapRoomsError(s, a[1], a[2], b[1], b[2]) then
                    add({ kind = "swap", x = a[1], y = a[2], x2 = b[1], y2 = b[2] })
                end
            end
        end
    elseif e == E.Rotate then
        for x, y in s.board:each() do
            for turns = 1, 3 do
                if not GAME.rotateRoomError(s, x, y, turns) then add({ kind = "rotate", x = x, y = y, turns = turns }) end
            end
        end
    elseif e == E.Map then
        for i, p in ipairs(s.players) do
            if p ~= me and #p.hand.tiles > 0 and p.hand ~= me.hand then add({ kind = "map", player = i }) end
        end
    elseif e == E.MindOrb then
        for i, p in ipairs(s.players) do
            if p ~= me and p.x then
                for x, y in s.board:each() do
                    if GAME.canMoveOther(s, p, x, y) then add({ kind = "orb", player = i, x = x, y = y }) end
                end
            end
        end
    elseif e == E.Float then
        local seen = {}
        local spots = { { me.x, me.y } }
        for bx, by in s.board:each() do
            for d = 0, 3 do
                local x, y = TILES.neighbor(bx, by, d)
                local k = x .. "," .. y
                if not seen[k] and not s.board:has(x, y) then seen[k] = true; spots[#spots + 1] = { x, y } end
            end
        end
        for _, sq in ipairs(spots) do
            for turns = 0, 3 do
                if not GAME.floatError(s, sq[1], sq[2], turns) then add({ kind = "float", x = sq[1], y = sq[2], turns = turns }) end
            end
        end
    end
    return out
end

---every square Drakon may go to
---@param s GAME.STATE
---@return AI.OPTION[]
local function drakonOptions(s)
    local out = {}
    for _, sq in ipairs(GAME.legalDrakonMoves(s)) do out[#out + 1] = { kind = "drakon", x = sq[1], y = sq[2] } end
    return out
end

---hero abilities (greedy only).
---@param s GAME.STATE
---@return AI.OPTION[]
local function abilityOptions(s)
    local out = {}
    local me = s.activePlayer --[[@as GAME.PLAYER]]
    if GAME.canThiefSteal(s) then
        for i, p in ipairs(s.players) do
            if p ~= me and p.x == me.x and p.y == me.y and p.unlockedGold > 0 then out[#out + 1] = { kind = "thief", player = i } end
        end
    end
    if GAME.canDwarfDraw(s) then out[#out + 1] = { kind = "dwarf" } end
    return out
end

---every legal Barbarian push
---@param s GAME.STATE
---@return AI.OPTION[]
local function barbarianOptions(s)
    local out = {}
    if not GAME.canBarbarianPush(s) then return out end
    local me = s.activePlayer --[[@as GAME.PLAYER]]
    for i, p in ipairs(s.players) do
        if p ~= me and p.x == me.x and p.y == me.y then
            for x, y in s.board:each() do
                if not GAME.barbarianPushError(s, p, x, y) then out[#out + 1] = { kind = "push", player = i, x = x, y = y } end
            end
        end
    end
    return out
end

---play an option on a state
---@param s GAME.STATE
---@param o AI.OPTION
---@return any|nil ok what the game call returned
---@return string? err
local function apply(s, o)
    local k = o.kind
    if k == "skip" then return true
    elseif k == "place" then
        local t = s.activePlayer.hand.tiles[o.hand]
        t:rotate(o.turns)
        return GAME.placeTile(s, t, o.x, o.y)
    elseif k == "move" then return GAME.movePlayer(s, o.x, o.y)
    elseif k == "escape" then return GAME.moveToEscape(s)
    elseif k == "drakon" then return GAME.moveDrakon(s, o.x, o.y)
    elseif k == "destroy" then return GAME.destroyRoom(s, o.x, o.y)
    elseif k == "bargain" then return GAME.bargainRoom(s, o.x, o.y)
    elseif k == "shift" then
        local t = s.activePlayer.hand.tiles[o.hand]
        t:rotate(o.turns)
        return GAME.magicShift(s, t, o.x, o.y)
    elseif k == "swap" then return GAME.swapRooms(s, o.x, o.y, o.x2, o.y2)
    elseif k == "rotate" then return GAME.rotateRoom(s, o.x, o.y, o.turns)
    elseif k == "map" then return GAME.mapSteal(s, s.players[o.player])
    elseif k == "orb" then return GAME.moveOtherPlayer(s, s.players[o.player], o.x, o.y)
    elseif k == "float" then return GAME.floatRoom(s, o.x, o.y, o.turns)
    elseif k == "thief" then return GAME.thiefSteal(s, s.players[o.player])
    elseif k == "dwarf" then return GAME.dwarfDraw(s)
    elseif k == "push" then return GAME.barbarianPush(s, s.players[o.player], o.x, o.y)
    elseif k == "reclaim" then return GAME.knightReclaim(s)
    elseif k == "decline" then return GAME.knightDecline(s)
    end
    error("unknown AI option " .. tostring(k))
end

---------------------------------------------------------------------------- scoring

---@param s GAME.STATE
---@param teamName string
---@return integer
local function teamGold(s, teamName)
    local g = 0
    for _, p in ipairs(s.players) do
        if p.team.name == teamName then g = g + GAME.totalGold(p) end
    end
    return g
end

---steps between two squares, along the grid
---@param ax integer
---@param ay integer
---@param bx integer
---@param by integer
---@return integer
local function distance(ax, ay, bx, by) return math.abs(ax - bx) + math.abs(ay - by) end

---what entering the room at (x, y) would be worth to `me`, roughly in coins. Drakon's room
---is worth nothing: he attacks.
---@param s GAME.STATE
---@param me GAME.PLAYER
---@param t TILES.TILE
---@param x integer
---@param y integer
---@return number
local function roomValue(s, me, t, x, y)
    if s.drakonActive and s.drakonX == x and s.drakonY == y then return 0 end
    local e = t:effect()
    if e == E.OneGold then return 1
    elseif e == E.TwoGold then return 2
    elseif e == E.Start then return s.goldOnStart > 0 and 1 or 0
    elseif e == E.StealLeft then return GAME.leftOf(s, me).unlockedGold > 0 and 1 or 0
    elseif e == E.StealRight then return GAME.rightOf(s, me).unlockedGold > 0 and 1 or 0
    elseif e == E.LockedChest then return me.unlockedGold > 0 and 0.3 or 0
    elseif e == E.Map then return 0.2
    end
    return 0
end

--where `me` can actually move next turn (the real rules for the room they're in): a set of
--"x,y" keys. Rooms that send heroes far (Vortex, Friendly Visit, Secret Passage) are checked
--everywhere; others within 4 squares.
local FAR = { [E.MagicVortex] = true, [E.FriendlyVisit] = true, [E.Passage] = true }
---rooms the player could enter on their next move, keyed "x,y"
---@param s GAME.STATE
---@param me GAME.PLAYER
---@return {[string]:boolean}
local function nextMoves(s, me)
    local out = {}
    local far = FAR[s.board:get(me.x, me.y):effect()]
    for x, y in s.board:each() do
        if (far or distance(me.x, me.y, x, y) <= 4) and GAME.canMovePlayerTo(s, me, x, y, false) then
            out[x .. "," .. y] = { x, y }
        end
    end
    return out
end

---steps to every room reachable within `limit`: the first step by the real move rules, then
---ordinary one-room moves (through exits; a room without exits in any direction whose
---neighbour doesn't point back). The starting room counts too, by the shortest way out and
---back in: gold rooms pay out every time they are entered.
---@param s GAME.STATE
---@param first {[string]:boolean} rooms the first step reaches (nextMoves)
---@param limit integer
---@return {[string]:integer} steps keyed "x,y"
local function walkSteps(s, first, limit)
    local steps, queue, head = {}, {}, 1
    for k, sq in pairs(first) do
        steps[k] = 1
        queue[#queue + 1] = { sq[1], sq[2], 1 }
    end
    while head <= #queue do
        local cx, cy, n = queue[head][1], queue[head][2], queue[head][3]
        head = head + 1
        if n < limit then
            local here = s.board:get(cx, cy) --[[@as TILES.TILE]]   --(only rooms are queued)
            local noExits = here:style() == TILES.Style.None
            for d = 0, 3 do
                local nx, ny = TILES.neighbor(cx, cy, d)
                local there = s.board:get(nx, ny)
                local k = nx .. "," .. ny
                if there and not steps[k]
                   and (here:hasExit(d) or (noExits and not there:hasExit(TILES.opposite(d)))) then
                    steps[k] = n + 1
                    queue[#queue + 1] = { nx, ny, n + 1 }
                end
            end
        end
    end
    return steps
end

---score of state `s` for the player at index `meIndex`: higher is better. ai.explain gives
---the parts it is made of.
---@param s GAME.STATE
---@param meIndex integer
---@return AI.SCORE
function lib.explain(s, meIndex)
    local me = s.players[meIndex]
    local parts = {}
    local mine = teamGold(s, me.team.name)
    if mine >= me.team.goldToWin then parts.win = 1e6; return parts end
    parts.gold = mine * 100
    parts.locked = me.lockedGold * 10
    --(the hand is refilled to its limit at the end of the action, so the limit is what counts)
    parts.hand = me.hand.tileLimit * 3
    local seen, bestOpp = { [me.team.name] = true }, 0
    for _, p in ipairs(s.players) do
        if not seen[p.team.name] then
            seen[p.team.name] = true
            local g = teamGold(s, p.team.name)
            if g >= p.team.goldToWin then parts.lose = -1e6; return parts end
            bestOpp = math.max(bestOpp, g / p.team.goldToWin)
        end
    end
    parts.opponents = -bestOpp * me.team.goldToWin * 70

    if not me.x then
        parts.void = -40
    else
        --the best gold room reachable next turn, and a weaker pull towards the nearest one
        --that can be walked to
        local first = nextMoves(s, me)
        local steps = walkSteps(s, first, 12)
        local best, pull = 0, 0
        for x, y, t in s.board:each() do
            local v = roomValue(s, me, t, x, y)
            if v > 0 then
                local k = x .. "," .. y
                if first[k] and v > best then best = v end
                if steps[k] then pull = math.max(pull, v * 8 / steps[k]) end
            end
        end
        parts.reach = best * 25
        parts.pull = pull
        --boxed in (e.g. a Heavy Gale with no 3-step route): placing a way out is worth something
        if next(first) == nil then parts.stuck = -30 end
        if s.drakonActive and me.unlockedGold > 0 and distance(me.x, me.y, s.drakonX, s.drakonY) <= 3 then
            parts.drakon = -15
        end
    end
    return parts
end

--ai.explain's parts, in the order they are added up: always the same order, as adding
--fractions in a different order can differ in the last digit and so break ties differently
local PARTS = { "win", "lose", "gold", "locked", "hand", "opponents", "void", "reach", "pull", "stuck", "drakon" }

---the sum of ai.explain's parts
---@param s GAME.STATE
---@param meIndex integer
---@return number
function lib.evaluate(s, meIndex)
    local parts, total = lib.explain(s, meIndex), 0
    for _, name in ipairs(PARTS) do total = total + (parts[name] or 0) end
    return total
end

---------------------------------------------------------------------------- choosing

---@param s GAME.STATE
---@param options AI.OPTION[]
---@return AI.OPTION
local function pickRandom(s, options)
    return options[s.random(1, #options)]
end

---the option whose result scores best (ties broken at random). `skip` adds "do nothing".
---@param s GAME.STATE
---@param options AI.OPTION[]
---@param skip? boolean
---@return AI.OPTION|nil
local function pickBest(s, options, skip)
    local meIndex = indexOf(s.players, s.activePlayer) --[[@as integer]]
    local best, bestScore, ties = nil, -math.huge, 0
    local list = options
    if skip then
        list = { { kind = "skip" } }
        for _, o in ipairs(options) do list[#list + 1] = o end
    end
    for _, o in ipairs(list) do
        local c = GAME.cloneState(s)
        c.noUndo = true
        local score
        if apply(c, o) then score = lib.evaluate(c, meIndex) else score = -math.huge end
        if score > bestScore then
            best, bestScore, ties = o, score, 1
        elseif score == bestScore then
            ties = ties + 1
            if s.random(1, ties) == 1 then best = o end
        end
    end
    return best
end

---the next thing the AI does and which decision it is ("drakon", "choice", "main"...), or nil
---when it is done. `done` marks decisions already declined in this action.
---@param s GAME.STATE
---@param level string "greedy" or "random"
---@param done {[string]:boolean} decisions already declined
---@return AI.OPTION|nil option
---@return string? decision
local function decide(s, level, done)
    local greedy = level == "greedy"
    if GAME.canKnightReclaim(s) then
        --(tried on a throwaway copy first)
        if greedy and GAME.knightReclaim(GAME.cloneState(s)) then return { kind = "reclaim" }, "knight" end
        return { kind = "decline" }, "knight"
    end
    if GAME.mustPlaceDrakon(s) and not done.drakon then
        local opts = drakonOptions(s)
        if #opts > 0 then
            if not greedy then return pickRandom(s, opts), "drakon" end
            return pickBest(s, opts, s.drakonActive), "drakon"
        end
    end
    if GAME.canMoveToEscape(s) and not done.escape then
        if not greedy then return { kind = "escape" }, "escape" end
        return pickBest(s, { { kind = "escape" } }, true), "escape"
    end
    if GAME.openChoice(s) and not done.choice then
        local opts = choiceOptions(s)
        if #opts > 0 then
            if not greedy then return pickRandom(s, opts), "choice" end
            return pickBest(s, opts, true), "choice"
        end
    end
    if greedy and not done.ability then
        local opts = abilityOptions(s)
        if #opts > 0 then return pickBest(s, opts, true), "ability" end
    end
    if not done.main then
        local opts = placeOptions(s)
        for _, o in ipairs(moveOptions(s)) do opts[#opts + 1] = o end
        if greedy then
            for _, o in ipairs(barbarianOptions(s)) do opts[#opts + 1] = o end
        end
        if #opts > 0 then
            if not greedy then return pickRandom(s, opts), "main" end
            --a second (Amazon) move or anything after a push is optional
            return pickBest(s, opts, s.moved or s.placedTile or s.pushedHero), "main"
        end
    end
    return nil
end

---------------------------------------------------------------------------- describing

---a log line for an option played
---@param s GAME.STATE
---@param who GAME.PLAYER
---@param o AI.OPTION
---@param r any what the game call returned
---@param goldBefore integer
---@return string|nil
local function describe(s, who, o, r, goldBefore)
    local k = o.kind
    ---@param x integer
    ---@param y integer
    ---@return string
    local function room(x, y) local t = s.board:get(x, y); return t and t:effectName() or "room" end
    local text
    if k == "place" then text = ("placed the %s at [%d,%d]"):format(room(o.x, o.y), o.x, o.y)
    elseif k == "move" then text = ("moved to the %s [%d,%d]"):format(room(o.x, o.y), o.x, o.y)
    elseif k == "escape" then text = "stepped onto the Escape tile"
    elseif k == "drakon" then
        text = ("moved Drakon to the %s [%d,%d]"):format(room(o.x, o.y), o.x, o.y)
        if type(r) == "table" and r.attacked and #r.attacked > 0 then
            local names = {}
            for _, p in ipairs(r.attacked) do names[#names + 1] = p.name end
            text = text .. ", attacking " .. table.concat(names, " and ")
        end
    elseif k == "destroy" then text = ("destroyed the room at [%d,%d]"):format(o.x, o.y)
    elseif k == "bargain" then text = ("bought the %s [%d,%d] from Drakon"):format(room(o.x, o.y), o.x, o.y)
    elseif k == "shift" then text = ("swapped the room at [%d,%d] for a tile from their hand"):format(o.x, o.y)
    elseif k == "swap" then text = ("switched the rooms at [%d,%d] and [%d,%d]"):format(o.x, o.y, o.x2, o.y2)
    elseif k == "rotate" then text = ("rotated the %s [%d,%d]"):format(room(o.x, o.y), o.x, o.y)
    elseif k == "map" then text = "took a tile from " .. s.players[o.player].name .. "'s hand"
    elseif k == "orb" then text = ("moved %s to [%d,%d] with the Mind Control Orb"):format(s.players[o.player].name, o.x, o.y)
    elseif k == "float" then text = ("moved the Floating Room to [%d,%d]"):format(o.x, o.y)
    elseif k == "thief" then text = "stole a coin from " .. s.players[o.player].name .. " (Thief)"
    elseif k == "dwarf" then text = "drew two extra tiles (Dwarf)"
    elseif k == "push" then text = ("pushed %s to [%d,%d] (Barbarian)"):format(s.players[o.player].name, o.x, o.y)
    elseif k == "reclaim" then text = "took back a lost coin (Knight)"
    elseif k == "decline" then text = "let a lost coin go"
    else return nil end
    local diff = GAME.totalGold(who) - goldBefore
    if diff > 0 then text = text .. (", +%d gold"):format(diff)
    elseif diff < 0 then text = text .. (", %d gold"):format(diff) end
    return who.name .. " " .. text .. "."
end

---------------------------------------------------------------------------- playing

---the AI level of a player ("greedy" / "random"), or nil for a person.
---@param player GAME.PLAYER|nil
---@return string|nil
function lib.levelOf(player) return player and player.config and player.config.ai end

---play the active player's whole action, then finish it. Returns the log lines.
---@param s GAME.STATE
---@param level? string default: the player's own level
---@return string[] log
function lib.act(s, level)
    local log = {}
    local me = s.activePlayer --[[@as GAME.PLAYER]]
    if not me then return log end
    level = level or lib.levelOf(me) or "random"
    local done = {}
    for _ = 1, 40 do
        if GAME.isOver(s) or s.activePlayer ~= me then break end
        local o, decision = decide(s, level, done)
        if not o then break end
        local group = decision --[[@as string]]   --(given with every option)
        local goldBefore = GAME.totalGold(me)
        if o.kind == "skip" then
            done[group] = true
        else
            local r, err = apply(s, o)
            if not r then
                log[#log + 1] = ("AI: %s failed (%s)"):format(o.kind, tostring(err))
                done[group] = true
            else
                log[#log + 1] = describe(s, me, o, r, goldBefore)
            end
        end
    end
    if not GAME.isOver(s) and s.activePlayer == me then
        if GAME.canEndTurn(s) then
            GAME.endTurn(s)
        else
            log[#log + 1] = "AI: No legal moves"
            GAME.endTurn(s, true)
        end
    end
    return log
end

return lib
