--network play. One computer hosts: it keeps the real game, runs the computer players and
--carries out every action. The others join: they send the actions of their own seat and
--get the whole game back after every change (which also lets them join late or come back).
--A joining player applies their own action at once too, so the screen answers straight
--away; the game's random numbers are part of the game state, so the host gets the same result.
--
--The original game did this through a server on the internet (its Connect, Host Game and
--Select Game dialogs, port 5229). This version needs no server: players join the host's
--game directly, on the same network or (with the port forwarded) over the internet, from
--the desktop version or the web version.
--
--Messages are tables sent with serial.lua. pure Lua: the network itself is a "transport"
--(wslink.lua over WebSockets in the game, a pair of queues in the tests):
--  host transport:   poll() -> {kind="connect"|"receive"|"disconnect", id, data}[],
--                    send(id, text), drop(id), close()
--  client transport: poll() -> {kind="connect"|"receive"|"disconnect", data}[],
--                    send(text), close()

local GAME = require('src.game')
local TILES = require('src.tiles')
local BOARD = require('src.board')
local SETUP = require('src.setup')
local SERIAL = require('src.serial')
local ACTIONS = require('src.actions')

local lib = {}

lib.PROTOCOL = 1
lib.LOG_MAX = 10    --lines of the shared game log kept
lib.CHAT_MAX = 40   --lines of chat kept
local TEXT_MAX = 200
local NAME_MAX = 24

---classes a game may hold, for serial.lua
---@type SERIAL.CLASSES
lib.CLASSES = { Tile = getmetatable(TILES.new(0)), Board = BOARD, RNG = GAME.RNG }

---@param msg table
---@return string
function lib.pack(msg) return SERIAL.encode(msg, lib.CLASSES) end

---@param text string
---@return table|nil msg
---@return string? err
function lib.unpack(text)
    local msg, err = SERIAL.decode(text, lib.CLASSES)
    if msg ~= nil and type(msg) ~= "table" then return nil, "not a message" end
    return msg, err
end

---text from the network made safe to show: one line, trimmed, at most `max` bytes (cut at a
---character boundary), or nil if nothing is left
---@param text any
---@param max integer
---@return string|nil
function lib.clean(text, max)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > max then
        local cut = max
        while cut > 0 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
            cut = cut - 1
        end
        text = text:sub(1, cut)
    end
    if text == "" then return nil end
    return text
end

---@param list string[]
---@param line string
---@param max integer
local function push(list, line, max)
    list[#list + 1] = line
    while #list > max do table.remove(list, 1) end
end

---something for the program to react to
---@class SESSION.EVENT
---@field type "joined"|"left"|"chat"|"lobby"|"game"|"rejected"|"closed"|"changed"
---@field text? string
---@field fresh? boolean a new game started

---------------------------------------------------------------------------- hosting

---a connected player
---@class SESSION.CLIENT
---@field name string
---@field seq integer last action of theirs carried out

---the hosting computer
---@class SESSION.HOST
---@field role "host"
---@field transport table
---@field port integer|nil the port it listens on
---@field name string who chat from this computer is from
---@field clients {[integer]:SESSION.CLIENT} by connection id
---@field cfg GAME.CONFIG|nil the setup being edited (shared with the setup screen)
---@field lobbySent string|nil the setup as last sent
---@field state GAME.STATE|nil the game in play
---@field log string[] the shared game log
---@field chat string[]
---@field events SESSION.EVENT[]
lib.Host = {}

---@param transport table
---@param name? string
---@return SESSION.HOST
function lib.Host:new(transport, name)
    local o = {
        role = "host", transport = transport, name = name or "Host",
        clients = {}, cfg = nil, lobbySent = nil, state = nil,
        log = {}, chat = {}, events = {},
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param id integer
---@param msg table
function lib.Host:send(id, msg) self.transport:send(id, lib.pack(msg)) end

---@param msg table
function lib.Host:broadcast(msg)
    local text = lib.pack(msg)
    for id in pairs(self.clients) do self.transport:send(id, text) end
end

---names of the connected players, in the order they joined
---@return string[]
function lib.Host:names()
    local ids = {}
    for id in pairs(self.clients) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = self.clients[id].name end
    return out
end

---whether this computer plays a seat (a person here, not a computer player or a network seat)
---@param player GAME.PLAYER|nil
---@return boolean
function lib.Host:controls(player)
    return player ~= nil and not player.config.ai and not player.config.remote
end

---the seat a connection plays in the setup or the game, if any
---@param id integer
---@return GAME.PLAYERCONFIG|nil
function lib.Host:seatOf(id)
    local cfg = self.state and self.state.config or self.cfg
    for _, pc in ipairs(cfg and cfg.players or {}) do
        if pc.peer == id then return pc end
    end
end

---a seat is played by a connection from now on: named after them, with their initial if
---nobody else has it
---@param pc GAME.PLAYERCONFIG
---@param id integer
---@param name string
---@param cfg GAME.CONFIG
function lib.Host:claim(pc, id, name, cfg)
    pc.peer = id
    SETUP.rename(pc, name, cfg)
    local initial = name:sub(1, 1):upper()
    if initial:match("%a") then
        for _, other in ipairs(cfg.players) do
            if other ~= pc and (other.initial or ""):upper() == initial then return end
        end
        pc.initial = initial
    end
end

---the setup changed (or is shown for the first time): forget seats of players who have
---gone, give open network seats to connected players without one (theirs by name first),
---and send it to everyone if anything is different. Stops any game being played.
---@param cfg GAME.CONFIG
function lib.Host:setLobby(cfg)
    self.cfg = cfg
    if self.state then self.state = nil; self.lobbySent = nil end
    local seated = {}
    for _, pc in ipairs(cfg.players) do
        if pc.peer and not self.clients[pc.peer] then pc.peer = nil end
        if not pc.remote then pc.peer = nil end
        if pc.peer then seated[pc.peer] = true end
    end
    local ids = {}
    for id in pairs(self.clients) do if not seated[id] then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local name, open = self.clients[id].name, nil
        for _, pc in ipairs(cfg.players) do
            if pc.remote and not pc.peer then
                if pc.name == name then open = pc; break end
                open = open or pc
            end
        end
        if open then self:claim(open, id, name, cfg) end
    end
    local text = lib.pack({ t = "lobby", cfg = cfg, names = self:names() })
    if text ~= self.lobbySent then
        self.lobbySent = text
        for id in pairs(self.clients) do self.transport:send(id, text) end
    end
end

---the game message, with each player's last action carried out
---@param fresh? boolean
---@return table
function lib.Host:gameMessage(fresh)
    local acks = {}
    for id, c in pairs(self.clients) do acks[id] = c.seq end
    return { t = "game", state = self.state, log = self.log, acks = acks, fresh = fresh or nil }
end

---a game starts (with the setup's seats), or goes on after the host looked at the setup
---(`resume`: the log is kept)
---@param state GAME.STATE
---@param resume? boolean
function lib.Host:startGame(state, resume)
    self.state = state
    if not resume then self.log = {} end
    --a network seat whose player has gone (while the setup was shown) is played by a
    --computer until they come back
    for _, pc in ipairs(state.config.players) do
        if pc.remote and not pc.ai and not (pc.peer and self.clients[pc.peer]) then
            pc.peer, pc.ai, pc.dropped = nil, "greedy", pc.name
        end
    end
    for _, c in pairs(self.clients) do c.seq = 0 end
    self:broadcast(self:gameMessage(true))
end

---the game changed on this computer (a person here or a computer player acted): `lines`
---go into the shared log, and everyone gets the game
---@param lines? string[]
function lib.Host:changed(lines)
    for _, line in ipairs(lines or {}) do push(self.log, line, lib.LOG_MAX) end
    if self.state then self:broadcast(self:gameMessage()) end
end

---@param from string
---@param text string
function lib.Host:addChat(from, text)
    local line = from .. ": " .. text
    push(self.chat, line, lib.CHAT_MAX)
    self:broadcast({ t = "chat", line = line })
    self.events[#self.events + 1] = { type = "chat", text = line }
end

---chat from this computer
---@param text string
function lib.Host:say(text)
    local line = lib.clean(text, TEXT_MAX)
    if line then self:addChat(self.name, line) end
end

---a name nobody else here has (the player's own, or with a number added)
---@param name string
---@param id integer
---@return string
function lib.Host:uniqueName(name, id)
    local taken = {}
    for cid, c in pairs(self.clients) do if cid ~= id then taken[c.name] = true end end
    local cfg = self.state and self.state.config or self.cfg
    for _, pc in ipairs(cfg and cfg.players or {}) do
        if pc.peer ~= id and not pc.remote then taken[pc.name] = true end
    end
    if not taken[name] then return name end
    for n = 2, 99 do
        local try = name:sub(1, NAME_MAX - 3) .. " " .. n
        if not taken[try] then return try end
    end
    return name .. " " .. id
end

---give a newcomer a seat: in a game, the seat they left (if they come back); in the setup,
---an open network seat (theirs by name first) or a new one
---@param id integer
---@param name string
---@return GAME.PLAYERCONFIG|nil
function lib.Host:seat(id, name)
    if self.state then
        for _, pc in ipairs(self.state.config.players) do
            if pc.dropped == name then
                pc.peer, pc.ai, pc.dropped = id, nil, nil
                return pc
            end
        end
        return nil
    end
    local cfg = self.cfg
    if not cfg then return nil end
    local open
    for _, pc in ipairs(cfg.players) do
        if pc.remote and not pc.peer then
            if pc.name == name then open = pc; break end
            open = open or pc
        end
    end
    if not open and #cfg.players < #GAME.COLORS + 1 then
        open = SETUP.addPlayer(cfg)
        open.remote = true
    end
    if not open then return nil end
    self:claim(open, id, name, cfg)
    return open
end

---@param id integer
---@param msg table
function lib.Host:onHello(id, msg)
    if msg.protocol ~= lib.PROTOCOL then
        self:send(id, { t = "refused", reason = "a different version of Drakon" })
        return self.transport:drop(id)
    end
    local name = lib.clean(msg.name, NAME_MAX) or ("Player " .. id)
    name = self:uniqueName(name, id)
    self.clients[id] = { name = name, seq = 0 }
    local pc = self:seat(id, name)
    self:send(id, { t = "welcome", id = id, name = name })
    local text
    if self.state then
        text = pc and (name .. " is back and plays again.") or (name .. " is watching.")
        if pc then push(self.log, text, lib.LOG_MAX) end
        self:broadcast(self:gameMessage())
        self:send(id, self:gameMessage(true))
    else
        text = pc and (name .. " joined and plays " .. pc.name .. ".") or (name .. " joined to watch (no seat free).")
        self.lobbySent = nil
        if self.cfg then self:setLobby(self.cfg) end
    end
    for _, line in ipairs(self.chat) do self:send(id, { t = "chat", line = line }) end
    self.events[#self.events + 1] = { type = "joined", text = text }
end

---@param id integer
---@param msg table
function lib.Host:onAction(id, msg)
    local c = self.clients[id]
    local s = self.state
    if not s then return end
    local seq = msg.seq
    if type(seq) ~= "number" or seq <= c.seq then return end   --old, or sent twice
    c.seq = seq
    local result, err
    if not (s.activePlayer and s.activePlayer.config.peer == id) then
        err = "It is not your turn"
    else
        local ok, r, e = pcall(ACTIONS.apply, s, msg.action)
        if not ok then result, err = nil, "That could not be done (" .. tostring(r) .. ")"
        else result, err = r, e end
    end
    if not result then
        self:send(id, { t = "rejected", reason = tostring(err or "That could not be done") })
        self:send(id, self:gameMessage())
        return
    end
    local line = lib.clean(msg.log, TEXT_MAX)
    if line then push(self.log, line, lib.LOG_MAX) end
    self:broadcast(self:gameMessage())
    self.events[#self.events + 1] = { type = "changed", text = line }
end

---a seat's player asks to change their own hero, colour or name (in the setup)
---@param id integer
---@param msg table
function lib.Host:onSeat(id, msg)
    local pc = (not self.state) and self:seatOf(id)
    if not pc then return end
    local dir = msg.dir == -1 and -1 or 1
    if msg.field == "hero" then SETUP.cycleHero(pc, dir)
    elseif msg.field == "color" then SETUP.cycleColor(self.cfg, pc, dir)
    elseif msg.field == "name" then
        local name = lib.clean(msg.text, NAME_MAX)
        if name then
            name = self:uniqueName(name, id)
            if SETUP.rename(pc, name, self.cfg) then self.clients[id].name = pc.name end
        end
    end
    self:setLobby(self.cfg)
    self.events[#self.events + 1] = { type = "changed" }
end

---@param id integer
function lib.Host:onLeave(id)
    local c = self.clients[id]
    if not c then return end
    self.clients[id] = nil
    local text = c.name .. " left."
    if self.state then
        for _, pc in ipairs(self.state.config.players) do
            if pc.peer == id then
                --a computer player keeps the seat warm until they come back
                pc.peer, pc.ai, pc.dropped = nil, "greedy", c.name
                text = c.name .. " left: a computer player takes over until they come back."
            end
        end
        push(self.log, text, lib.LOG_MAX)
        self:broadcast(self:gameMessage())
    elseif self.cfg then
        self:setLobby(self.cfg)
    end
    self.events[#self.events + 1] = { type = "left", text = text }
end

---handle what came in from the network
function lib.Host:update()
    for _, ev in ipairs(self.transport:poll()) do
        if ev.kind == "disconnect" then
            self:onLeave(ev.id)
        elseif ev.kind == "receive" then
            local msg = lib.unpack(ev.data)
            local c = self.clients[ev.id]
            if not msg then
                --(garbage: ignore it)
            elseif msg.t == "hello" and not c then self:onHello(ev.id, msg)
            elseif c and msg.t == "action" then self:onAction(ev.id, msg)
            elseif c and msg.t == "seat" then self:onSeat(ev.id, msg)
            elseif c and msg.t == "chat" then
                local text = lib.clean(msg.text, TEXT_MAX)
                if text then self:addChat(c.name, text) end
            end
        end
    end
end

---stop hosting: everyone is told and let go
function lib.Host:close()
    self:broadcast({ t = "bye", reason = "The host stopped the network game." })
    self.transport:close()
end

---------------------------------------------------------------------------- joining

---a computer that joined a host
---@class SESSION.CLIENTSESSION
---@field role "client"
---@field transport table
---@field name string asked for; the host may change it
---@field id integer|nil given by the host
---@field status "connecting"|"lobby"|"game"|"closed"
---@field cfg GAME.CONFIG|nil the host's setup
---@field names string[] connected players
---@field state GAME.STATE|nil the game in play
---@field log string[] the shared game log
---@field chat string[]
---@field seq integer last action sent
---@field events SESSION.EVENT[]
lib.Client = {}

---@param transport table
---@param name string
---@return SESSION.CLIENTSESSION
function lib.Client:new(transport, name)
    local o = {
        role = "client", transport = transport, name = name, id = nil, status = "connecting",
        cfg = nil, names = {}, state = nil, log = {}, chat = {}, seq = 0, events = {},
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param msg table
function lib.Client:send(msg) self.transport:send(lib.pack(msg)) end

---whether this computer plays a seat
---@param player GAME.PLAYER|nil
---@return boolean
function lib.Client:controls(player)
    return player ~= nil and self.id ~= nil and player.config.peer == self.id
end

---send an action of ours (already carried out here) with the log line describing it
---@param action ACTIONS.ACTION
---@param line? string
function lib.Client:sendAction(action, line)
    self.seq = self.seq + 1
    self:send({ t = "action", seq = self.seq, action = action, log = line })
end

---ask the host to change our seat (in the setup)
---@param field "hero"|"color"|"name"
---@param dir? integer
---@param text? string
function lib.Client:askSeat(field, dir, text)
    self:send({ t = "seat", field = field, dir = dir, text = text })
end

---@param text string
function lib.Client:say(text)
    local line = lib.clean(text, TEXT_MAX)
    if line then self:send({ t = "chat", text = line }) end
end

---@param reason string
function lib.Client:closed(reason)
    if self.status == "closed" then return end
    self.status = "closed"
    self.events[#self.events + 1] = { type = "closed", text = reason }
end

---@param msg table
function lib.Client:onMessage(msg)
    local t = msg.t
    if t == "welcome" then
        self.id = msg.id
        self.name = lib.clean(msg.name, NAME_MAX) or self.name
        self.status = "lobby"
    elseif t == "refused" or t == "bye" then
        self:closed(lib.clean(msg.reason, TEXT_MAX) or "The host closed the connection.")
        self.transport:close()
    elseif t == "lobby" and type(msg.cfg) == "table" then
        self.cfg, self.state = msg.cfg, nil
        self.names = type(msg.names) == "table" and msg.names or {}
        self.status = "lobby"
        self.events[#self.events + 1] = { type = "lobby" }
    elseif t == "game" and type(msg.state) == "table" then
        local acked = type(msg.acks) == "table" and msg.acks[self.id] or 0
        --a game from before our latest action got there: ours is already shown, wait
        if not msg.fresh and acked < self.seq then return end
        if msg.fresh then self.seq = 0 end
        self.state = msg.state
        self.log = type(msg.log) == "table" and msg.log or {}
        self.status = "game"
        self.events[#self.events + 1] = { type = "game", fresh = msg.fresh }
    elseif t == "rejected" then
        --(the host's game follows: it has seen our action, so it is taken)
        self.events[#self.events + 1] = { type = "rejected", text = lib.clean(msg.reason, TEXT_MAX) }
    elseif t == "chat" then
        local line = lib.clean(msg.line, TEXT_MAX + NAME_MAX + 2)
        if line then
            push(self.chat, line, lib.CHAT_MAX)
            self.events[#self.events + 1] = { type = "chat", text = line }
        end
    end
end

---handle what came in from the network
function lib.Client:update()
    for _, ev in ipairs(self.transport:poll()) do
        if ev.kind == "connect" then
            self:send({ t = "hello", protocol = lib.PROTOCOL, name = self.name })
        elseif ev.kind == "disconnect" then
            local why = lib.clean(ev.data, TEXT_MAX)
            self:closed(why or (self.status == "connecting" and "Could not reach the host." or "Lost the connection to the host."))
        elseif ev.kind == "receive" then
            local msg = lib.unpack(ev.data)
            if msg then self:onMessage(msg) end
        end
    end
end

---leave the game
function lib.Client:close()
    self.transport:close()
    self.status = "closed"
end

---the events since last asked
---@param self SESSION.HOST|SESSION.CLIENTSESSION
---@return SESSION.EVENT[]
function lib.takeEvents(self)
    local e = self.events
    self.events = {}
    return e
end

return lib
