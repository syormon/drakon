--building and shuffling the draw deck, ported from the original DrakonUtil.pas.
--
--the counts below were extracted from the deck builder in Drakon.exe ($00BF901C) and
--cross-checked against "Dracon Chamber Counts.xls". They agree except for one row, noted
--below. Pure Lua: no LÖVE calls.

local TILES = require('src.tiles')
local E = TILES.Effect

---deck options (a subset of the game options)
---@class DECK.OPTIONS
---@field expansionTiles? boolean must not be false: the original never supported the basic set
---@field doubleGold? boolean use Find Two Gold tiles
---@field mindOrb? boolean include Mind Control Orb tiles
---@field shuffle? boolean false to leave the deck in table order

---one row of COUNTS: effect, counts by arrow style, and the option it depends on
---@class DECK.ROW
---@field [1] TILES.EFFECT
---@field [2] integer[] tiles with no arrows, one, two adjacent, two opposite, three
---@field when? string option name, or "not <option>"

---@class DECK
local lib = {}

--arrows given to every tile of each style ($00E049A8 in the original):
--none, Up, Up+Right, Up+Down, Up+Right+Down. Tiles are rotated freely when placed.
---@type {[TILES.STYLE]:TILES.ARROWS}
lib.STYLE_ARROWS = { [0] = 0, 1, 3, 5, 7 }

--tiles per chamber, by arrow style: { none, one, two adjacent, two opposite, three }.
--in the original's order. `when` names the game option a row depends on.
---@type DECK.ROW[]
lib.COUNTS = {
    { E.Empty,          { 0, 5, 8, 5, 4 } },
    { E.Base,           { 0, 0, 0, 2, 0 } },
    { E.Destroy,        { 0, 0, 3, 0, 0 } },
    { E.DrakonMoves,    { 0, 0, 4, 0, 0 } },
    { E.DrakonsBargain, { 0, 0, 2, 0, 0 } },
    { E.DrakonsDue,     { 0, 0, 0, 0, 3 } },
    { E.Escape,         { 0, 0, 2, 0, 0 } },
    { E.OneGold,        { 0, 5, 6, 5, 2 } },
    --two extra one-arrow gold tiles: "Find Two Gold" with the double-gold option,
    --otherwise two more "Find One Gold".
    { E.TwoGold,        { 0, 2, 0, 0, 0 }, when = "doubleGold" },
    { E.OneGold,        { 0, 2, 0, 0, 0 }, when = "not doubleGold" },
    { E.Float,          { 0, 0, 2, 0, 0 } },
    { E.FriendlyVisit,  { 2, 0, 0, 0, 0 } },
    { E.HeavyGale,      { 0, 0, 3, 0, 0 } },
    { E.LockedChest,    { 0, 0, 2, 0, 0 } },
    { E.MagicHarp,      { 0, 0, 2, 0, 0 } },
    { E.MagicShift,     { 0, 0, 0, 3, 0 } },
    { E.MagicVortex,    { 3, 0, 0, 0, 0 } },
    { E.Map,            { 0, 0, 3, 0, 0 } },
    { E.MasterKey,      { 3, 0, 0, 0, 0 } },
    { E.MindOrb,        { 0, 0, 3, 0, 0 }, when = "mindOrb" },
    { E.MovingTiles,    { 0, 0, 2, 0, 0 } },
    { E.Rotate,         { 0, 0, 3, 0, 0 } },
    { E.Passage,        { 0, 4, 0, 0, 0 } },
    { E.SmallRoom,      { 0, 0, 2, 0, 0 } },
    --Start is not in the deck; it begins on the board with three exits (see START_ARROWS).
    { E.StealLeft,      { 0, 0, 3, 0, 0 } },
    --the spreadsheet has 3 here; the original game builds 2 (it reuses the count table of the
    --find Two Gold row). Decided: keep 2, as the game shipped.
    { E.StealRight,     { 0, 2, 0, 0, 0 } },
    { E.StrongWind,     { 0, 0, 3, 0, 0 } },
    { E.Void,           { 2, 0, 0, 0, 0 } },
    { E.Tornado,        { 0, 0, 2, 0, 0 } },
    { E.WishingWell,    { 0, 0, 0, 0, 3 } },
}

--the Start chamber's arrows: Right, Down and Left, as the original places it ($00BE3AF0).
lib.START_ARROWS = TILES.arrowSet(TILES.RIGHT, TILES.DOWN, TILES.LEFT)

---whether a COUNTS row is in the deck with these options
---@param row DECK.ROW
---@param options DECK.OPTIONS
---@return boolean
local function applies(row, options)
    if not row.when then return true end
    local negate, name = row.when:match("^(not )(.+)$")
    if negate then return not options[name] end
    return options[row.when] and true or false
end

---Fisher-Yates shuffle, as in the original ($00BF93E4): each position i swaps with a random
---position from i to the end. `random(lo, hi)` returns an integer in [lo, hi].
---@generic T
---@param list T[]
---@param random? fun(lo:integer, hi:integer):integer default math.random
---@return T[] list the same list, shuffled in place
function lib.shuffle(list, random)
    random = random or math.random
    for i = 1, #list - 1 do
        local j = random(i, #list)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

---build the deck.
---options.expansionTiles  must be true (default); the original never supported the basic set
---options.doubleGold      use Find Two Gold tiles
---options.mindOrb         include Mind Control Orb tiles
---options.shuffle         false to leave the deck in table order (default: shuffled)
---random                  optional random(lo, hi) function, e.g. love.math.random
---@param options? DECK.OPTIONS
---@param random? fun(lo:integer, hi:integer):integer
---@return TILES.TILE[] deck drawn from the end
function lib.build(options, random)
    options = options or {}
    if options.expansionTiles == false then
        error("Basic tile set not yet supported", 2)
    end
    local list = {}
    for _, row in ipairs(lib.COUNTS) do
        if applies(row, options) then
            local effect, counts = row[1], row[2]
            for style = 0, 4 do
                local kind = TILES.makeKind(effect, lib.STYLE_ARROWS[style])
                for _ = 1, counts[style + 1] do
                    list[#list + 1] = TILES.new(kind)
                end
            end
        end
    end
    if options.shuffle ~= false then lib.shuffle(list, random) end
    return list
end

---the Start tile that begins on the board.
---@return TILES.TILE
function lib.startTile()
    return TILES.fromParts(E.Start, lib.START_ARROWS)
end

---count tiles in a list by effect: { [effect] = n }.
---@param list TILES.TILE[]
---@return {[TILES.EFFECT]:integer}
function lib.countByEffect(list)
    local counts = {}
    for _, t in ipairs(list) do
        local e = t:effect()
        counts[e] = (counts[e] or 0) + 1
    end
    return counts
end

return lib
