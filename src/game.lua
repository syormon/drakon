--game configuration, game state and setup, ported from TDrakonGame in the original
--DrakonGame.pas. Addresses of the original routines are noted for reference.
--pure Lua: no LÖVE calls.

local TILES = require('src.tiles')
local DECK = require('src.deck')
local BOARD = require('src.board')
local E = TILES.Effect
local unpack = table.unpack or unpack

---a team: players on it pool their gold
---@class GAME.TEAM
---@field name string
---@field goldToWin integer

---a hand in the configuration; players naming the same table share one hand
---@class GAME.HANDCONFIG
---@field name string
---@field tileCount integer hand limit at the start

---one seat in the configuration
---@class GAME.PLAYERCONFIG
---@field name string
---@field initial string one letter
---@field hero GAME.HERO
---@field colorIndex integer index into GAME.COLORS
---@field team GAME.TEAM
---@field hand GAME.HANDCONFIG
---@field ai? string computer player level (AI.LEVELS), nil for a person
---@field remote? boolean played over the network (session.lua)
---@field peer? integer the network connection playing it
---@field dropped? string name of who played it over the network and left (a computer plays it meanwhile)

---the rule options (the original TDrakonConfig)
---@class GAME.OPTIONS : DECK.OPTIONS
---@field expansionTiles boolean
---@field doubleGold boolean
---@field mindOrb boolean
---@field forceGoldTile boolean every starting hand gets at least one gold tile
---@field separateTeamStart boolean each team starts in its own room of a small dungeon
---@field dwarfEnhancement boolean kept, no effect yet
---@field secretEscape boolean Secret Passages also lead to Escape tiles
---@field secretStart boolean Secret Passages also lead to the Start chamber
---@field emptyHand boolean a player with a hand limit of 0 may draw a tile as their action
---@field stealAsLocked boolean stolen coins are locked
---@field bigDungeonRounds integer opening rounds in which nobody may move
---@field startTimeLimit integer seconds, kept, no clock yet
---@field turnTimeBonus integer seconds, kept, no clock yet

---a game configuration
---@class GAME.CONFIG
---@field players GAME.PLAYERCONFIG[] in order of play
---@field options GAME.OPTIONS

---a hand in play
---@class GAME.HAND
---@field name string
---@field tileLimit integer
---@field tiles TILES.TILE[]

---a player in play
---@class GAME.PLAYER
---@field name string
---@field initial string
---@field hero GAME.HERO
---@field colorIndex integer
---@field team GAME.TEAM
---@field config GAME.PLAYERCONFIG
---@field unlockedGold integer
---@field lockedGold integer
---@field usedHero boolean the once-per-game hero ability is spent
---@field skipTurn boolean loses their next turn (the Void)
---@field x integer|nil nil while in the Void
---@field y integer|nil
---@field hand GAME.HAND shared with players whose config names the same hand

---a coin a Knight may take back (a chain, newest first)
---@class GAME.GOLDSTATE
---@field player GAME.PLAYER the Knight who lost it
---@field lostTo GAME.PLAYER|"start"|nil who took it: a player, the Start chamber, or nowhere
---@field next GAME.GOLDSTATE|nil

---a random number function: random(lo, hi) is a whole number from lo to hi (math.random,
---love.math.random, or a GAME.RNG)
---@alias GAME.RANDOM fun(lo:integer, hi:integer):integer

---the game in play (the original TGameState / TDrakonGame)
---@class GAME.STATE
---@field config GAME.CONFIG
---@field random GAME.RANDOM
---@field deck TILES.TILE[] drawn from the end; rebuilt and reshuffled whenever empty
---@field board BOARD
---@field players GAME.PLAYER[]
---@field turnPlayer GAME.PLAYER|nil whose turn it is
---@field activePlayer GAME.PLAYER|nil who acts now (nil when the game is over)
---@field goldOnStart integer coins lying on the Start chamber
---@field drakonActive boolean Drakon is on the board
---@field drakonX integer|nil
---@field drakonY integer|nil
---@field turnNumber integer
---@field moved boolean the turn player has moved this turn
---@field placedTile boolean the turn player has placed (or drawn) a tile this turn
---@field pushedHero boolean the Barbarian pushed this turn
---@field pendingActivePlayer GAME.PLAYER|nil acts next: their hero was moved into a chamber with a choice
---@field tileEffect TILES.EFFECT the chamber effect waiting to be resolved
---@field escapeX integer the Escape tile just placed
---@field escapeY integer
---@field importantLocs table unused, kept from the original
---@field savedGoldState GAME.GOLDSTATE|nil
---@field savedState GAME.STATE|nil the undo point
---@field noUndo? boolean keep no undo points (the AI's trial copies)

---what a hero entering a chamber did
---@class GAME.MOVERESULT
---@field gold integer coins gained (negative: lost)
---@field attacked? boolean Drakon was there: sent back to Start
---@field locked? integer coins locked in a Locked Chest
---@field stole? GAME.PLAYER took a coin from this player
---@field void? boolean fell into the Void
---@field wizard? boolean the move went through a wall (Wizard)
---@field second? boolean a second move (Amazon)
---@field tookTile? TILES.TILE the Barbarian took this tile
---@field orb? boolean (set by the game screen) the hero was moved by someone else: Mind Control Orb, Barbarian

---what moving Drakon did
---@class GAME.DRAKONRESULT
---@field attacked GAME.PLAYER[]
---@field pickedUp boolean the victims each picked up a coin on Start

---what finishing an action did
---@class GAME.TURNRESULT
---@field skipped GAME.PLAYER[] lost their turn in the Void
---@field winners? GAME.TEAMTOTAL[] the game is over and these teams won
---@field drawn? TILES.TILE[] drawn to refill the hand
---@field stuck? boolean nobody can act: the game is over without a winner

---a team's gold
---@class GAME.TEAMTOTAL
---@field name string
---@field goldToWin integer
---@field gold integer
---@field players GAME.PLAYER[]

---@class GAME.PLACEMENT
---@field x integer
---@field y integer
---@field turns integer clockwise quarter turns from the tile's current orientation

---@class GAME.MOVE
---@field x integer
---@field y integer
---@field wizard boolean takes the Wizard's ability

---a separate team start layout: rooms { x, y, exits } and team starting squares { x, y }
---@class GAME.TEAMSTART
---@field rooms {[1]:integer, [2]:integer, [3]:string}[]
---@field starts {[1]:integer, [2]:integer}[]

---@class GAME
local lib = {}

--player colours, by ColorIndex (each has a Char_<name>.gif token in the image folders).
---@type {[integer]:string}
lib.COLORS = { [0] = "Red", "Blue", "Yellow", "Green", "Orange", "Purple", "White", "Magenta",
                "Aqua", "Black", "Brown_Eye", "Blue_Eye", "Black_Eye", "Green_Eye" }

---@enum GAME.HERO
lib.Hero = {
    None = 0,
    Amazon = 1,
    Barbarian = 2,
    Dwarf = 3,
    Knight = 4,
    Thief = 5,
    Wizard = 6,
}
---@type {[GAME.HERO]:string}
lib.HeroName = { [0] = "None", "Amazon", "Barbarian", "Dwarf", "Knight", "Thief", "Wizard" }

lib.DEFAULT_GOLD_TO_WIN = 5   --per team, set when a player is added ($00BE4054)
lib.DEFAULT_HAND_SIZE = 4     --tiles in a new player's hand

--the Start chamber begins at (0, 0) with exits Right, Down and Left ($00BE3AF0 = $0E).
lib.START_ARROWS = DECK.START_ARROWS

---------------------------------------------------------------------------- configuration

---game options (the original TDrakonConfig fields).
---@return GAME.CONFIG
function lib.newConfig()
    return {
        players = {},
        options = {
            expansionTiles = true,     --the basic set was never supported
            doubleGold = false,        --two of the gold tiles are Find Two Gold
            mindOrb = false,           --include Mind Control Orb tiles
            forceGoldTile = false,     --every starting hand gets at least one gold tile
            separateTeamStart = false, --each team starts in its own room of a small pre-built dungeon
            dwarfEnhancement = false,
            secretEscape = false,
            secretStart = false,
            emptyHand = false,
            stealAsLocked = false,
            bigDungeonRounds = 0,
            startTimeLimit = 0,
            turnTimeBonus = 0,
        },
    }
end

---upper-case a lower-case letter
---@param ch string
---@return string
local function upper(ch)
    if ch:match("^%l$") then return ch:upper() end
    return ch
end

---add a player with the original defaults ($00BE4054):
---colour = next colour index, no hero, own team (GoldToWin 5), own hand of 4 tiles.
---team names are made unique by appending "-2".
---initial: the given one, else the first character of the name (lower case letters made
---upper case) not used by another player, else the first unused letter A-Z.
---@param config GAME.CONFIG
---@param name string
---@param initial? string
---@return GAME.PLAYERCONFIG
function lib.addPlayer(config, name, initial)
    local used = {}
    for _, p in ipairs(config.players) do
        if p.initial then used[upper(p.initial)] = true end
    end

    local teamName = name
    ---@param n string
    ---@return boolean|nil
    local function teamTaken(n)
        for _, p in ipairs(config.players) do
            if p.team.name == n then return true end
        end
    end
    while teamTaken(teamName) do teamName = teamName .. "-2" end

    local p = {
        name = name,
        hero = lib.Hero.None,
        colorIndex = #config.players,
        team = { name = teamName, goldToWin = lib.DEFAULT_GOLD_TO_WIN },
        hand = { name = name, tileCount = lib.DEFAULT_HAND_SIZE },
    }

    if initial and initial ~= "" then
        p.initial = initial
    else
        for ch in name:gmatch(".") do
            local c = upper(ch)
            if not used[c] then p.initial = c; break end
        end
        if not p.initial then
            for b = string.byte("A"), string.byte("Z") do
                local c = string.char(b)
                if not used[c] then p.initial = c; break end
            end
        end
    end

    config.players[#config.players + 1] = p
    return p
end

---check a configuration before starting ($00BE3AF4).
---errors for duplicate names or no players
---@param config GAME.CONFIG
function lib.validate(config)
    local seen = {}
    for _, p in ipairs(config.players) do
        if seen[p.name] then error(('Multiple players named "%s"'):format(p.name), 2) end
        seen[p.name] = true
    end
    if #config.players == 0 then error("No players", 2) end
end

---------------------------------------------------------------------------- state

---a random number generator whose whole state is one number kept in the game state, so a
---copy of the game (as sent over the network) goes on to draw the same numbers. Called like
---a function: random(lo, hi). The "minimal standard" generator (Park and Miller): its
---numbers stay exact both as Lua integers and as doubles (LuaJIT).
---@class GAME.RNG
---@field seed integer 1 .. 2147483646
---@overload fun(lo:integer, hi:integer):integer

---the generators' metatable (also how serial.lua knows them)
---@type metatable
lib.RNG = {
    ---draw a number from lo to hi
    ---@param self GAME.RNG
    ---@param lo integer
    ---@param hi integer
    ---@return integer
    __call = function(self, lo, hi)
        self.seed = (self.seed * 16807) % 2147483647
        return lo + self.seed % (hi - lo + 1)
    end,
}

---a generator started from `seed` (any whole number; 0 and its multiples are moved). It is
---a GAME.RNG (a table, so it can be sent), used as a random function.
---@param seed integer
---@return GAME.RANDOM
function lib.newRandom(seed)
    seed = math.floor(seed) % 2147483647
    if seed == 0 then seed = 1 end
    return setmetatable({ seed = seed }, lib.RNG) --[[@as GAME.RANDOM]]
end

---a fresh game state (the original TGameState / TDrakonGame fields).
---@param config GAME.CONFIG
---@param random? GAME.RANDOM
---@return GAME.STATE
local function newState(config, random)
    return {
        config = config,
        random = random or math.random,
        deck = {},                --drawn from the end; rebuilt and reshuffled whenever empty
        board = BOARD:new(),
        players = {},
        turnPlayer = nil,
        activePlayer = nil,
        goldOnStart = 0,          --coins lying on the Start chamber
        drakonActive = false,     --Drakon enters when a Drakon Moves tile is first placed
        drakonX = nil, drakonY = nil,
        turnNumber = 1,           --set to 1 when the game object is created ($00BE16C4)
        moved = false,
        placedTile = false,
        pushedHero = false,
        pendingActivePlayer = nil,
        tileEffect = E.Empty,
        escapeX = 0, escapeY = 0,
        importantLocs = {},
        savedGoldState = nil,
        savedState = nil,
    }
end

---undo ($00BE551C): before each action a copy of the game is kept in state.savedState. The
---copy holds the previous one, so undo goes back action by action, until something clears
---them: play passing to another player, or hidden tiles being revealed (Map, the Barbarian,
---drawing a tile). Copies made by the AI to try things out keep no undo points.
---@param state GAME.STATE
local function checkpoint(state)
    if state.noUndo then return end
    local snap = lib.cloneState(state)
    snap.savedState = state.savedState
    state.savedState = snap
end

---in-game player from its configuration.
---@param pc GAME.PLAYERCONFIG
---@return GAME.PLAYER
local function newPlayer(pc)
    return {
        name = pc.name, initial = pc.initial, hero = pc.hero, colorIndex = pc.colorIndex,
        team = pc.team, config = pc,
        unlockedGold = 0, lockedGold = 0,
        usedHero = false, skipTurn = false,
        x = 0, y = 0,
        hand = nil,               --shared with other players whose config names the same hand
    }
end

---------------------------------------------------------------------------- drawing

---draw a tile ($00BE5F48). An empty deck is replaced by a new, shuffled one, so the deck
---never runs out. Tiles come off the end of the list.
---@param state GAME.STATE
---@return TILES.TILE
function lib.drawTile(state)
    if #state.deck == 0 then
        state.deck = DECK.build(state.config.options, state.random)
    end
    return table.remove(state.deck)
end

---draw until the player's hand is full ($00BE1B60). Returns the tiles drawn.
---@param state GAME.STATE
---@param player GAME.PLAYER
---@return TILES.TILE[] drawn
function lib.fillHand(state, player)
    local drawn = {}
    local hand = player.hand
    while #hand.tiles < hand.tileLimit do
        local t = lib.drawTile(state)
        drawn[#drawn + 1] = t
        hand.tiles[#hand.tiles + 1] = t
    end
    return drawn
end

---@param t TILES.TILE
---@return boolean
local function isGold(t)
    local e = t:effect()
    return e == E.OneGold or e == E.TwoGold
end

---ForceGoldTile option ($00BE1C70): a hand with no gold tile puts its last tile back on the
---deck (where it will be drawn next) and takes the first gold tile found in the deck.
---@param state GAME.STATE
---@param player GAME.PLAYER
function lib.forceGoldTile(state, player)
    local handTiles = player.hand.tiles
    if #handTiles == 0 then return end
    for _, t in ipairs(handTiles) do
        if isGold(t) then return end
    end
    state.deck[#state.deck + 1] = table.remove(handTiles)
    for i, t in ipairs(state.deck) do
        if isGold(t) then
            handTiles[#handTiles + 1] = table.remove(state.deck, i)
            return
        end
    end
end

---------------------------------------------------------------------------- turns

---Start of a turn ($00BE1804): the turn player acts, and per-turn flags are reset.
---@param state GAME.STATE
function lib.beginTurn(state)
    state.activePlayer = state.turnPlayer
    state.moved = false
    state.placedTile = false
    state.pushedHero = false
    state.pendingActivePlayer = nil
    state.tileEffect = E.Empty
    state.escapeX, state.escapeY = 0, 0
    state.savedGoldState = nil
end

---the game is over when nobody is left to act ($00BE487C).
---@param state GAME.STATE
---@return boolean
function lib.isOver(state)
    return state.activePlayer == nil
end

---not in the Void
---@param player GAME.PLAYER
---@return boolean
local function onBoard(player) return player.x ~= nil end   --false while in the Void

---the square of a hero on the board (not in the Void)
---@param player GAME.PLAYER
---@return integer x
---@return integer y
local function square(player) return player.x --[[@as integer]], player.y --[[@as integer]] end

---a Drakon Moves tile was just placed and Drakon isn't on the board yet: the player must
---place Drakon before doing anything else ($00BE7880).
---@param state GAME.STATE
---@return boolean
function lib.mustPlaceDrakon(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    return not lib.isOver(state) and state.tileEffect == E.DrakonMoves
       and #p.hand.tiles <= p.hand.tileLimit and state.pendingActivePlayer == nil
end

---the active player holds more tiles than their hand allows and must discard ($00BEAE44).
---@param state GAME.STATE
---@return boolean
function lib.mustDiscard(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    return not lib.isOver(state) and #p.hand.tiles > p.hand.tileLimit
       and state.tileEffect == E.Empty and state.pendingActivePlayer == nil
end

---------------------------------------------------------------------------- placing tiles

---whether `tile` may sit at (x, y) with exits `arrows` ($00BE30A8). Returns nil if it may,
---otherwise the original error message. The tile's own square doesn't count as occupied, so
---this also checks a tile being moved or rotated where it stands.
---* the square must be empty;
---* at least one neighbouring square must hold a tile;
---* an exit may not face a neighbour's exit pointing straight back.
---@param state GAME.STATE
---@param tile TILES.TILE
---@param x integer
---@param y integer
---@param arrows? TILES.ARROWS default: the tile's own
---@return string|nil err
function lib.placementError(state, tile, x, y, arrows)
    arrows = arrows or tile:arrows()
    local board = state.board
    local here = board:get(x, y)
    if here and here ~= tile then return "A tile already exists here" end
    local adjacent = false
    for d = 0, 3 do
        local other = board:get(TILES.neighbor(x, y, d))
        if other and other ~= tile then
            adjacent = true
            if TILES.hasArrow(arrows, d) and other:hasExit(TILES.opposite(d)) then
                return "Arrows may not point at other arrows"
            end
        end
    end
    if not adjacent then return "Tiles must be placed adjacent to at least one other tile" end
    return nil
end

---whether the active player may place a tile now ($00BE6DA8): once per turn, instead of
---moving, by the turn player, while on the board and with nothing else to resolve first.
---@param state GAME.STATE
---@return boolean
function lib.canPlaceTile(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if lib.isOver(state) or state.moved or state.placedTile then return false end
    if p ~= state.turnPlayer or #p.hand.tiles == 0 or not onBoard(p) then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    if lib.mustDiscard(state) then return false end
    return state.pendingActivePlayer == nil
end

---@param list table
---@param item any
---@return integer|nil
local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
end

---every legal placement of `tile` (rotations included) as a list of
---{ x =, y =, turns = clockwise quarter turns from the tile's current orientation }.
---@param state GAME.STATE
---@param tile TILES.TILE
---@return GAME.PLACEMENT[]
function lib.legalPlacements(state, tile)
    local result, tried = {}, {}
    for bx, by in state.board:each() do
        for d = 0, 3 do
            local x, y = TILES.neighbor(bx, by, d)
            local key = x .. "," .. y
            if not tried[key] and not state.board:has(x, y) then
                tried[key] = true
                local seen = {}
                for turns = 0, 3 do
                    local arrows = TILES.kindArrows(TILES.rotateKind(tile.kind, turns))
                    if not seen[arrows] then  --symmetric tiles look the same after some turns
                        seen[arrows] = true
                        if not lib.placementError(state, tile, x, y, arrows) then
                            result[#result + 1] = { x = x, y = y, turns = turns }
                        end
                    end
                end
            end
        end
    end
    return result
end

---place a tile from the active player's hand at (x, y), in its current orientation
---($00BE6F0C). Returns true, or nil and the reason it isn't allowed.
---placing a Drakon Moves tile while Drakon is off the board leaves the player owing a
---"place Drakon" decision; placing an Escape tile lets them move onto it.
---@param state GAME.STATE
---@param tile TILES.TILE
---@param x integer
---@param y integer
---@return true|nil ok
---@return string? err
function lib.placeTile(state, tile, x, y)
    if not lib.canPlaceTile(state) then return nil, "You cannot place a tile now" end
    local hand = state.activePlayer.hand.tiles
    local index = indexOf(hand, tile)
    if not index then return nil, "You cannot place a tile that is not in your hand" end
    local err = lib.placementError(state, tile, x, y, tile:arrows())
    if err then return nil, err end

    checkpoint(state)
    state.board:set(x, y, tile)
    state.placedTile = true
    table.remove(hand, index)
    state.tileEffect = E.Empty
    local effect = tile:effect()
    if effect == E.DrakonMoves then
        if not state.drakonActive then state.tileEffect = effect end
    elseif effect == E.Escape then
        state.tileEffect = effect
        state.escapeX, state.escapeY = x, y
    end
    return true
end

---------------------------------------------------------------------------- moving heroes

---steps between two squares, along the grid
---@param ax integer
---@param ay integer
---@param bx integer
---@param by integer
---@return integer
local function distance(ax, ay, bx, by) return math.abs(ax - bx) + math.abs(ay - by) end

---the player has this hero and hasn't used its once-per-game ability yet ($00BE64F0).
---@param player GAME.PLAYER|nil
---@param hero GAME.HERO
---@return boolean
function lib.canUseHero(player, hero)
    return player ~= nil and player.hero == hero and not player.usedHero
end

---nothing is waiting to be resolved before the active player can act again ($00BE5C84).
---@param state GAME.STATE
---@return boolean
local function nothingPending(state)
    if state.pendingActivePlayer ~= nil then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state)
end

---another hero (not `player`) stands on (x, y) ($00BE2064).
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@return boolean
local function occupiedByOther(state, player, x, y)
    for _, p in ipairs(state.players) do
        if p ~= player and p.x == x and p.y == y then return true end
    end
    return false
end

---one of the tile's exits leads into a Magic Harp, which then pulls the hero in ($00BE2134).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param tile TILES.TILE
---@return boolean
local function exitsIntoHarp(state, x, y, tile)
    for d = 0, 3 do
        if tile:hasExit(d) then
            local other = state.board:get(TILES.neighbor(x, y, d))
            if other and other:effect() == E.MagicHarp then return true end
        end
    end
    return false
end

---a Base Structure, or a tile next to one: these can't be moved, rotated or destroyed ($00BE337C).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return boolean
function lib.isProtected(state, x, y)
    local t = state.board:get(x, y)
    if not t then return false end
    if t:effect() == E.Base then return true end
    for d = 0, 3 do
        local other = state.board:get(TILES.neighbor(x, y, d))
        if other and other:effect() == E.Base then return true end
    end
    return false
end

---path search ($00BE21DC): can the hero get from (x, y) to (tx, ty) in between `min` and `max`
---steps? Each step leaves through an exit of the tile it is on. A tile with no exits at all
---may be left in any direction, except towards a neighbour whose exit points straight back.
---tiles with an exit into a Magic Harp may only be left into a Harp. A Small Room with
---another hero in it can't be entered. With `mayIgnoreWall` (the Wizard), one step may go
---through a wall.
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@param tx integer
---@param ty integer
---@param steps integer taken so far
---@param min integer
---@param max integer
---@param mayIgnoreWall boolean the Wizard may still cross one wall
---@return boolean
local function search(state, player, x, y, tx, ty, steps, min, max, mayIgnoreWall)
    if x == tx and y == ty and steps >= min and steps <= max then return true end
    if steps >= max then return false end
    local board = state.board
    local here = board:get(x, y) --[[@as TILES.TILE]]   --(the search only goes through rooms)
    local harp = exitsIntoHarp(state, x, y, here)
    steps = steps + 1
    for d = 0, 3 do
        local nx, ny = TILES.neighbor(x, y, d)
        local there = board:get(nx, ny)
        if there and not (there:effect() == E.SmallRoom and occupiedByOther(state, player, nx, ny))
           and not (here:hasExit(d) and harp and there:effect() ~= E.MagicHarp) then
            local blocked = false
            if not here:hasExit(d) then
                blocked = here:style() ~= TILES.Style.None or there:hasExit(TILES.opposite(d))
            end
            if (not blocked or mayIgnoreWall)
               and search(state, player, nx, ny, tx, ty, steps, min, max, mayIgnoreWall and not blocked) then
                return true
            end
        end
    end
    return false
end

---whether `player` could move to (x, y), going by the chamber they are leaving ($00BE23B0).
---returns ok, and whether the move needs the Wizard's ability (only tried when `useWizard`).
---* Friendly Visit: only to a chamber with another hero in it, anywhere on the board;
---* Magic Vortex: anywhere; Master Key: any adjacent chamber, walls or not;
---* Secret Passage: also to any other Secret Passage (and to Escape / Start with the
---SecretEscape / SecretStart options), unless an exit leads into a Magic Harp;
---* Heavy Gale: exactly 3 steps; Strong Wind: exactly 2; Tornado: up to 4; otherwise 1.
---a hero in the Void may move to any chamber.
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@param useWizard? boolean
---@return boolean ok
---@return boolean wizard
function lib.canMovePlayerTo(state, player, x, y, useWizard)
    local board = state.board
    local dest = board:get(x, y)
    if not dest then return false, false end
    if dest:effect() == E.SmallRoom and occupiedByOther(state, player, x, y) then return false, false end
    if not onBoard(player) then
        if player.skipTurn then
            error('TDrakonGame.CanMove: Cannot move a player that is off the board(i.e. "in the void") when their turn is to be skipped', 2)
        end
        return true, false
    end
    local px, py = square(player)
    local here = board:get(px, py)
    if not here then error(("TDrakonGame.CanMove: Cannot find source tile for (%d, %d)"):format(px, py), 2) end
    if here:effect() == E.Void then error(("TDrakonGame.CanMove: Cannot start on the void (%d, %d)"):format(px, py), 2) end

    local min, max = 1, 1
    local e = here:effect()
    if e == E.FriendlyVisit then return occupiedByOther(state, player, x, y), false
    elseif e == E.MagicVortex then return true, false
    elseif e == E.MasterKey then return distance(px, py, x, y) == 1, false
    elseif e == E.HeavyGale then min, max = 3, 3
    elseif e == E.StrongWind then min, max = 2, 2
    elseif e == E.Tornado then max = 4
    elseif e == E.Passage then
        if not (x == px and y == py) and not exitsIntoHarp(state, px, py, here) then
            local de, opt = dest:effect(), state.config.options
            if de == E.Passage or (de == E.Escape and opt.secretEscape) or (de == E.Start and opt.secretStart) then
                return true, false
            end
        end
    end

    local d = distance(px, py, x, y)
    if d > max then return false, false end
    if min < 3 and d < min then return false, false end
    if search(state, player, px, py, x, y, 0, min, max, false) then return true, false end
    if useWizard and search(state, player, px, py, x, y, 0, min, max, true) then return true, true end
    return false, false
end

---somewhere on the board the player could move to ($00BE2E34).
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param useWizard boolean
---@return boolean
local function hasAnyMove(state, player, useWizard)
    for x, y in state.board:each() do
        if lib.canMovePlayerTo(state, player, x, y, useWizard) then return true end
    end
    return false
end

---whether the active player may move now ($00BE7278): the turn player, instead of placing a
---tile, once the BigDungeonRounds opening rounds are over, with nothing else to resolve and
---somewhere to go. A second move is only possible with the Amazon's unused ability ($00BE71DC).
---@param state GAME.STATE
---@return boolean
function lib.canMoveNow(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if lib.isOver(state) or p ~= state.turnPlayer then return false end
    if state.config.options.bigDungeonRounds * #state.players >= state.turnNumber then return false end
    if state.placedTile then return false end
    if state.moved and not (lib.canUseHero(p, lib.Hero.Amazon) and nothingPending(state)) then return false end
    if not hasAnyMove(state, p, lib.canUseHero(p, lib.Hero.Wizard)) then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    if lib.mustDiscard(state) then return false end
    return state.pendingActivePlayer == nil
end

---whether the active player may move to (x, y) now ($00BE7318). Returns ok, whether it takes
---the Wizard's ability, and whether it is a second move (the Amazon's ability).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return boolean ok
---@return boolean wizard
---@return boolean second
function lib.canMove(state, x, y)
    if not lib.canMoveNow(state) then return false, false, false end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    local ok, wizard = lib.canMovePlayerTo(state, p, x, y, lib.canUseHero(p, lib.Hero.Wizard))
    return ok, wizard, ok and state.moved
end

---every square the active player may move to now, as a list of { x =, y =, wizard = }.
---@param state GAME.STATE
---@return GAME.MOVE[]
function lib.legalMoves(state)
    local result = {}
    if not lib.canMoveNow(state) then return result end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    local useWizard = lib.canUseHero(p, lib.Hero.Wizard)
    for x, y in state.board:each() do
        local ok, wizard = lib.canMovePlayerTo(state, p, x, y, useWizard)
        if ok then result[#result + 1] = { x = x, y = y, wizard = wizard } end
    end
    table.sort(result, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
    return result
end

---@param state GAME.STATE
---@param player GAME.PLAYER
---@return integer|nil
local function indexOfPlayer(state, player)
    for i, p in ipairs(state.players) do if p == player then return i end end
end

---the players a Steal tile takes from: the next player in turn order (left, $00BE5E98) or the
---previous one (right, $00BE5EF0).
---@param state GAME.STATE
---@param player GAME.PLAYER
---@return GAME.PLAYER
function lib.leftOf(state, player)
    local i = indexOfPlayer(state, player)
    return state.players[i % #state.players + 1]
end
---the previous player in turn order
---@param state GAME.STATE
---@param player GAME.PLAYER
---@return GAME.PLAYER
function lib.rightOf(state, player)
    local i = indexOfPlayer(state, player)
    return state.players[(i - 2) % #state.players + 1]
end

---lose one unlocked coin, if there is one ($00BFB354).
---@param player GAME.PLAYER
---@return boolean lost
local function loseCoin(player)
    if player.unlockedGold > 0 then
        player.unlockedGold = player.unlockedGold - 1
        return true
    end
    return false
end

---an unused Knight about to lose a coin gets the chance to take it back ($00BE56BC): the loss
---is recorded in state.savedGoldState, a chain of { player =, lostTo =, next = }. lostTo is
---the player who took the coin, "start" for the Start chamber, or nil if it went nowhere.
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param lostTo GAME.PLAYER|"start"|nil
local function noteCoinLoss(state, player, lostTo)
    if lib.canUseHero(player, lib.Hero.Knight) then
        state.savedGoldState = { player = player, lostTo = lostTo, next = state.savedGoldState }
    end
end

--entering effects that need the player to decide something: recorded in tileEffect.
local CHOICE_ON_ENTRY = {
    [E.Destroy] = true, [E.DrakonMoves] = true, [E.MagicShift] = true, [E.Map] = true,
    [E.MindOrb] = true, [E.MovingTiles] = true, [E.Rotate] = true,
}

---put `player` on (x, y) and carry out what entering the chamber does at once
---($00BE2914, DoMovePlayer). Returns a table describing what happened:
---attacked = true    Drakon was there: the hero goes back to the Start chamber, losing a coin
---gold = n           coins gained (negative: lost)
---stole = player     took a coin from this player
---void = true        fell into the Void: off the board, next turn lost
---effects that need a decision are left in state.tileEffect; if the hero isn't the active
---player's (moved by someone else) that hero's player then has to resolve it.
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@param usedAbility boolean
---@return GAME.MOVERESULT
function lib.doMovePlayer(state, player, x, y, usedAbility)
    local board, opt = state.board, state.config.options
    local isActive = (player == state.activePlayer)
    local result = { gold = 0 }
    player.x, player.y = x, y
    if usedAbility then player.usedHero = true end
    state.tileEffect = E.Empty

    if state.drakonActive and x == state.drakonX and y == state.drakonY then
        --Drakon attacks: back to the Start chamber's square
        result.attacked = true
        player.x, player.y = 0, 0
        if player.unlockedGold > 0 then noteCoinLoss(state, player, nil) end
        if loseCoin(player) then result.gold = result.gold - 1 end
    end
    local tile = board:get(square(player)) --[[@as TILES.TILE]]
    local e = tile:effect()

    if CHOICE_ON_ENTRY[e] then
        state.tileEffect = e
    elseif e == E.Float then
        if not lib.isProtected(state, player.x, player.y) then state.tileEffect = e end
    elseif e == E.DrakonsBargain then
        if player.unlockedGold > 0 then state.tileEffect = e end
    elseif e == E.DrakonsDue then        --pay a coin onto the Start chamber
        if player.unlockedGold > 0 then noteCoinLoss(state, player, "start") end
        if loseCoin(player) then
            result.gold = result.gold - 1
            state.goldOnStart = state.goldOnStart + 1
        end
    elseif e == E.OneGold then
        player.unlockedGold = player.unlockedGold + 1
        result.gold = result.gold + 1
    elseif e == E.TwoGold then
        player.unlockedGold = player.unlockedGold + 2
        result.gold = result.gold + 2
    elseif e == E.Start then             --pick up a coin left here
        if state.goldOnStart > 0 then
            player.unlockedGold = player.unlockedGold + 1
            state.goldOnStart = state.goldOnStart - 1
            result.gold = result.gold + 1
        end
    elseif e == E.LockedChest then       --every unlocked coin becomes locked
        if player.unlockedGold > 0 then
            result.locked = player.unlockedGold
            player.lockedGold = player.lockedGold + player.unlockedGold
            player.unlockedGold = 0
        end
    elseif e == E.StealLeft or e == E.StealRight then
        local victim = (e == E.StealLeft) and lib.leftOf(state, player) or lib.rightOf(state, player)
        if victim.unlockedGold > 0 then
            noteCoinLoss(state, victim, player)
            if opt.stealAsLocked then player.lockedGold = player.lockedGold + 1
            else player.unlockedGold = player.unlockedGold + 1 end
            loseCoin(victim)
            result.stole = victim
            result.gold = result.gold + 1
        end
    elseif e == E.Void then
        player.x, player.y = nil, nil
        player.skipTurn = true
        result.void = true
    elseif e == E.WishingWell then
        if player.unlockedGold > 0 then noteCoinLoss(state, player, nil) end
        if loseCoin(player) then result.gold = result.gold - 1 end
    end

    if isActive then state.moved = true end
    --a Knight who lost a coin decides first; otherwise a moved hero's player resolves the choice
    if state.savedGoldState then
        state.pendingActivePlayer = state.savedGoldState.player
    elseif state.tileEffect ~= E.Empty and not isActive then
        state.pendingActivePlayer = player
    end
    return result
end

---move the active player's hero to (x, y) ($00BE73C8). Returns the doMovePlayer result, or
---nil and the reason it isn't allowed. A move through a wall uses up the Wizard's ability;
---a second move in a turn uses up the Amazon's.
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return GAME.MOVERESULT|nil result
---@return string? err
function lib.movePlayer(state, x, y)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if not p then return nil, "There is no active player" end
    local ok, wizard, second = lib.canMove(state, x, y)
    if not ok then return nil, "This is not a valid move" end
    checkpoint(state)
    local result = lib.doMovePlayer(state, p, x, y, wizard)
    if second then p.usedHero = true end
    state.moved = true
    result.wizard, result.second = wizard, second
    return result
end

---------------------------------------------------------------------------- chamber choices
--entering some chambers leaves the player a choice (state.tileEffect). Each has a "can"
--check and an action; the action returns true (or a result table), or nil and the reason.
--the choices are optional: finishing the turn skips them.

---a hero or Drakon is on (x, y) ($00BE1A74).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return boolean
function lib.isOccupied(state, x, y)
    if state.drakonActive and state.drakonX == x and state.drakonY == y then return true end
    for _, p in ipairs(state.players) do
        if p.x == x and p.y == y then return true end
    end
    return false
end

---at least `needed` rooms with nobody in them, not counting the Start chamber unless
---`includeStart` ($00BE5CC8).
---@param state GAME.STATE
---@param includeStart boolean
---@param needed integer
---@return boolean
local function enoughFreeRooms(state, includeStart, needed)
    for x, y, t in state.board:each() do
        if (includeStart or t:effect() ~= E.Start) and not lib.isOccupied(state, x, y) then
            needed = needed - 1
            if needed == 0 then return true end
        end
    end
    return false
end

local PROTECTED = "Base Structures, and the tiles next to them, cannot be rotated, moved or destroyed"

---the checks every choice shares: the game is on, this is the effect waiting, Drakon isn't
---owed, no discard is due and nobody else has a decision pending.
---@param state GAME.STATE
---@param effect TILES.EFFECT
---@return boolean
local function choiceOpen(state, effect)
    if lib.isOver(state) or state.tileEffect ~= effect then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state) and state.pendingActivePlayer == nil
end

---adding a tile to a hand from elsewhere also raises its limit by one ($00BE634C); taking one
---out lowers it ($00BE6008). The original never restores these limits.
---@param player GAME.PLAYER
---@param tile TILES.TILE
local function addToHand(player, tile)
    local hand = player.hand
    hand.tileLimit = hand.tileLimit + 1
    hand.tiles[#hand.tiles + 1] = tile
end

---whether `tile` would be legal at (x, y) with `arrows` if the board tile at (x, y) were
---gone (it is put back afterwards).
---@param state GAME.STATE
---@param tile TILES.TILE
---@param x integer
---@param y integer
---@param arrows TILES.ARROWS
---@return string|nil err
local function placementErrorReplacing(state, tile, x, y, arrows)
    local old = state.board:get(x, y)
    state.board:remove(x, y)
    local err = lib.placementError(state, tile, x, y, arrows)
    state.board:set(x, y, old)
    return err
end

---Destroy ($00BE9D44 / $00BE9DB0): remove an unoccupied room other than Start from the board.
---(The rules text says it goes to the bottom of the draw pile; the original just removes it.)
---@param state GAME.STATE
---@return boolean
function lib.canDestroy(state)
    return choiceOpen(state, E.Destroy) and enoughFreeRooms(state, false, 1)
end
---remove a room (Destroy)
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return true|nil ok
---@return string? err
function lib.destroyRoom(state, x, y)
    if not lib.canDestroy(state) then return nil, "You cannot destroy a tile now" end
    local t = state.board:get(x, y)
    if not t then return nil, "There is no tile here" end
    if t:effect() == E.Start then return nil, "You cannot destroy the Start room" end
    if lib.isOccupied(state, x, y) then return nil, "You cannot destroy a room that is occupied" end
    if lib.isProtected(state, x, y) then return nil, PROTECTED end
    checkpoint(state)
    state.board:remove(x, y)
    state.tileEffect = E.Empty
    return true
end

---Drakon's Bargain ($00BE8688 / $00BE8784): pay an unlocked coin to take an unoccupied room
---(not the one at the Start square) into your hand.
---@param state GAME.STATE
---@return boolean
function lib.canBargain(state)
    return not lib.isOver(state) and state.activePlayer.unlockedGold > 0
       and choiceOpen(state, E.DrakonsBargain) and enoughFreeRooms(state, false, 1)
end
---buy a room into your hand (Drakon's Bargain)
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return true|nil ok
---@return string? err
function lib.bargainRoom(state, x, y)
    if not lib.canBargain(state) then return nil, "You cannot buy a board tile now" end
    local t = state.board:get(x, y)
    if not t then return nil, "There is no tile here" end
    if lib.isOccupied(state, x, y) then return nil, "You cannot buy a tile that has players or Drakon on it" end
    if x == 0 and y == 0 then return nil, "You cannot buy the start tile" end
    if lib.isProtected(state, x, y) then return nil, PROTECTED end
    checkpoint(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    p.unlockedGold = p.unlockedGold - 1          --paid to the Hoard
    addToHand(p, t)
    state.board:remove(x, y)
    state.tileEffect = E.Empty
    return true
end

---Magic Shift ($00BE8A5C / $00BE8B30): swap an unoccupied board room (not Start) for a tile
---from your hand, which must fit there legally as it is turned.
---@param state GAME.STATE
---@return boolean
function lib.canMagicShift(state)
    return choiceOpen(state, E.MagicShift) and #state.activePlayer.hand.tiles > 0
       and enoughFreeRooms(state, false, 1)
end
---why this Magic Shift isn't allowed, or nil
---@param state GAME.STATE
---@param handTile TILES.TILE
---@param x integer
---@param y integer
---@return string|nil err
function lib.magicShiftError(state, handTile, x, y)
    local t = state.board:get(x, y)
    if not t then return "There is no tile here" end
    if t:effect() == E.Start then return "You cannot swap the Start chamber" end
    if not indexOf(state.activePlayer.hand.tiles, handTile) then
        return "You cannot place a tile that is not in your hand"
    end
    if lib.isOccupied(state, x, y) then return "You cannot swap a tile that has players or Drakon on it" end
    if lib.isProtected(state, x, y) then return PROTECTED end
    return placementErrorReplacing(state, handTile, x, y, handTile:arrows())
end
---swap a hand tile for a board room (Magic Shift)
---@param state GAME.STATE
---@param handTile TILES.TILE
---@param x integer
---@param y integer
---@return true|nil ok
---@return string? err
function lib.magicShift(state, handTile, x, y)
    if not lib.canMagicShift(state) then
        return nil, "You cannot swap a tile in your hand for one on the board now"
    end
    local err = lib.magicShiftError(state, handTile, x, y)
    if err then return nil, err end
    checkpoint(state)
    local hand = state.activePlayer.hand.tiles
    hand[#hand + 1] = state.board:get(x, y)
    state.board:set(x, y, handTile)
    table.remove(hand, indexOf(hand, handTile))
    state.tileEffect = E.Empty
    return true
end

---Moving Chambers ($00BE8F80 / $00BE8FEC): two unoccupied rooms with the same arrow style
---change places, each taking on the arrows of the square it moves to.
---@param state GAME.STATE
---@return boolean
function lib.canSwapRooms(state)
    return choiceOpen(state, E.MovingTiles) and enoughFreeRooms(state, false, 2)
end
---why these rooms can't be switched, or nil
---@param state GAME.STATE
---@param x1 integer
---@param y1 integer
---@param x2 integer
---@param y2 integer
---@return string|nil err
function lib.swapRoomsError(state, x1, y1, x2, y2)
    for _, sq in ipairs({ { x1, y1 }, { x2, y2 } }) do
        if not state.board:get(sq[1], sq[2]) then return "There is no tile here" end
        if lib.isOccupied(state, sq[1], sq[2]) then return "You cannot swap a tile with players or Drakon on it" end
        if lib.isProtected(state, sq[1], sq[2]) then return PROTECTED end
    end
    if state.board:get(x1, y1):style() ~= state.board:get(x2, y2):style() then
        return "You must select tiles with the same arrow configuration"
    end
end
---switch two rooms (Moving Chambers)
---@param state GAME.STATE
---@param x1 integer
---@param y1 integer
---@param x2 integer
---@param y2 integer
---@return true|nil ok
---@return string? err
function lib.swapRooms(state, x1, y1, x2, y2)
    if not lib.canSwapRooms(state) then return nil, "You cannot swap tiles on the board right now" end
    local err = lib.swapRoomsError(state, x1, y1, x2, y2)
    if err then return nil, err end
    checkpoint(state)
    local a = state.board:get(x1, y1) --[[@as TILES.TILE]]   --(both checked by swapRoomsError)
    local b = state.board:get(x2, y2) --[[@as TILES.TILE]]
    local arrowsA, arrowsB = a:arrows(), b:arrows()
    a.kind = TILES.kindSetArrows(a.kind, arrowsB)
    b.kind = TILES.kindSetArrows(b.kind, arrowsA)
    state.board:set(x1, y1, b)
    state.board:set(x2, y2, a)
    state.tileEffect = E.Empty
    return true
end

---Rotate Chamber ($00BE93E0 / $00BE9604): turn any room, even an occupied one or Start, to an
---orientation that is legal where it stands. `turns` is clockwise quarter turns.
---@param state GAME.STATE
---@return boolean
function lib.canRotateRoom(state)
    return choiceOpen(state, E.Rotate)
end
---why this rotation isn't allowed, or nil
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param turns integer
---@return string|nil err
function lib.rotateRoomError(state, x, y, turns)
    local t = state.board:get(x, y)
    if not t then return "There is no tile there" end
    if lib.isProtected(state, x, y) then return PROTECTED end
    return lib.placementError(state, t, x, y, TILES.kindArrows(TILES.rotateKind(t.kind, turns)))
end
---turn a room (Rotate Chamber)
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param turns integer clockwise quarter turns
---@return true|nil ok
---@return string? err
function lib.rotateRoom(state, x, y, turns)
    if not lib.canRotateRoom(state) then return nil, "You cannot rotate a tile now" end
    local err = lib.rotateRoomError(state, x, y, turns)
    if err then return nil, err end
    checkpoint(state)
    state.board:get(x, y):rotate(turns)
    state.tileEffect = E.Empty
    return true
end

---Map ($00BE996C / $00BE99D0): take a tile at random from another player's hand.
---@param state GAME.STATE
---@return boolean
function lib.canMapSteal(state)
    if not choiceOpen(state, E.Map) then return false end
    for _, p in ipairs(state.players) do
        if p ~= state.activePlayer and #p.hand.tiles > 0 then return true end
    end
    return false
end
---take a random tile from another player's hand (Map)
---@param state GAME.STATE
---@param victim GAME.PLAYER
---@return TILES.TILE|nil tile
---@return string? err
function lib.mapSteal(state, victim)
    if not lib.canMapSteal(state) then return nil, "You cannot steal a tile now" end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if victim == p then return nil, "You cannot steal a tile from yourself" end
    local from = victim.hand
    if #from.tiles == 0 then return nil, "You cannot take a tile from a player with no tiles in their hand" end
    if from == p.hand then return nil, "You cannot take a tile from a player who is sharing your hand" end
    local i = #from.tiles == 1 and 1 or state.random(1, #from.tiles)
    local t = table.remove(from.tiles, i)
    from.tileLimit = from.tileLimit - 1
    addToHand(p, t)
    state.tileEffect = E.Empty
    state.savedState = nil   --a hidden tile has been seen: no undo past this
    return t
end

---Mind Control Orb ($00BE7524 / $00BE7624 / $00BE7668): move another hero (not one in the
---Void) by the usual rules for the room they are in; they then carry out what they enter.
---@param state GAME.STATE
---@return boolean
function lib.canMindOrb(state)
    if not choiceOpen(state, E.MindOrb) then return false end
    for _, p in ipairs(state.players) do
        if p ~= state.activePlayer and onBoard(p) and hasAnyMove(state, p, false) then return true end
    end
    return false
end
---whether the Mind Control Orb may move this hero there
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@return boolean
function lib.canMoveOther(state, player, x, y)
    return lib.canMindOrb(state) and onBoard(player) and (lib.canMovePlayerTo(state, player, x, y, false))
end
---move another hero (Mind Control Orb)
---@param state GAME.STATE
---@param player GAME.PLAYER
---@param x integer
---@param y integer
---@return GAME.MOVERESULT|nil result
---@return string? err
function lib.moveOtherPlayer(state, player, x, y)
    if not player then return nil, "TDrakonGame.MoveAnotherPlayer: Player is nil" end
    if player == state.activePlayer then return nil, "You must pick another player to move" end
    if not lib.canMoveOther(state, player, x, y) then return nil, "This is not a valid move" end
    checkpoint(state)
    return lib.doMovePlayer(state, player, x, y, false)
end

---Floating Room ($00BE7FA4 / $00BE801C / $00BE82DC): move the room you are in (and everyone
---in it) to any empty square where it fits, turned as you like, or just turn it in place.
---@param state GAME.STATE
---@return boolean
function lib.canFloat(state)
    if lib.isOver(state) or state.tileEffect ~= E.Float then return false end
    if lib.mustDiscard(state) or state.pendingActivePlayer ~= nil then return false end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    return onBoard(p) and not lib.isProtected(state, square(p))
end
---why the Floating Room can't go there, or nil
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param turns integer
---@return string|nil err
function lib.floatError(state, x, y, turns)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    local t = state.board:get(square(p)) --[[@as TILES.TILE]]
    local arrows = TILES.kindArrows(TILES.rotateKind(t.kind, turns))
    local same = (x == p.x and y == p.y)
    if same and arrows == t:arrows() then return "The room hasn't moved" end
    if not same and state.board:get(x, y) then return "You cannot move the Floating Room onto another room" end
    return lib.placementError(state, t, x, y, arrows)
end
---move and turn the room you are in (Floating Room)
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param turns integer
---@return true|nil ok
---@return string? err
function lib.floatRoom(state, x, y, turns)
    if not lib.canFloat(state) then return nil, "You cannot move a room now" end
    local err = lib.floatError(state, x, y, turns)
    if err then return nil, err end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    checkpoint(state)
    local fx, fy = square(p)
    local t = state.board:get(fx, fy) --[[@as TILES.TILE]]
    state.board:remove(fx, fy)
    t:rotate(turns)
    state.board:set(x, y, t)
    state.tileEffect = E.Empty
    for _, q in ipairs(state.players) do
        if q.x == fx and q.y == fy then q.x, q.y = x, y end
    end
    return true
end

---the choice waiting for the active player, if they can make it: the effect, else nil.
---@param state GAME.STATE
---@return TILES.EFFECT|nil
function lib.openChoice(state)
    local e = state.tileEffect
    local can = ({
        [E.Destroy] = lib.canDestroy, [E.DrakonsBargain] = lib.canBargain,
        [E.MagicShift] = lib.canMagicShift, [E.MovingTiles] = lib.canSwapRooms,
        [E.Rotate] = lib.canRotateRoom, [E.Map] = lib.canMapSteal,
        [E.MindOrb] = lib.canMindOrb, [E.Float] = lib.canFloat,
    })[e]
    return can and can(state) and e or nil
end

---------------------------------------------------------------------------- Drakon

---heroes standing on (x, y) ($00BE1870).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return GAME.PLAYER[]
function lib.playersAt(state, x, y)
    local out = {}
    for _, p in ipairs(state.players) do
        if p.x == x and p.y == y then out[#out + 1] = p end
    end
    return out
end

---Drakon can get from (x, y) to (tx, ty) in at most 3 steps between rooms, ignoring arrows,
---never into or through a Small Room ($00BE7944).
---@param state GAME.STATE
---@param x integer
---@param y integer
---@param tx integer
---@param ty integer
---@param steps integer taken so far
---@return boolean
local function drakonReaches(state, x, y, tx, ty, steps)
    if x == tx and y == ty then return true end
    if steps == 3 then return false end
    steps = steps + 1
    for d = 0, 3 do
        local nx, ny = TILES.neighbor(x, y, d)
        local t = state.board:get(nx, ny)
        if t and t:effect() ~= E.SmallRoom and drakonReaches(state, nx, ny, tx, ty, steps) then return true end
    end
    return false
end

---whether Drakon may go to (x, y) now ($00BE7ABC). Only while a Drakon Moves tile is waiting
---(placed for the first time, or entered). The first time, Drakon goes into any room with no
---heroes in it; after that he moves up to 3 rooms (staying put counts). Never a Small Room.
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return boolean
function lib.canMoveDrakonTo(state, x, y)
    if not lib.mustPlaceDrakon(state) then return false end
    local t = state.board:get(x, y)
    if not t or t:effect() == E.SmallRoom then return false end
    if not state.drakonActive then return #lib.playersAt(state, x, y) == 0 end
    return drakonReaches(state, state.drakonX, state.drakonY, x, y, 0)
end

---every square Drakon may go to now, as a list of { x, y }.
---@param state GAME.STATE
---@return {[1]:integer, [2]:integer}[]
function lib.legalDrakonMoves(state)
    local out = {}
    for x, y in state.board:each() do
        if lib.canMoveDrakonTo(state, x, y) then out[#out + 1] = { x, y } end
    end
    return out
end

---place or move Drakon ($00BE7B54). Heroes in the room he enters are attacked: each goes back
---to the Start square and loses an unlocked coin. Then, if there are enough coins lying on
---Start for all of them, each picks one up. Returns { attacked = { player, ... },
---pickedUp = bool }, or nil and the reason.
---@param state GAME.STATE
---@param x integer
---@param y integer
---@return GAME.DRAKONRESULT|nil result
---@return string? err
function lib.moveDrakon(state, x, y)
    if not state.activePlayer then return nil, "There is no active player" end
    if not lib.canMoveDrakonTo(state, x, y) then return nil, "This is not a valid Drakon move" end
    checkpoint(state)
    state.drakonX, state.drakonY = x, y
    state.drakonActive = true
    state.tileEffect = E.Empty
    local victims = lib.playersAt(state, x, y)
    local result = { attacked = victims, pickedUp = false }
    if #victims > 0 then
        for _, p in ipairs(victims) do
            p.x, p.y = 0, 0
            if p.unlockedGold > 0 then noteCoinLoss(state, p, nil) end
            loseCoin(p)
        end
        if #victims <= state.goldOnStart then
            state.goldOnStart = state.goldOnStart - #victims
            for _, p in ipairs(victims) do p.unlockedGold = p.unlockedGold + 1 end
            result.pickedUp = true
        end
    end
    return result
end

---------------------------------------------------------------------------- Escape

---after placing an Escape tile, the player may move onto it ($00BE7E04 / $00BE7E68). This
---doesn't count as entering it (no chamber effect) and doesn't use up the move.
---@param state GAME.STATE
---@return boolean
function lib.canMoveToEscape(state)
    if lib.isOver(state) or not state.placedTile or state.tileEffect ~= E.Escape then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state) and state.pendingActivePlayer == nil
end
---step onto the Escape tile just placed
---@param state GAME.STATE
---@return true|nil ok
---@return string? err
function lib.moveToEscape(state)
    if not lib.canMoveToEscape(state) then return nil, "You cannot move to an escape tile now" end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    checkpoint(state)
    p.x, p.y = state.escapeX, state.escapeY
    state.escapeX, state.escapeY = 0, 0
    state.tileEffect = E.Empty
    return true
end

---------------------------------------------------------------------------- hero abilities
--(The Wizard and Amazon are part of moving.) Each ability needs the hero's once-per-game
--ability unused, nothing pending, Drakon not owed and no discard due.

---the checks every hero ability shares
---@param state GAME.STATE
---@param hero GAME.HERO
---@return boolean
local function abilityOpen(state, hero)
    if lib.isOver(state) or not lib.canUseHero(state.activePlayer, hero) then return false end
    if not nothingPending(state) then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state) and state.pendingActivePlayer == nil
end

---other heroes in the active player's room.
---@param state GAME.STATE
---@return GAME.PLAYER[]
local function roommates(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    local out = {}
    if not onBoard(p) then return out end
    for _, q in ipairs(lib.playersAt(state, square(p))) do
        if q ~= p then out[#out + 1] = q end
    end
    return out
end

---Thief ($00BEA138 / $00BEA1B4): take an unlocked coin from a hero in the same room (locked
---with the StealAsLocked option). Clears any chamber choice still waiting.
---fix: the original hands over to a robbed Knight at once, which locks the game when the
---Thief hasn't moved or placed yet (they can neither act nor finish). Here the Knight is
---asked when the Thief's action ends (see game.endTurn).
---@param state GAME.STATE
---@return boolean
function lib.canThiefSteal(state)
    if not abilityOpen(state, lib.Hero.Thief) then return false end
    for _, q in ipairs(roommates(state)) do
        if q.unlockedGold > 0 then return true end
    end
    return false
end
---take a coin from a hero in the same room (Thief)
---@param state GAME.STATE
---@param victim GAME.PLAYER
---@return true|nil ok
---@return string? err
function lib.thiefSteal(state, victim)
    if not lib.canThiefSteal(state) then return nil, "You cannot steal gold now" end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if victim.unlockedGold <= 0 then return nil, "You cannot steal gold from a player with no gold" end
    if victim == p then return nil, "You cannot steal from yourself" end
    if not (onBoard(victim) and victim.x == p.x and victim.y == p.y) then
        return nil, "You must be on the same location as another player to steal from them using your thief ability"
    end
    checkpoint(state)
    noteCoinLoss(state, victim, p)
    loseCoin(victim)
    if state.config.options.stealAsLocked then p.lockedGold = p.lockedGold + 1
    else p.unlockedGold = p.unlockedGold + 1 end
    p.usedHero = true
    state.tileEffect = E.Empty
    return true
end

---Barbarian ($00BEA650 / $00BEA6CC): push a hero in the same room to a room they could move
---to (as with the Mind Control Orb; they carry out what they enter), and take a random tile
---from their hand. Counts as the turn's action, like moving or placing.
---@param state GAME.STATE
---@return boolean
function lib.canBarbarianPush(state)
    if not abilityOpen(state, lib.Hero.Barbarian) then return false end
    for _, q in ipairs(roommates(state)) do
        if hasAnyMove(state, q, false) then return true end
    end
    return false
end
---why this push isn't allowed, or nil
---@param state GAME.STATE
---@param victim GAME.PLAYER
---@param x integer
---@param y integer
---@return string|nil err
function lib.barbarianPushError(state, victim, x, y)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if victim == p then return "You cannot push yourself" end
    if not (onBoard(victim) and victim.x == p.x and victim.y == p.y) then
        return "You must be on the same location as another player to push them using your barbarian ability"
    end
    if not lib.canMovePlayerTo(state, victim, x, y, false) then return "This is not a valid move" end
end
---push a hero in the same room and take a tile from them (Barbarian)
---@param state GAME.STATE
---@param victim GAME.PLAYER
---@param x integer
---@param y integer
---@return GAME.MOVERESULT|nil result
---@return string? err
function lib.barbarianPush(state, victim, x, y)
    if not lib.canBarbarianPush(state) then return nil, "You cannot push a player now" end
    local err = lib.barbarianPushError(state, victim, x, y)
    if err then return nil, err end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    state.tileEffect = E.MindOrb          --the original pushes through the Mind Control Orb move
    local result, merr = lib.moveOtherPlayer(state, victim, x, y)
    if not result then state.tileEffect = E.Empty; return nil, merr end
    if #victim.hand.tiles > 0 then
        local from = victim.hand
        local t = table.remove(from.tiles, #from.tiles == 1 and 1 or state.random(1, #from.tiles))
        from.tileLimit = from.tileLimit - 1
        addToHand(p, t)
        result.tookTile = t
    end
    p.usedHero = true
    state.pushedHero = true
    state.savedState = nil   --a hidden tile has been seen: no undo past this
    return result
end

---Knight ($00BEAA08 / $00BEAA78 / $00BE5768): take back the coin just lost, from the player
---who took it or from the Start chamber (a coin lost to Drakon or a Wishing Well comes back
---from nowhere). The next Knight in the chain, if any, decides next.
---@param state GAME.STATE
---@return boolean
function lib.canKnightReclaim(state)
    if lib.isOver(state) or not state.savedGoldState then return false end
    if not lib.canUseHero(state.activePlayer, lib.Hero.Knight) then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state) and state.pendingActivePlayer == nil
end
---drop the newest Knight record; the next Knight in the chain decides next
---@param state GAME.STATE
local function popGoldState(state)
    state.savedGoldState = state.savedGoldState.next
    if state.savedGoldState then state.pendingActivePlayer = state.savedGoldState.player end
    state.tileEffect = E.Empty
end
---take back the coin just lost (Knight)
---@param state GAME.STATE
---@return true|nil ok
---@return string? err
function lib.knightReclaim(state)
    if not lib.canKnightReclaim(state) then return nil, "You cannot reclaim lost gold now" end
    local saved = state.savedGoldState --[[@as GAME.GOLDSTATE]]   --(canKnightReclaim checked it)
    local knight, lostTo = saved.player, saved.lostTo
    if not lib.canUseHero(knight, lib.Hero.Knight) then return nil, "You do not have the knight ability" end
    if type(lostTo) == "table" and lostTo.unlockedGold <= 0 then
        return nil, "You cannot take back a gold from a player with no unlocked gold"
    end
    if lostTo == "start" and state.goldOnStart <= 0 then
        return nil, "There is no gold on the start chamber to recover"
    end
    checkpoint(state)
    knight.usedHero = true
    knight.unlockedGold = knight.unlockedGold + 1
    if type(lostTo) == "table" then loseCoin(lostTo)
    elseif lostTo == "start" then state.goldOnStart = state.goldOnStart - 1 end
    popGoldState(state)
    return true
end
---let the coin go (the original's routine with its "use" flag off; nothing in the original
---calls it that way, finishing the action just leaves the record until the next turn).
---@param state GAME.STATE
---@return true|nil ok
---@return string? err
function lib.knightDecline(state)
    if not lib.canKnightReclaim(state) then return nil, "You cannot reclaim lost gold now" end
    popGoldState(state)
    return true
end

---Dwarf ($00BEAC18 / $00BEACD8): fill the hand, then draw two more tiles, raising the hand
---limit by two. Fix: the original never marks the ability as used, so it could be repeated
---without limit; here it is once per game like the others.
---@param state GAME.STATE
---@return boolean
function lib.canDwarfDraw(state)
    return abilityOpen(state, lib.Hero.Dwarf) and state.activePlayer.hand.tileLimit >= 1
end
---fill the hand and draw two more (Dwarf)
---@param state GAME.STATE
---@return TILES.TILE[]|nil drawn
---@return string? err
function lib.dwarfDraw(state)
    if not lib.canDwarfDraw(state) then return nil, "You cannot exchange two tiles now" end
    checkpoint(state)
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    local drawn = lib.fillHand(state, p)
    for _ = 1, 2 do
        local t = lib.drawTile(state)
        addToHand(p, t)
        drawn[#drawn + 1] = t
    end
    p.usedHero = true
    state.tileEffect = E.Empty
    return drawn
end

---------------------------------------------------------------------------- drawing a tile (EmptyHand)

---"Empty Hand Can Draw One Tile" option ($00BE6B08 / $00BE6C3C): a player whose hand limit
---has dropped to nothing (Map and Barbarian thefts lower it) may, as their action, raise it
---to one and draw. It counts as placing a tile.
---@param state GAME.STATE
---@return boolean
function lib.canDrawTileAction(state)
    if lib.isOver(state) or state.moved or state.placedTile or state.pushedHero then return false end
    if not state.config.options.emptyHand then return false end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    if p ~= state.turnPlayer or #p.hand.tiles ~= 0 or p.hand.tileLimit ~= 0 then return false end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state) and state.pendingActivePlayer == nil
end
---draw one tile with an empty hand (EmptyHand option)
---@param state GAME.STATE
---@return TILES.TILE[]|nil drawn
---@return string? err
function lib.drawTileAction(state)
    if not lib.canDrawTileAction(state) then return nil, "You cannot draw a tile now" end
    local p = state.activePlayer --[[@as GAME.PLAYER]]
    p.hand.tileLimit = p.hand.tileLimit + 1
    local drawn = lib.fillHand(state, p)
    state.placedTile = true
    state.savedState = nil   --a hidden tile has been seen: no undo past this
    return drawn
end

---------------------------------------------------------------------------- undo

---put `snap` (a copy made by game.cloneState) back into `state`, keeping the same state,
---player and hand tables (so references to them stay good); tiles are the copy's.
---@param state GAME.STATE
---@param snap GAME.STATE
local function restore(state, snap)
    local index = {}
    for i, p in ipairs(snap.players) do index[p] = i end
    ---the state's own player for one of the copy's
    ---@param p GAME.PLAYER|nil
    ---@return GAME.PLAYER|nil
    local function real(p) return p and state.players[index[p]] end
    local hands = {}
    for i, sp in ipairs(snap.players) do hands[sp.hand] = state.players[i].hand end
    for k in pairs(state) do
        if snap[k] == nil then state[k] = nil end   --fields that were empty then
    end
    for k, v in pairs(snap) do
        if k ~= "players" then state[k] = v end
    end
    for i, sp in ipairs(snap.players) do
        local p = state.players[i]
        for k, v in pairs(sp) do p[k] = v end
        p.hand = hands[sp.hand]
    end
    for sh, h in pairs(hands) do
        h.tileLimit = sh.tileLimit
        h.tiles = {}
        for j, t in ipairs(sh.tiles) do h.tiles[j] = t end
    end
    state.turnPlayer = real(snap.turnPlayer)
    state.activePlayer = real(snap.activePlayer)
    state.pendingActivePlayer = real(snap.pendingActivePlayer)
    ---the Knight records, with the state's own players
    ---@param g GAME.GOLDSTATE|nil
    ---@return GAME.GOLDSTATE|nil
    local function gold(g)
        if not g then return nil end
        local lostTo = g.lostTo
        if type(lostTo) == "table" then lostTo = real(lostTo) end
        return { player = real(g.player), lostTo = lostTo, next = gold(g.next) }
    end
    state.savedGoldState = gold(snap.savedGoldState)
end

---undo ($00BE6A34 / $00BE6A68): "revert your decision", back to before the last action.
---@param state GAME.STATE
---@return boolean
function lib.canUndo(state)
    return not lib.isOver(state) and state.savedState ~= nil
end
---go back to before the last action
---@param state GAME.STATE
---@return true|nil ok
---@return string? err
function lib.undo(state)
    if not lib.canUndo(state) then return nil, "You cannot revert your decision now" end
    restore(state, state.savedState)
    return true
end

---------------------------------------------------------------------------- ending a turn

---a player's coins, locked and unlocked ($00BFAA8C).
---@param player GAME.PLAYER
---@return integer
function lib.totalGold(player) return player.unlockedGold + player.lockedGold end

---teams with as much gold between their players as they need to win, in the order their
---players first appear ($00BE38AC, team totals from $00BE36B0).
---@param state GAME.STATE
---@return GAME.TEAMTOTAL[]
function lib.winners(state)
    local teams, order = {}, {}
    for _, p in ipairs(state.players) do
        local name = p.team.name
        if not teams[name] then
            teams[name] = { name = name, goldToWin = p.team.goldToWin, gold = 0, players = {} }
            order[#order + 1] = teams[name]
        end
        local t = teams[name]
        t.gold = t.gold + lib.totalGold(p)
        t.players[#t.players + 1] = p
    end
    local result = {}
    for _, t in ipairs(order) do
        if t.gold >= t.goldToWin then result[#result + 1] = t end
    end
    return result
end

---whether the active player can still do something ($00BE65AC): place, move, make a chamber
---choice, use a hero ability, or something they owe.
---@param state GAME.STATE
---@return boolean
function lib.canAct(state)
    return lib.canPlaceTile(state) or lib.canMoveNow(state) or lib.openChoice(state) ~= nil
        or lib.mustPlaceDrakon(state) or lib.canThiefSteal(state) or lib.canBarbarianPush(state)
        or lib.canKnightReclaim(state) or lib.canDwarfDraw(state) or lib.mustDiscard(state)
end

---whether the active player may finish now ($00BE6534): they must have done something
---(moved, placed a tile or pushed a hero) unless they were acting out of turn, and they
---can't leave Drakon unplaced or more tiles in hand than allowed.
---@param state GAME.STATE
---@return boolean
function lib.canEndTurn(state)
    if lib.isOver(state) then return false end
    if not (state.moved or state.placedTile or state.pushedHero) and state.activePlayer == state.turnPlayer then
        return false
    end
    if lib.mustPlaceDrakon(state) and not state.drakonActive then return false end
    return not lib.mustDiscard(state)
end

---finish the active player's action ($00BE66B8). `force` skips the canEndTurn check.
---returns a table describing what happened, or nil and the reason it isn't allowed:
---winners = { team, ... }   the game is over and these teams won
---drawn = { tile, ... }      tiles drawn to refill the hand
---skipped = { player, ... }  players who lost their turn in the Void
---stuck = true              nobody can do anything: the game is over without a winner
---in order:
---1. a team with enough gold wins, and the game ends;
---2. the active player's hand is refilled;
---3. a player with a decision pending (their hero was moved into a chamber) acts next;
---4. a player acting out of turn hands back to the turn player, who carries on if they
---still can do something;
---5. when the BigDungeonRounds opening rounds are over, a random player starts;
---6. otherwise play passes to the next player (left) who can do something. A player whose
---turn is lost in the Void is skipped (once); if play comes round twice to the player
---who just finished without anyone able to act, the game ends.
---@param state GAME.STATE
---@param force? boolean
---@return GAME.TURNRESULT|nil result
---@return string? err
function lib.endTurn(state, force)
    if not force and not lib.canEndTurn(state) then
        return nil, "You cannot finish an action right now"
    end
    local result = { skipped = {} }
    checkpoint(state)

    local winners = lib.winners(state)
    if #winners > 0 then
        state.savedState = nil
        state.activePlayer = nil
        result.winners = winners
        return result
    end

    result.drawn = lib.fillHand(state, state.activePlayer)

    --(fix, see game.thiefSteal) a Knight's loss nobody has been asked about yet
    if state.savedGoldState and not state.pendingActivePlayer then
        state.pendingActivePlayer = state.savedGoldState.player
    end

    if state.pendingActivePlayer then
        state.activePlayer = state.pendingActivePlayer
        state.pendingActivePlayer = nil
        state.savedState = nil
        return result
    end

    if state.activePlayer ~= state.turnPlayer then
        state.activePlayer = state.turnPlayer
        state.savedState = nil
        state.tileEffect = E.Empty
        if lib.canAct(state) then return result end
    end

    local previous = state.turnPlayer
    local opening = state.config.options.bigDungeonRounds * #state.players
    if opening == state.turnNumber and not lib.canAct(state) then
        state.turnPlayer = state.players[state.random(1, #state.players)]
        lib.beginTurn(state)
        state.turnNumber = state.turnNumber + 1
        if state.turnPlayer ~= previous then state.savedState = nil end
        return result
    end

    local cameBack = 0
    while true do
        state.turnPlayer = lib.leftOf(state, state.turnPlayer)
        lib.beginTurn(state)
        if state.turnPlayer.skipTurn then
            state.turnPlayer.skipTurn = false
            result.skipped[#result.skipped + 1] = state.turnPlayer
        elseif lib.canAct(state) then
            state.turnNumber = state.turnNumber + 1
            if state.turnPlayer ~= previous then state.savedState = nil end
            return result
        elseif state.turnPlayer == previous then
            cameBack = cameBack + 1
            if cameBack == 2 then
                state.savedState = nil
                state.activePlayer = nil
                result.stuck = true
                return result
            end
        end
    end
end

---------------------------------------------------------------------------- copying

---a deep copy of a game state, for trying things out (the AI). Tiles, hands, players and
---the Knight records are copied; the configuration and teams are shared (never changed in
---play). The copy uses `random` if given, else the original's random function.
---@param state GAME.STATE
---@param random? GAME.RANDOM
---@return GAME.STATE
function lib.cloneState(state, random)
    local tileMap, handMap, playerMap = {}, {}, {}
    ---copy of a tile (nil stays nil)
    ---@param t TILES.TILE|nil
    ---@return TILES.TILE|nil
    local function ct(t)
        if not t then return nil end
        local c = tileMap[t]
        if not c then c = t:clone(); tileMap[t] = c end
        return c
    end
    local n = {}
    for k, v in pairs(state) do n[k] = v end
    n.random = random or state.random
    n.savedState = nil
    n.board = BOARD:new()
    for x, y, t in state.board:each() do n.board:set(x, y, ct(t)) end
    n.deck = {}
    for i, t in ipairs(state.deck) do n.deck[i] = ct(t) end
    n.players = {}
    for i, p in ipairs(state.players) do
        local q = {}
        for k, v in pairs(p) do q[k] = v end
        local h = handMap[p.hand]
        if not h then
            h = { tileLimit = p.hand.tileLimit, name = p.hand.name, tiles = {} }
            for j, t in ipairs(p.hand.tiles) do h.tiles[j] = ct(t) end
            handMap[p.hand] = h
        end
        q.hand = h
        n.players[i] = q
        playerMap[p] = q
    end
    n.turnPlayer = playerMap[state.turnPlayer]
    n.activePlayer = playerMap[state.activePlayer]
    n.pendingActivePlayer = playerMap[state.pendingActivePlayer]
    ---@param g GAME.GOLDSTATE|nil
    ---@return GAME.GOLDSTATE|nil
    local function copyGold(g)
        if not g then return nil end
        local lostTo = g.lostTo
        if type(lostTo) == "table" then lostTo = playerMap[lostTo] end
        return { player = playerMap[g.player], lostTo = lostTo, next = copyGold(g.next) }
    end
    n.savedGoldState = copyGold(state.savedGoldState)
    n.importantLocs = {}
    for i, v in ipairs(state.importantLocs) do n.importantLocs[i] = v end
    return n
end

---------------------------------------------------------------------------- setup

--SeparateTeamStart ($00BEB468): for 2 to 6 teams, a small dungeon of Empty chambers is
--built around the Start chamber and each team starts in its own room (teams in the order
--their players first appear). Rooms are { x, y, exits }; exits as U/R/D/L letters.
---@type {[integer]:GAME.TEAMSTART}
lib.TEAM_STARTS = {
    [2] = { rooms = { { 1, 0, "R" }, { 2, 0, "RD" }, { -1, 0, "L" }, { -2, 0, "DL" } },
            starts = { { -2, 0 }, { 2, 0 } } },
    [3] = { rooms = { { 1, 0, "R" }, { 2, 0, "UR" }, { -1, 0, "L" }, { -2, 0, "UL" }, { 0, 1, "D" },
                      { 0, 2, "RL" } },
            starts = { { -2, 0 }, { 2, 0 }, { 0, 2 } } },
    [4] = { rooms = { { 0, 1, "D" }, { 0, 2, "RL" }, { 1, 2, "R" }, { 2, 2, "URD" }, { 2, 1, "UR" },
                      { 2, 3, "RD" }, { -1, 2, "L" }, { -2, 2, "UDL" }, { -2, 1, "UL" }, { -2, 3, "DL" } },
            starts = { { -2, 1 }, { -2, 3 }, { 2, 1 }, { 2, 3 } } },
    [5] = { rooms = { { 0, 1, "D" }, { 0, 2, "RDL" }, { 1, 2, "R" }, { 2, 2, "URD" }, { 2, 1, "UR" },
                      { 2, 3, "RD" }, { -1, 2, "L" }, { -2, 2, "UDL" }, { -2, 1, "UL" }, { -2, 3, "DL" },
                      { 0, 3, "RL" }, { 0, 4, "RL" }, { 0, 5, "RDL" } },
            starts = { { -2, 1 }, { -2, 3 }, { 2, 1 }, { 2, 3 }, { 0, 5 } } },
    [6] = { rooms = { { 0, 1, "D" }, { 0, 2, "RL" }, { 1, 2, "R" }, { 2, 2, "URD" }, { 2, 1, "U" },
                      { 3, 2, "R" }, { 2, 3, "D" }, { -1, 2, "L" }, { -2, 2, "UDL" }, { -2, 1, "U" },
                      { -3, 2, "L" }, { -2, 3, "D" } },
            starts = { { -2, 1 }, { -3, 2 }, { -2, 3 }, { 2, 1 }, { 3, 2 }, { 2, 3 } } },
}

---arrow set from U/R/D/L letters
---@param letters string
---@return TILES.ARROWS
local function exitLetters(letters)
    local dirs = {}
    for ch in letters:gmatch(".") do
        dirs[#dirs + 1] = ({ U = TILES.UP, R = TILES.RIGHT, D = TILES.DOWN, L = TILES.LEFT })[ch]
    end
    return TILES.arrowSet(unpack(dirs))
end

---build the separate team start dungeon and put each team on its start (2 to 6 teams)
---@param state GAME.STATE
function lib.buildTeamStarts(state)
    local teams, order = {}, {}
    for _, p in ipairs(state.players) do
        if not teams[p.team.name] then
            order[#order + 1] = p.team.name
            teams[p.team.name] = #order
        end
    end
    local layout = lib.TEAM_STARTS[#order]
    if not layout then return end
    for _, r in ipairs(layout.rooms) do
        state.board:set(r[1], r[2], TILES.fromParts(E.Empty, exitLetters(r[3])))
    end
    for _, p in ipairs(state.players) do
        local sq = layout.starts[teams[p.team.name]]
        p.x, p.y = sq[1], sq[2]
    end
end

---deal hands and pick the first player ($00BE45F4).
---@param state GAME.STATE
local function startGame(state)
    local hands = {}   --hand config -> shared in-game hand
    for _, p in ipairs(state.players) do
        local hc = p.config.hand
        local hand = hands[hc]
        if not hand then
            hand = { tileLimit = hc.tileCount, tiles = {}, name = hc.name }
            hands[hc] = hand
        end
        p.hand = hand
        lib.fillHand(state, p)
        if state.config.options.forceGoldTile then lib.forceGoldTile(state, p) end
    end
    state.turnPlayer = state.players[state.random(1, #state.players)]
    state.savedState = nil
    lib.beginTurn(state)
    if state.config.options.separateTeamStart then lib.buildTeamStarts(state) end
end

---set up a new game from a configuration ($00BE39EC):
---Start chamber at (0, 0), every hero on it, hands dealt, first player chosen at random.
---`random(lo, hi)` is optional (e.g. love.math.random); it drives shuffling and the first player.
---@param config GAME.CONFIG
---@param random? GAME.RANDOM
---@return GAME.STATE
function lib.newGame(config, random)
    lib.validate(config)
    local state = newState(config, random)
    for _, pc in ipairs(config.players) do
        state.players[#state.players + 1] = newPlayer(pc)
    end
    state.board:clear()
    state.board:set(0, 0, DECK.startTile())
    for _, p in ipairs(state.players) do p.x, p.y = 0, 0 end
    state.importantLocs = {}
    startGame(state)
    return state
end

return lib
