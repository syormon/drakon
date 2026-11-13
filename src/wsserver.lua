--a WebSocket server (RFC 6455) over LuaSocket, run by the hosting player's game (desktop
--and Android), so others can join it from the desktop version and from the web version (a
--browser can only make WebSocket connections). Plain ws://, text messages; put something
--that adds TLS in front (nginx with a certificate) and the web version on an https page
--(GitHub Pages) can join it with wss://. A plain web request gets one line saying what this
--is. Every connection is pinged now and then, so proxies don't close quiet ones. Nothing
--blocks: poll handles what came in and sends what is waiting. The frame functions are pure
--Lua (tested in plain Lua); listening needs LuaSocket, and the handshake needs SHA-1
--(love.data.hash).

local BASE64 = require('src.base64')

local lib = {}

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local MAX_HEADER = 16 * 1024
local MAX_MESSAGE = 8 * 1024 * 1024
local MAX_CLIENTS = 32
--seconds between pings to each connection: nginx closes a WebSocket after 60 quiet seconds
--by default, and a lobby can easily sit idle that long
lib.PING_EVERY = 25

---------------------------------------------------------------------------- frames

---xor of two bytes: LuaJIT's bit library when there is one, else arithmetic
---@type fun(a:integer, b:integer):integer
local bxor
do
    local ok, bit = pcall(require, 'bit')
    if ok and bit then
        bxor = bit.bxor
    else
        ---@param a integer
        ---@param b integer
        ---@return integer
        bxor = function(a, b)
            local r, p = 0, 1
            while a > 0 or b > 0 do
                local x, y = a % 2, b % 2
                if x ~= y then r = r + p end
                a, b, p = (a - x) / 2, (b - y) / 2, p * 2
            end
            return r
        end
    end
end

---a client's masked payload, unmasked
---@param data string
---@param key string 4 bytes
---@return string
function lib.unmask(data, key)
    if key == "\0\0\0\0" then return data end
    local k = { key:byte(1, 4) }
    local out = {}
    local char = string.char
    for i = 1, #data do
        out[i] = char(bxor(data:byte(i), k[(i - 1) % 4 + 1]))
    end
    return table.concat(out)
end

---a server frame (final, unmasked)
---@param opcode integer 1 text, 8 close, 9 ping, 10 pong
---@param payload string
---@return string
function lib.frame(opcode, payload)
    local n = #payload
    local head
    if n < 126 then
        head = string.char(0x80 + opcode, n)
    elseif n < 65536 then
        head = string.char(0x80 + opcode, 126, math.floor(n / 256), n % 256)
    else
        head = string.char(0x80 + opcode, 127, 0, 0, 0, 0,
            math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    return head .. payload
end

---a received (client) frame
---@class WSSERVER.FRAME
---@field fin boolean
---@field opcode integer
---@field payload string unmasked

---the client frame starting at `pos` in `buf`: the frame and where the next one starts; nil
---if more bytes are needed; false and why if it can't be read (a client's frames are masked)
---@param buf string
---@param pos integer
---@return WSSERVER.FRAME|false|nil frame
---@return integer|string|nil next (or what is wrong)
function lib.parse(buf, pos)
    if #buf - pos + 1 < 2 then return nil end
    local b1, b2 = buf:byte(pos, pos + 1)
    if b2 < 128 then return false, "an unmasked frame from a client" end
    local n = b2 % 128
    local p = pos + 2
    if n == 126 then
        if #buf < p + 1 then return nil end
        local a, b = buf:byte(p, p + 1)
        n, p = a * 256 + b, p + 2
    elseif n == 127 then
        if #buf < p + 7 then return nil end
        n = 0
        for i = 0, 7 do n = n * 256 + buf:byte(p + i) end
        p = p + 8
    end
    if n > MAX_MESSAGE then return false, "a message too large" end
    if #buf < p + 3 + n then return nil end
    local key = buf:sub(p, p + 3)
    p = p + 4
    return { fin = b1 >= 128, opcode = b1 % 16, payload = lib.unmask(buf:sub(p, p + n - 1), key) }, p + n
end

---the Sec-WebSocket-Accept answer to a client's key
---@param key string
---@param sha1? fun(s:string):string raw SHA-1 (default love.data.hash)
---@return string
function lib.accept(key, sha1)
    sha1 = sha1 or function(s) return love.data.hash("sha1", s) --[[@as string]] end
    return BASE64.encode(sha1(key .. GUID))
end

---------------------------------------------------------------------------- plain web requests

---the answer to a plain web request (`head`: its request line and headers), such as a
---browser opening the host's address, or checking that a proxy reaches the game: one line
---@param head string
---@return string
function lib.respond(head)
    local method = head:match("^(%u+) %S+ HTTP/1%.%d")
    local status, body = "200 OK", "A Drakon game is hosted here. Join it from Drakon: Join a game...\n"
    if not method then status, body = "400 Bad Request", "Bad request\n" end
    return ("HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\n"
        .. "Connection: close\r\n\r\n"):format(status, #body) .. (method == "HEAD" and "" or body)
end

---------------------------------------------------------------------------- the server

---something that happened on the server
---@class WSSERVER.EVENT
---@field type "open"|"message"|"close"
---@field id integer which connection
---@field data? string the message

---one connection
---@class WSSERVER.CONN
---@field sock table
---@field state "handshake"|"open"|"http" a plain web request being answered
---@field inbuf string
---@field outbuf string
---@field outpos integer the next byte of outbuf to send
---@field finishing boolean close once everything is sent
---@field parts string[]

---a listening WebSocket server
---@class WSSERVER
---@field sock table|nil the listening LuaSocket socket
---@field conns {[integer]:WSSERVER.CONN}
---@field nextId integer
---@field events WSSERVER.EVENT[]
---@field lastPing number when every connection was last pinged (socket.gettime)
local Server = {}
Server.__index = Server

---listen on `port` (all addresses), or nil and why not
---@param port integer
---@return WSSERVER|nil
---@return string? err
function lib.listen(port)
    local ok, socket = pcall(require, 'socket')
    if not ok then return nil, "No network support (LuaSocket) in this version of LÖVE" end
    --IPv4 on every address of this computer. (Not socket.bind("*"): it may listen on IPv6
    --only, and it sets SO_REUSEADDR, which on Windows lets a second program take a port
    --already in use; elsewhere that option only allows hosting again straight after stopping.)
    local sock, err = socket.tcp4()
    if not sock then return nil, "Could not start the network (" .. tostring(err) .. ")" end
    if package.config:sub(1, 1) ~= "\\" then sock:setoption("reuseaddr", true) end
    local ok2
    ok2, err = sock:bind("0.0.0.0", port)
    if ok2 then ok2, err = sock:listen(32) end
    if not ok2 then
        sock:close()
        return nil, ("Could not use port %d (%s): is another game hosting on it?"):format(port, tostring(err))
    end
    sock:settimeout(0)
    local o = setmetatable({ sock = sock, conns = {}, nextId = 1, events = {}, lastPing = socket.gettime() }, Server)
    return o --[[@as WSSERVER]], nil
end

---@param id integer
---@param data string
function Server:write(id, data)
    local c = self.conns[id]
    if not c then return end
    if c.outpos > 1 then
        c.outbuf, c.outpos = c.outbuf:sub(c.outpos), 1
    end
    c.outbuf = c.outbuf .. data
end

---let a connection go now (whatever is still waiting is tried once)
---@param id integer
---@param why? string
function Server:drop(id, why)
    local c = self.conns[id]
    if not c then return end
    self.conns[id] = nil
    if c.outpos <= #c.outbuf then pcall(c.sock.send, c.sock, c.outbuf, c.outpos) end
    c.sock:close()
    if c.state == "open" then self.events[#self.events + 1] = { type = "close", id = id, data = why } end
end

---answer a connection's HTTP request: true once it is a WebSocket
---@param id integer
---@param c WSSERVER.CONN
---@return boolean
function Server:handshake(id, c)
    local e = c.inbuf:find("\r\n\r\n", 1, true)
    if not e then
        if #c.inbuf > MAX_HEADER then self:drop(id) end
        return false
    end
    local head = c.inbuf:sub(1, e + 3)
    c.inbuf = c.inbuf:sub(e + 4)
    local key = head:match("\n[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
    local upgrade = (head:match("\n[Uu]pgrade:%s*([^\r\n]+)") or ""):lower()
    if not key or upgrade ~= "websocket" then
        --a plain web request (a browser opening the address): say what this is
        self:write(id, lib.respond(head))
        c.state, c.finishing = "http", true
        return false
    end
    self:write(id, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Accept: " .. lib.accept(key) .. "\r\n\r\n")
    c.state = "open"
    self.events[#self.events + 1] = { type = "open", id = id }
    return true
end

---turn a connection's received bytes into events
---@param id integer
---@param c WSSERVER.CONN
function Server:read(id, c)
    if c.state == "http" then c.inbuf = ""; return end
    if c.state == "handshake" and not self:handshake(id, c) then return end
    local pos = 1
    while self.conns[id] do
        local f, nxt = lib.parse(c.inbuf, pos)
        if f == nil then break end
        if f == false then return self:drop(id, tostring(nxt)) end
        pos = nxt --[[@as integer]]
        if f.opcode == 9 then
            self:write(id, lib.frame(10, f.payload))
        elseif f.opcode == 8 then
            self:write(id, lib.frame(8, ""))
            return self:drop(id, "closed")
        elseif f.opcode == 0 or f.opcode == 1 or f.opcode == 2 then
            c.parts[#c.parts + 1] = f.payload
            if f.fin then
                self.events[#self.events + 1] = { type = "message", id = id, data = table.concat(c.parts) }
                c.parts = {}
            end
        end
    end
    if self.conns[id] then c.inbuf = c.inbuf:sub(pos) end
end

---send what is waiting on a connection, as much as the network takes now
---@param id integer
---@param c WSSERVER.CONN
function Server:flush(id, c)
    if c.outpos <= #c.outbuf then
        local last, err, partial = c.sock:send(c.outbuf, c.outpos)
        local sent = last or partial or (c.outpos - 1)
        if err and err ~= "timeout" then return self:drop(id, "the connection was lost") end
        c.outpos = sent + 1
        if c.outpos > #c.outbuf then c.outbuf, c.outpos = "", 1 end
    end
    if c.finishing and c.outpos > #c.outbuf then self:drop(id) end
end

---take in new connections, move bytes in and out; the events since last asked
---@return WSSERVER.EVENT[]
function Server:poll()
    if self.sock then
        while true do
            local client = self.sock:accept()
            if not client then break end
            client:settimeout(0)
            local count = 0
            for _ in pairs(self.conns) do count = count + 1 end
            if count >= MAX_CLIENTS then
                client:close()
            else
                local id = self.nextId
                self.nextId = id + 1
                self.conns[id] = { sock = client, state = "handshake", inbuf = "", outbuf = "", outpos = 1,
                    finishing = false, parts = {} }
            end
        end
    end
    for id, c in pairs(self.conns) do
        while not c.finishing do
            local data, err, partial = c.sock:receive(65536)
            local got = data or partial
            if got and #got > 0 then c.inbuf = c.inbuf .. got end
            if err == "closed" then
                self:read(id, c)
                self:drop(id, "the connection was lost")
                break
            end
            if not data then break end
        end
        if self.conns[id] and not c.finishing then self:read(id, c) end
        if self.conns[id] then self:flush(id, c) end
    end
    --keep quiet connections open through proxies (browsers and websocket.lua answer pings)
    local now = require('socket').gettime()
    if now - self.lastPing >= lib.PING_EVERY then
        self.lastPing = now
        for id, c in pairs(self.conns) do
            if c.state == "open" then self:write(id, lib.frame(9, "")) end
        end
    end
    local e = self.events
    self.events = {}
    return e
end

---send a text message to a connection
---@param id integer
---@param text string
function Server:send(id, text)
    local c = self.conns[id]
    if c and c.state == "open" then self:write(id, lib.frame(1, text)) end
end

---close one connection (after what was sent to it)
---@param id integer
function Server:close(id)
    local c = self.conns[id]
    if not c then return end
    self:write(id, lib.frame(8, ""))
    self:drop(id)
end

---stop listening and let everyone go
function Server:shutdown()
    for id in pairs(self.conns) do self:close(id) end
    if self.sock then self.sock:close() end
    self.sock = nil
end

return lib
