--the setup screen: players, teams, hands and rule options for a new game, after the
--original Configure dialog. The editing itself is in setup.lua.
--
--< and > in a cell (or left / right click, or the mouse wheel) step through its values;
--Shift steps numbers by 10. Click a name (player, team or hand) or a number to type it,
--then Enter (Esc cancels). Enter starts the game.
--
--network games: "Host network game" lets others join (their seats play "Network");
--"Join network game" goes to the join screen. While hosting or joined, Tab chats. A joined
--player sees the host's setup and can change only their own name, colour and hero.

local GAME = require('src.game')
local SETUP = require('src.setup')
local TILEART = require('src.tileart')
local UI = require('src.ui')
local WSLINK = require('src.wslink')

---a clickable area drawn this frame
---@class SETUPVIEW.HIT
---@field x number
---@field y number
---@field w number
---@field h number
---@field kind string what it is: "name", "team", "option", "start"...
---@field i? integer player (or option) index
---@field part? "prev"|"next"|"type" which part of a cell

---text being typed into a cell
---@class SETUPVIEW.EDIT
---@field kind string
---@field i? integer
---@field text string

---the setup screen
---@class SETUPVIEW
---@field cfg GAME.CONFIG the setup being edited (a copy)
---@field canReturn boolean a game is running that Esc goes back to
---@field hits SETUPVIEW.HIT[]
---@field edit SETUPVIEW.EDIT|nil
---@field message {text:string, error?:boolean}|nil
---@field started GAME.CONFIG|nil set when the game should start with this setup
---@field back boolean set when Esc should go back to the game
---@field net SESSION.HOST|SESSION.CLIENTSESSION|nil hosting, or joined to a host
---@field request "host"|"join"|"stopHosting"|"leave"|nil network step main.lua should take
---@field address string|nil this computer's address, while hosting
local lib = {}

local SAVE_FILE = "setup.dsc"
local ROW_H = 28
---@type {[1]:string, [2]:string, [3]:integer}[] key, heading, width
local COLUMNS = {   --key, heading, width
    { "token", "", 34 }, { "name", "Name", 150 }, { "initial", "Init", 44 }, { "color", "Color", 128 },
    { "hero", "Hero", 116 }, { "control", "Plays", 116 }, { "team", "Team", 150 }, { "gold", "Gold", 64 },
    { "hand", "Hand", 150 }, { "tiles", "Tiles", 64 }, { "rowButtons", "", 96 },
}

---`cfg` is copied, so the game it came from is left alone (except for a joined player:
---the host's setup is shown as it is). `canReturn`: a game is running that Esc goes back to.
---@param cfg GAME.CONFIG
---@param canReturn boolean
---@param net? SESSION.HOST|SESSION.CLIENTSESSION
---@return SETUPVIEW
function lib:new(cfg, canReturn, net)
    local o = {
        cfg = (net and net.role == "client") and cfg or SETUP.copy(cfg),
        canReturn = canReturn,
        hits = {},
        edit = nil,
        message = nil,
        started = nil,
        back = false,
        net = net,
        request = nil,
        address = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param text string
---@param isError? boolean
function lib:setMessage(text, isError) self.message = { text = text, error = isError } end

---@return boolean
function lib:isClient() return self.net ~= nil and self.net.role == "client" end

---whether this computer may change a player's row: all of them, except for a joined player,
---who may change only their own (and only some of it, through the host)
---@param pc GAME.PLAYERCONFIG
---@return boolean
function lib:mayEdit(pc)
    if not self:isClient() then return true end
    return pc.peer ~= nil and pc.peer == self.net.id
end

---------------------------------------------------------------------------- drawing

---remember a clickable area for this frame
---@param self SETUPVIEW
---@param x number
---@param y number
---@param w number
---@param h number
---@param kind string
---@param i? integer
---@param part? "prev"|"next"|"type"
local function hit(self, x, y, w, h, kind, i, part)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, kind = kind, i = i, part = part }
end

---a cell or check box background
---@param x number
---@param y number
---@param w number
---@param h number
---@param hot? boolean
local function box(x, y, w, h, hot)
    love.graphics.setColor(hot and { 0.32, 0.28, 0.22 } or { 0.24, 0.21, 0.18 })
    love.graphics.rectangle("fill", x, y, w, h, 3)
end

---whether this cell is being typed in
---@param self SETUPVIEW
---@param kind string
---@param i? integer
---@return boolean
local function editing(self, kind, i)
    local e = self.edit
    return e ~= nil and e.kind == kind and e.i == i
end

---a cell showing `text`, with < > to step its value (`stepper`) and, for `typeable` cells,
---a middle part that starts typing.
---@param self SETUPVIEW
---@param x number
---@param y number
---@param w number
---@param kind string
---@param i integer
---@param text string
---@param stepper? boolean
---@param typeable? boolean
local function cell(self, x, y, w, kind, i, text, stepper, typeable)
    local h = ROW_H - 4
    box(x, y, w - 4, h, editing(self, kind, i))
    if editing(self, kind, i) then
        local caret = (love.timer.getTime() % 1 < 0.5) and "|" or ""
        love.graphics.setColor(1, 0.95, 0.6)
        love.graphics.print(self.edit.text .. caret, x + 6, y + 5)
        hit(self, x, y, w - 4, h, kind, i, "type")
        return
    end
    love.graphics.setColor(0.92, 0.89, 0.82)
    if stepper then
        love.graphics.setColor(0.7, 0.66, 0.58)
        love.graphics.print("<", x + 5, y + 5)
        love.graphics.print(">", x + w - 16, y + 5)
        love.graphics.setColor(0.92, 0.89, 0.82)
        love.graphics.printf(text, x + 16, y + 5, w - 36, "center")
        hit(self, x, y, 16, h, kind, i, "prev")
        hit(self, x + w - 20, y, 16, h, kind, i, "next")
        hit(self, x + 16, y, w - 36, h, kind, i, typeable and "type" or "next")
    else
        love.graphics.printf(text, x + 6, y + 5, w - 16, "left")
        hit(self, x, y, w - 4, h, kind, i, typeable and "type" or "next")
    end
end

---a button; disabled ones can't be clicked
---@param self SETUPVIEW
---@param x number
---@param y number
---@param label string
---@param kind string
---@param enabled? boolean
---@return number x where the next button goes
local function drawButton(self, x, y, label, kind, enabled)
    local w = love.graphics.getFont():getWidth(label) + 24
    if enabled == false then
        love.graphics.setColor(0.2, 0.18, 0.16)
        love.graphics.rectangle("fill", x, y, w, 28, 4)
        love.graphics.setColor(0.5, 0.47, 0.42)
    else
        love.graphics.setColor(0.36, 0.3, 0.2)
        love.graphics.rectangle("fill", x, y, w, 28, 4)
        love.graphics.setColor(1, 0.9, 0.6)
        hit(self, x, y, w, 28, kind)
    end
    love.graphics.print(label, x + 12, y + 7)
    return x + w + 10
end

---whether several players share this team (hand): shown with a marker.
---@param cfg GAME.CONFIG
---@param field "team"|"hand"
---@param t table
---@return string
local function shareMark(cfg, field, t)
    local n = SETUP.sharing(cfg, field, t)
    return n > 1 and (" (" .. n .. ")") or ""
end

---the player table
---@param left number
---@param top number
---@return number y below the table
function lib:drawPlayers(left, top)
    local cfg = self.cfg
    local x = left
    love.graphics.setColor(0.75, 0.7, 0.6)
    for _, c in ipairs(COLUMNS) do
        love.graphics.print(c[2], x + 6, top)
        x = x + c[3]
    end
    local y = top + 22
    for i, pc in ipairs(cfg.players) do
        x = left
        for _, c in ipairs(COLUMNS) do
            local k, w = c[1], c[3]
            if k == "token" then
                love.graphics.setColor(1, 1, 1)
                love.graphics.draw(TILEART.tokenImage(GAME.COLORS[pc.colorIndex], 128), x + 2, y + 1)
            elseif k == "name" then cell(self, x, y, w, "name", i, pc.name, false, true)
            elseif k == "initial" then cell(self, x, y, w, "initial", i, pc.initial or "", false, true)
            elseif k == "color" then cell(self, x, y, w, "color", i, (GAME.COLORS[pc.colorIndex]:gsub("_", " ")), true)
            elseif k == "hero" then cell(self, x, y, w, "hero", i, GAME.HeroName[pc.hero], true)
            elseif k == "control" then
                local text = SETUP.controlName(pc.ai, pc.remote, pc.peer ~= nil)
                if self:isClient() and pc.peer == self.net.id then text = "You" end
                cell(self, x, y, w, "control", i, text, true)
            elseif k == "team" then cell(self, x, y, w, "team", i, pc.team.name .. shareMark(cfg, "team", pc.team), true, true)
            elseif k == "gold" then cell(self, x, y, w, "gold", i, tostring(pc.team.goldToWin), true, true)
            elseif k == "hand" then cell(self, x, y, w, "hand", i, pc.hand.name .. shareMark(cfg, "hand", pc.hand), true, true)
            elseif k == "tiles" then cell(self, x, y, w, "tiles", i, tostring(pc.hand.tileCount), true, true)
            elseif k == "rowButtons" and self:isClient() then
                --(a joined player can't reorder or remove anyone)
            elseif k == "rowButtons" then
                local bx, bh = x, ROW_H - 4
                local cx, cy = bx + 13, y + math.floor(bh / 2)
                --move up / move down: arrow icons, dimmed where the player can't move further
                for _, b in ipairs({ { "up", -1, i > 1 }, { "down", 1, i < #cfg.players } }) do
                    box(bx, y, 26, bh)
                    love.graphics.setColor(0.92, 0.89, 0.82, b[3] and 1 or 0.3)
                    local d = b[2]   --points up for -1, down for 1
                    love.graphics.polygon("fill", cx - 6, cy - 3 * d, cx + 6, cy - 3 * d, cx, cy + 4 * d)
                    hit(self, bx, y, 26, bh, b[1], i)
                    bx, cx = bx + 30, cx + 30
                end
                --remove: red, with a white cross
                UI.box(bx, y, 26, bh, { 0.62, 0.16, 0.13 }, 3)
                love.graphics.setColor(1, 0.95, 0.92)
                love.graphics.setLineStyle("rough")
                love.graphics.setLineWidth(2)
                love.graphics.line(cx - 5, cy - 5, cx + 5, cy + 5)
                love.graphics.line(cx - 5, cy + 5, cx + 5, cy - 5)
                love.graphics.setLineWidth(1)
                hit(self, bx, y, 26, bh, "remove", i)
            end
            x = x + w
        end
        y = y + ROW_H
    end
    return y
end

---the rule check boxes and numbers
---@param left number
---@param top number
---@param width number
---@return number y below them
function lib:drawOptions(left, top, width)
    local cfg = self.cfg
    love.graphics.setColor(1, 0.9, 0.6)
    love.graphics.print("Rules", left, top)
    local colW = math.floor(width / 2)
    local y0 = top + 24
    for n, o in ipairs(SETUP.OPTIONS) do
        local col, row = (n - 1) % 2, math.floor((n - 1) / 2)
        local x, y = left + col * colW, y0 + row * 26
        local on = cfg.options[o.key]
        box(x, y + 2, 18, 18)
        if on then
            love.graphics.setColor(o.fixed and { 0.6, 0.57, 0.5 } or { 1, 0.85, 0.35 })
            love.graphics.rectangle("fill", x + 4, y + 6, 10, 10, 2)
        end
        love.graphics.setColor(o.fixed and { 0.6, 0.57, 0.5 } or { 0.92, 0.89, 0.82 })
        love.graphics.print(o.label, x + 26, y + 4)
        if o.note then
            love.graphics.setColor(0.6, 0.57, 0.5)
            love.graphics.print("(" .. o.note .. ")", x + 30 + love.graphics.getFont():getWidth(o.label), y + 4)
        end
        if not o.fixed then hit(self, x, y, colW - 10, 24, "option", n) end
    end
    local y = y0 + math.ceil(#SETUP.OPTIONS / 2) * 26 + 8
    for n, o in ipairs(SETUP.NUMBERS) do
        love.graphics.setColor(0.92, 0.89, 0.82)
        love.graphics.print(o.label, left, y + 5)
        cell(self, left + 170, y, 110, "number", n, tostring(cfg.options[o.key]), true, true)
        if o.note then
            love.graphics.setColor(0.6, 0.57, 0.5)
            love.graphics.print("(" .. o.note .. ")", left + 290, y + 5)
        end
        y = y + ROW_H
    end
    return y
end

---@param top number y the screen starts at
function lib:draw(top)
    self.hits = {}
    local w, h = love.graphics.getDimensions()
    local left = 20
    local title = "New game: players and rules"
    if self:isClient() then title = "Network game: waiting for the host to start"
    elseif self.net then title = "Network game: players and rules" end
    UI.text(title, left, top + 10, 20, UI.COLOR.accent)
    love.graphics.setFont(UI.font(12))
    local y = self:drawPlayers(left, top + 44)

    if self:isClient() then
        drawButton(self, left, y + 6, "Leave (Esc)", "leave")
    else
        local room = #self.cfg.players <= #GAME.COLORS
        local bx = drawButton(self, left, y + 6, "Add person", "addPerson", room)
        bx = drawButton(self, bx, y + 6, "Add computer player", "addComputer", room)
        if self.net then bx = drawButton(self, bx, y + 6, "Add network seat", "addNetwork", room) end
        bx = drawButton(self, bx, y + 6, "Two Teams", "twoTeams")
        bx = drawButton(self, bx + 20, y + 6, "Save (Ctrl+S)", "save")
        bx = drawButton(self, bx, y + 6, "Load (Ctrl+L)", "load", love.filesystem.getInfo(SAVE_FILE) ~= nil)
        bx = drawButton(self, bx + 20, y + 6, "Start game (Enter)", "start")
        if self.canReturn then drawButton(self, bx, y + 6, "Back to game (Esc)", "back") end
    end

    --network: hosting / joining, or (while connected) who is here and the chat, beside the rules
    local optionsW = math.min(w - 40, 1000)
    if self.net then
        optionsW = math.min(optionsW, w - 40 - 320)
        self:drawNetwork(left + optionsW + 20, y + 54, w - left - optionsW - 40, h - 56 - (y + 54))
    end
    local below = self:drawOptions(left, y + 54, optionsW)
    if not self.net then
        local ny = math.max(below + 30, h - 90)
        UI.text("Network", left, ny - 20, 13, UI.COLOR.accent)
        love.graphics.setFont(UI.font(12))
        local nx = left
        --(a browser can't take connections: the web version can only join)
        if not WSLINK.isWeb() then nx = drawButton(self, nx, ny, "Host a game...", "host") end
        drawButton(self, nx, ny, "Join a game...", "join")
    end

    local text, color
    if self:isClient() and not self.message then
        text = "Waiting for the host to start the game. You can change your own name, colour and hero. Tab: chat."
        color = { 0.75, 0.7, 0.6 }
    elseif self.edit and self.edit.kind == "twoTeams" then
        text = "Two Teams: gold each team needs to win: " .. self.edit.text .. "_   (Enter to make the teams, Esc to cancel)"
        color = { 1, 0.95, 0.6 }
    elseif self.message then
        text, color = self.message.text, self.message.error and { 1, 0.5, 0.45 } or { 0.6, 1, 0.6 }
    else
        text = "Click < > (or left / right click, or the wheel) to change a value, Shift for steps of 10. "
            .. "Click a name or number to type it. Players sharing a team pool their gold; players sharing "
            .. "a hand draw from one hand. Play goes down the list."
        color = { 0.75, 0.7, 0.6 }
    end
    love.graphics.setColor(0.1, 0.09, 0.08, 0.95)
    love.graphics.rectangle("fill", 0, h - 46, w, 46)
    love.graphics.setColor(color)
    love.graphics.printf(text, 10, h - 40, w - 20)
    love.graphics.setColor(1, 1, 1)
end

---the network panel: where others can join, who is here, and the chat
---@param left number
---@param top number
---@param width number
---@param height number
function lib:drawNetwork(left, top, width, height)
    if height < 80 then return end
    local net = self.net --[[@as SESSION.HOST|SESSION.CLIENTSESSION]]   --(only drawn while connected)
    UI.box(left, top, width, height, UI.COLOR.card, 8)
    local x, y = left + 12, top + 10
    local status
    if self:isClient() then
        UI.text("Network game (joined)", x, y, 14, UI.COLOR.accent)
        status = "Playing as " .. net.name .. "."
    else
        UI.text("Hosting a game", x, y, 14, UI.COLOR.accent)
        local port = net.port or WSLINK.PORT
        local address = self.address or "this computer's address"
        status = ("Others choose Join a game... and type %s and your password (port %d; over the internet, "
            .. "forward TCP port %d to this computer, or give them your secure address if a proxy with a "
            .. "certificate sits in front)."):format(address, port, port)
    end
    y = y + 22
    UI.text(status, x, y, 12, UI.COLOR.text, width - 24)
    y = y + UI.textHeight(status, 12, width - 24) + 4
    local names = (net.role == "host") and (net --[[@as SESSION.HOST]]):names() or (net --[[@as SESSION.CLIENTSESSION]]).names
    local here = #names > 0 and ("Connected: " .. table.concat(names, ", ")) or "Nobody has joined yet."
    UI.text(here, x, y, 12, UI.COLOR.dim, width - 24)
    y = y + UI.textHeight(here, 12, width - 24) + 8
    if not self:isClient() then
        drawButton(self, x, y, "Stop hosting", "stopHosting")
        y = y + 36
    end
    --the chat, newest last
    UI.box(left, y, width, 1, UI.COLOR.border, 0)
    y = y + 8
    UI.text("Chat", x, y, 12, UI.COLOR.faint)
    local lineH = UI.font(12):getHeight() + 3
    local bottom = top + height - 30
    local room = math.max(0, math.floor((bottom - y - 20) / lineH))
    local ly = y + 18
    for i = math.max(1, #net.chat - room + 1), #net.chat do
        UI.text(net.chat[i], x, ly, 12, UI.COLOR.dim, width - 24)
        ly = ly + lineH
    end
    if self.edit and self.edit.kind == "chat" then
        UI.box(left + 8, bottom - 2, width - 16, 22, UI.COLOR.panel, 4)
        UI.text("> " .. self.edit.text .. "_", x, bottom + 2, 12, UI.COLOR.accent, width - 24)
    else
        UI.text("Tab: say something", x, bottom + 2, 12, UI.COLOR.faint)
        hit(self, left, bottom - 4, width, 26, "chat")
    end
    love.graphics.setFont(UI.font(12))
end

---------------------------------------------------------------------------- editing

---@return boolean
local function shiftDown()
    return love.keyboard.isDown("lshift", "rshift")
end

---Start typing into a cell.
---@param kind string
---@param i? integer
function lib:startEdit(kind, i)
    local cfg, pc = self.cfg, self.cfg.players[i]
    local text
    if kind == "name" then text = pc.name
    elseif kind == "initial" then text = pc.initial or ""
    elseif kind == "team" then text = pc.team.name
    elseif kind == "hand" then text = pc.hand.name
    elseif kind == "gold" then text = tostring(pc.team.goldToWin)
    elseif kind == "tiles" then text = tostring(pc.hand.tileCount)
    elseif kind == "number" then text = tostring(cfg.options[SETUP.NUMBERS[i].key])
    elseif kind == "twoTeams" then text = tostring(GAME.DEFAULT_GOLD_TO_WIN)
    end
    self.edit = { kind = kind, i = i, text = text }
end

local NUMERIC = { gold = true, tiles = true, number = true, twoTeams = true }

---apply what was typed (if anything is being typed)
function lib:commitEdit()
    local e = self.edit
    if not e then return end
    self.edit = nil
    if e.kind == "chat" then
        if self.net and e.text ~= "" then self.net:say(e.text) end
        return
    end
    if self:isClient() then
        if e.kind == "name" and self.net then (self.net --[[@as SESSION.CLIENTSESSION]]):askSeat("name", nil, e.text) end
        return
    end
    local cfg, pc = self.cfg, self.cfg.players[e.i]
    ---@type true|nil, string|nil
    local ok, err = true, nil
    if NUMERIC[e.kind] then
        local v = tonumber(e.text)
        if not v then return self:setMessage("That is not a number", true) end
        v = math.floor(v)
        if e.kind == "gold" then SETUP.setGold(pc.team, v)
        elseif e.kind == "tiles" then SETUP.setTiles(pc.hand, v)
        elseif e.kind == "number" then SETUP.setNumber(cfg, SETUP.NUMBERS[e.i].key, v)
        elseif e.kind == "twoTeams" then
            ok, err = SETUP.twoTeams(cfg, v)
            if ok then self:setMessage(("Two teams, each needing %d gold to win."):format(math.max(1, math.min(SETUP.MAX_GOLD, v)))) end
        end
    elseif e.kind == "name" then ok, err = SETUP.rename(pc, e.text, cfg)
    elseif e.kind == "initial" then ok, err = SETUP.setInitial(pc, e.text)
    elseif e.kind == "team" then ok, err = SETUP.renameTeam(cfg, pc.team, e.text)
    elseif e.kind == "hand" then
        local name = e.text:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then ok, err = nil, "A hand needs a name" else pc.hand.name = name end
    end
    if not ok then self:setMessage(err or "That can't be done", true) end
end

---step a cell's value by `dir`.
---@param kind string
---@param i integer
---@param dir integer 1 or -1
function lib:step(kind, i, dir)
    local cfg, pc = self.cfg, self.cfg.players[i]
    if self:isClient() then
        if kind == "hero" or kind == "color" then (self.net --[[@as SESSION.CLIENTSESSION]]):askSeat(kind, dir)
        elseif kind == "name" then self:startEdit(kind, i)
        else self:setMessage("Only the host can change that", true) end
        return
    end
    local big = shiftDown() and 10 or 1
    if kind == "color" then SETUP.cycleColor(cfg, pc, dir)
    elseif kind == "hero" then SETUP.cycleHero(pc, dir)
    elseif kind == "control" then SETUP.cycleControl(pc, dir, self.net ~= nil)
    elseif kind == "team" then
        if not SETUP.cycleTeam(cfg, i, dir) then self:setMessage("Only one team: rename it, or add a player to join it", true) end
    elseif kind == "hand" then
        if not SETUP.cycleHand(cfg, i, dir) then self:setMessage("Only one hand: rename it, or add a player to share it", true) end
    elseif kind == "gold" then SETUP.setGold(pc.team, pc.team.goldToWin + dir * big)
    elseif kind == "tiles" then SETUP.setTiles(pc.hand, pc.hand.tileCount + dir * big)
    elseif kind == "number" then
        local key = SETUP.NUMBERS[i].key
        SETUP.setNumber(cfg, key, cfg.options[key] + dir * big)
    elseif kind == "name" or kind == "initial" then self:startEdit(kind, i)
    end
end

---save the setup to setup.dsc
function lib:save()
    love.filesystem.write(SAVE_FILE, SETUP.serialize(self.cfg))
    self:setMessage("Setup saved to " .. love.filesystem.getSaveDirectory() .. "/" .. SAVE_FILE)
end

---load the setup saved in setup.dsc
function lib:load()
    local text = love.filesystem.read(SAVE_FILE)
    if not text then return self:setMessage("No saved setup yet", true) end
    local cfg, err = SETUP.parse(text)
    if not cfg then return self:setMessage(err or "The saved setup can't be read", true) end
    self.cfg = cfg
    self:setMessage("Saved setup loaded.")
end

---try to start: sets self.started to the configuration to play, or explains what's wrong.
function lib:start()
    self:commitEdit()
    if self:isClient() then return self:setMessage("The host starts the game", true) end
    local problem = SETUP.problem(self.cfg) or SETUP.seatProblem(self.cfg, self.net ~= nil)
    if problem then return self:setMessage(problem, true) end
    self.started = self.cfg
end

---do what a clicked area does
---@param h SETUPVIEW.HIT
---@param button integer 1 left, 2 right
function lib:action(h, button)
    local dir = (button == 2) and -1 or 1
    local cfg = self.cfg
    if h.kind == "host" or h.kind == "join" or h.kind == "stopHosting" or h.kind == "leave" then
        self.request = h.kind
        return
    end
    if h.kind == "chat" then
        self.edit = { kind = "chat", text = "" }
        return
    end
    if self:isClient() and h.i and h.kind ~= "option" and not self:mayEdit(cfg.players[h.i]) then
        return self:setMessage("Only the host can change other players", true)
    end
    if self:isClient() and (h.kind == "option" or not h.i) then
        return self:setMessage("Only the host can change the setup", true)
    end
    if self:isClient() and h.kind ~= "name" and h.kind ~= "hero" and h.kind ~= "color" then
        return self:setMessage("Only the host can change that: you can change your name, colour and hero", true)
    end
    if h.kind == "addNetwork" then
        local pc = SETUP.addPlayer(cfg)
        pc.remote = true
        self:setMessage(pc.name .. " added: the next player to join plays it.")
    elseif h.kind == "addPerson" or h.kind == "addComputer" then
        local pc = SETUP.addPlayer(cfg, h.kind == "addComputer" and "greedy" or nil)
        self:setMessage(pc.name .. " added. Click the name to change it.")
    elseif h.kind == "twoTeams" then
        if #cfg.players % 2 == 1 then return self:setMessage("Odd number of players", true) end
        self:startEdit("twoTeams")
        self:setMessage("Two Teams: type the gold each team needs to win, then Enter.")
    elseif h.kind == "save" then self:save()
    elseif h.kind == "load" then self:load()
    elseif h.kind == "start" then self:start()
    elseif h.kind == "back" then self.back = true
    elseif h.kind == "up" then SETUP.movePlayer(cfg, h.i, -1)
    elseif h.kind == "down" then SETUP.movePlayer(cfg, h.i, 1)
    elseif h.kind == "remove" then
        local name = cfg.players[h.i].name
        SETUP.removePlayer(cfg, h.i)
        self:setMessage(name .. " removed.")
    elseif h.kind == "option" then
        local o = SETUP.OPTIONS[h.i]
        cfg.options[o.key] = not cfg.options[o.key]
    elseif h.part == "prev" then self:step(h.kind, h.i, -1)
    elseif h.part == "next" then self:step(h.kind, h.i, dir)
    elseif h.part == "type" then
        if button == 2 then self:step(h.kind, h.i, -1) else self:startEdit(h.kind, h.i) end
    end
end

---@param self SETUPVIEW
---@param mx number
---@param my number
---@return SETUPVIEW.HIT|nil
local function hitAt(self, mx, my)
    for n = #self.hits, 1, -1 do
        local h = self.hits[n]
        if mx >= h.x and mx < h.x + h.w and my >= h.y and my < h.y + h.h then return h end
    end
end

---@param mx number
---@param my number
---@param button integer
function lib:mousepressed(mx, my, button)
    local h = hitAt(self, mx, my)
    local e = self.edit
    if e then
        if h and h.kind == e.kind and h.i == e.i then return end   --clicking the field being typed in
        self:commitEdit()
        if e.kind == "twoTeams" then return end
    end
    self.message = nil
    if h then self:action(h, button) end
end

---step the value under the mouse
---@param dy number
---@return boolean used
function lib:wheelmoved(dy)
    local h = hitAt(self, love.mouse.getPosition())
    if not h or not h.i or self.edit then return false end
    if h.kind == "option" or h.kind == "up" or h.kind == "down" or h.kind == "remove" then return false end
    self:step(h.kind, h.i, dy > 0 and 1 or -1)
    return true
end

---@param t string
function lib:textinput(t)
    local e = self.edit
    if not e then return end
    if NUMERIC[e.kind] and not t:match("^%d+$") then return end
    if e.kind == "initial" then e.text = t:sub(1, 1)
    elseif e.kind == "chat" then
        if #e.text < 160 then e.text = e.text .. t:gsub("[\t\r\n]", "") end
    elseif #e.text < 24 then e.text = e.text .. t:gsub("[\t\r\n]", "")
    end
end

---returns true when the key was used here.
---@param key love.KeyConstant
---@return boolean used
function lib:keypressed(key)
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    if self.edit then
        if key == "return" or key == "kpenter" then self:commitEdit()
        elseif key == "escape" then self.edit = nil
        elseif key == "backspace" then
            local t = self.edit.text
            --drop the last UTF-8 character
            local cut = #t
            while cut > 0 and t:byte(cut) >= 0x80 and t:byte(cut) < 0xC0 do cut = cut - 1 end
            self.edit.text = t:sub(1, math.max(0, cut - 1))
        end
        return true
    end
    if key == "tab" and self.net then self.edit = { kind = "chat", text = "" }; return true end
    if key == "escape" and self:isClient() then self.request = "leave"; return true end
    if ctrl and key == "s" and not self:isClient() then self:save(); return true end
    if ctrl and key == "l" and not self:isClient() then self:load(); return true end
    if key == "return" or key == "kpenter" then self:start(); return true end
    if key == "escape" and self.canReturn then self.back = true; return true end
    return false
end

return lib
