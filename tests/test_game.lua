--tests for src/game.lua and src/board.lua (setup). Runs under plain Lua, from the repository's top folder:
--lua tests/test_game.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local GAME = require('src.game')
local BOARD = require('src.board')
local E = TILES.Effect

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
---Park-Miller "minimal standard" generator: products stay below 2^53, so it gives the same
---numbers under LuaJIT (doubles) and Lua 5.3+ (integers).
---a repeatable random function
---@param seed integer
---@return GAME.RANDOM
local function lcg(seed)
    local s = seed % 2147483646 + 1
    return function(lo, hi)
        s = (s * 16807) % 2147483647
        return lo + math.floor(s / 2147483647 * (hi - lo + 1))
    end
end

---------------------------------------------------------------------------- board

do
    local b = BOARD:new()
    eq("empty board", b.count, 0)
    local t = TILES.fromParts(E.Map, 1)
    b:set(2, -1, t)
    check("get", b:get(2, -1) == t and b:has(2, -1) and not b:has(0, 0))
    b:set(-3, 4, TILES.fromParts(E.Empty, 1))
    local x0, y0, x1, y1 = b:bounds()
    check("bounds", x0 == -3 and y0 == -1 and x1 == 2 and y1 == 4, table.concat({ x0, y0, x1, y1 }, ","))
    local fx, fy = b:find(t)
    check("find", fx == 2 and fy == -1)
    b:set(2, -1, TILES.new(0))
    eq("replace keeps count", b.count, 2)
    local c = b:clone()
    c:get(-3, 4):rotate(1)
    check("clone is deep", c:get(-3, 4).kind ~= b:get(-3, 4).kind)
    b:remove(2, -1)
    eq("remove", b.count, 1)
end

---------------------------------------------------------------------------- adding players

do
    local cfg = GAME.newConfig()
    local a = GAME.addPlayer(cfg, "Alice")
    local b = GAME.addPlayer(cfg, "adam")
    local c = GAME.addPlayer(cfg, "Ada")
    eq("colour index 0", a.colorIndex, 0)
    eq("colour index 2", c.colorIndex, 2)
    eq("no hero", a.hero, GAME.Hero.None)
    eq("gold to win", a.team.goldToWin, 5)
    eq("hand size", a.hand.tileCount, 4)
    check("own team and hand", a.team ~= b.team and a.hand ~= b.hand)
    eq("initial from first letter", a.initial, "A")
    eq("next unused letter, upper-cased", b.initial, "D")
    --"Ada": A and D are taken, the next character is "a" -> "A", taken, so no letter from the
    --name works; first free letter A-Z is B
    eq("fallback to A-Z", c.initial, "B")
    local d = GAME.addPlayer(cfg, "Zed", "Q")
    eq("given initial", d.initial, "Q")

    local cfg2 = GAME.newConfig()
    GAME.addPlayer(cfg2, "Bob")
    local bob2 = GAME.addPlayer(cfg2, "Bob")
    local bob3 = GAME.addPlayer(cfg2, "Bob")
    eq("unique team name", bob2.team.name, "Bob-2")
    eq("unique team name again", bob3.team.name, "Bob-2-2")
    check("duplicate player names rejected", not pcall(GAME.validate, cfg2))
    check("no players rejected", not pcall(GAME.newGame, GAME.newConfig()))
end

---------------------------------------------------------------------------- new game

---a configuration of n players P1, P2...
---@param n integer
---@param opts? table
---@return GAME.CONFIG
local function config(n, opts)
    local cfg = GAME.newConfig()
    for i = 1, n do GAME.addPlayer(cfg, "P" .. i) end
    for k, v in pairs(opts or {}) do cfg.options[k] = v end
    return cfg
end

do
    local s = GAME.newGame(config(3), lcg(1))
    local start = s.board:get(0, 0) --[[@as TILES.TILE]]
    eq("one tile on the board", s.board.count, 1)
    eq("start tile effect", start:effect(), E.Start)
    eq("start exits right, down, left", start:arrows(), TILES.arrowSet(TILES.RIGHT, TILES.DOWN, TILES.LEFT))
    for i, p in ipairs(s.players) do
        check("player " .. i .. " on start", p.x == 0 and p.y == 0)
        eq("player " .. i .. " hand", #p.hand.tiles, 4)
        eq("player " .. i .. " gold", p.unlockedGold + p.lockedGold, 0)
    end
    eq("deck after dealing", #s.deck, 107 - 12)
    check("turn player chosen", s.turnPlayer ~= nil)
    check("active = turn player", s.activePlayer == s.turnPlayer)
    check("turn flags reset", not s.moved and not s.placedTile and not s.pushedHero)
    eq("no tile effect", s.tileEffect, E.Empty)
    check("Drakon not yet on the board", not s.drakonActive)
    eq("no gold on start", s.goldOnStart, 0)
    --every tile is accounted for: hands + deck = a full deck
    local counts = {}
    ---@param t TILES.TILE
    local function add(t) counts[t:effect()] = (counts[t:effect()] or 0) + 1 end
    for _, t in ipairs(s.deck) do add(t) end
    for _, p in ipairs(s.players) do for _, t in ipairs(p.hand.tiles) do add(t) end end
    local total = 0
    for _, n in pairs(counts) do total = total + n end
    eq("hands + deck = 107", total, 107)
end

do --same seed, same game
    local a = GAME.newGame(config(4), lcg(99))
    local b = GAME.newGame(config(4), lcg(99))
    ---the first player and every hand tile, as one string
    ---@param s GAME.STATE
    ---@return string
    local function sig(s)
        ---@type (string|integer)[]
                local parts = { (s.turnPlayer --[[@as GAME.PLAYER]]).name }
        for _, p in ipairs(s.players) do
            for _, t in ipairs(p.hand.tiles) do parts[#parts + 1] = t.kind end
        end
        return table.concat(parts, ",")
    end
    eq("deterministic with a seed", sig(a), sig(b))
end

do --first player is spread over all players
    local seen = {}
    for seed = 1, 60 do
        local s = GAME.newGame(config(4), lcg(seed))
        seen[s.turnPlayer.name] = true
    end
    check("every player can go first", seen.P1 and seen.P2 and seen.P3 and seen.P4)
end

do --shared hands
    local cfg = config(3)
    cfg.players[2].hand = cfg.players[1].hand
    local s = GAME.newGame(cfg, lcg(5))
    check("players 1 and 2 share a hand", s.players[1].hand == s.players[2].hand)
    check("player 3 has their own", s.players[3].hand ~= s.players[1].hand)
    eq("shared hand filled once", #s.players[1].hand.tiles, 4)
    eq("deck after dealing two hands", #s.deck, 107 - 8)
end

do --ForceGoldTile
    for seed = 1, 30 do
        local s = GAME.newGame(config(5, { forceGoldTile = true }), lcg(seed))
        for _, p in ipairs(s.players) do
            local gold = false
            for _, t in ipairs(p.hand.tiles) do
                if t:effect() == E.OneGold or t:effect() == E.TwoGold then gold = true end
            end
            if not gold then check("every hand has gold (seed " .. seed .. ")", false); break end
            eq("hand size kept", #p.hand.tiles, 4)
        end
    end
end

do --ForceGoldTile puts the swapped-out tile where it will be drawn next
    local s = GAME.newGame(config(1), lcg(3))
    local hand = s.players[1].hand.tiles
    for i = 1, #hand do hand[i] = TILES.fromParts(E.Empty, 1) end
    local last = hand[#hand]
    local before = #s.deck
    GAME.forceGoldTile(s, s.players[1])
    check("hand now has gold", hand[#hand]:effect() == E.OneGold or hand[#hand]:effect() == E.TwoGold)
    check("old tile is next to draw", s.deck[#s.deck] == last)
    eq("deck size unchanged", #s.deck, before)
end

do --the deck never runs out
    local s = GAME.newGame(config(1), lcg(8))
    for _ = 1, #s.deck do GAME.drawTile(s) end
    eq("deck empty", #s.deck, 0)
    local t = GAME.drawTile(s)
    check("drawing from an empty deck builds a new one", t ~= nil and #s.deck == 106)
end

do --options reach the deck
    local s = GAME.newGame(config(1, { mindOrb = true }), lcg(2))
    eq("mind orb deck size", #s.deck + 4, 110)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
