--network play: the network under session.lua, over WebSockets. The hosting player's game
--(desktop or Android) listens (wsserver.lua, TCP port 5229) and asks for a password; the
--others connect to it, from the desktop version (websocket.lua) or the web version (the
--browser's WebSocket, through webbridge.lua). The host may sit behind a proxy that adds TLS
--(nginx with a certificate), so the web version on an https page (GitHub Pages) can join it
--with wss://; the desktop version (LÖVE has no TLS) joins the host's port directly.
--
--Words in text frames; the game's own messages travel as base64:
--
--  joining player -> host          host -> joining player
--  join <version> <password>       joined <id>  /  error <why>
--  send <payload>                  data <payload>
--                                  closed <why>   (the host stopped, or let them go)

local BASE64 = require('src.base64')

local lib = {}

lib.VERSION = "drakon-ws-1"
lib.PORT = 5229   --the original game's port

---@return boolean
function lib.isWeb()
    return love ~= nil and love.system ~= nil and love.system.getOS() == "Web"
end

---whether this is the web version on a page served over https (as GitHub Pages is): it
---can only open secure (wss://) connections
---@return boolean
function lib.pageIsSecure()
    return lib.isWeb() and require('src.webbridge').pageIsSecure()
end

---the host's address as typed, made a WebSocket address, or nil and why not. A bare
---address becomes wss://address on an https page (a host behind a proxy with a
---certificate, port 443 unless given), else ws://address:5229 (unless another port is
---given). Full addresses are kept, path and all (http:// is read as ws://, https:// as wss://).
---@param address string e.g. "192.168.1.20", "game.example.com", "wss://game.example.com/drakon"
---@param secure? boolean make a bare address wss:// (default: whether the page is https)
---@return string|nil url
---@return string? err
function lib.url(address, secure)
    address = (address or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if address == "" then return nil, "Type the host's address" end
    if secure == nil then secure = lib.pageIsSecure() end
    local scheme, rest = address:match("^(%a+)://(.*)$")
    if scheme then
        scheme = ({ ws = "ws", wss = "wss", http = "ws", https = "wss" })[scheme:lower()]
        if not scheme then return nil, "Type the host's address, e.g. 192.168.1.20 or game.example.com" end
    else
        scheme, rest = secure and "wss" or "ws", address
    end
    local hostport, path = rest:match("^([^/]+)(.*)$")
    if not hostport then return nil, "Type the host's address, e.g. 192.168.1.20 or game.example.com" end
    if path == "/" then path = "" end
    if scheme == "ws" and not hostport:find(":%d+$") then hostport = hostport .. ":" .. lib.PORT end
    return scheme .. "://" .. hostport .. path
end

---a new socket to `url`: the browser's in the web build, LuaSocket's elsewhere; or nil and
---why it can't be reached from here
---@param url string
---@return table|nil socket with poll/send/close
---@return string? err
function lib.socket(url)
    local WEBBRIDGE = require('src.webbridge')
    if WEBBRIDGE.available() then
        --browsers don't let an https page open a plain ws:// connection (except to this computer)
        if url:find("^ws://") and WEBBRIDGE.pageIsSecure() and not url:find("^ws://localhost[:/]")
           and not url:find("^ws://127%.0%.0%.1[:/]") then
            return nil, "This page is https, so it can only join a secure address: the host's address "
                .. "behind their certificate (e.g. game.example.com), not a plain ws:// one."
        end
        return WEBBRIDGE.connect(url)
    end
    if url:find("^wss://") then
        return nil, ("The desktop version can't use secure (wss://) addresses: join the host's own "
            .. "address and port instead (e.g. 203.0.113.5:%d)."):format(lib.PORT)
    end
    return require('src.websocket').connect(url)
end

---this computer's address on its network, to tell the others (nothing is sent to find it)
---@return string|nil
function lib.localAddress()
    local ok, socket = pcall(require, 'socket')
    if not ok then return nil end
    local u = socket.udp()
    if not u then return nil end
    --(naming a peer for a UDP socket only picks the way out; no packet is sent)
    local addr
    if u:setpeername("10.255.255.255", 9) then addr = u:getsockname() end
    u:close()
    if addr == "0.0.0.0" then return nil end
    return addr
end

---a password as sent: one line
---@param password string
---@return string
local function oneLine(password)
    return (password:gsub("[\r\n]", ""))
end

---------------------------------------------------------------------------- hosting

---a joined connection, once its password was right
---@class WSLINK.PEER
---@field joined boolean

---hosting: the listening server, with the password
---@class WSLINK.HOST
---@field server table wsserver.lua's server (or one like it, in the tests)
---@field password string
---@field peers {[integer]:WSLINK.PEER}
local Host = {}
Host.__index = Host

---start hosting on `port`, with `password` (may be ""), or nil and why not
---@param port integer
---@param password string
---@param server? table a server to use (default: wsserver.listen(port))
---@return WSLINK.HOST|nil
---@return string? err
function lib.host(port, password, server)
    if not server then
        local err
        server, err = require('src.wsserver').listen(port)
        if not server then return nil, err end
    end
    local o = setmetatable({ server = server, password = oneLine(password or ""), peers = {} }, Host)
    return o --[[@as WSLINK.HOST]], nil
end

---what happened since last asked, as session.lua expects: "connect" once a player is in
---with the right password, "receive", "disconnect"
---@return {kind:string, id:integer, data?:string}[]
function Host:poll()
    local out = {}
    for _, ev in ipairs(self.server:poll()) do
        local id = ev.id
        if ev.type == "open" then
            self.peers[id] = { joined = false }
        elseif ev.type == "message" then
            local peer = self.peers[id]
            if peer and not peer.joined then
                local word, version, password = ev.data:match("^(%S+) (%S+) ?(.*)$")
                if word ~= "join" or version ~= lib.VERSION then
                    self.server:send(id, "error The host has a different version of Drakon")
                    self.server:close(id)
                elseif password ~= self.password then
                    self.server:send(id, "error Wrong password")
                    self.server:close(id)
                else
                    peer.joined = true
                    self.server:send(id, "joined " .. id)
                    out[#out + 1] = { kind = "connect", id = id }
                end
            elseif peer then
                local payload = ev.data:match("^send (.*)$")
                local text = payload and BASE64.decode(payload)
                if text then out[#out + 1] = { kind = "receive", id = id, data = text } end
            end
        elseif ev.type == "close" then
            local peer = self.peers[id]
            self.peers[id] = nil
            if peer and peer.joined then out[#out + 1] = { kind = "disconnect", id = id } end
        end
    end
    return out
end

---@param id integer
---@param text string
function Host:send(id, text)
    local peer = self.peers[id]
    if peer and peer.joined then self.server:send(id, "data " .. BASE64.encode(text)) end
end

---let a player go (after what was sent to them)
---@param id integer
function Host:drop(id)
    self.server:close(id)
end

---stop hosting: everyone is let go
function Host:close()
    for id, peer in pairs(self.peers) do
        if peer.joined then self.server:send(id, "closed The host stopped the game.") end
    end
    self.server:shutdown()
    self.peers = {}
end

---------------------------------------------------------------------------- joining

---joining a hosted game
---@class WSLINK.CLIENT
---@field ws table the socket to the host
---@field password string
---@field done boolean
---@field opened boolean the host was reached
local Client = {}
Client.__index = Client

---join the game hosted at `address` ("connect" comes from poll once in), or nil and why not
---@param address string as typed
---@param password string
---@param ws? table a socket to use (default: a new one to the address)
---@return WSLINK.CLIENT|nil
---@return string? err
function lib.join(address, password, ws)
    if not ws then
        local url, err = lib.url(address)
        if not url then return nil, err end
        ws, err = lib.socket(url)
        if not ws then return nil, err end
    end
    local o = setmetatable({ ws = ws, password = oneLine(password or ""), done = false, opened = false }, Client)
    return o --[[@as WSLINK.CLIENT]], nil
end

---what happened since last asked, as session.lua expects ("disconnect" carries why)
---@return {kind:string, data?:string}[]
function Client:poll()
    local out = {}
    if self.done then return out end
    for _, ev in ipairs(self.ws:poll()) do
        if ev.type == "open" then
            self.opened = true
            self.ws:send("join " .. lib.VERSION .. " " .. self.password)
        elseif ev.type == "message" then
            local word, rest = ev.data:match("^(%S+) ?(.*)$")
            if word == "joined" then
                out[#out + 1] = { kind = "connect" }
            elseif word == "data" then
                local text = BASE64.decode(rest)
                if text then out[#out + 1] = { kind = "receive", data = text } end
            elseif word == "error" or word == "closed" then
                self.done = true
                out[#out + 1] = { kind = "disconnect", data = rest }
                self.ws:close()
                break
            end
        elseif ev.type == "close" then
            self.done = true
            local why = self.opened and "Lost the connection to the host" or "Could not reach the host"
            out[#out + 1] = { kind = "disconnect", data = why .. " (" .. tostring(ev.data) .. ")" }
            break
        end
    end
    return out
end

---@param text string
function Client:send(text)
    if not self.done then self.ws:send("send " .. BASE64.encode(text)) end
end

function Client:close()
    if self.done then return end
    self.done = true
    self.ws:close()
end

return lib
