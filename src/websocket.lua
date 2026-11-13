--a WebSocket client (RFC 6455) over LuaSocket, for joining a hosted game from the desktop
--and Android versions (the web build uses the browser's own WebSocket: webbridge.lua).
--Plain ws://. Nothing blocks: connect, send and poll return at once. Text messages only
--(network play's messages are ASCII words and base64).
--
--Frames sent are masked with an all-zero key (the standard asks for a mask, any value),
--so no bit operations are needed. The frame and URL functions are pure Lua (tested in
--plain Lua); the connection needs LuaSocket.

local lib = {}

local CONNECT_TIMEOUT = 10   --seconds
local MAX_MESSAGE = 8 * 1024 * 1024

---------------------------------------------------------------------------- frames

---a client frame: final, masked with a zero key
---@param opcode integer 1 text, 8 close, 9 ping, 10 pong
---@param payload string
---@return string
function lib.frame(opcode, payload)
    local n = #payload
    local head
    if n < 126 then
        head = string.char(0x80 + opcode, 0x80 + n)
    elseif n < 65536 then
        head = string.char(0x80 + opcode, 0x80 + 126, math.floor(n / 256), n % 256)
    else
        head = string.char(0x80 + opcode, 0x80 + 127, 0, 0, 0, 0,
            math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    return head .. "\0\0\0\0" .. payload
end

---a received frame
---@class WEBSOCKET.FRAME
---@field fin boolean the last part of a message
---@field opcode integer
---@field payload string

---the frame starting at `pos` in `buf`: the frame and where the next one starts; nil if
---more bytes are needed; false and why if it can't be read (a server's frames are never masked)
---@param buf string
---@param pos integer
---@return WEBSOCKET.FRAME|false|nil frame
---@return integer|string|nil next (or what is wrong)
function lib.parse(buf, pos)
    if #buf - pos + 1 < 2 then return nil end
    local b1, b2 = buf:byte(pos, pos + 1)
    local p = pos + 2
    local n = b2 % 128
    if b2 >= 128 then return false, "a masked frame from the server" end
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
    if #buf < p + n - 1 then return nil end
    return { fin = b1 >= 128, opcode = b1 % 16, payload = buf:sub(p, p + n - 1) }, p + n
end

---host, port and path of a ws:// address, or nil and why not
---@param url string
---@return string|nil host
---@return integer|string port (or what is wrong)
---@return string? path
function lib.parseURL(url)
    local scheme, rest = url:match("^(%a+)://(.+)$")
    if not scheme then return nil, "not a ws:// address: " .. url end
    if scheme:lower() ~= "ws" then return nil, "not a ws:// address: " .. url end
    local hostport, path = rest:match("^([^/]+)(/.*)$")
    if not hostport then hostport, path = rest, "/" end
    local host, port = hostport:match("^(.+):(%d+)$")
    if not host then host, port = hostport, "80" end
    return host, tonumber(port) --[[@as integer]], path
end

---------------------------------------------------------------------------- the connection

---something that happened on a connection
---@class WEBSOCKET.EVENT
---@field type "open"|"message"|"close"
---@field data? string the message, or why it closed

---a connection to a WebSocket server
---@class WEBSOCKET
---@field sock table|nil the LuaSocket TCP socket
---@field state "connecting"|"handshake"|"open"|"closed"
---@field host string
---@field port integer
---@field path string
---@field started number when connecting began (socket.gettime)
---@field key? string the handshake key sent
---@field inbuf string bytes received and not yet read
---@field outbuf string bytes waiting to be sent
---@field parts string[] parts of a message arriving in pieces
---@field events WEBSOCKET.EVENT[]
local Client = {}
Client.__index = Client

---start connecting to a ws:// address ("open" comes from poll once connected), or nil and
---why not
---@param url string
---@return WEBSOCKET|nil
---@return string? err
function lib.connect(url)
    local host, port, path = lib.parseURL(url)
    if not host then return nil, tostring(port) end
    local ok, socket = pcall(require, 'socket')
    if not ok then return nil, "No network support (LuaSocket) in this version of LÖVE" end
    local sock = socket.tcp()
    if not sock then return nil, "Could not start the network" end
    sock:settimeout(0)
    local _, err = sock:connect(host, port)
    if err and err ~= "timeout" and err ~= "Operation already in progress" then
        sock:close()
        return nil, ("Could not reach %s (%s)"):format(host, err)
    end
    local o = setmetatable({
        sock = sock, state = "connecting", host = host, port = port --[[@as integer]], path = path or "/",
        started = socket.gettime(), inbuf = "", outbuf = "", parts = {}, events = {},
    }, Client)
    return o --[[@as WEBSOCKET]], nil
end

---@param data string
function Client:write(data)
    self.outbuf = self.outbuf .. data
end

---@param why string
function Client:fail(why)
    if self.state == "closed" then return end
    self.state = "closed"
    if self.sock then self.sock:close() end
    self.sock = nil
    self.events[#self.events + 1] = { type = "close", data = why }
end

---a random handshake key (16 bytes, base64)
---@return string
local function newKey()
    local BASE64 = require('src.base64')
    local rnd = (love and love.math and love.math.random) or math.random
    local bytes = {}
    for i = 1, 16 do bytes[i] = string.char(rnd(0, 255)) end
    return BASE64.encode(table.concat(bytes))
end

---the reply a server must give to `key`, if this LÖVE can work it out (else nil: not checked)
---@param key string
---@return string|nil
local function expectedAccept(key)
    if not (love and love.data and love.data.hash) then return nil end
    local BASE64 = require('src.base64')
    local digest = love.data.hash("sha1", key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    return BASE64.encode(digest --[[@as string]])
end

---move bytes in and out, and turn them into events
function Client:pump()
    local socket = require('socket')
    if self.state == "connecting" then
        --a connection being made shows as writable once it is up (on Unix also when it
        --failed, but then there is no peer); a refused one on Windows never does, so it
        --waits out CONNECT_TIMEOUT. (Asking connect again would start a new attempt.)
        local _, writable = socket.select(nil, { self.sock }, 0)
        if writable and #writable > 0 then
            if not self.sock:getpeername() then
                return self:fail(("%s:%d is not answering"):format(self.host, self.port))
            end
            self.state = "handshake"
            self.key = newKey()
            self.outbuf = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                .. "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"):format(self.path, self.host, self.port, self.key)
                .. self.outbuf
        elseif socket.gettime() - self.started > CONNECT_TIMEOUT then
            return self:fail(("%s:%d is not answering"):format(self.host, self.port))
        else
            return
        end
    end
    --send what is waiting
    if #self.outbuf > 0 then
        local last, err, partial = self.sock:send(self.outbuf)
        local sent = last or partial or 0
        if err and err ~= "timeout" then return self:fail("The connection was lost (" .. err .. ")") end
        self.outbuf = self.outbuf:sub(sent + 1)
    end
    --take in what came
    while true do
        local data, err, partial = self.sock:receive(65536)
        local got = data or partial
        if got and #got > 0 then self.inbuf = self.inbuf .. got end
        if err == "closed" then
            self:read()
            return self:fail("The server closed the connection")
        end
        if not data then break end
    end
    self:read()
end

---turn received bytes into events
function Client:read()
    if self.state == "handshake" then
        local e = self.inbuf:find("\r\n\r\n", 1, true)
        if not e then return end
        local head = self.inbuf:sub(1, e + 3)
        self.inbuf = self.inbuf:sub(e + 4)
        if not head:match("^HTTP/1%.1 101") then
            return self:fail("The server didn't accept the connection (" .. (head:match("^[^\r\n]*") or "?") .. ")")
        end
        local want = expectedAccept(self.key)
        local got = head:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)")
        if want and got ~= want then return self:fail("The server's answer was wrong") end
        self.state = "open"
        self.events[#self.events + 1] = { type = "open" }
    end
    if self.state ~= "open" then return end
    local pos = 1
    while true do
        local f, nxt = lib.parse(self.inbuf, pos)
        if f == nil then break end
        if f == false then return self:fail("The connection broke (" .. tostring(nxt) .. ")") end
        pos = nxt --[[@as integer]]
        if f.opcode == 9 then
            self:write(lib.frame(10, f.payload))
        elseif f.opcode == 8 then
            self:write(lib.frame(8, ""))
            pcall(self.sock.send, self.sock, self.outbuf)
            self.inbuf = ""
            return self:fail("The server closed the connection")
        elseif f.opcode == 0 or f.opcode == 1 or f.opcode == 2 then
            self.parts[#self.parts + 1] = f.payload
            if f.fin then
                self.events[#self.events + 1] = { type = "message", data = table.concat(self.parts) }
                self.parts = {}
            end
        end
    end
    self.inbuf = self.inbuf:sub(pos)
end

---what happened since last asked
---@return WEBSOCKET.EVENT[]
function Client:poll()
    if self.state ~= "closed" then self:pump() end
    local e = self.events
    self.events = {}
    return e
end

---send a text message (held until the connection is open)
---@param text string
function Client:send(text)
    if self.state == "closed" then return end
    self:write(lib.frame(1, text))
end

---close the connection (after sending what is waiting)
function Client:close()
    if self.state == "closed" then return end
    if self.state == "open" then
        self:write(lib.frame(8, ""))
        pcall(self.sock.send, self.sock, self.outbuf)
    end
    self.state = "closed"
    if self.sock then self.sock:close() end
    self.sock = nil
end

return lib
