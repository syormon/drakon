--tile encoding and tile objects, ported from the original DrakonUtil.pas.
--
--a tile "kind" packs a chamber into one 16-bit number, exactly as the Delphi version did:
--bits 0..4  effect (0..29, see tiles.Effect)
--bits 5..8  exit arrows (bit 5 = up, 6 = right, 7 = down, 8 = left)
--keeping the same encoding means kinds from the original game (e.g. in old save files)
--mean the same thing here.
--
--pure Lua: works under LuaJIT (LÖVE) and plain Lua 5.1+, so it can be tested without LÖVE.

---@alias TILES.KIND integer a tile packed into one number: effect in bits 0-4, arrows in bits 5-8
---@alias TILES.ARROWS integer an arrow set 0-15: bit d is set when there is an exit in direction d
---@alias TILES.DIRECTION 0|1|2|3 up, right, down, left

---@class TILES
local lib = {}

---------------------------------------------------------------------------- effects

--the number is the value stored in the low 5 bits of a kind (the original TEffect order)
---@enum TILES.EFFECT
lib.Effect = {
    Empty = 0,
    Base = 1,
    Destroy = 2,
    DrakonMoves = 3,
    DrakonsBargain = 4,
    DrakonsDue = 5,
    Escape = 6,
    OneGold = 7,
    TwoGold = 8,
    Float = 9,
    FriendlyVisit = 10,
    HeavyGale = 11,
    LockedChest = 12,
    MagicHarp = 13,
    MagicShift = 14,
    MagicVortex = 15,
    Map = 16,
    MasterKey = 17,
    MindOrb = 18,
    MovingTiles = 19,
    Rotate = 20,
    Passage = 21,
    SmallRoom = 22,
    Start = 23,
    StealLeft = 24,
    StealRight = 25,
    StrongWind = 26,
    Void = 27,
    Tornado = 28,
    WishingWell = 29,
}

---effect names by number: tiles.EffectId[12] == "LockedChest"
---@type {[TILES.EFFECT]:string}
lib.EffectId = {}
for id, e in pairs(lib.Effect) do lib.EffectId[e] = id end
lib.EFFECT_COUNT = 30

--original display names and rules text, verbatim from Drakon.exe
---@type {[TILES.EFFECT]:string}
lib.EffectName = {
    [0] = "Empty Chamber", "Base Structure", "Destroy a Chamber", "Drakon Moves",
    "Drakon's Bargain", "Drakon's Due", "Escape", "Find One Gold", "Find Two Gold",
    "Floating Chamber", "Friendly Visit", "Heavy Gale", "Locked Chest", "Magic Harp",
    "Magic Shift", "Magic Vortex", "Map Chamber", "Master Key", "Mind Control Orb",
    "Moving Tiles", "Rotate Chamber", "Secret Passage", "Small Room", "Start",
    "Steal Coin Left", "Steal Coin Right", "Strong Wind", "The Void", "Tornado", "Wishing Well",
}

---@type {[TILES.EFFECT]:string}
lib.EffectHelp = {
    [0] = "This is just an ordinary room in Drakon's dungeon.",
    "This chamber, and the four adjacent to it, cannot be moved, rotated, destroyed, or altered in any way by other chamber effects.",
    "[Entering] You may choose an unoccupied room and discard it to the bottom of the draw pile.",
    "The first time this tile is placed, put Drakon in an unoccupied chamber.  Upon entry, you may move Drakon up to 3 spaces, ignoring arrows and effects.  Drakon may never move into or through a Small Room.",
    "[Entering] You may pay one unlocked gold to the Hoard to take one unoccupied room from the board (add it to your hand).",
    "[Entering] You lose one coin (place it on the Start Chamber).",
    "[Placing] You may move your hero onto this tile as you place it.",
    "[Entering] You must take one gold from Drakon's Hoard.",
    "[Entering] You must take two gold from Drakon's Hoard.",
    "[Entering] You may move (and rotate) this room to any legal location.",
    "[Leaving] When you leave this room, you must go to a chamber occupied by another hero.",
    "[Leaving] When you exit, you must move 3 spaces (ignore the spaces you skip over).  Treat tiles with no exit arrows (i.e., Vortex, Friendly Visit, etc.) as having exit arrows in every direction that does not have an arrow pointing in from another room.",
    "[Entering] Set aside your coins; they can't be lost to theft, chamber effects, or Drakon attacking.",
    "If an adjacent room has an arrow pointing towards the Harp, Heroes must move into this room.  If a hero is in a room that has multiple exits leading into Harp rooms, the player may choose which Harp to enter.",
    "[Entering] You may choose an empty room, add it to your hand, and replace it with a tile from your hand that you must play legally.",
    "[Leaving] When you leave this room, you may move to any chamber on the board.  A hero in a Magic Vortex may be moved via Mind Control Orb to any chamber on the board by the player operating the mind orb.",
    "[Entering] Take a chamber at random from an opponent's hand, and add it to your own hand.",
    "[Leaving] When you leave this room, you may exit in any direction, even against arrows.",
    "[Entering] You may legally move another hero (except heroes in the Void), who must then carry out any relevant chamber effects.  If the hero you move is currently on the Magic Vortex, you may move him to any room on the board.",
    "[Entering] You may choose two unoccupied rooms with the same number and configuration of arrows, and switch them (preserving the arrows at both locations).",
    "[Entering] You may rotate any room, even if occupied, so that the arrows are arranged legally.  You may even rotate the Start Chamber.",
    "[Leaving] When you leave this room, you may move into the Start Chamber, or any other Secret Passage or Escape tile on the board.",
    "Only one Hero can be in this room at any time.  Drakon may never enter or pass through this room.",
    "This is the room where heroes return when Drakon attacks.  This room may be rotated or moved, but cannot be destroyed or removed.  When you enter this room (even as a result of Drakon attacking you), you must pick up one coin (if any are in this room).",
    "[Entering] Steal one coin (if available) from the player on your left.",
    "[Entering] Steal one coin (if available) from the player on your right.",
    "[Leaving] When you exit, you must move 2 spaces (ignore the spaces you skip over).  Treat tiles with no exit arrows (i.e., Vortex, Friendly Visit, etc.) as having exit arrows in every direction that does not have an arrow pointing in from another room.",
    "[Entering] Remove your hero from play and lose your next turn.  On your following turn, you may not place a tile, but instead you must move your hero in any chamber on the board.",
    "[Leaving] When you exit, you may move up to 4 spaces (ignore the spaces you skip over).  Treat tiles with no exit arrows (i.e., Vortex, Friendly Visit, etc.) as having exit arrows in every direction that does not have an arrow pointing in from another room.",
    "[Entering] You lose one coin to Drakon's Hoard.",
}

---------------------------------------------------------------------------- arrows

--directions, in the original TArrow order. Each is also a bit in an arrow set.
lib.UP, lib.RIGHT, lib.DOWN, lib.LEFT = 0, 1, 2, 3
---@type TILES.DIRECTION[]
lib.DIRECTIONS = { 0, 1, 2, 3 }
---@type {[TILES.DIRECTION]:string}
lib.ArrowName = { [0] = "Up", "Right", "Down", "Left" }

local BIT = { [0] = 1, 2, 4, 8 }   --integer bit values (powers of 2 would give floats in Lua 5.3+)
local DX = { [0] = 0, 1, 0, -1 }
local DY = { [0] = -1, 0, 1, 0 }

---an arrow set is a number 0..15; bit d is set when there is an exit in direction d.
---@param arrows TILES.ARROWS
---@param dir TILES.DIRECTION
---@return boolean
local function has(arrows, dir)
    return math.floor(arrows / BIT[dir]) % 2 == 1
end
lib.hasArrow = has

---arrow set with an exit in each of the given directions
---@param ... TILES.DIRECTION
---@return TILES.ARROWS
function lib.arrowSet(...)
    local s = 0
    for _, d in ipairs({ ... }) do
        if not has(s, d) then s = s + BIT[d] end
    end
    return s
end

---the direction facing the other way
---@param dir TILES.DIRECTION
---@return TILES.DIRECTION
function lib.opposite(dir) return (dir + 2) % 4 end
---the next direction clockwise
---@param dir TILES.DIRECTION
---@return TILES.DIRECTION
function lib.clockwise(dir) return (dir + 1) % 4 end

---step one square from (x, y) in a direction. Up is y - 1, as in the original.
---@param x integer
---@param y integer
---@param dir TILES.DIRECTION
---@return integer x
---@return integer y
function lib.neighbor(x, y, dir)
    return x + DX[dir], y + DY[dir]
end

---arrow names joined by commas, e.g. "Up, Left"
---@param arrows TILES.ARROWS
---@return string
function lib.arrowsToString(arrows)
    local parts = {}
    for d = 0, 3 do
        if has(arrows, d) then parts[#parts + 1] = lib.ArrowName[d] end
    end
    return table.concat(parts, ", ")
end

---------------------------------------------------------------------------- arrow styles

---arrow styles: how many arrows and how they sit (the original TArrowStyle)
---@enum TILES.STYLE
lib.Style = {
    None = 0,
    One = 1,
    TwoAdjacent = 2,
    TwoOpposite = 3,
    Three = 4,
}
---@type {[TILES.STYLE]:string}
lib.StyleName = { [0] = "No Arrows", "One Arrow", "Two Adjacent Arrows",
                    "Two Opposite Arrows", "Three Arrows" }

---same algorithm as the original: two arrows are adjacent unless they alternate around the
---tile, i.e. unless every pair of neighbouring sides differs.
---@param arrows TILES.ARROWS
---@return TILES.STYLE
function lib.arrowsToStyle(arrows)
    local count, prev, adjacent = 0, false, false
    for d = 0, 3 do
        local h = has(arrows, d)
        if h then count = count + 1 end
        if not adjacent and d > 0 and h == prev then adjacent = true end
        prev = h
    end
    if count == 0 then return lib.Style.None
    elseif count == 1 then return lib.Style.One
    elseif count == 2 then return adjacent and lib.Style.TwoAdjacent or lib.Style.TwoOpposite
    elseif count == 3 then return lib.Style.Three
    end
    error("Invalid tile arrows", 2)
end

---------------------------------------------------------------------------- kinds

---the chamber effect of a kind; errors for an invalid kind
---@param kind TILES.KIND
---@return TILES.EFFECT
function lib.kindEffect(kind)
    local e = kind % 32
    if e >= lib.EFFECT_COUNT then
        error(("Invalid tile kind: %d"):format(kind), 2)
    end
    return e
end

---the exit arrows of a kind
---@param kind TILES.KIND
---@return TILES.ARROWS
function lib.kindArrows(kind)
    return math.floor(kind / 32) % 16
end

---pack an effect and arrows into a kind
---@param effect TILES.EFFECT
---@param arrows TILES.ARROWS
---@return TILES.KIND
function lib.makeKind(effect, arrows)
    return effect + arrows * 32
end

---the same chamber with other arrows
---@param kind TILES.KIND
---@param arrows TILES.ARROWS
---@return TILES.KIND
function lib.kindSetArrows(kind, arrows)
    return lib.makeKind(lib.kindEffect(kind), arrows)
end

---the arrow style of a kind
---@param kind TILES.KIND
---@return TILES.STYLE
function lib.kindStyle(kind)
    return lib.arrowsToStyle(lib.kindArrows(kind))
end

---turn an arrow set clockwise
---@param arrows TILES.ARROWS
---@param quarterTurns integer 0 or more
---@return TILES.ARROWS
local function rotateArrows(arrows, quarterTurns)
    for _ = 1, quarterTurns do
        local r = 0
        for d = 0, 3 do
            if has(arrows, d) then r = r + BIT[lib.clockwise(d)] end
        end
        arrows = r
    end
    return arrows
end

---Rotate clockwise by a number of quarter turns (negative = anticlockwise).
---@param kind TILES.KIND
---@param quarterTurns integer
---@return TILES.KIND
function lib.rotateKind(kind, quarterTurns)
    quarterTurns = quarterTurns % 4   --Lua's % is already non-negative for a positive divisor
    if quarterTurns == 0 then return kind end
    return lib.makeKind(lib.kindEffect(kind), rotateArrows(lib.kindArrows(kind), quarterTurns))
end

---------------------------------------------------------------------------- Tile objects

---a tile object: one chamber, in a hand or on the board
---@class TILES.TILE
---@field kind TILES.KIND
local Tile = {}
Tile.__index = Tile
lib.Tile = Tile

---new tile object
---@param kind? TILES.KIND default 0, an Empty Chamber with no exits
---@return TILES.TILE
function lib.new(kind) return setmetatable({ kind = kind or 0 }, Tile) end
---new tile object from an effect and arrows
---@param effect TILES.EFFECT
---@param arrows TILES.ARROWS
---@return TILES.TILE
function lib.fromParts(effect, arrows) return lib.new(lib.makeKind(effect, arrows)) end

---@return TILES.EFFECT
function Tile:effect() return lib.kindEffect(self.kind) end
---@return TILES.ARROWS
function Tile:arrows() return lib.kindArrows(self.kind) end
---@return TILES.STYLE
function Tile:style() return lib.kindStyle(self.kind) end
---original display name, e.g. "Find One Gold"
---@return string
function Tile:effectName() return lib.EffectName[self:effect()] end
---original rules text
---@return string
function Tile:helpText() return lib.EffectHelp[self:effect()] end
---e.g. "Two Adjacent Arrows"
---@return string
function Tile:styleName() return lib.StyleName[self:style()] end
---@param dir TILES.DIRECTION
---@return boolean
function Tile:hasExit(dir) return has(self:arrows(), dir) end
---turn the tile clockwise in place
---@param quarterTurns integer negative turns anticlockwise
function Tile:rotate(quarterTurns) self.kind = lib.rotateKind(self.kind, quarterTurns) end
---a new tile object of the same kind
---@return TILES.TILE
function Tile:clone() return lib.new(self.kind) end

---arrows may only be re-arranged, never changed to a different style.
---@param arrows TILES.ARROWS
function Tile:setArrows(arrows)
    if lib.kindStyle(self.kind) ~= lib.arrowsToStyle(arrows) then
        error("TTile.SetArrows: Cannot change arrow style", 2)
    end
    self.kind = lib.kindSetArrows(self.kind, arrows)
end

---e.g. "Find One Gold [Up, Left]"
---@return string
function Tile:__tostring()
    return ("%s [%s]"):format(self:effectName(), lib.arrowsToString(self:arrows()))
end

return lib
