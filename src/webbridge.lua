--WebSockets for the web build (love.js): the browser's own WebSocket, reached through
--love.js.eval (from 2dengine's love.js, which runs JavaScript and hands back its text) and
--wasm/drakonnet.js in the page. Same interface as websocket.lua: connect, poll, send, close.

local lib = {}

local POLL_EVERY = 1 / 20   --seconds between looks at the socket (calls into JavaScript)

---whether this is the web build with the bridge to JavaScript
---@return boolean
function lib.available()
    return love ~= nil and love.js ~= nil and type(love.js.eval) == "function"
end

---whether the page was served over https (as on GitHub Pages): a browser then won't let it
---connect to a game hosted on someone's computer (plain ws://), apart from this computer
---@return boolean
function lib.pageIsSecure()
    return lib.available() and love.js.eval("location.protocol") == "https:"
end

---a JavaScript string literal holding `s` (what crosses is ASCII: network play's words and base64;
---quotes, backslashes and line breaks are escaped)
---@param s string
---@return string
function lib.quote(s)
    return "'" .. s:gsub("[\\'\r\n]", function(c)
        return ("\\x%02x"):format(c:byte())
    end) .. "'"
end

---@param js string
---@return string
local function eval(js)
    return love.js.eval(js) or ""
end

---a connection through the page's DrakonNet
---@class WEBBRIDGE
---@field id string DrakonNet's number for it
---@field state "connecting"|"open"|"closed"
---@field lastPoll number
local Conn = {}
Conn.__index = Conn

---start connecting ("open" comes from poll once connected), or nil and why not
---@param url string a ws:// address
---@return WEBBRIDGE|nil
---@return string? err
function lib.connect(url)
    if not lib.available() then return nil, "Not the web version" end
    local reply = eval("DrakonNet.open(" .. lib.quote(url) .. ")")
    local id = reply:match("^(%d+)$")
    if not id or id == "0" then
        if reply == "" then return nil, "This web page is missing drakonnet.js (the game's network bridge)" end
        return nil, (reply:gsub("^0 ", ""))
    end
    local o = setmetatable({ id = id, state = "connecting", lastPoll = -1 }, Conn)
    return o --[[@as WEBBRIDGE]], nil
end

---what happened since last asked
---@return WEBSOCKET.EVENT[]
function Conn:poll()
    local out = {}
    if self.state == "closed" then return out end
    local now = love.timer.getTime()
    if now - self.lastPoll < POLL_EVERY then return out end
    self.lastPoll = now
    local text = eval("DrakonNet.poll(" .. self.id .. ")")
    for line in text:gmatch("[^\n]+") do
        local kind, rest = line:sub(1, 1), line:sub(3)
        if kind == "o" then
            self.state = "open"
            out[#out + 1] = { type = "open" }
        elseif kind == "m" then
            out[#out + 1] = { type = "message", data = rest }
        elseif kind == "c" then
            self.state = "closed"
            out[#out + 1] = { type = "close", data = rest }
            break
        end
    end
    return out
end

---send a text message (held until the connection is open)
---@param text string
function Conn:send(text)
    if self.state == "closed" then return end
    eval("DrakonNet.send(" .. self.id .. "," .. lib.quote(text) .. ")")
end

function Conn:close()
    if self.state == "closed" then return end
    self.state = "closed"
    eval("DrakonNet.close(" .. self.id .. ")")
end

return lib
