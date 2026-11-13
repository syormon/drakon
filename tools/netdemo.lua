--network play end to end, in one process: a host (with a password) and a joined player
--talk over WebSockets on this computer (the host's game listens, as when hosting for real),
--through the real setup and game screens (clicks and keys), with the host's computer player
--in between. Checks the two copies of the game never differ, then that a player who drops
--out gets their seat back. Pictures go to the save folder.
--love . --run tools/netdemo.lua

local m = ...
local GAME, SETUP, SETUPVIEW, GAMEVIEW = m.game, m.setup, m.setupview, m.gameview
local SESSION = require('src.session')
local WSLINK = require('src.wslink')
local AI = require('src.ai')
local TOP = 40
local PORT = 52291   --(not the usual 5229, in case a real game is hosted)
local PASSWORD = "open sesame"

local failures = 0
---print a check and count failures
---@param name string
---@param cond any
local function check(name, cond)
    print((cond and "ok    " or "FAIL  ") .. name)
    if not cond then failures = failures + 1 end
end

local canvas = love.graphics.newCanvas(love.graphics.getDimensions())
---draw a view to the canvas (which also lays it out for clicks), and save it if named
---@param v SETUPVIEW|GAMEVIEW|JOINVIEW
---@param save? string
local function render(v, save)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.11, 0.10, 0.09)
    v:draw(TOP)
    love.graphics.setCanvas()
    if save then canvas:newImageData():encode("png", "net_" .. save .. ".png") end
end

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
        out[#out + 1] = ("%s %d/%d %s,%s [%s]"):format(p.name, p.unlockedGold, p.lockedGold, tostring(p.x), tostring(p.y),
            table.concat(hand, ","))
    end
    out[#out + 1] = ("deck %d turn %s active %s n%d seed %s"):format(#s.deck, tostring(indexOf(s.players, s.turnPlayer)),
        tostring(indexOf(s.players, s.activePlayer)), s.turnNumber, tostring((s.random --[[@as GAME.RNG]]).seed))
    return table.concat(out, " | ")
end

---------------------------------------------------------------------------- the join and host screens

do
    local JOINVIEW = require('src.joinview')
    local jv = JOINVIEW:new("Bob")
    jv.fields.name.text, jv.fields.address.text = "Bob", ""
    jv:connect()
    check("join screen asks for the address", jv.request == nil and jv.message and jv.message.error)
    jv.focus = "address"
    for ch in ("192.168.1.20"):gmatch(".") do jv:textinput(ch) end
    jv.focus = "password"
    for ch in (PASSWORD):gmatch(".") do jv:textinput(ch) end
    local t = jv:target()
    check("join screen reads name, address and password", t and t.mode == "join" and t.name == "Bob"
        and t.address == "192.168.1.20" and t.password == PASSWORD)
    render(jv, "join")
    local hj = JOINVIEW:new("Alice", true)
    hj.fields.password.text = PASSWORD
    local ht = hj:target()
    check("host screen reads the password", ht and ht.mode == "host" and ht.password == PASSWORD)
    render(hj, "host")
end

---------------------------------------------------------------------------- connecting

local hostLink, err = WSLINK.host(PORT, PASSWORD)
check("hosting on port " .. PORT, hostLink)
if not hostLink then print(err); error("cannot host") end
local host = SESSION.Host:new(hostLink, "Alice")
host.port = PORT
local hv = SETUPVIEW:new(SETUP.defaultConfig(), false, host)
hv.address = WSLINK.localAddress()
print("      this computer's address: " .. tostring(hv.address))
check("a second host can't take the same port", WSLINK.host(PORT, PASSWORD) == nil)
local p = hv.cfg.players
table.remove(p, 4)                  --Alice (here), Bram (network), Cora (computer)
p[2].ai, p[2].remote = nil, true
host:setLobby(hv.cfg)

local bob, bv, bobView
local rejected = 0
---the joined player's screen follows the network, as main.lua does
local function followBob()
    for _, ev in ipairs(SESSION.takeEvents(bob)) do
        if ev.type == "lobby" then bv = bv or SETUPVIEW:new(bob.cfg, false, bob); bv.cfg = bob.cfg
        elseif ev.type == "game" then
            if ev.fresh or not bobView then bobView = GAMEVIEW:new(bob.state, bob)
            else bobView:replaceState(bob.state) end
        elseif ev.type == "rejected" then
            rejected = rejected + 1
            print("      rejected: " .. tostring(ev.text))
        end
    end
end
---let the network run until `cond` holds (or a few seconds pass)
---@param cond fun():any
---@param seconds? number
---@return any
local function waitFor(cond, seconds)
    local t0 = love.timer.getTime()
    repeat
        host:update()
        if bob then bob:update(); followBob() end
        if cond() then return cond() end
        love.timer.sleep(0.003)
    until love.timer.getTime() - t0 > (seconds or 5)
    return cond()
end
---let messages settle
local function settle() waitFor(function() return false end, 0.08) end

---a connection to the host, on this computer
---@param password? string
---@return table
local function joinLink(password)
    return assert(WSLINK.join("127.0.0.1:" .. PORT, password or PASSWORD))
end

do
    --a wrong password is refused, and said so
    local wrong = SESSION.Client:new(joinLink(PASSWORD .. "x"), "Eve")
    local why
    local t0 = love.timer.getTime()
    repeat
        wrong:update()
        host:update()
        for _, e in ipairs(SESSION.takeEvents(wrong)) do if e.type == "closed" then why = e.text end end
        love.timer.sleep(0.01)
    until why or love.timer.getTime() - t0 > 5
    check("a wrong password is refused and explained", why == "Wrong password")
    check("and she isn't seated", #host:names() == 0 and not p[2].peer)
    --a host that isn't there is reported
    local nobody = SESSION.Client:new(assert(WSLINK.join("127.0.0.1:1", PASSWORD)), "Nobody")
    local gone
    t0 = love.timer.getTime()
    repeat
        nobody:update()
        for _, e in ipairs(SESSION.takeEvents(nobody)) do if e.type == "closed" then gone = e.text end end
        love.timer.sleep(0.01)
    until gone or love.timer.getTime() - t0 > 15
    check("an address where nobody hosts is reported", gone and gone:find("Could not reach the host"))
    print(("      (after %.1f s: %s)"):format(love.timer.getTime() - t0, tostring(gone)))
end
bob = SESSION.Client:new(joinLink(), "Bob")
check("bob connects", waitFor(function() return bob.status == "lobby" and bv end))
check("bob takes the network seat", p[2].peer == bob.id and p[2].name == "Bob")
check("bob's initial follows his name", p[2].initial == "B")
check("bob sees the host's setup", bv and #bv.cfg.players == 3 and bv.cfg.players[2].name == "Bob")

---click a hit area of the setup screen (as drawn now)
---@param v SETUPVIEW
---@param kind string
---@param i? integer
---@param part? string
---@return boolean
local function click(v, kind, i, part)
    render(v)
    for _, h in ipairs(v.hits) do
        if h.kind == kind and h.i == i and (part == nil or h.part == part) then
            v:mousepressed(h.x + math.floor(h.w / 2), h.y + math.floor(h.h / 2), 1)
            return true
        end
    end
    return false
end

--bob changes his hero from his screen; he can't change Alice or the rules
local hero = p[2].hero
click(bv, "hero", 2, "next")
check("bob's hero changes on the host", waitFor(function() return p[2].hero ~= hero end))
check("bob sees his new hero", waitFor(function() return bv.cfg.players[2].hero == p[2].hero end))
click(bv, "name", 1, "type")
check("bob can't rename alice", bv.message and bv.message.error and p[1].name == "Alice")
click(bv, "option", 1)
check("bob can't change the rules", bv.message and bv.message.error)
--chat both ways
bv:keypressed("tab")
for ch in ("good luck"):gmatch(".") do bv:textinput(ch) end
bv:keypressed("return")
check("bob's chat reaches the host", waitFor(function() return host.chat[#host.chat] == "Bob: good luck" end))
host:say("you too")
check("the host's chat reaches bob", waitFor(function() return bob.chat[#bob.chat] == "Alice: you too" end))
render(hv, "host_setup")
render(bv, "client_setup")

---------------------------------------------------------------------------- playing

hv:start()
check("the host can start", hv.started)
local state = GAME.newGame(SETUP.copy(hv.started), GAME.newRandom(4242))
local hostView = GAMEVIEW:new(state, host)
host:startGame(state)
check("bob gets the game", waitFor(function() return bobView end))
check("bob's game is the host's", bobView and fingerprint(bobView.state) == fingerprint(state))

---play the active player's turn through a game screen, with clicks and keys: place a tile
---if one fits, move if possible, then Enter (again if a choice is waiting)
---@param view GAMEVIEW
local function playTurn(view)
    local s = view.state
    local me = s.activePlayer --[[@as GAME.PLAYER]]
    render(view)
    for _, r in ipairs(view.handRects) do
        local opts = GAME.legalPlacements(s, r.tile)
        if #opts > 0 then
            view:mousepressed(r.x + 4, r.y + 4, 1)
            for _ = 1, opts[1].turns do view:keypressed("r") end
            render(view)
            local sx, sy = view:toScreen(opts[1].x, opts[1].y)
            view:mousepressed(sx + 6, sy + 6, 1)
            break
        end
    end
    s = view.state
    if s.activePlayer == me and not GAME.openChoice(s) and not GAME.mustPlaceDrakon(s) then
        local moves = GAME.legalMoves(s)
        if #moves > 0 then
            render(view)
            local sx, sy = view:toScreen(moves[1].x, moves[1].y)
            view:mousepressed(sx + 6, sy + 6, 1)
        end
    end
    for _ = 1, 4 do
        s = view.state
        if s.activePlayer ~= me or GAME.isOver(s) then break end
        if GAME.mustPlaceDrakon(s) and not s.drakonActive then
            --Drakon's first room can't be skipped: put him in one
            local sq = GAME.legalDrakonMoves(s)[1]
            if sq then
                render(view)
                local sx, sy = view:toScreen(sq[1], sq[2])
                view:mousepressed(sx + 6, sy + 6, 1)
            end
        else
            view:keypressed("return")
        end
    end
    s = view.state
    if s.activePlayer == me and not GAME.isOver(s) then
        local hints = {}
        for _, h in ipairs(view:hints()) do hints[#hints + 1] = h[2] end
        print(("      %s's turn didn't end: %s / %s"):format(me.name, view.message and view.message.text or "",
            table.concat(hints, "; ")))
    end
end

local turns, bobTurns, hostTurns, same = 0, 0, 0, true
while not GAME.isOver(state) and turns < 45 do
    turns = turns + 1
    local active = state.activePlayer
    if host:controls(active) then
        hostTurns = hostTurns + 1
        playTurn(hostView)
    elseif AI.levelOf(active) then
        hostView:update(1)              --the computer player, after its pause
    else
        bobTurns = bobTurns + 1
        waitFor(function() return bobView.state.activePlayer.config.peer == bob.id end)
        playTurn(bobView)
    end
    waitFor(function() return fingerprint(bobView.state) == fingerprint(state) end, 2)
    settle()
    if fingerprint(bobView.state) ~= fingerprint(state) then
        same = false
        print("      host: " .. fingerprint(state))
        print("      bob:  " .. fingerprint(bobView.state))
        break
    end
end
print(("      %d turns: %d by Bob over the network, %d by Alice on the host"):format(turns, bobTurns, hostTurns))
check("bob and alice both played", bobTurns >= 3 and hostTurns >= 3)
check("turns took turns (alice and bob about even)", math.abs(bobTurns - hostTurns) <= 2)
check("the two copies never differed", same)
check("the host accepted all of bob's actions", rejected == 0)
local bobLines = 0
for _, line in ipairs(bob.log) do if line:find("^Bob") then bobLines = bobLines + 1 end end
check("bob's own actions are in the shared log", bobLines > 0)
render(hostView, "host_game")
render(bobView, "client_game")

---------------------------------------------------------------------------- dropping out

if not GAME.isOver(state) then
    local seat = state.players[2]
    bob:close()
    bob = nil
    check("the host sees bob go", waitFor(function() return seat.config.ai == "greedy" end))
    check("a computer keeps bob's seat", seat.config.dropped == "Bob")
    bob, bobView = SESSION.Client:new(joinLink(), "Bob"), nil
    check("bob comes back", waitFor(function() return bobView end))
    check("bob has his seat again", seat.config.peer == bob.id and not seat.config.ai)
    check("bob's game is the host's again", bobView and fingerprint(bobView.state) == fingerprint(state))
    check("bob plays his seat again", bobView and bobView:controls(bobView.state.players[2]))
end

host:close()
bob:close()
print(failures == 0 and "all network checks passed" or (failures .. " network checks FAILED"))
if failures > 0 then error("network checks failed") end
