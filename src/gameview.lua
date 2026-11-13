--interactive view of a game: the board with heroes, each player's card and hand, what can
--be done now, and a log of computer moves.
--
--click a highlighted room (no tile selected) move your hero there
--click a tile in the active player's hand  select it
--R / right click / mouse wheel             rotate the selected tile
--click a highlighted square                place it there
--Enter / the green Finish turn button       finish your turn
--U / the red Undo button                   take back the last action
--Esc / the Quit button                     asks, then ends the game and goes back to the setup (Leave in a
--                                          joined network game); Esc first drops a half-made pick
--Tab (in a network game)                   chat: type, then Enter (Esc cancels)
--+ / - / Ctrl+wheel (or the wheel, with      zoom the board in and out (at the mouse); 0 fits the
--  nothing to turn)                          board to the window again
--the - / + / Fit buttons (top right)        the same, zooming at the middle of the board
--drag the board (left or middle button)     move it around when zoomed in

local TILES = require('src.tiles')
local GAME = require('src.game')
local TILEART = require('src.tileart')
local AI = require('src.ai')
local UI = require('src.ui')
local ACTIONS = require('src.actions')

---where the board is drawn
---@class GAMEVIEW.LAYOUT
---@field minX integer
---@field minY integer
---@field maxX integer
---@field maxY integer
---@field size integer tile size in pixels
---@field ox number pixel of the top-left square
---@field oy number
---@field left number the area the board is drawn in (it is cut off at its edges)
---@field top number
---@field width number
---@field height number

---the game screen
---@class GAMEVIEW
---@field state GAME.STATE
---@field selected TILES.TILE|nil hand tile being placed
---@field message {text:string, error?:boolean}|nil
---@field hover TILES.TILE|nil tile under the mouse
---@field layout GAMEVIEW.LAYOUT|nil
---@field handRects {x:number, y:number, tile:TILES.TILE}[]
---@field playerRects {y1:number, y2:number, player:GAME.PLAYER}[]
---@field pick {[1]:integer, [2]:integer}|nil first room picked for a chamber choice
---@field turns integer quarter turns previewed for Rotate / Floating Room
---@field orbHero GAME.PLAYER|nil hero picked for the Mind Control Orb or the Barbarian
---@field ability "thief"|"barbarian"|nil while picking a target
---@field aiTimer number pause before a computer player acts
---@field log string[] recent computer moves, newest last
---@field animStart {[TILES.TILE]:number} when each animating tile (selected or hovered) started
---@field net SESSION.HOST|SESSION.CLIENTSESSION|nil the network game this is part of
---@field outbox ACTIONS.ACTION[] actions done here since the last input, to send
---@field actor string|nil who did them
---@field chatting string|nil chat being typed
---@field buttonRects {x:number, y:number, w:number, h:number, kind:"confirm"|"cancel", enabled:boolean}[]
---@field quitRect {x:number, y:number, w:number, h:number}|nil the Quit button, as drawn
---@field request "quit"|nil set when quitting was confirmed (main.lua goes back to the setup, or leaves the network game)
---@field confirmQuit boolean the "Quit this game?" question is showing
---@field dialogRects {x:number, y:number, w:number, h:number, kind:"yes"|"no"}[]
---@field zoom integer|nil board tile size picked with + / - (one of ZOOM_SIZES); nil fits the window
---@field panX number how far the zoomed board is moved from the middle, in pixels
---@field panY number
---@field drag {x:number, y:number, button:integer, moved:boolean}|nil a press on the board that may become a drag
---@field zoomRects UI.BUTTON[]|nil the zoom buttons, as drawn
local lib = {}

local HAND_TILE = 64
local PANEL_W = 460
local INFO_H = 76 --message bar under the board
---board tile sizes, largest first: the 128 and 064 image sets at their own size (and the
---064 set at a half or a quarter for huge dungeons), so every pixel stays sharp
---@type integer[]
local TILE_SIZES = { 128, 64, 32, 16 }
---sizes + / - step through, smallest first: each is a whole-number scale of an image set
---(the 064 set at a quarter or a half, the sets at their own size, the 128 set doubled), so
---zooming keeps the pixel art sharp
---@type integer[]
local ZOOM_SIZES = { 16, 32, 64, 128, 256 }
---pixels the mouse must move with the left button down before a press becomes a drag
local DRAG_START = 6

---@param state GAME.STATE
---@param net? SESSION.HOST|SESSION.CLIENTSESSION a network game: the host, or a joined player
---@return GAMEVIEW
function lib:new(state, net)
    local o = {
        state = state,
        selected = nil,
        message = nil,
        hover = nil,
        layout = nil,
        handRects = {},
        buttonRects = {},
        confirmQuit = false,
        dialogRects = {},
        playerRects = {},
        pick = nil, --first room picked for a chamber choice ({x, y})
        turns = 0, --quarter turns previewed for Rotate / Floating Room
        orbHero = nil, --hero picked for the Mind Control Orb or the Barbarian
        ability = nil, --"thief" / "barbarian" while picking a target
        aiTimer = 0, --pause before a computer player acts
        log = {}, --recent computer moves, newest last
        animStart = {}, --tile -> time its animation started
        net = net,
        outbox = {},
        actor = nil,
        chatting = nil,
        zoom = nil,
        panX = 0,
        panY = 0,
        drag = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param text string
---@param isError? boolean
function lib:setMessage(text, isError)
    self.message = { text = text, error = isError }
end

---------------------------------------------------------------------------- playing over the network

---whether a player's moves are made here (with the mouse and keys): not a computer player,
---and in a network game, a seat of this computer's
---@param player GAME.PLAYER|nil
---@return boolean
function lib:controls(player)
    if not player or AI.levelOf(player) then return false end
    if self.net then return self.net:controls(player) end
    return true
end

---@return boolean
function lib:isClient() return self.net ~= nil and self.net.role == "client" end

---whether a player's hand is shown face up here: always on one computer; in a network game,
---only the hands of seats played here (and every hand once the game is over)
---@param p GAME.PLAYER
---@return boolean
function lib:seesHand(p)
    if not self.net or GAME.isOver(self.state) then return true end
    for _, q in ipairs(self.state.players) do
        if q.hand == p.hand then
            if self:isClient() then
                if q.config.peer == self.net.id then return true end
            elseif not q.config.remote then
                return true
            end
        end
    end
    return false
end

---carry out a game call (game[op](state, ...)) for the active player, and remember it to
---send if this is a network game
---@param op string
---@param ... any
---@return any result
---@return any err
function lib:act(op, ...)
    local action = self.net and ACTIONS.encode(self.state, op, ...)
    local who = self.state.activePlayer
    local r, err = GAME[op](self.state, ...)
    if r and action then
        self.outbox[#self.outbox + 1] = action
        self.actor = self.actor or (who and who.name)
    end
    return r, err
end

---send what was done since the last input, with the message saying what happened (named
---after who did it) for everyone's log
function lib:flush()
    if #self.outbox == 0 then return end
    local line = self.message and not self.message.error and self.message.text or nil
    local finished = false
    for _, a in ipairs(self.outbox) do if a.op == "endTurn" then finished = true end end
    if line and self.actor and finished then
        line = self.actor .. " finished their turn. " .. line
    elseif line and self.actor and line:sub(1, #self.actor) ~= self.actor then
        line = self.actor .. ": " .. line
    end
    local net = self.net
    if net and net.role == "client" then
        local client = net --[[@as SESSION.CLIENTSESSION]]
        for i, a in ipairs(self.outbox) do client:sendAction(a, i == #self.outbox and line or nil) end
    elseif net then
        (net --[[@as SESSION.HOST]]):changed(line and { line } or nil)
    end
    self.outbox, self.actor = {}, nil
end

---"Game over..." for a finished game
---@return string
function lib:gameOverText()
    local w = GAME.winners(self.state)
    if #w == 0 then return "Game over: nobody can do anything more." end
    local names = {}
    for _, t in ipairs(w) do names[#names + 1] = t.name end
    return ("Game over: %s won with %d gold!"):format(table.concat(names, " and "), w[1].gold)
end

---a joined player: the host sent the game. What was picked (a hand tile and how it is turned,
---a hero, a room) is kept while it is still this computer's move.
---@param state GAME.STATE
function lib:replaceState(state)
    local old = self.state
    local wasMine = self:controls(old.activePlayer)
    local selIndex, selKind
    if self.selected and old.activePlayer then
        for i, t in ipairs(old.activePlayer.hand.tiles) do
            if t == self.selected then selIndex, selKind = i, t.kind end
        end
    end
    local orbIndex
    for i, q in ipairs(old.players) do if q == self.orbHero then orbIndex = i end end
    self.state = state
    self.selected, self.orbHero = nil, nil
    self.animStart, self.hover = {}, nil
    local mine = self:controls(state.activePlayer)
    if mine then
        local t = selIndex and state.activePlayer.hand.tiles[selIndex]
        if t and TILES.new(selKind):effect() == t:effect() then t.kind = selKind; self.selected = t end
        self.orbHero = orbIndex and state.players[orbIndex]
    else
        self.pick, self.ability, self.turns = nil, nil, 0
    end
    if GAME.isOver(state) then
        self:setMessage(self:gameOverText())
    elseif mine and not wasMine then
        self:setMessage(state.activePlayer.name .. ", your turn.")
    end
end

---start typing a chat line (network games)
function lib:startChat()
    if self.net then self.chatting = "" end
end

---@param t string
function lib:textinput(t)
    if self.chatting and #self.chatting < 160 then self.chatting = self.chatting .. t:gsub("[\t\r\n]", "") end
end

---keys while typing a chat line
---@param key love.KeyConstant
function lib:chatKey(key)
    if key == "return" or key == "kpenter" then
        if self.chatting ~= "" then self.net:say(self.chatting) end
        self.chatting = nil
    elseif key == "escape" then
        self.chatting = nil
    elseif key == "backspace" then
        local t = self.chatting or ""
        local cut = #t
        while cut > 0 and t:byte(cut) >= 0x80 and t:byte(cut) < 0xC0 do cut = cut - 1 end
        self.chatting = t:sub(1, math.max(0, cut - 1))
    end
end

---------------------------------------------------------------------------- layout

---where the board starts along one side: in the middle if it fits, else moved by `pan` but
---never so far that space opens up beyond its edge
---@param start number
---@param length number room for it
---@param content number its size
---@param pan number
---@return number origin whole pixels
---@return number pan as kept
local function place(start, length, content, pan)
    if content <= length - 20 then return start + math.floor((length - content) / 2), 0 end
    local middle = start + (length - content) / 2
    local o = math.max(start + length - content - 10, math.min(start + 10, middle + pan))
    return math.floor(o), o - middle
end

---board area: everything placed plus a ring of empty squares, at the zoom picked, or else the
---largest tile size that fits.
---@param left number
---@param top number
---@param width number
---@param height number
---@return GAMEVIEW.LAYOUT
function lib:boardLayout(left, top, width, height)
    local minX, minY, maxX, maxY = self.state.board:bounds()
    minX, minY, maxX, maxY = minX - 1, minY - 1, maxX + 1, maxY + 1
    local cols, rows = maxX - minX + 1, maxY - minY + 1
    local size = self.zoom
    if not size then
        size = TILE_SIZES[#TILE_SIZES]
        for _, s in ipairs(TILE_SIZES) do
            if cols * s <= width - 20 and rows * s <= height - 20 then size = s; break end
        end
    end
    local ox, oy
    ox, self.panX = place(left, width, cols * size, self.panX)
    oy, self.panY = place(top, height, rows * size, self.panY)
    return { minX = minX, minY = minY, maxX = maxX, maxY = maxY, size = size, ox = ox, oy = oy,
             left = left, top = top, width = width, height = height }
end

---whether a pixel is in the board's area (and not on the zoom buttons over it)
---@param sx number
---@param sy number
---@return boolean
function lib:onBoard(sx, sy)
    local l = self.layout
    return l ~= nil and sx >= l.left and sx < l.left + l.width and sy >= l.top and sy < l.top + l.height
        and not UI.hit(self.zoomRects, sx, sy)
end

---zoom one step in (steps > 0) or out, keeping the point at (mx, my) where it is (default:
---the middle of the board's area). Returns whether the size changed.
---@param steps integer
---@param mx? number
---@param my? number
---@return boolean
function lib:zoomBy(steps, mx, my)
    local l = self.layout
    if not l then return false end
    local new
    if steps > 0 then
        for _, size in ipairs(ZOOM_SIZES) do if size > l.size then new = size; break end end
    else
        for i = #ZOOM_SIZES, 1, -1 do if ZOOM_SIZES[i] < l.size then new = ZOOM_SIZES[i]; break end end
    end
    if not new then return false end
    if not (mx and my and self:onBoard(mx, my)) then mx, my = l.left + l.width / 2, l.top + l.height / 2 end
    --the board point under the mouse, in squares from the layout's corner, stays put
    local gx, gy = (mx - l.ox) / l.size, (my - l.oy) / l.size
    local cols, rows = l.maxX - l.minX + 1, l.maxY - l.minY + 1
    self.zoom = new
    self.panX = (mx - gx * new) - (l.left + (l.width - cols * new) / 2)
    self.panY = (my - gy * new) - (l.top + (l.height - rows * new) / 2)
    self.layout = self:boardLayout(l.left, l.top, l.width, l.height)
    return true
end

---back to fitting the whole board in the window
function lib:zoomFit()
    self.zoom, self.panX, self.panY = nil, 0, 0
    local l = self.layout
    if l then self.layout = self:boardLayout(l.left, l.top, l.width, l.height) end
end

---top-left pixel of a board square
---@param x integer
---@param y integer
---@return number sx
---@return number sy
function lib:toScreen(x, y)
    local l = self.layout --[[@as GAMEVIEW.LAYOUT]]
    return l.ox + (x - l.minX) * l.size, l.oy + (y - l.minY) * l.size
end

---board square under a pixel, or nil
---@param sx number
---@param sy number
---@return integer|nil x
---@return integer|nil y
function lib:toGrid(sx, sy)
    local l = self.layout --[[@as GAMEVIEW.LAYOUT]]
    if not l or not self:onBoard(sx, sy) then return end
    local x = l.minX + math.floor((sx - l.ox) / l.size)
    local y = l.minY + math.floor((sy - l.oy) / l.size)
    if x < l.minX or x > l.maxX or y < l.minY or y > l.maxY then return end
    return x, y
end

---every empty square next to the board (where a room could go).
---@param s GAME.STATE
---@return {[1]:integer, [2]:integer}[]
local function emptySquares(s)
    local out, seen = {}, {}
    for bx, by in s.board:each() do
        for d = 0, 3 do
            local x, y = TILES.neighbor(bx, by, d)
            local k = x .. "," .. y
            if not seen[k] and not s.board:has(x, y) then
                seen[k] = true
                out[#out + 1] = { x, y }
            end
        end
    end
    return out
end

---a crisp highlight on a board square
---@param view GAMEVIEW
---@param x integer
---@param y integer
---@param c UI.COLOR
---@param fill? number fill alpha, default 0.16
local function mark(view, x, y, c, fill)
    local sx, sy = view:toScreen(x, y)
    local size = view.layout.size
    local inset = size >= 64 and 3 or 2
    UI.box(sx + inset, sy + inset, size - 2 * inset, size - 2 * inset, { c[1], c[2], c[3], fill or 0.16 }, 5)
    UI.outline(sx + inset, sy + inset, size - 2 * inset, size - 2 * inset, { c[1], c[2], c[3], 0.95 }, 2, 5)
end

---------------------------------------------------------------------------- drawing

---faint outlines on the empty squares next to the dungeon, where a room could go
function lib:drawGrid()
    local l = self.layout --[[@as GAMEVIEW.LAYOUT]]
    local inset = l.size >= 64 and 4 or 2
    for _, sq in ipairs(emptySquares(self.state)) do
        local sx, sy = self:toScreen(sq[1], sq[2])
        UI.outline(sx + inset, sy + inset, l.size - 2 * inset, l.size - 2 * inset, { 1, 1, 1, 0.07 }, 1, 8)
    end
end

---whole-number scale for hero tokens on a board of this tile size: the original tokens are
---small (18 pixels on a 128 room), so they are doubled on 64 and 128 rooms
---@param size integer
---@return integer
local function tokenScale(size)
    return size >= 64 and 2 or 1
end

---size of a hero token as drawn on the board
---@param name string colour name, or "Drakon"
---@param size integer tile size
---@return number
local function tokenSize(name, size)
    return (TILEART.tokenSize(name, size)) * tokenScale(size)
end

---a hero (or Drakon) token with a dark ring so it stands out on any room
---@param name string colour name, or "Drakon"
---@param x number
---@param y number
---@param size integer tile size
local function token(name, x, y, size)
    local w = tokenSize(name, size)
    x, y = math.floor(x), math.floor(y)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.circle("fill", x + w / 2, y + w / 2 + 1, w / 2 + 2)
    love.graphics.setColor(1, 1, 1)
    local k = tokenScale(size) * size / TILEART.setFor(size)
    love.graphics.draw(TILEART.tokenImage(name, size), x, y, 0, k, k)
end

---rooms, highlights, Drakon and heroes
function lib:drawBoard()
    local s, l = self.state, self.layout --[[@as GAMEVIEW.LAYOUT]]
    self:drawGrid()
    love.graphics.setColor(1, 1, 1)
    for x, y, t in s.board:each() do
        local sx, sy = self:toScreen(x, y)
        TILEART.draw(t, sx, sy, l.size, self:animTime(t))
    end

    --where the selected tile can go: green = as it is turned now, faint = after turning
    if self.selected and GAME.canPlaceTile(s) then
        local now, later = {}, {}
        for _, p in ipairs(GAME.legalPlacements(s, self.selected)) do
            local key = p.x .. "," .. p.y
            if p.turns == 0 then now[key] = p else later[key] = later[key] or p end
        end
        for key, p in pairs(later) do
            if not now[key] then
                local sx, sy = self:toScreen(p.x, p.y)
                UI.outline(sx + 3, sy + 3, l.size - 6, l.size - 6, { 0.9, 0.8, 0.4, 0.35 }, 1, 5)
            end
        end
        for _, p in pairs(now) do mark(self, p.x, p.y, UI.COLOR.good) end
        --ghost of the tile under the mouse
        local hx, hy = self:toGrid(love.mouse.getPosition())
        if hx and hy and not s.board:has(hx, hy) then
            local sx, sy = self:toScreen(hx, hy)
            love.graphics.setColor(1, 1, 1, now[hx .. "," .. hy] and 0.8 or 0.3)
            TILEART.draw(self.selected, sx, sy, l.size, self:animTime(self.selected))
        end
    end

    self:drawChoice()

    --Barbarian: where the picked hero can be pushed (blue)
    if self.ability == "barbarian" and self.orbHero then
        for x, y in s.board:each() do
            if not GAME.barbarianPushError(s, self.orbHero, x, y) then mark(self, x, y, UI.COLOR.blue) end
        end
    end
    --Drakon owed: where he may go (orange)
    if GAME.mustPlaceDrakon(s) then
        for _, sq in ipairs(GAME.legalDrakonMoves(s)) do mark(self, sq[1], sq[2], UI.COLOR.orange) end
    end
    --just placed an Escape tile: it can be stepped onto (green)
    if GAME.canMoveToEscape(s) then mark(self, s.escapeX, s.escapeY, UI.COLOR.good) end
    --where the hero can move: blue, or purple through a wall with the Wizard's ability
    if not self.selected and not GAME.openChoice(s) and self:controls(s.activePlayer) then
        for _, m in ipairs(GAME.legalMoves(s)) do
            mark(self, m.x, m.y, m.wizard and UI.COLOR.purple or UI.COLOR.blue)
        end
    end

    --the square under the mouse
    local hx, hy = self:toGrid(love.mouse.getPosition())
    if hx and hy and s.board:has(hx, hy) then
        local sx, sy = self:toScreen(hx, hy)
        UI.outline(sx + 1, sy + 1, l.size - 2, l.size - 2, { 1, 1, 1, 0.5 }, 1, 6)
    end

    --Drakon, in the bottom-right corner of its room
    if s.drakonActive and s.drakonX then
        local sx, sy = self:toScreen(s.drakonX, s.drakonY)
        local w = tokenSize("Drakon", l.size)
        token("Drakon", sx + l.size - 8 - w, sy + l.size - 8 - w, l.size)
    end

    --heroes, in rows from each square's top-left corner
    local bySquare = {}
    for _, p in ipairs(s.players) do
        if p.x then
            local k = p.x .. "," .. p.y
            bySquare[k] = bySquare[k] or { x = p.x, y = p.y }
            table.insert(bySquare[k], p)
        end
    end
    for _, sq in pairs(bySquare) do
        local sx, sy = self:toScreen(sq.x, sq.y)
        for i, p in ipairs(sq) do
            local name = GAME.COLORS[p.colorIndex]
            local step = tokenSize(name, l.size) + 5
            local perRow = math.max(1, math.floor((l.size - 14) / step))
            local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
            token(name, sx + 8 + col * step, sy + 8 + row * step, l.size)
        end
    end
end

---the turn line at the top of the panel
---@param left number
---@param top number
---@param width number
---@return number y below it
function lib:drawTurn(left, top, width)
    local s = self.state
    local title
    if GAME.isOver(s) then
        local w = GAME.winners(s)[1]
        title = w and (w.name .. " wins!") or "Game over"
    else
        title = ("Turn %d  -  %s to play"):format(s.turnNumber, s.activePlayer.name)
    end
    UI.text(title, left, top, 20, UI.COLOR.accent)
    local y = top + 32
    UI.icon("Icon_Tile_Back.gif", left, y - 3)
    UI.text(("%d in the deck"):format(#s.deck), left + 28, y, 13, UI.COLOR.dim)
    UI.icon("Icon_Gold.gif", left + 150, y - 3)
    UI.text(("%d on Start"):format(s.goldOnStart), left + 178, y, 13, UI.COLOR.dim)
    if s.placedTile then
        UI.tag("placed a tile", left + width - 84, y, UI.COLOR.good)
    elseif s.moved then
        UI.tag("moved", left + width - 46, y, UI.COLOR.blue)
    end
    return y + 30
end

---one player's card: name, hero, gold and hand
---@param p GAME.PLAYER
---@param left number
---@param top number
---@param width number
---@param tileSize integer hand tile size
---@param sharedWith string|nil name of the player whose hand this player shares
---@return number height
function lib:drawCard(p, left, top, width, tileSize, sharedWith)
    local s = self.state
    local active = (p == s.activePlayer)
    local handH = sharedWith and 18 or tileSize
    local h = 12 + 22 + 10 + handH + 12
    UI.box(left, top, width, h, active and UI.COLOR.cardActive or UI.COLOR.card, 8)
    if active then
        UI.outline(left, top, width, h, UI.COLOR.accent, 2, 8)
    elseif p == self.orbHero then
        UI.outline(left, top, width, h, UI.COLOR.blue, 2, 8)
    end

    --name line: token, name, hero, tags
    local x, y = left + 12, top + 12
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(TILEART.tokenImage(GAME.COLORS[p.colorIndex], 128), x, y + 2)
    UI.text(p.name, x + 26, y, 16, active and UI.COLOR.text or UI.COLOR.dim)
    local nx = x + 26 + UI.font(16):getWidth(p.name) + 10
    local hero = GAME.HeroName[p.hero]
    if p.hero ~= GAME.Hero.None then
        UI.text(hero, nx, y + 3, 13, p.usedHero and UI.COLOR.faint or UI.COLOR.dim)
        nx = nx + UI.font(13):getWidth(hero) + 8
    end
    local level = AI.levelOf(p)
    if level then nx = nx + UI.tag(level, nx, y + 3, UI.COLOR.teal) + 4 end
    if p.config.dropped then
        nx = nx + UI.tag("left", nx, y + 3, UI.COLOR.bad) + 4
    elseif self:isClient() and self:controls(p) then
        nx = nx + UI.tag("you", nx, y + 3, UI.COLOR.good) + 4
    elseif p.config.remote then
        nx = nx + UI.tag("network", nx, y + 3, UI.COLOR.blue) + 4
    end
    if not p.x then nx = nx + UI.tag(p.skipTurn and "Void: loses a turn" or "Void", nx, y + 3, UI.COLOR.bad) + 4 end

    --gold, right-aligned: unlocked, locked, and the team's total against what it needs
    local team = 0
    for _, q in ipairs(s.players) do
        if q.team == p.team then team = team + GAME.totalGold(q) end
    end
    local goal = ("%d/%d"):format(team, p.team.goldToWin)
    local gx = left + width - 12 - UI.font(13):getWidth(goal)
    UI.text(goal, gx, y + 3, 13, team > 0 and UI.COLOR.accent or UI.COLOR.dim)
    gx = gx - 44
    UI.icon("Icon_LockedGold.gif", gx, y - 1)
    UI.text(tostring(p.lockedGold), gx + 26, y + 3, 13, UI.COLOR.text)
    gx = gx - 40
    UI.icon("Icon_Gold.gif", gx, y - 1)
    UI.text(tostring(p.unlockedGold), gx + 26, y + 3, 13, UI.COLOR.text)

    --how close the team is to winning
    local barY = y + 26
    UI.box(x, barY, width - 24, 4, UI.COLOR.panel, 2)
    local frac = math.min(1, team / math.max(1, p.team.goldToWin))
    if frac > 0 then UI.box(x, barY, math.max(4, (width - 24) * frac), 4, UI.COLOR.accent, 2) end

    --hand
    local hy = barY + 10
    if sharedWith then
        UI.text("shares " .. sharedWith .. "'s hand", x, hy, 12, UI.COLOR.faint)
    elseif not self:seesHand(p) then
        --someone else's hand in a network game: face down
        local back = TILEART.backImage(tileSize)
        local k = tileSize / back:getWidth()
        for i = 1, #p.hand.tiles do
            love.graphics.setColor(1, 1, 1, active and 1 or 0.6)
            love.graphics.draw(back, x + (i - 1) * (tileSize + 6), hy, 0, k, k)
        end
        if #p.hand.tiles == 0 then UI.text("no tiles", x, hy + tileSize / 2 - 8, 12, UI.COLOR.faint) end
    else
        for i, t in ipairs(p.hand.tiles) do
            local hx = x + (i - 1) * (tileSize + 6)
            love.graphics.setColor(1, 1, 1, active and 1 or 0.6)
            TILEART.draw(t, hx, hy, tileSize, self:animTime(t))
            if active then
                self.handRects[#self.handRects + 1] = { x = hx, y = hy, tile = t }
                if t == self.selected then UI.outline(hx - 3, hy - 3, tileSize + 6, tileSize + 6, UI.COLOR.accent, 3, 6) end
            end
        end
        if #p.hand.tiles == 0 then UI.text("no tiles", x, hy + tileSize / 2 - 8, 12, UI.COLOR.faint) end
    end
    return h
end

---what the active player can do now: { key, text } rows (key false for plain text)
---@return {[1]:string|false, [2]:string}[]
function lib:hints()
    local s = self.state
    local out = {}
    ---@param key string|false
    ---@param text string
    local function add(key, text) out[#out + 1] = { key, text } end
    if GAME.isOver(s) then
        if self:isClient() then add(false, "The host can start another game.") else add("N", "new game") end
        return out
    end
    if AI.levelOf(s.activePlayer) then add(false, s.activePlayer.name .. " is thinking..."); return out end
    if not self:controls(s.activePlayer) then add(false, "Waiting for " .. s.activePlayer.name .. " to play..."); return out end
    if GAME.canMoveNow(s) then
        add("Click", s.moved and "a blue room to move again (Amazon)" or "a blue room to move (purple: Wizard)")
    end
    if GAME.canPlaceTile(s) then add("Click", "a hand tile, then a green square; R turns it") end
    local E = TILES.Effect
    if GAME.mustPlaceDrakon(s) then
        add("Click", s.drakonActive and "an orange room to move Drakon (Enter skips)" or "an orange room to put Drakon in")
    elseif s.tileEffect == E.Escape then
        if GAME.canMoveToEscape(s) then add("Click", "the Escape tile to step onto it") end
    elseif GAME.openChoice(s) then
        add(false, self:choiceHelp() .. " (Enter skips)")
    elseif s.tileEffect ~= E.Empty then
        add(false, TILES.EffectName[s.tileEffect] .. ": nothing can be done with it now.")
    end
    if GAME.canThiefSteal(s) then add("T", "Thief: steal a coin") end
    if GAME.canBarbarianPush(s) then add("B", "Barbarian: push a hero") end
    if GAME.canDwarfDraw(s) then add("D", "Dwarf: draw two tiles") end
    if GAME.canDrawTileAction(s) then add("G", "draw a tile (empty hand)") end
    if GAME.canKnightReclaim(s) then
        add("K", "Knight: take back the coin just lost")
    elseif s.savedGoldState and s.pendingActivePlayer == s.savedGoldState.player then
        add(false, s.pendingActivePlayer.name .. " (Knight) may take back a lost coin next.")
    end
    --(finishing and undoing are the Confirm / Cancel buttons under these)
    return out
end

---players, hands, what can be done and the log, on the right
---@param left number
---@param top number
---@param width number
---@param bottom number
function lib:drawPanel(left, top, width, bottom)
    local s = self.state
    self.handRects = {}
    self.playerRects = {}
    local y = self:drawTurn(left, top, width)

    --cards: other players' hands shrink to half size when they would not all fit
    local hints = self:hints()
    local fullH = 12 + 22 + 10 + HAND_TILE + 12 + 8
    local small = #s.players * fullH + #hints * 26 + 174 > bottom - y
    local shownHands = {}
    for _, p in ipairs(s.players) do
        local size = (small and p ~= s.activePlayer) and HAND_TILE / 2 or HAND_TILE
        local h = self:drawCard(p, left, y, width, size, shownHands[p.hand])
        shownHands[p.hand] = shownHands[p.hand] or p.name
        self.playerRects[#self.playerRects + 1] = { y1 = y, y2 = y + h, player = p }
        y = y + h + 8
    end

    --what can be done now
    y = y + 6
    for _, row in ipairs(hints) do
        local x = left
        if row[1] then x = x + UI.keycap(row[1], x, y) + 8 end
        UI.text(row[2], x, y + 2, 13, row[1] and UI.COLOR.text or UI.COLOR.accent, left + width - x)
        y = y + math.max(26, UI.textHeight(row[2], 13, left + width - x) + 8)
    end
    self.buttonRects = {}
    if not GAME.isOver(s) and self:controls(s.activePlayer) then
        y = self:drawButtons(left, y + 4, width) + 10
    end
    local keys = "N new game     C change the setup"
    if self:isClient() then keys = "Tab chat"
    elseif self.net then keys = keys .. "     Tab chat" end
    UI.text(keys, left, y + 2, 12, UI.COLOR.faint)
    self:drawQuit(left + width, y - 3)
    y = y + 30

    --the log (shared in a network game) and the chat, newest last, as much as fits
    local log = self.net and self.net.log or self.log
    if self.net then
        local chatH = math.min(130, math.floor(math.max(0, bottom - y) * 0.42))
        if #log > 0 then self:drawLines("Log", log, left, y, width, bottom - y - chatH - 8) end
        self:drawChat(left, bottom - chatH, width, chatH)
    elseif #log > 0 then
        self:drawLines("Log", log, left, y, width, bottom - y)
    end
end

---one action button: a coloured box with a drawn mark (a tick or a cross), a label and its
---key, dimmed when it can't be used now
---@param x number
---@param y number
---@param w number
---@param kind "confirm"|"cancel"
---@param label string
---@param key string
---@param enabled boolean
function lib:drawButton(x, y, w, kind, label, key, enabled)
    local h = 36
    local confirm = kind == "confirm"
    local c = confirm and { 0.20, 0.52, 0.27 } or { 0.62, 0.16, 0.13 }
    local mx, my = love.mouse.getPosition()
    local over = enabled and mx >= x and mx < x + w and my >= y and my < y + h
    if over then c = { c[1] * 1.2, c[2] * 1.2, c[3] * 1.2 } end
    UI.box(x, y, w, h, c, 6)
    if over then UI.outline(x, y, w, h, { 1, 1, 1, 0.6 }, 1, 6) end
    local a = enabled and 1 or 0.35
    --the mark
    local cx, cy = x + 20, y + math.floor(h / 2)
    love.graphics.setColor(1, 0.97, 0.92, a)
    love.graphics.setLineStyle("rough")
    love.graphics.setLineWidth(3)
    if confirm then
        love.graphics.line(cx - 7, cy, cx - 2, cy + 5, cx + 7, cy - 6)
    else
        love.graphics.line(cx - 6, cy - 6, cx + 6, cy + 6)
        love.graphics.line(cx - 6, cy + 6, cx + 6, cy - 6)
    end
    love.graphics.setLineWidth(1)
    UI.text(label, x + 36, y + 9, 15, { 1, 0.97, 0.92, a })
    --the key, at the right
    local kw = UI.font(12):getWidth(key) + 12
    local kx = x + w - kw - 10
    UI.box(kx, y + 8, kw, 20, { 0, 0, 0, 0.25 * a }, 4)
    UI.text(key, kx + 6, y + 11, 12, { 1, 0.97, 0.92, 0.85 * a })
    self.buttonRects[#self.buttonRects + 1] = { x = x, y = y, w = w, h = h, kind = kind, enabled = enabled }
end

---the Quit button (Leave in a joined network game), right-aligned at `right`
---@param right number
---@param top number
function lib:drawQuit(right, top)
    local label = self:isClient() and "Leave" or "Quit"
    local w = UI.font(13):getWidth(label) + UI.font(12):getWidth("Esc") + 40
    local h = 26
    local x = right - w
    local mx, my = love.mouse.getPosition()
    local over = mx >= x and mx < x + w and my >= top and my < top + h
    UI.box(x, top, w, h, over and UI.COLOR.cardActive or UI.COLOR.card, 5)
    UI.outline(x, top, w, h, over and UI.COLOR.dim or UI.COLOR.border, 1, 5)
    UI.text(label, x + 10, top + 5, 13, UI.COLOR.text)
    local kx = x + w - UI.font(12):getWidth("Esc") - 20
    UI.box(kx, top + 4, UI.font(12):getWidth("Esc") + 12, 18, UI.COLOR.border, 4)
    UI.text("Esc", kx + 6, top + 6, 12, UI.COLOR.text)
    self.quitRect = { x = x, y = top, w = w, h = h }
end

---Confirm (finish the turn, Enter) and Cancel (undo the last action, U), side by side
---@param left number
---@param top number
---@param width number
---@return number y below them
function lib:drawButtons(left, top, width)
    local s = self.state
    local gap = 10
    local bw = math.floor((width - gap) / 2)
    self:drawButton(left, top, bw, "confirm", "Finish turn", "Enter", GAME.canEndTurn(s))
    self:drawButton(left + bw + gap, top, width - bw - gap, "cancel", "Undo", "U", GAME.canUndo(s))
    return top + 36
end

---a box of text lines with a heading: the newest (last) ones, as many as fit
---@param title string
---@param lines string[]
---@param left number
---@param top number
---@param width number
---@param height number
---@param reserve? number height kept free at the bottom
function lib:drawLines(title, lines, left, top, width, height, reserve)
    if height < 50 then return end
    UI.box(left, top, width, height, UI.COLOR.card, 8)
    UI.text(title, left + 12, top + 8, 12, UI.COLOR.faint)
    local lineH = UI.font(12):getHeight() + 3
    local room = math.floor((height - 34 - (reserve or 0)) / lineH)
    local first = math.max(1, #lines - room + 1)
    local ly = top + 28
    for i = first, #lines do
        UI.text(lines[i], left + 12, ly, 12, i == #lines and UI.COLOR.text or UI.COLOR.dim, width - 24)
        ly = ly + lineH
    end
end

---the chat box, with the line being typed
---@param left number
---@param top number
---@param width number
---@param height number
function lib:drawChat(left, top, width, height)
    if height < 50 then return end
    self:drawLines("Chat", self.net.chat, left, top, width, height, 24)
    local y = top + height - 26
    if self.chatting then
        UI.box(left + 8, y - 2, width - 16, 20, UI.COLOR.panel, 4)
        local blink = (love.timer.getTime() % 1 < 0.5) and "_" or ""
        UI.text("> " .. self.chatting .. blink, left + 14, y, 12, UI.COLOR.accent, width - 28)
    else
        UI.text("Tab: say something", left + 12, y, 12, UI.COLOR.faint)
    end
end

---the message (or hovered tile's rules) along the bottom of the board
---@param left number
---@param top number
---@param width number
function lib:drawInfo(left, top, width)
    local t = self.hover
    local h = INFO_H - 12
    if t then
        UI.box(left, top, width, h, UI.COLOR.panel, 8)
        local title = ("%s  (%s)"):format(t:effectName(), t:styleName())
        UI.text(title, left + 14, top + 8, 15, UI.COLOR.accent)
        UI.text(t:helpText(), left + 14, top + 30, 13, UI.COLOR.text, width - 28)
    elseif self.message then
        UI.box(left, top, width, h, UI.COLOR.panel, 8)
        local c = self.message.error and UI.COLOR.bad or UI.COLOR.good
        UI.box(left, top, 4, h, c, 2)
        UI.text(self.message.text, left + 16, top + 10, 14, self.message.error and UI.COLOR.bad or UI.COLOR.text, width - 30)
    end
end

---@param top number y the screen starts at
function lib:draw(top)
    local w, h = love.graphics.getDimensions()
    local boardW = w - PANEL_W
    UI.box(0, top, boardW, h - top, UI.COLOR.board, 0)
    self.layout = self:boardLayout(0, top, boardW, h - top - INFO_H)
    self:updateHover()
    love.graphics.setScissor(0, top, boardW, h - top - INFO_H)
    self:drawBoard()
    love.graphics.setScissor()
    self:drawZoom()
    UI.box(boardW, top, PANEL_W, h - top, UI.COLOR.panel, 0)
    UI.box(boardW, top, 1, h - top, UI.COLOR.border, 0)
    self:drawPanel(boardW + 16, top + 14, PANEL_W - 32, h - 12)
    self:drawInfo(12, h - INFO_H, boardW - 24)
    if self.confirmQuit then self:drawQuitDialog(top) end
    love.graphics.setColor(1, 1, 1)
end

---the zoom buttons (- and +, and Fit when zoomed) in the board's top-right corner, with
---the size and keys beside them
function lib:drawZoom()
    local l = self.layout --[[@as GAMEVIEW.LAYOUT]]
    local labels = self.zoom and { "-", "+", "Fit" } or { "-", "+" }
    self.zoomRects = UI.buttonRow(labels, l.left + l.width - 10, l.top + 8)
    local text = self.zoom and ("%d px   0: fit   drag: move"):format(l.size) or ("Fit (%d px)"):format(l.size)
    local f = UI.font(12)
    local x = self.zoomRects[1].x - 10 - f:getWidth(text)
    UI.box(x - 6, l.top + 13, f:getWidth(text) + 12, 18, { 0, 0, 0, 0.45 }, 4)
    UI.text(text, x, l.top + 15, 12, UI.COLOR.dim)
end

---ask before quitting (the Quit button, or Esc with nothing to drop)
function lib:askQuit()
    self.confirmQuit = true
    self.chatting = nil
end

---the "Quit this game?" question, over a dimmed screen
---@param top number
function lib:drawQuitDialog(top)
    local w, h = love.graphics.getDimensions()
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, top, w, h - top)
    local client = self:isClient()
    local title = client and "Leave this network game?" or "Quit this game?"
    local text
    if client then
        text = "You go back to your own game setup. A computer player keeps your seat going; join again with the same name to have it back."
    elseif self.net then
        text = "The game ends for everyone and you go back to the game setup. The players who joined stay connected."
    else
        text = "The game ends and you go back to the game setup."
    end
    local dw = 460
    local tw = dw - 48
    local dh = 24 + 30 + UI.textHeight(text, 14, tw) + 24 + 38 + 24
    local x, y = math.floor((w - dw) / 2), math.floor(top + (h - top - dh) / 2)
    UI.box(x, y, dw, dh, UI.COLOR.panel, 10)
    UI.outline(x, y, dw, dh, UI.COLOR.border, 1, 10)
    UI.text(title, x + 24, y + 22, 20, UI.COLOR.accent)
    UI.text(text, x + 24, y + 58, 14, UI.COLOR.text, tw)
    local by = y + dh - 24 - 38
    self.dialogRects = {}
    local mx, my = love.mouse.getPosition()
    ---one of the two answers
    ---@param bx number
    ---@param bw number
    ---@param label string
    ---@param key string
    ---@param c table
    ---@param kind "yes"|"no"
    local function answer(bx, bw, label, key, c, kind)
        local over = mx >= bx and mx < bx + bw and my >= by and my < by + 38
        if over then c = { c[1] * 1.2, c[2] * 1.2, c[3] * 1.2 } end
        UI.box(bx, by, bw, 38, c, 6)
        if over then UI.outline(bx, by, bw, 38, { 1, 1, 1, 0.6 }, 1, 6) end
        UI.text(label, bx + 14, by + 10, 15, { 1, 0.97, 0.92 })
        local kw = UI.font(12):getWidth(key) + 12
        UI.box(bx + bw - kw - 10, by + 9, kw, 20, { 0, 0, 0, 0.25 }, 4)
        UI.text(key, bx + bw - kw - 4, by + 12, 12, { 1, 0.97, 0.92, 0.85 })
        self.dialogRects[#self.dialogRects + 1] = { x = bx, y = by, w = bw, h = 38, kind = kind }
    end
    local bw = math.floor((dw - 48 - 12) / 2)
    answer(x + 24, bw, client and "Leave" or "Quit game", "Enter", { 0.62, 0.16, 0.13 }, "yes")
    answer(x + 24 + bw + 12, bw, "Keep playing", "Esc", { 0.30, 0.26, 0.20 }, "no")
end

---------------------------------------------------------------------------- chamber choices

local E = TILES.Effect

---@type {[TILES.EFFECT]:string}
local HELP = {
    [E.Destroy] = "Destroy: click a red room to remove it.",
    [E.DrakonsBargain] = "Drakon's Bargain: click a gold-outlined room to buy it for one coin.",
    [E.MagicShift] = "Magic Shift: pick a tile in your hand (R turns it), then a green room to swap it with.",
    [E.MovingTiles] = "Moving Chambers: click two rooms with the same arrow style to switch them.",
    [E.Rotate] = "Rotate: click a room, turn it with R / right click / wheel, click it again to confirm.",
    [E.Map] = "Map: click another player to take a random tile from their hand.",
    [E.MindOrb] = "Mind Control Orb: click another player, then a blue room to move their hero.",
    [E.Float] = "Floating Room: turn it with R / right click / wheel, then click a green square (or the room itself).",
}

---what to click for the chamber choice waiting
---@return string
function lib:choiceHelp()
    local e = GAME.openChoice(self.state)
    if e == E.MovingTiles and self.pick then
        return "Moving Chambers: now click the room to switch with (Esc: start again)."
    end
    if e == E.MindOrb and self.orbHero then
        return "Mind Control Orb: click a blue room to move " .. self.orbHero.name .. " (Esc: pick again)."
    end
    return e and HELP[e] or ""
end

local RED, GOLD, GREEN = UI.COLOR.bad, UI.COLOR.accent, UI.COLOR.good
local BLUE, TEAL = UI.COLOR.blue, UI.COLOR.teal

---draw a room as it would look turned `turns` quarter turns, over the square (x, y).
---@param view GAMEVIEW
---@param t TILES.TILE
---@param x integer
---@param y integer
---@param turns integer
---@param alpha number
local function drawPreview(view, t, x, y, turns, alpha)
    local preview = TILES.new(TILES.rotateKind(t.kind, turns))
    local sx, sy = view:toScreen(x, y)
    love.graphics.setColor(1, 1, 1, alpha)
    TILEART.draw(preview, sx, sy, view.layout.size)
end

---highlights for the chamber choice waiting
function lib:drawChoice()
    local s = self.state
    local e = GAME.openChoice(s)
    if not e then
        self.pick = nil
        if not self.ability then self.orbHero = nil end
        return
    end
    ---an unoccupied room other than Start
    ---@param x integer
    ---@param y integer
    ---@param t TILES.TILE
    ---@return boolean
    local function free(x, y, t)
        return t:effect() ~= E.Start and not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y)
    end
    if e == E.Destroy then
        for x, y, t in s.board:each() do
            if free(x, y, t) then mark(self, x, y, RED) end
        end
    elseif e == E.DrakonsBargain then
        for x, y in s.board:each() do
            if not (x == 0 and y == 0) and not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y) then
                mark(self, x, y, GOLD)
            end
        end
    elseif e == E.MagicShift then
        for x, y, t in s.board:each() do
            if self.selected then
                if not GAME.magicShiftError(s, self.selected, x, y) then mark(self, x, y, GREEN) end
            elseif free(x, y, t) then
                mark(self, x, y, GREEN, 0.04)
            end
        end
    elseif e == E.MovingTiles then
        for x, y in s.board:each() do
            if self.pick then
                if (x ~= self.pick[1] or y ~= self.pick[2])
                   and not GAME.swapRoomsError(s, self.pick[1], self.pick[2], x, y) then
                    mark(self, x, y, TEAL)
                end
            elseif not GAME.isOccupied(s, x, y) and not GAME.isProtected(s, x, y) then
                mark(self, x, y, TEAL)
            end
        end
        if self.pick then mark(self, self.pick[1], self.pick[2], GOLD, 0.3) end
    elseif e == E.Rotate then
        if self.pick then
            local x, y = self.pick[1], self.pick[2]
            local sx, sy = self:toScreen(x, y)
            UI.box(sx, sy, self.layout.size, self.layout.size, UI.COLOR.board, 0)
            drawPreview(self, s.board:get(x, y) --[[@as TILES.TILE]], x, y, self.turns, 1)   --(only a room can be picked)
            mark(self, x, y, GAME.rotateRoomError(s, x, y, self.turns) and RED or GREEN, 0.05)
        else
            for x, y in s.board:each() do
                if not GAME.isProtected(s, x, y) then mark(self, x, y, TEAL, 0.04) end
            end
        end
    elseif e == E.MindOrb then
        if self.orbHero then
            for x, y in s.board:each() do
                if GAME.canMoveOther(s, self.orbHero, x, y) then mark(self, x, y, BLUE) end
            end
        end
    elseif e == E.Float then
        local p = s.activePlayer --[[@as GAME.PLAYER]]
        local t = s.board:get(p.x --[[@as integer]], p.y --[[@as integer]]) --[[@as TILES.TILE]]   --(canFloat: on the board)
        local spots = emptySquares(s)
        spots[#spots + 1] = { p.x, p.y }
        for _, sq in ipairs(spots) do
            if not GAME.floatError(s, sq[1], sq[2], self.turns) then mark(self, sq[1], sq[2], GREEN) end
        end
        local hx, hy = self:toGrid(love.mouse.getPosition())
        if hx and hy and (not s.board:has(hx, hy) or (hx == p.x and hy == p.y)) then
            drawPreview(self, t, hx, hy, self.turns, GAME.floatError(s, hx, hy, self.turns) and 0.3 or 0.8)
        end
    end
    love.graphics.setColor(1, 1, 1)
end

---player whose row in the panel is under the mouse
---@param mx number
---@param my number
---@return GAME.PLAYER|nil
function lib:playerAt(mx, my)
    if mx < love.graphics.getWidth() - PANEL_W then return end
    for _, r in ipairs(self.playerRects) do
        if my >= r.y1 and my < r.y2 then return r.player end
    end
end

---a chamber choice was made: clear the picks and say what happened
---@param text string
function lib:done(text)
    self.pick, self.orbHero, self.turns = nil, nil, 0
    self.selected = nil
    self:setMessage(text)
end

---a click while a chamber choice is waiting
---@param mx number
---@param my number
function lib:choiceClick(mx, my)
    local s = self.state
    local e = GAME.openChoice(s)
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    local x, y = self:toGrid(mx, my)
    local ok, err

    if e == E.Map or e == E.MindOrb then
        local who = self:playerAt(mx, my)
        if who and e == E.Map then
            local t
            t, err = self:act("mapSteal", who)
            if t then return self:done(("%s took a tile from %s's hand: %s."):format(p.name, who.name, t:effectName())) end
            return self:setMessage(err, true)
        elseif who then
            if who == p then return self:setMessage("You must pick another player to move", true) end
            if not who.x then return self:setMessage("Heroes in the Void can't be moved", true) end
            self.orbHero = who
            return self:setMessage(self:choiceHelp())
        elseif e == E.MindOrb and self.orbHero and x and y then
            local hero = self.orbHero --[[@as GAME.PLAYER]]
            local r
            r, err = self:act("moveOtherPlayer", hero, x, y)
            if not r then return self:setMessage(err, true) end
            r.orb = true
            self.pick, self.orbHero, self.turns = nil, nil, 0
            return self:describeMove(hero, r, x, y)
        end
        return
    end

    if not (x and y) then return end
    local here = s.board:get(x, y)
    local name = here and here:effectName()
    if e == E.Destroy then
        ok, err = self:act("destroyRoom", x, y)
        if ok then return self:done(("%s destroyed the %s [%d,%d]."):format(p.name, name, x, y)) end
    elseif e == E.DrakonsBargain then
        ok, err = self:act("bargainRoom", x, y)
        if ok then return self:done(("%s paid Drakon a coin and took the %s [%d,%d]."):format(p.name, name, x, y)) end
    elseif e == E.MagicShift then
        if not self.selected then return self:setMessage("Pick a tile in your hand first", true) end
        ok, err = self:act("magicShift", self.selected, x, y)
        if ok then return self:done(("%s swapped the %s [%d,%d] for a tile from their hand."):format(p.name, name, x, y)) end
    elseif e == E.MovingTiles then
        if not self.pick then
            if not here then return end
            self.pick = { x, y }
            return self:setMessage(self:choiceHelp())
        end
        local px, py = self.pick[1], self.pick[2]
        ok, err = self:act("swapRooms", px, py, x, y)
        if ok then return self:done(("%s switched the rooms at [%d,%d] and [%d,%d]."):format(p.name, px, py, x, y)) end
    elseif e == E.Rotate then
        if not self.pick or self.pick[1] ~= x or self.pick[2] ~= y then
            if not here then return end
            self.pick, self.turns = { x, y }, 0
            return self:setMessage("Turn it with R / right click / wheel, then click it again to confirm.")
        end
        ok, err = self:act("rotateRoom", x, y, self.turns)
        if ok then return self:done(("%s rotated the %s [%d,%d]."):format(p.name, name, x, y)) end
    elseif e == E.Float then
        ok, err = self:act("floatRoom", x, y, self.turns)
        if ok then return self:done(("%s moved the Floating Room to [%d,%d]."):format(p.name, x, y)) end
    end
    if err then self:setMessage(err, true) end
end

---------------------------------------------------------------------------- Drakon

---a click while Drakon is to be placed or moved
---@param mx number
---@param my number
function lib:drakonClick(mx, my)
    local s = self.state
    local x, y = self:toGrid(mx, my)
    if not (x and y) then return end
    local first = not s.drakonActive
    local r, err = self:act("moveDrakon", x, y)
    if not r then return self:setMessage(err, true) end
    local where = ("the %s [%d,%d]"):format(s.board:get(x, y):effectName(), x, y)
    local text = (first and "%s put Drakon in %s." or "%s moved Drakon to %s."):format(s.activePlayer.name, where)
    if #r.attacked > 0 then
        local names = {}
        for _, p in ipairs(r.attacked) do names[#names + 1] = p.name end
        text = text .. " Drakon attacked " .. table.concat(names, " and ") .. ": back to the Start chamber"
        text = text .. (r.pickedUp and ", picking up a coin there." or ".")
    end
    self:setMessage(text)
end

---------------------------------------------------------------------------- hero abilities

---a click while picking a Thief or Barbarian target
---@param mx number
---@param my number
function lib:abilityClick(mx, my)
    local s = self.state
    local who = self:playerAt(mx, my)
    if self.ability == "thief" then
        if not who then return end
        local ok, err = self:act("thiefSteal", who)
        if not ok then return self:setMessage(err, true) end
        self.ability = nil
        return self:setMessage(("%s stole a coin from %s (Thief ability)."):format(s.activePlayer.name, who.name))
    elseif self.ability == "barbarian" then
        if who then
            self.orbHero = who
            return self:setMessage("Barbarian: click a blue room to push " .. who.name .. " into.")
        end
        local x, y = self:toGrid(mx, my)
        if not (x and y and self.orbHero) then return end
        local victim = self.orbHero --[[@as GAME.PLAYER]]
        local me = s.activePlayer --[[@as GAME.PLAYER]]
        local r, err = self:act("barbarianPush", victim, x, y)
        if not r then return self:setMessage(err, true) end
        self.ability, self.orbHero = nil, nil
        r.orb = true
        self:describeMove(victim, r, x, y)
        local said = self.message and self.message.text or ""
        local text = ("%s pushed %s (Barbarian ability). "):format(me.name, victim.name) .. said
        if r.tookTile then text = text .. (" Took the %s from their hand."):format(r.tookTile:effectName()) end
        self:setMessage(text)
    end
end

---------------------------------------------------------------------------- computer players

local AI_PAUSE = 0.8   --seconds before each computer action, so it can be followed

---computer players take their turns, after a pause
---@param dt number seconds since the last frame
function lib:update(dt)
    local s = self.state
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    if not p or not AI.levelOf(p) or self:isClient() then self.aiTimer = 0; return end
    if self.confirmQuit and not self.net then return end   --(on one computer, the game waits for the answer)
    self.aiTimer = self.aiTimer + dt
    if self.aiTimer < AI_PAUSE then return end
    self.aiTimer = 0
    self.selected, self.pick, self.orbHero, self.ability, self.turns = nil, nil, nil, nil, 0
    local lines = AI.act(s)
    for _, line in ipairs(lines) do self.log[#self.log + 1] = line end
    while #self.log > 8 do table.remove(self.log, 1) end
    if self.net then (self.net --[[@as SESSION.HOST]]):changed(lines) end   --(clients run no computer players)
    if GAME.isOver(s) then
        self:setMessage(self:gameOverText())
    elseif self:controls(s.activePlayer) then
        self:setMessage(s.activePlayer.name .. ", your turn.")
    elseif not AI.levelOf(s.activePlayer) then
        self:setMessage("Waiting for " .. s.activePlayer.name .. ".")
    end
end

---------------------------------------------------------------------------- input

---@param mx number
---@param my number
---@param x number
---@param y number
---@param size number
---@return boolean
local function inRect(mx, my, x, y, size)
    return mx >= x and mx < x + size and my >= y and my < y + size
end

---hand tile under the mouse
---@param mx number
---@param my number
---@return TILES.TILE|nil
function lib:handTileAt(mx, my)
    for _, r in ipairs(self.handRects) do
        if inRect(mx, my, r.x, r.y, HAND_TILE) then return r.tile end
    end
end

---the tile under the mouse, for its rules text; the selected and hovered tiles animate
function lib:updateHover()
    local mx, my = love.mouse.getPosition()
    self.hover = self:handTileAt(mx, my)
    if not self.hover then
        local x, y = self:toGrid(mx, my)
        if x and y then self.hover = self.state.board:get(x, y) end
    end
    local now = love.timer.getTime()
    local was = self.animStart
    self.animStart = {}
    --(not ipairs over { selected, hover }: it would stop at a nil selected tile)
    if self.selected then self.animStart[self.selected] = was[self.selected] or now end
    if self.hover then self.animStart[self.hover] = was[self.hover] or now end
end

---seconds a tile has been animating, or nil if it is still
---@param t TILES.TILE
---@return number|nil
function lib:animTime(t)
    local start = self.animStart[t]
    return start and love.timer.getTime() - start
end

---turn the selected hand tile, or the Rotate / Floating Room preview
---@param turns integer
function lib:rotateSelected(turns)
    local e = GAME.openChoice(self.state)
    if (e == TILES.Effect.Rotate and self.pick) or e == TILES.Effect.Float then
        self.turns = (self.turns + turns) % 4
        self.message = nil
    elseif self.selected then
        self.selected:rotate(turns)
        self.message = nil
    end
end

---@param mx number
---@param my number
---@param button integer
function lib:mousepressed(mx, my, button)
    if self.confirmQuit then
        for _, r in ipairs(self.dialogRects) do
            if button == 1 and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
                self.confirmQuit = false
                if r.kind == "yes" then self.request = "quit" end
            end
        end
        return
    end
    local q = self.quitRect
    if button == 1 and q and mx >= q.x and mx < q.x + q.w and my >= q.y and my < q.y + q.h then
        return self:askQuit()
    end
    local zoom = button == 1 and UI.hit(self.zoomRects, mx, my)
    if zoom then
        if zoom == "Fit" then self:zoomFit() else self:zoomBy(zoom == "+" and 1 or -1) end
        return
    end
    --(a press on the board may turn into dragging it; the middle button only drags)
    if (button == 1 or button == 3) and self:onBoard(mx, my) then
        self.drag = { x = mx, y = my, button = button, moved = button == 3 }
    end
    if button == 3 then return end
    self:handleMouse(mx, my, button)
    self:flush()
end

---dragging the board moves it (when it is bigger than its area)
---@param mx number
---@param my number
---@param dx number
---@param dy number
function lib:mousemoved(mx, my, dx, dy)
    local d = self.drag
    if not d then return end
    if not love.mouse.isDown(d.button) then self.drag = nil; return end
    if not d.moved then
        if math.abs(mx - d.x) + math.abs(my - d.y) < DRAG_START then return end
        d.moved, dx, dy = true, mx - d.x, my - d.y
    end
    self.panX, self.panY = self.panX + dx, self.panY + dy
end

---@param button integer
function lib:mousereleased(button)
    if self.drag and self.drag.button == button then self.drag = nil end
end

---@param mx number
---@param my number
---@param button integer
function lib:handleMouse(mx, my, button)
    if not self:controls(self.state.activePlayer) then return end   --a computer's or someone else's turn
    if button == 2 then return self:rotateSelected(1) end
    if button ~= 1 then return end
    for _, b in ipairs(self.buttonRects) do
        if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then
            if not b.enabled then return end
            if b.kind == "confirm" then return self:endTurn() end
            return self:undo()
        end
    end
    local t = self:handTileAt(mx, my)
    if t then
        self.selected = (self.selected ~= t) and t or nil
        self.message = nil
        return
    end
    if self.ability then return self:abilityClick(mx, my) end
    if GAME.mustPlaceDrakon(self.state) then return self:drakonClick(mx, my) end
    if GAME.openChoice(self.state) then return self:choiceClick(mx, my) end
    do
        local s = self.state
        local x, y = self:toGrid(mx, my)
        if x and y and GAME.canMoveToEscape(s) and x == s.escapeX and y == s.escapeY and not self.selected then
            local ok, err = self:act("moveToEscape")
            return self:setMessage(ok and (s.activePlayer.name .. " moved onto the Escape tile.") or err, not ok)
        end
    end
    local x, y = self:toGrid(mx, my)
    if x and y and self.selected then
        local ok, err = self:act("placeTile", self.selected, x, y)
        if ok then
            self:setMessage(("Placed %s at (%d, %d)."):format(self.selected:effectName(), x, y))
            self.selected = nil
        else
            self:setMessage(err, true)
        end
    elseif x and y and self.state.board:has(x, y) then
        self:move(x, y)
    end
end

---move the active player's hero, and say what happened (wording after the original log).
---@param x integer
---@param y integer
function lib:move(x, y)
    local s = self.state
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    local r, err = self:act("movePlayer", x, y)
    if not r then return self:setMessage(err, true) end
    self:describeMove(p, r, x, y)
end

---say what a move did
---@param p GAME.PLAYER
---@param r GAME.MOVERESULT
---@param x integer
---@param y integer
function lib:describeMove(p, r, x, y)
    local s = self.state
    local how = r.wizard and " (using the Wizard ability)" or r.second and " (using the Amazon ability)"
             or r.orb and " (via the Mind Control Orb)" or ""
    local text
    if r.attacked then
        text = ("%s moved%s into Drakon's room and was attacked: back to the Start chamber."):format(p.name, how)
    elseif r.void then
        text = ("%s moved%s into the Void and loses their next turn."):format(p.name, how)
    else
        text = ("%s moved%s to the %s [%d,%d]."):format(p.name, how, s.board:get(x, y):effectName(), x, y)
    end
    if r.stole then text = text .. " Stole a coin from " .. r.stole.name .. "."
    elseif r.locked then text = text .. (" %d coins locked away."):format(r.locked)
    elseif r.gold > 0 then text = text .. (" +%d gold."):format(r.gold)
    elseif r.gold < 0 then text = text .. (" Lost %d gold."):format(-r.gold)
    end
    if s.pendingActivePlayer == p then
        text = text .. " " .. p.name .. " will have a choice to make (" .. TILES.EffectName[s.tileEffect] .. ")."
    elseif not r.orb and GAME.openChoice(s) then
        text = text .. " " .. self:choiceHelp()
    end
    self:setMessage(text)
end

---the wheel turns the selected tile or preview (on this computer's turn), and otherwise
---zooms at the mouse; Ctrl+wheel always zooms
---@param dy number
---@return boolean|nil used
function lib:wheelmoved(dy)
    local e = GAME.openChoice(self.state)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if not ctrl and self:controls(self.state.activePlayer)
       and (self.selected or (e == TILES.Effect.Rotate and self.pick) or e == TILES.Effect.Float) then
        self:rotateSelected(dy > 0 and 3 or 1)
        return true
    end
    if dy ~= 0 then self:zoomBy(dy > 0 and 1 or -1, love.mouse.getPosition()) end
    return true
end

---end the active player's action (Enter), as the original's Finish button does.
function lib:endTurn()
    local s = self.state
    if GAME.canKnightReclaim(s) then self:act("knightDecline") end
    self.ability = nil
    local finishing = s.activePlayer
    local r, err = self:act("endTurn")
    if not r then return self:setMessage(err, true) end
    self.selected, self.pick, self.orbHero, self.turns = nil, nil, nil, 0
    local parts = {}
    if r.winners then
        local names = {}
        for _, t in ipairs(r.winners) do names[#names + 1] = t.name end
        return self:setMessage(("Game over: %s won with %d gold!"):format(table.concat(names, " and "), r.winners[1].gold))
    end
    if r.stuck then return self:setMessage("Game over: nobody can do anything more.") end
    for _, p in ipairs(r.skipped) do parts[#parts + 1] = p.name .. " loses a turn in the Void." end
    if s.activePlayer ~= s.turnPlayer then
        parts[#parts + 1] = s.activePlayer.name .. " has a choice to make."
    elseif s.activePlayer == finishing then
        parts[#parts + 1] = s.activePlayer.name .. " carries on."
    else
        parts[#parts + 1] = s.activePlayer.name .. "'s turn."
    end
    self:setMessage(table.concat(parts, " "))
end

---take back the last action (U, or the Cancel button)
function lib:undo()
    local ok, err = self:act("undo")
    self.selected, self.pick, self.orbHero, self.ability, self.turns = nil, nil, nil, nil, 0
    self:setMessage(ok and "Took back the last action." or err, not ok)
end

---Esc: drop a half-made pick (chamber choice or selected hand tile). True if there was one.
---@return boolean
function lib:cancel()
    if self.confirmQuit then self.confirmQuit = false; return true end
    if self.chatting then self.chatting = nil; return true end
    if self.pick or self.orbHero or self.selected or self.turns ~= 0 or self.ability then
        self.pick, self.orbHero, self.selected, self.turns, self.ability = nil, nil, nil, 0, nil
        self.message = nil
        return true
    end
    return false
end

---@param key love.KeyConstant
function lib:keypressed(key)
    if self.confirmQuit then
        if key == "return" or key == "kpenter" then self.confirmQuit, self.request = false, "quit"
        elseif key == "escape" then self.confirmQuit = false end
        return
    end
    if self.chatting then return self:chatKey(key) end
    if key == "tab" then return self:startChat() end
    --zooming works whoever's turn it is
    if key == "=" or key == "+" or key == "kp+" then self:zoomBy(1, love.mouse.getPosition()); return end
    if key == "-" or key == "kp-" then self:zoomBy(-1, love.mouse.getPosition()); return end
    if key == "0" or key == "kp0" then self:zoomFit(); return end
    self:handleKey(key)
    self:flush()
end

---@param key love.KeyConstant
function lib:handleKey(key)
    local s = self.state
    if not self:controls(s.activePlayer) then return end       --a computer's or someone else's turn
    if key == "r" then self:rotateSelected(1)
    elseif key == "return" or key == "kpenter" then self:endTurn()
    elseif key == "t" and GAME.canThiefSteal(s) then
        self.ability, self.orbHero = "thief", nil
        self:setMessage("Thief: click a player in your room to steal a coin from (Esc: cancel).")
    elseif key == "b" and GAME.canBarbarianPush(s) then
        self.ability, self.orbHero = "barbarian", nil
        self:setMessage("Barbarian: click a player in your room, then a blue room to push them into (Esc: cancel).")
    elseif key == "k" and GAME.canKnightReclaim(s) then
        local who = s.activePlayer.name
        local ok, err = self:act("knightReclaim")
        self:setMessage(ok and (who .. " took the coin back (Knight ability).") or err, not ok)
    elseif key == "u" then
        self:undo()
    elseif key == "g" and GAME.canDrawTileAction(s) then
        local drawn, err = self:act("drawTileAction")
        self:setMessage(drawn and (s.activePlayer.name .. " drew a tile (empty hand).") or err, not drawn)
    elseif key == "d" and GAME.canDwarfDraw(s) then
        local drawn, err = self:act("dwarfDraw")
        self:setMessage(drawn and (("%s drew %d tiles (Dwarf ability); hand limit now %d.")
            :format(s.activePlayer.name, #drawn, s.activePlayer.hand.tileLimit)) or err, not drawn)
    end
end

return lib
