--a player's action as plain data, so it can be sent over the network and carried out on
--another copy of the same game. Tiles are sent as their place in the active player's hand
--(with their arrows, which the player may have turned) and players as their seat number.
--Decoding checks everything, as the action may come from anyone on the network.
--pure Lua: no LÖVE calls.

local GAME = require('src.game')
local TILES = require('src.tiles')
local unpack = table.unpack or unpack

---an action to carry out with game[op](state, args...)
---@class ACTIONS.ACTION
---@field op string a name in ACTIONS.OPS
---@field args any[] numbers, booleans and { "tile", index, kind } / { "player", index }

---what a game call takes, after the state: "tile" (from the active player's hand), "player",
---"int" (a board square, a number of turns) or "bool"
---@alias ACTIONS.ARG "tile"|"player"|"int"|"bool"

local lib = {}

---every game call a player can make, with what it takes
---@type {[string]:ACTIONS.ARG[]}
lib.OPS = {
    placeTile = { "tile", "int", "int" },
    movePlayer = { "int", "int" },
    endTurn = {},
    knightDecline = {},
    knightReclaim = {},
    undo = {},
    drawTileAction = {},
    dwarfDraw = {},
    moveToEscape = {},
    mapSteal = { "player" },
    moveOtherPlayer = { "player", "int", "int" },
    destroyRoom = { "int", "int" },
    bargainRoom = { "int", "int" },
    magicShift = { "tile", "int", "int" },
    swapRooms = { "int", "int", "int", "int" },
    rotateRoom = { "int", "int", "int" },
    floatRoom = { "int", "int", "int" },
    moveDrakon = { "int", "int" },
    thiefSteal = { "player" },
    barbarianPush = { "player", "int", "int" },
}

---@param list table
---@param item any
---@return integer|nil
local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
end

---the action for game[op](state, ...), made before the call (while the tile is still in
---the hand). Errors if the arguments don't fit.
---@param state GAME.STATE
---@param op string
---@param ... any the call's arguments after the state
---@return ACTIONS.ACTION
function lib.encode(state, op, ...)
    local kinds = lib.OPS[op]
    if not kinds then error("actions: unknown game call " .. tostring(op)) end
    local args = { ... }
    local out = {}
    for i, kind in ipairs(kinds) do
        local v = args[i]
        if kind == "tile" then
            local hand = state.activePlayer and state.activePlayer.hand.tiles or {}
            local at = indexOf(hand, v)
            if not at then error("actions: the tile is not in the active player's hand") end
            out[i] = { "tile", at, v.kind }
        elseif kind == "player" then
            local at = indexOf(state.players, v)
            if not at then error("actions: not a player of this game") end
            out[i] = { "player", at }
        else
            out[i] = v
        end
    end
    return { op = op, args = out }
end

---@param v any
---@return boolean
local function isInt(v)
    return type(v) == "number" and v == math.floor(v) and math.abs(v) < 2 ^ 31
end

---the game call and its arguments for an action, or nil and why it doesn't fit this game.
---A tile keeps its place in the hand; its arrows are set as sent (the same chamber turned).
---@param state GAME.STATE
---@param action any
---@return string|nil op
---@return any[]|string args (or what is wrong)
function lib.decode(state, action)
    if type(action) ~= "table" or type(action.op) ~= "string" or type(action.args) ~= "table" then
        return nil, "not an action"
    end
    local kinds = lib.OPS[action.op]
    if not kinds then return nil, "unknown action " .. action.op end
    local args = {}
    for i, kind in ipairs(kinds) do
        local v = action.args[i]
        if kind == "tile" then
            local hand = state.activePlayer and state.activePlayer.hand.tiles or {}
            --(a tile's kind: the chamber in bits 0-4, its exits in bits 5-8)
            if type(v) ~= "table" or v[1] ~= "tile" or not isInt(v[2]) or not isInt(v[3]) or v[3] < 0 or v[3] > 511 then
                return nil, "bad tile"
            end
            local t = hand[v[2]]
            if not t then return nil, "no such tile in the hand" end
            local turned = TILES.new(v[3])
            if turned:effect() ~= t:effect() or turned:styleName() ~= t:styleName() then
                return nil, "that is a different tile"
            end
            args[i] = { tile = t, kind = v[3] }
        elseif kind == "player" then
            if type(v) ~= "table" or v[1] ~= "player" or not isInt(v[2]) then return nil, "bad player" end
            local p = state.players[v[2]]
            if not p then return nil, "no such player" end
            args[i] = p
        elseif kind == "int" then
            if not isInt(v) then return nil, "bad number" end
            args[i] = v
        elseif kind == "bool" then
            if type(v) ~= "boolean" then return nil, "bad flag" end
            args[i] = v
        end
    end
    --turn the tiles as the player did (only once everything else is known to be good)
    for i, kind in ipairs(kinds) do
        if kind == "tile" then
            args[i].tile.kind = args[i].kind
            args[i] = args[i].tile
        end
    end
    return action.op, args
end

---carry out an action on a game: what the game call returns (nil and an error message if
---it was refused, or didn't fit this game)
---@param state GAME.STATE
---@param action any
---@return any result
---@return any err
function lib.apply(state, action)
    local op, args = lib.decode(state, action)
    if not op then return nil, args end
    local list = args --[[@as any[] ]]
    return GAME[op](state, unpack(list, 1, #lib.OPS[op]))
end

return lib
