--tests for network play over WebSockets: base64.lua, the frames and addresses of
--websocket.lua (joining) and wsserver.lua (hosting), and wslink.lua over a pretend network
--(the host's password, whole games played through session.lua, the web build's bridge).
--Runs under plain Lua, from the repository's top folder:
--lua tests/test_online.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local GAME = require('src.game')
local SETUP = require('src.setup')
local AI = require('src.ai')
local ACTIONS = require('src.actions')
local SESSION = require('src.session')
local BASE64 = require('src.base64')
local WEBSOCKET = require('src.websocket')
local WSSERVER = require('src.wsserver')
local WSLINK = require('src.wslink')
local WEBBRIDGE = require('src.webbridge')

local passed, failed = 0, 0
---count a check, printing it when it fails
---@param name string
---@param cond any
---@param detail? any shown when it fails
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end
---check that got == want
---@param name string
---@param got any
---@param want any
local function eq(name, got, want)
    check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

---------------------------------------------------------------------------- base64

do
    eq("base64 empty", BASE64.encode(""), "")
    eq("base64 f", BASE64.encode("f"), "Zg==")
    eq("base64 fo", BASE64.encode("fo"), "Zm8=")
    eq("base64 foo", BASE64.encode("foo"), "Zm9v")
    eq("base64 foobar", BASE64.encode("foobar"), "Zm9vYmFy")
    eq("base64 decode", BASE64.decode("Zm9vYmE="), "fooba")
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
    local all = table.concat(bytes)
    local same = true
    for n = 0, 40 do
        local s = all:sub(1, n) .. all:sub(200, 200 + n)
        if BASE64.decode(BASE64.encode(s)) ~= s then same = false end
    end
    check("base64 round trips every byte and length", same)
    check("base64 output is one line of plain characters", BASE64.encode(all):match("^[%w+/=]+$"))
    for _, bad in ipairs({ "abc", "ab$=", "=abc", "ab=c", "a===" }) do
        eq("base64 refuses " .. bad, BASE64.decode(bad), nil)
    end
end

---------------------------------------------------------------------------- websocket frames

do
    ---a frame as a server sends it (unmasked)
    ---@param opcode integer
    ---@param payload string
    ---@param fin? boolean
    ---@return string
    local function serverFrame(opcode, payload, fin)
        local n = #payload
        local b1 = string.char((fin == false and 0 or 0x80) + opcode)
        if n < 126 then return b1 .. string.char(n) .. payload end
        if n < 65536 then return b1 .. string.char(126, math.floor(n / 256), n % 256) .. payload end
        return b1 .. string.char(127, 0, 0, 0, 0, math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256, n % 256) .. payload
    end
    for _, n in ipairs({ 0, 5, 125, 126, 1000, 65535, 65536, 200000 }) do
        local payload = ("x"):rep(n)
        local f, nxt = WEBSOCKET.parse(serverFrame(1, payload), 1)
        check("frame of " .. n .. " bytes read", f and f.payload == payload and f.fin and f.opcode == 1)
        local whole = serverFrame(1, payload)
        eq("next frame after " .. n, nxt, #whole + 1)
        check("half a frame of " .. n .. " waits", n == 0 or WEBSOCKET.parse(whole:sub(1, #whole - 1), 1) == nil)
        --our own frames: masked (zero key), with the length the server expects
        local mine = WEBSOCKET.frame(1, payload)
        local lenByte = mine:byte(2)
        check("client frame of " .. n .. " is masked", lenByte >= 128)
        check("client frame of " .. n .. " ends with the payload", mine:sub(-n - 4) == "\0\0\0\0" .. payload)
    end
    local two = serverFrame(1, "ab", false) .. serverFrame(0, "cd")
    local f1, p2 = WEBSOCKET.parse(two, 1)
    local f2 = WEBSOCKET.parse(two, p2 --[[@as integer]])
    check("a message in two parts", f1 and not f1.fin and f2 and f2.fin and f1.payload .. f2.payload == "abcd")
    local bad, why = WEBSOCKET.parse(string.char(0x81, 0x85, 1, 2, 3, 4) .. "hello", 1)
    check("a masked frame from a server is refused", bad == false and why)

    local host, port, path = WEBSOCKET.parseURL("ws://host.example.com:8765/drakon")
    check("address read", host == "host.example.com" and port == 8765 and path == "/drakon")
    host, port, path = WEBSOCKET.parseURL("ws://example.com")
    check("default port and path", host == "example.com" and port == 80 and path == "/")
    check("only ws:// addresses", WEBSOCKET.parseURL("http://example.com") == nil)
    check("not an address", WEBSOCKET.parseURL("example.com") == nil)
    eq("JS quoting", WEBBRIDGE.quote("a'b\\c\nd"), "'a\\x27b\\x5cc\\x0ad'")
end

---------------------------------------------------------------------------- the host's frames

do
    ---a frame as a browser sends it: masked with `key`
    ---@param payload string
    ---@param key string 4 bytes
    ---@param fin? boolean
    ---@param opcode? integer
    ---@return string
    local function clientFrame(payload, key, fin, opcode)
        local n = #payload
        local b1 = string.char((fin == false and 0 or 0x80) + (opcode or 1))
        local len
        if n < 126 then len = string.char(0x80 + n)
        elseif n < 65536 then len = string.char(0x80 + 126, math.floor(n / 256), n % 256)
        else len = string.char(0x80 + 127, 0, 0, 0, 0, math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256, n % 256) end
        return b1 .. len .. key .. WSSERVER.unmask(payload, key)   --(masking is its own inverse)
    end
    local key = string.char(0x37, 0xfa, 0x21, 0x3d)
    for _, n in ipairs({ 0, 5, 125, 126, 1000, 70000 }) do
        local payload = ("join drakon-ws-1 p\195\164ssw\195\182rd "):rep(math.ceil(n / 30)):sub(1, n)
        local whole = clientFrame(payload, key)
        local f, nxt = WSSERVER.parse(whole, 1)
        check("browser frame of " .. n .. " bytes unmasked", f and f.payload == payload and f.fin and f.opcode == 1)
        eq("next frame after " .. n, nxt, #whole + 1)
        check("half a frame of " .. n .. " waits", n == 0 or WSSERVER.parse(whole:sub(1, #whole - 1), 1) == nil)
        local mine = WSSERVER.frame(1, payload)
        local back = WEBSOCKET.parse(mine, 1)
        check("host frame of " .. n .. " reads back (as the joining side reads it)", back and back.payload == payload)
    end
    eq("the RFC's masking example", WSSERVER.unmask(string.char(0x7f, 0x9f, 0x4d, 0x51, 0x58), string.char(0x37, 0xfa, 0x21, 0x3d)), "Hello")
    local bad, why = WSSERVER.parse(string.char(0x81, 0x05) .. "hello", 1)
    check("an unmasked frame from a client is refused", bad == false and why)
    local two = clientFrame("ab", key, false) .. clientFrame("cd", key, true, 0)
    local f1, p2 = WSSERVER.parse(two, 1)
    local f2 = WSSERVER.parse(two, p2 --[[@as integer]])
    check("a browser's message in two parts", f1 and not f1.fin and f2 and f2.fin and f1.payload .. f2.payload == "abcd")
    if love and love.data then
        eq("the RFC's handshake example", WSSERVER.accept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    end
    --addresses: plain ones get port 5229; on an https page (or asked to) a bare one is wss://
    eq("an address gets the port", WSLINK.url(" 192.168.1.20 ", false), "ws://192.168.1.20:5229")
    eq("a port given is kept", WSLINK.url("host.example.com:6000", false), "ws://host.example.com:6000")
    eq("a full address is kept", WSLINK.url("ws://1.2.3.4:5229", false), "ws://1.2.3.4:5229")
    eq("http:// is read as ws://", WSLINK.url("http://1.2.3.4:5229/", false), "ws://1.2.3.4:5229")
    eq("secure: a bare name is wss://, port 443", WSLINK.url("game.example.com", true), "wss://game.example.com")
    eq("secure: a path is kept", WSLINK.url("game.example.com/drakon", true), "wss://game.example.com/drakon")
    eq("https:// is read as wss://", WSLINK.url("https://game.example.com:8443/drakon", false), "wss://game.example.com:8443/drakon")
    eq("a wss:// address is kept", WSLINK.url("wss://game.example.com", false), "wss://game.example.com")
    eq("a ws:// address on a secure page is kept", WSLINK.url("ws://127.0.0.1:5229", true), "ws://127.0.0.1:5229")
    check("other kinds of address are explained", WSLINK.url("ftp://1.2.3.4", false) == nil)
    check("no address: explained", WSLINK.url("  ") == nil and select(2, WSLINK.url("")) ~= nil)
    local none, noWss = WSLINK.socket("wss://game.example.com")
    check("the desktop version explains it can't use wss://", none == nil and tostring(noWss):find("desktop version"))

    --a plain web request (a browser opening the address, a proxy's check): one line
    ---the status line and body of a response
    ---@param r string
    ---@return string|nil status
    ---@return string body
    local function split(r)
        local head, body = r:match("^(.-)\r\n\r\n(.*)$")
        head = head or ""
        return head:match("^HTTP/1%.1 (%d+)"), body
    end
    local status, body = split(WSSERVER.respond("GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
    check("a web request is answered with a line", status == "200" and body:find("Drakon game is hosted"))
    status, body = split(WSSERVER.respond("HEAD / HTTP/1.1\r\n\r\n"))
    check("HEAD: no body", status == "200" and body == "")
    eq("junk", (split(WSSERVER.respond("hello\r\n\r\n"))), "400")
end

---------------------------------------------------------------------------- a pretend network

local PASSWORD = "open sesame"

--sockets for joining players, wired to a pretend wsserver for the host: what one side
--sends, the other polls
---@return table net
local function newNetwork()
    local net = { conns = {}, nextId = 1, serverEvents = {}, down = false }
    net.server = {
        poll = function() local q = net.serverEvents; net.serverEvents = {}; return q end,
        send = function(_, id, text)
            local c = net.conns[id]
            if c and not c.closed then c.queue[#c.queue + 1] = { type = "message", data = text } end
        end,
        close = function(_, id)
            local c = net.conns[id]
            if not c or c.closed then return end
            c.closed = true
            c.queue[#c.queue + 1] = { type = "close", data = "closed by the host" }
            net.serverEvents[#net.serverEvents + 1] = { type = "close", id = id }
        end,
        shutdown = function()
            for id in pairs(net.conns) do net.server.close(nil, id) end
            net.down = true
        end,
    }
    ---a joining player's socket (as websocket.lua's), already connecting
    ---@return table
    function net.socket()
        local id = net.nextId
        net.nextId = id + 1
        local c = { queue = {}, closed = false }
        if net.down then
            c.queue[1] = { type = "close", data = "nobody is hosting" }
            c.closed = true
        else
            c.queue[1] = { type = "open" }
            net.serverEvents[#net.serverEvents + 1] = { type = "open", id = id }
        end
        net.conns[id] = c
        c.poll = function() local q = c.queue; c.queue = {}; return q end
        c.send = function(_, text)
            if not c.closed then net.serverEvents[#net.serverEvents + 1] = { type = "message", id = id, data = text } end
        end
        c.close = function()
            if c.closed then return end
            c.closed = true
            net.serverEvents[#net.serverEvents + 1] = { type = "close", id = id }
        end
        return c
    end
    return net
end

---------------------------------------------------------------------------- playing over the network

---@param list table
---@param item any
---@return integer|nil
local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
    return nil
end

---everything that matters about a game, to compare two copies
---@param s GAME.STATE
---@return string
local function fingerprint(s)
    local out = {}
    local cells = {}
    for x, y, t in s.board:each() do cells[#cells + 1] = ("%d,%d=%d"):format(x, y, t.kind) end
    table.sort(cells)
    out[#out + 1] = table.concat(cells, " ")
    for _, p in ipairs(s.players) do
        local hand = {}
        for _, t in ipairs(p.hand.tiles) do hand[#hand + 1] = t.kind end
        out[#out + 1] = ("%s %d/%d %s,%s [%s]"):format(p.name, p.unlockedGold, p.lockedGold, tostring(p.x),
            tostring(p.y), table.concat(hand, ","))
    end
    out[#out + 1] = ("deck %d active %s seed %s"):format(#s.deck, tostring(indexOf(s.players, s.activePlayer)),
        tostring((s.random --[[@as GAME.RNG]]).seed))
    return table.concat(out, " | ")
end

do
    local net = newNetwork()
    local link = assert(WSLINK.host(WSLINK.PORT, PASSWORD, net.server))
    local host = SESSION.Host:new(link, "Alice")
    local cfg = SETUP.defaultConfig()
    table.remove(cfg.players, 4)
    cfg.players[2].ai, cfg.players[2].remote = nil, true
    host:setLobby(cfg)

    ---a joining player, after a few updates each side
    ---@param name string
    ---@param password string
    ---@return SESSION.CLIENTSESSION
    local function tryJoin(name, password)
        local c = SESSION.Client:new(assert(WSLINK.join("host", password, net.socket())), name)
        for _ = 1, 4 do c:update(); host:update() end
        return c
    end
    ---why a joining player was turned away
    ---@param c SESSION.CLIENTSESSION
    ---@return string|nil
    local function reason(c)
        for _, e in ipairs(SESSION.takeEvents(c)) do if e.type == "closed" then return e.text end end
    end

    local eve = tryJoin("Eve", "guess")
    eq("a wrong password is refused", eve.status, "closed")
    eq("with the host's reason", reason(eve), "Wrong password")
    eq("and the host doesn't count her", #host:names(), 0)

    local old = SESSION.Client:new(assert(WSLINK.join("host", PASSWORD, net.socket())), "Old")
    old.transport.ws.send = function(_, text) net.serverEvents[#net.serverEvents + 1] = { type = "message", id = 2, data = text:gsub("drakon%-ws%-1", "drakon-ws-0") } end
    for _ = 1, 4 do old:update(); host:update() end
    check("another version is refused", (reason(old) or ""):find("different version"))

    local bob = tryJoin("Bob", PASSWORD)
    ---let messages go back and forth
    local function pump()
        for _ = 1, 6 do host:update(); bob:update() end
    end
    pump()
    eq("bob joins with the password", bob.status, "lobby")
    eq("bob has the network seat", cfg.players[2].name, "Bob")

    local state = GAME.newGame(SETUP.copy(cfg), GAME.newRandom(77))
    host:startGame(state)
    pump()
    eq("bob gets the game", bob.state and fingerprint(bob.state), fingerprint(state))

    --play: bob's turns over the network, the rest on the host
    local same, bobTurns = true, 0
    for _ = 1, 40 do
        if GAME.isOver(state) then break end
        local p = state.activePlayer --[[@as GAME.PLAYER]]
        if p.config.peer == bob.id then
            bobTurns = bobTurns + 1
            local s = bob.state --[[@as GAME.STATE]]
            ---carried out here and sent, as the game screen does
            ---@param op string
            ---@param ... any
            local function act(op, ...)
                local action = ACTIONS.encode(s, op, ...)
                if GAME[op](s, ...) then bob:sendAction(action, "Bob did " .. op) end
            end
            for _, t in ipairs((s.activePlayer --[[@as GAME.PLAYER]]).hand.tiles) do
                local opts = GAME.legalPlacements(s, t)
                if GAME.canPlaceTile(s) and #opts > 0 then
                    t:rotate(opts[1].turns)
                    act("placeTile", t, opts[1].x, opts[1].y)
                    break
                end
            end
            if GAME.canKnightReclaim(s) then act("knightDecline") end
            act("endTurn")
            if (s.activePlayer and s.activePlayer.config.peer == bob.id) and GAME.canEndTurn(s) then act("endTurn") end
        else
            host:changed(AI.act(state, p.config.ai or "greedy"))
        end
        pump()
        if fingerprint(bob.state --[[@as GAME.STATE]]) ~= fingerprint(state) then same = false; break end
    end
    check("bob played over the network", bobTurns >= 3, bobTurns)
    check("the copies stayed the same", same)

    --bob's connection drops: a computer keeps his seat
    bob.transport:close()
    pump()
    eq("a computer keeps bob's seat", state.players[2].config.ai, "greedy")

    --the host stops: everyone joined is told
    local cat = tryJoin("Cat", PASSWORD)
    for _ = 1, 4 do host:update(); cat:update() end
    eq("cat joins to watch", cat.status, "game")
    host:close()
    for _ = 1, 3 do cat:update() end
    eq("the host stopping ends cat's game", cat.status, "closed")
    eq("with the reason", reason(cat), "The host stopped the network game.")

    local late = SESSION.Client:new(assert(WSLINK.join("host", PASSWORD, net.socket())), "Late")
    late:update()
    check("nobody hosting: can't reach the host", (reason(late) or ""):find("Could not reach the host"))
end

---------------------------------------------------------------------------- the web build's bridge

--love.js.eval (2dengine's love.js) running wasm/drakonnet.js, pretended in Lua over the
--pretend network: the calls webbridge.lua makes are read back from the JavaScript it writes
do
    local net = newNetwork()
    local realLove = _G.love   --(nil in plain Lua; LÖVE's own when run inside it)
    local sockets, nextId, clock, calls, protocol = {}, 1, 0, {}, "http:"
    ---a JavaScript string literal back to text
    ---@param js string
    ---@return string
    local function unquote(js)
        return (js:sub(2, -2):gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end
    _G.love = {
        system = { getOS = function() return "Web" end },
        timer = { getTime = function() clock = clock + 1; return clock end },
        js = {
            ---@param js string
            ---@return string
            eval = function(js)
                calls[#calls + 1] = js
                if js == "location.protocol" then return protocol end
                local url = js:match("^DrakonNet%.open%(('.*')%)$")
                if url then
                    local id = nextId
                    nextId = id + 1
                    sockets[id] = net.socket()
                    sockets[id].url = unquote(url)
                    return tostring(id)
                end
                local id, text = js:match("^DrakonNet%.send%((%d+),('.*')%)$")
                if id then sockets[tonumber(id)].send(nil, unquote(text)); return "" end
                id = js:match("^DrakonNet%.poll%((%d+)%)$")
                if id then
                    local lines = {}
                    for _, ev in ipairs(sockets[tonumber(id)].poll()) do
                        lines[#lines + 1] = ev.type == "open" and "o" or ev.type == "message" and ("m " .. ev.data)
                            or ("c " .. tostring(ev.data))
                    end
                    return table.concat(lines, "\n")
                end
                id = js:match("^DrakonNet%.close%((%d+)%)$")
                if id then sockets[tonumber(id)].close(); return "" end
                return ""
            end,
        },
    }
    check("the web build is recognised", WSLINK.isWeb() and WEBBRIDGE.available())
    local link = assert(WSLINK.host(WSLINK.PORT, PASSWORD, net.server))   --(the host: a desktop game)
    local host = SESSION.Host:new(link, "Alice")
    local cfg = SETUP.defaultConfig()
    table.remove(cfg.players, 4)
    cfg.players[2].ai, cfg.players[2].remote = nil, true
    host:setLobby(cfg)

    local bob = SESSION.Client:new(assert(WSLINK.join("192.168.1.20", PASSWORD)), "Web Bob")
    eq("joining opens a socket through the page", sockets[1] and sockets[1].url, "ws://192.168.1.20:5229")
    for _ = 1, 8 do host:update(); bob:update() end
    eq("the web version joins a desktop host", bob.status, "lobby")
    local state = GAME.newGame(SETUP.copy(cfg), GAME.newRandom(5))
    host:startGame(state)
    for _ = 1, 8 do host:update(); bob:update() end
    eq("the game crosses the page (base64, quoted)", bob.state and fingerprint(bob.state), fingerprint(state))
    bob:say("it's \"quoted\"\\ and fine")
    for _ = 1, 8 do host:update(); bob:update() end
    eq("chat with quotes and backslashes crosses", host.chat[#host.chat], "Web Bob: it's \"quoted\"\\ and fine")
    local plain = true
    for _, js in ipairs(calls) do
        if js:find("[\r\n]") then plain = false end
    end
    check("every call into JavaScript is one plain line", plain)

    --a page served over https can't open ws:// to another computer: said plainly
    --on an https page (GitHub Pages): a bare address is the host's secure one (wss://, behind
    --their proxy); a plain ws:// one is refused and explained (browsers would block it)
    protocol = "https:"
    local before = nextId
    local secure = WSLINK.join("game.example.com", PASSWORD)
    check("https page: joins the secure address", secure ~= nil and sockets[before] and sockets[before].url == "wss://game.example.com")
    local refused, why = WSLINK.join("ws://192.168.1.20:5229", PASSWORD)
    check("https page: a plain ws:// address is explained", refused == nil and tostring(why):find("secure address"))
    check("https page: this computer's plain address is allowed", WSLINK.join("ws://127.0.0.1:5229", PASSWORD) ~= nil)
    host:close()
    _G.love = realLove
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
