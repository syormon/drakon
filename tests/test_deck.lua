--tests for src/deck.lua. Runs under plain Lua, from the repository's top folder:
--lua tests/test_deck.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local DECK = require('src.deck')
local E, S = TILES.Effect, TILES.Style

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

--"Dracon Chamber Counts.xls", Sheet1, as typed in 2004: { none, one, two adj, two opp, three }
local SPREADSHEET = {
    [E.Base] = { 0, 0, 0, 2, 0 },          [E.Empty] = { 0, 5, 8, 5, 4 },
    [E.Destroy] = { 0, 0, 3, 0, 0 },       [E.DrakonMoves] = { 0, 0, 4, 0, 0 },
    [E.DrakonsBargain] = { 0, 0, 2, 0, 0 }, [E.DrakonsDue] = { 0, 0, 0, 0, 3 },
    [E.Escape] = { 0, 0, 2, 0, 0 },        [E.OneGold] = { 0, 5, 6, 5, 2 },
    [E.TwoGold] = { 0, 2, 0, 0, 0 },       [E.Float] = { 0, 0, 2, 0, 0 },
    [E.FriendlyVisit] = { 2, 0, 0, 0, 0 }, [E.HeavyGale] = { 0, 0, 3, 0, 0 },
    [E.LockedChest] = { 0, 0, 2, 0, 0 },   [E.MagicHarp] = { 0, 0, 2, 0, 0 },
    [E.MagicShift] = { 0, 0, 0, 3, 0 },    [E.MagicVortex] = { 3, 0, 0, 0, 0 },
    [E.Map] = { 0, 0, 3, 0, 0 },           [E.MasterKey] = { 3, 0, 0, 0, 0 },
    [E.MindOrb] = { 0, 0, 3, 0, 0 },       [E.MovingTiles] = { 0, 0, 2, 0, 0 },
    [E.Rotate] = { 0, 0, 3, 0, 0 },        [E.Passage] = { 0, 4, 0, 0, 0 },
    [E.SmallRoom] = { 0, 0, 2, 0, 0 },     [E.Start] = { 0, 0, 0, 0, 1 },
    [E.StealLeft] = { 0, 0, 3, 0, 0 },     [E.StealRight] = { 0, 3, 0, 0, 0 },
    [E.StrongWind] = { 0, 0, 3, 0, 0 },    [E.Void] = { 2, 0, 0, 0, 0 },
    [E.Tornado] = { 0, 0, 2, 0, 0 },       [E.WishingWell] = { 0, 0, 0, 0, 3 },
}
local SPREADSHEET_TOTAL = 112

---counts[effect][style + 1] for a built deck
---tiles per effect and arrow style
---@param list TILES.TILE[]
---@return {[TILES.EFFECT]:integer[]}
local function tally(list)
    local t = {}
    for e = 0, 29 do t[e] = { 0, 0, 0, 0, 0 } end
    for _, tile in ipairs(list) do
        local row = t[tile:effect()]
        row[tile:style() + 1] = row[tile:style() + 1] + 1
    end
    return t
end
---the first five counts match
---@param a integer[]
---@param b integer[]
---@return boolean
local function same(a, b)
    for i = 1, 5 do if a[i] ~= b[i] then return false end end
    return true
end
---@param r integer[]
---@return string
local function fmt(r) return "{" .. table.concat(r, ",") .. "}" end

--spreadsheet total is consistent with its rows
local sum = 0
for _, r in pairs(SPREADSHEET) do for i = 1, 5 do sum = sum + r[i] end end
eq("spreadsheet rows add up to its total", sum, SPREADSHEET_TOTAL)

--full deck (double gold + mind orb) against the spreadsheet
local full = tally(DECK.build({ doubleGold = true, mindOrb = true, shuffle = false }))
for e = 0, 29 do
    local want = SPREADSHEET[e]
    if e == E.Start then
        eq("Start is not in the deck", full[e][5], 0)
    elseif e == E.StealRight then
        --known difference: the game builds 2, the spreadsheet says 3
        check("StealRight as the game built it", same(full[e], { 0, 2, 0, 0, 0 }), fmt(full[e]))
    else
        check("matches spreadsheet: " .. TILES.EffectName[e], same(full[e], want),
              fmt(full[e]) .. " vs " .. fmt(want))
    end
end

--totals per option set
eq("deck size, no options", #DECK.build({ shuffle = false }), 107)
eq("deck size, double gold", #DECK.build({ doubleGold = true, shuffle = false }), 107)
eq("deck size, mind orb", #DECK.build({ mindOrb = true, shuffle = false }), 110)
eq("full deck = spreadsheet - Start - 1 StealRight", #DECK.build({ doubleGold = true, mindOrb = true }),
   SPREADSHEET_TOTAL - 2)

--option effects
local plain = tally(DECK.build({ shuffle = false }))
eq("no Two Gold without the option", plain[E.TwoGold][2], 0)
eq("Two Gold become One Gold", plain[E.OneGold][2], 7)
eq("no Mind Orb without the option", plain[E.MindOrb][3], 0)
check("basic set unsupported", not pcall(DECK.build, { expansionTiles = false }))

--every tile uses the standard arrows for its style
for _, t in ipairs(DECK.build({ mindOrb = true, shuffle = false })) do
    if t:arrows() ~= DECK.STYLE_ARROWS[t:style()] then
        check("standard arrows", false, tostring(t)); break
    end
end
eq("style arrows: three = Up+Right+Down", DECK.STYLE_ARROWS[S.Three],
   TILES.arrowSet(TILES.UP, TILES.RIGHT, TILES.DOWN))
eq("start tile", tostring(DECK.startTile()), "Start [Right, Down, Left]")

--unshuffled order follows the table: first tile is a one-arrow Empty Chamber
local ordered = DECK.build({ shuffle = false })
eq("table order", tostring(ordered[1]), "Empty Chamber [Up]")

---shuffling: deterministic with a seeded generator, and only reorders
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
local a = DECK.build({ mindOrb = true }, lcg(42))
local b = DECK.build({ mindOrb = true }, lcg(42))
local c = DECK.build({ mindOrb = true }, lcg(7))
---the kinds of a list of tiles, as one string
---@param list TILES.TILE[]
---@return string
local function kinds(list) local k = {} for i, t in ipairs(list) do k[i] = t.kind end return table.concat(k, ",") end
eq("same seed, same deck", kinds(a), kinds(b))
check("different seed, different deck", kinds(a) ~= kinds(c))
check("shuffled differs from table order", kinds(a) ~= kinds(DECK.build({ mindOrb = true, shuffle = false })))
local before, after = tally(DECK.build({ mindOrb = true, shuffle = false })), tally(a)
local permutation = true
for e = 0, 29 do if not same(before[e], after[e]) then permutation = false end end
check("shuffle keeps the same tiles", permutation)
check("tiles are separate objects", a[1] ~= a[2] and (a[1]:rotate(1) or true) and a[2].kind ~= nil)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
