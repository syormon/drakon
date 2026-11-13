--the dungeon: tiles placed on integer grid squares. Up is y - 1 (see tiles.neighbor).
--pure Lua: no LÖVE calls.

---a placed tile
---@class BOARD.CELL
---@field x integer
---@field y integer
---@field tile TILES.TILE

---the dungeon grid
---@class BOARD
---@field cells {[string]:BOARD.CELL} keyed "x,y"
---@field count integer tiles placed
local lib = {}

--each board's cells sorted by row, then column, made when first needed after a change. Kept
--outside the board (weakly), so it isn't copied or sent with it.
---@type {[BOARD]:BOARD.CELL[]}
local sorted = setmetatable({}, { __mode = "k" })

---@param x integer
---@param y integer
---@return string
local function key(x, y) return x .. "," .. y end

---new empty board
---@return BOARD
function lib:new()
    local o = { cells = {}, count = 0 }
    setmetatable(o, self)
    self.__index = self
    return o
end

---tile on a square, or nil
---@param x integer
---@param y integer
---@return TILES.TILE|nil
function lib:get(x, y)
    local c = self.cells[key(x, y)]
    return c and c.tile
end

---@param x integer
---@param y integer
---@return boolean
function lib:has(x, y) return self.cells[key(x, y)] ~= nil end

---put a tile on a square (nil removes it)
---@param x integer
---@param y integer
---@param tile TILES.TILE|nil
function lib:set(x, y, tile)
    local k = key(x, y)
    if tile == nil then return self:remove(x, y) end
    local c = self.cells[k]
    if c then
        c.tile = tile   --(same square: the order stands)
    else
        self.cells[k] = { x = x, y = y, tile = tile }
        self.count = self.count + 1
        sorted[self] = nil
    end
end

---@param x integer
---@param y integer
function lib:remove(x, y)
    local k = key(x, y)
    if self.cells[k] then
        self.cells[k] = nil
        self.count = self.count - 1
        sorted[self] = nil
    end
end

---remove every tile
function lib:clear()
    self.cells, self.count = {}, 0
    sorted[self] = nil
end

---iterate placed tiles: for x, y, tile in board:each() do ... end, row by row, left to
---right: the same order on every run and every computer (pairs order isn't), so the
---computer players' choices are too. Tiles placed or removed while going through don't
---change what this pass visits.
---@return fun():integer?, integer?, TILES.TILE?
function lib:each()
    local order = sorted[self]
    if not order then
        order = {}
        for _, c in pairs(self.cells) do order[#order + 1] = c end
        table.sort(order, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
        sorted[self] = order
    end
    local i = 0
    return function()
        i = i + 1
        local c = order[i]
        if c then return c.x, c.y, c.tile end
    end
end

---position of a tile object on the board, or nil.
---@param tile TILES.TILE
---@return integer|nil x
---@return integer|nil y
function lib:find(tile)
    for x, y, t in self:each() do
        if t == tile then return x, y end
    end
end

---bounding box of placed tiles: minX, minY, maxX, maxY (all 0 for an empty board).
---@return integer minX
---@return integer minY
---@return integer maxX
---@return integer maxY
function lib:bounds()
    local minX, minY, maxX, maxY
    for x, y in self:each() do
        minX = math.min(minX or x, x); minY = math.min(minY or y, y)
        maxX = math.max(maxX or x, x); maxY = math.max(maxY or y, y)
    end
    return minX or 0, minY or 0, maxX or 0, maxY or 0
end

---a copy with copies of every tile
---@return BOARD
function lib:clone()
    local b = lib:new()
    local order = {}
    for x, y, t in self:each() do
        b:set(x, y, t:clone())
        order[#order + 1] = b.cells[key(x, y)]
    end
    sorted[b] = order   --(already in order)
    return b
end

return lib
