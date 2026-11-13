--tests for network play: serial.lua, actions.lua and session.lua, over a pretend network
--(queues in memory). Runs under plain Lua, from the repository's top folder:
--lua tests/test_session.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local GAME = require('src.game')
local SETUP = require('src.setup')
local AI = require('src.ai')
local SERIAL = require('src.serial')
local ACTIONS = require('src.actions')
local SESSION = require('src.session')

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

---@param list table
---@param item any
---@return integer|nil
local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
    return nil
end

---everything that matters about a game, as text, to compare two copies
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
        out[#out + 1] = ("%s g%d/%d at %s,%s hand %s limit %d used %s skip %s ai %s"):format(p.name, p.unlockedGold, p.lockedGold,
            tostring(p.x), tostring(p.y), table.concat(hand, ","), p.hand.tileLimit, tostring(p.usedHero),
            tostring(p.skipTurn), tostring(p.config.ai))
    end
    local deck = {}
    for _, t in ipairs(s.deck) do deck[#deck + 1] = t.kind end
    out[#out + 1] = "deck " .. table.concat(deck, ",")
    out[#out + 1] = ("turn %s active %s n%d moved %s placed %s drakon %s %s,%s start %d seed %s effect %s"):format(
        tostring(indexOf(s.players, s.turnPlayer)), tostring(indexOf(s.players, s.activePlayer)), s.turnNumber,
        tostring(s.moved), tostring(s.placedTile), tostring(s.drakonActive), tostring(s.drakonX), tostring(s.drakonY),
        s.goldOnStart, tostring(type(s.random) == "table" and (s.random --[[@as GAME.RNG]]).seed), tostring(s.tileEffect))
    local undo, snap = 0, s.savedState
    while snap do undo, snap = undo + 1, snap.savedState end
    out[#out + 1] = "undo " .. undo
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------- serial

do
    local CL = SESSION.CLASSES
    local shared = { 1 }
    local v = { a = 1, b = -2.5, c = "x\0y;}{", d = true, e = false, f = { shared, shared }, [3] = "three",
                big = 2 ^ 40, tiny = 1e-7, inf = math.huge }
    v.self = v
    local back = SERIAL.decode(SERIAL.encode(v, CL), CL)
    eq("serial number", back.a, 1)
    eq("serial float", back.b, -2.5)
    eq("serial string with odd bytes", back.c, "x\0y;}{")
    eq("serial true", back.d, true)
    eq("serial false", back.e, false)
    eq("serial shared table stays shared", back.f[1], back.f[2])
    eq("serial cycle", back.self, back)
    eq("serial number key", back[3], "three")
    eq("serial big", back.big, 2 ^ 40)
    eq("serial tiny", back.tiny, 1e-7)
    eq("serial inf", back.inf, math.huge)
    check("serial refuses functions", not pcall(SERIAL.encode, { f = print }))
    check("serial refuses unknown classes", not pcall(SERIAL.encode, setmetatable({}, {})))
    --never runs text, and fails cleanly on junk
    for _, junk in ipairs({ "", "drakon1:", "drakon1:{;", "drakon1:s99:ab", "drakon1:r5;", "drakon1:n1e;",
                            "drakon1:{Nope;}", "drakon1:n1;n2;", "drakon1:x", "hello", "drakon1:{;n1;}" }) do
        local ok, val, err = pcall(SERIAL.decode, junk, CL)
        check("serial junk " .. junk .. " fails cleanly", ok and val == nil and type(err) == "string", tostring(val))
    end
end

---------------------------------------------------------------------------- the random generator

do
    local a, b = GAME.newRandom(12345), GAME.newRandom(12345)
    local same = true
    for _ = 1, 200 do if a(1, 6) ~= b(1, 6) then same = false end end
    check("rng repeatable", same)
    local seen = {}
    for _ = 1, 600 do seen[a(1, 6)] = true end
    check("rng covers 1-6", seen[1] and seen[2] and seen[3] and seen[4] and seen[5] and seen[6] and not seen[0] and not seen[7])
    local c = SERIAL.decode(SERIAL.encode(a, SESSION.CLASSES), SESSION.CLASSES)
    eq("rng carries on after sending", c(1, 1000000), a(1, 1000000))
    eq("rng seed 0 moved", (GAME.newRandom(0) --[[@as GAME.RNG]]).seed, 1)
end

---------------------------------------------------------------------------- a game sent over

---a game of computer players with the state-held random generator
---@param seed integer
---@return GAME.STATE
local function aiGame(seed)
    local cfg = GAME.newConfig()
    for i, h in ipairs({ GAME.Hero.Knight, GAME.Hero.Thief, GAME.Hero.Barbarian, GAME.Hero.Wizard }) do
        local pc = GAME.addPlayer(cfg, "P" .. i)
        pc.ai, pc.hero = (i % 2 == 0) and "random" or "greedy", h
    end
    return GAME.newGame(cfg, GAME.newRandom(seed))
end

do
    for seed = 1, 4 do
        local s = aiGame(seed * 7919)
        for _ = 1, 15 do if not GAME.isOver(s) then AI.act(s) end end
        local copy = SESSION.unpack(SESSION.pack({ state = s })).state
        eq("game sent over is the same (seed " .. seed .. ")", fingerprint(copy), fingerprint(s))
        check("shared hands stay shared", copy.players[1].hand ~= copy.players[2].hand
            and copy.players[1].config.team ~= nil)
        --(the AI isn't run on both copies to compare: it goes through tables with pairs, whose
        --order differs between copies; only the host runs computer players)
    end
end

---------------------------------------------------------------------------- actions

do
    local s = aiGame(99)
    local copy = SESSION.unpack(SESSION.pack({ state = s })).state
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    local tile = p.hand.tiles[1]
    tile:rotate(1)
    local opts = GAME.legalPlacements(s, tile)
    check("a placement exists", #opts > 0)
    local o = opts[1]
    tile:rotate(o.turns)
    local action = ACTIONS.encode(s, "placeTile", tile, o.x, o.y)
    local direct = GAME.placeTile(s, tile, o.x, o.y)
    check("placed directly", direct)
    local sent = SESSION.unpack(SESSION.pack({ a = action })).a
    local r, err = ACTIONS.apply(copy, sent)
    check("placed by action", r, err)
    eq("same game after a placement", fingerprint(copy), fingerprint(s))
    --a move, then finishing the turn
    local moves = GAME.legalMoves(s)
    if #moves > 0 then
        local m = moves[#moves]
        local a2 = ACTIONS.encode(s, "movePlayer", m.x, m.y)
        GAME.movePlayer(s, m.x, m.y)
        ACTIONS.apply(copy, a2)
    end
    local a3 = ACTIONS.encode(s, "endTurn")
    GAME.endTurn(s, true)
    ACTIONS.apply(copy, a3)
    eq("same game after moving and finishing", fingerprint(copy), fingerprint(s))
    --bad actions are refused, not crashes
    for _, bad in ipairs({ 5, {}, { op = "explode", args = {} }, { op = "placeTile", args = { "x", 1, 1 } },
                           { op = "placeTile", args = { { "tile", 99, 0 }, 1, 1 } },
                           { op = "placeTile", args = { { "tile", 1, 1023 }, 1, 1 } },
                           { op = "movePlayer", args = { 1.5, 0 } }, { op = "mapSteal", args = { { "player", 9 } } } }) do
        local ok, res, e = pcall(ACTIONS.apply, copy, bad)
        check("bad action refused cleanly", ok and res == nil and type(e) == "string", tostring(res))
    end
    --a tile sent as a different chamber is refused
    local t1 = copy.activePlayer.hand.tiles[1]
    local other = (t1.kind % 32 == 1) and 2 or 1
    local ok, res = pcall(ACTIONS.apply, copy, { op = "placeTile", args = { { "tile", 1, other }, 1, 0 } })
    check("a different chamber is refused", ok and res == nil)
end

---------------------------------------------------------------------------- the pretend network

---a network in memory: a host transport and a way to join it
---@return table net
local function newNetwork()
    local net = { hostQ = {}, clientQ = {}, nextId = 1, open = {} }
    net.host = {
        poll = function() local q = net.hostQ; net.hostQ = {}; return q end,
        send = function(_, id, text)
            if net.open[id] then table.insert(net.clientQ[id], { kind = "receive", data = text }) end
        end,
        drop = function(_, id)
            if net.open[id] then
                net.open[id] = nil
                table.insert(net.clientQ[id], { kind = "disconnect" })
                table.insert(net.hostQ, { kind = "disconnect", id = id })
            end
        end,
        close = function()
            for id in pairs(net.open) do table.insert(net.clientQ[id], { kind = "disconnect" }) end
            net.open = {}
        end,
    }
    ---a client transport, already connecting
    ---@return table
    function net.join()
        local id = net.nextId
        net.nextId = id + 1
        net.open[id], net.clientQ[id] = true, { { kind = "connect" } }
        table.insert(net.hostQ, { kind = "connect", id = id })
        return {
            id = id,
            poll = function() local q = net.clientQ[id]; net.clientQ[id] = {}; return q end,
            send = function(_, text)
                if net.open[id] then table.insert(net.hostQ, { kind = "receive", id = id, data = text }) end
            end,
            close = function()
                if net.open[id] then
                    net.open[id] = nil
                    table.insert(net.hostQ, { kind = "disconnect", id = id })
                end
            end,
        }
    end
    return net
end

---let messages go back and forth until all is quiet
---@param host SESSION.HOST
---@param clients SESSION.CLIENTSESSION[]
local function pump(host, clients)
    for _ = 1, 10 do
        host:update()
        for _, c in ipairs(clients) do c:update() end
    end
end

---@param list SESSION.EVENT[]
---@param kind string
---@return SESSION.EVENT|nil
local function findEvent(list, kind)
    for _, e in ipairs(list) do if e.type == kind then return e end end
end

---the joined player's action, as the game screen does it: carried out here and sent
---@param c SESSION.CLIENTSESSION
---@param op string
---@param ... any
---@return any
local function clientDo(c, op, ...)
    local action = ACTIONS.encode(c.state, op, ...)
    local r = GAME[op](c.state, ...)
    if r then c:sendAction(action, c.name .. " did " .. op) end
    return r
end

---the active player's whole action, one call at a time, done by `c` (a joined player)
---@param c SESSION.CLIENTSESSION
local function clientTurn(c)
    local s = c.state --[[@as GAME.STATE]]
    local p = s.activePlayer --[[@as GAME.PLAYER]]
    if GAME.canPlaceTile(s) then
        for _, t in ipairs(p.hand.tiles) do
            local opts = GAME.legalPlacements(s, t)
            if #opts > 0 then
                t:rotate(opts[1].turns)
                clientDo(c, "placeTile", t, opts[1].x, opts[1].y)
                break
            end
        end
    end
    --(a chamber choice or Drakon isn't tried here: finishing passes them by)
    local moves = GAME.legalMoves(s)
    if #moves > 0 and not GAME.openChoice(s) and not GAME.mustPlaceDrakon(s) then
        clientDo(c, "movePlayer", moves[1].x, moves[1].y)
    end
    if GAME.canKnightReclaim(s) then clientDo(c, "knightDecline") end
    clientDo(c, "endTurn")
end

---------------------------------------------------------------------------- hosting and joining

do
    local net = newNetwork()
    local host = SESSION.Host:new(net.host, "Alice")
    local cfg = GAME.newConfig()
    local alice = GAME.addPlayer(cfg, "Alice")
    alice.hero = GAME.Hero.Knight
    local open = SETUP.addPlayer(cfg)
    SETUP.cycleControl(open, -1, true)   --person -> network (the last choice)
    check("network seat chosen", open.remote and not open.ai)
    eq("network seat named open", SETUP.controlName(open.ai, open.remote, open.peer ~= nil), "Network (open)")
    local robot = SETUP.addPlayer(cfg, "greedy")
    robot.hero = GAME.Hero.Dwarf
    eq("open seat stops the start", SETUP.seatProblem(cfg, true), "Waiting for someone to join for " .. open.name)
    check("network seats need hosting", SETUP.seatProblem(cfg, false))
    host:setLobby(cfg)

    local bob = SESSION.Client:new(net.join(), "Bob")
    pump(host, { bob })
    eq("bob welcomed", bob.status, "lobby")
    eq("bob given the open seat", open.peer, bob.id)
    eq("seat renamed for bob", open.name, "Bob")
    check("bob sees the setup", bob.cfg and #bob.cfg.players == 3)
    eq("bob sees himself on the seat", bob.cfg.players[2].peer, bob.id)
    eq("nothing stops the start now", SETUP.seatProblem(cfg, true), nil)
    check("host told bob joined", findEvent(SESSION.takeEvents(host), "joined"))

    --bob changes his hero
    local before = open.hero
    bob:askSeat("hero", 1)
    pump(host, { bob })
    check("bob changed his hero", open.hero ~= before)
    eq("bob sees his new hero", bob.cfg.players[2].hero, open.hero)

    --a player who finds no seat, then another joining a full setup
    local cara = SESSION.Client:new(net.join(), "Bob")   --same name as bob
    pump(host, { bob, cara })
    eq("second joiner renamed", cara.name, "Bob 2")
    eq("a fourth seat added for her", #cfg.players, 4)
    eq("new seat is a network seat", cfg.players[4].remote, true)

    --chat
    bob:say("hello   there\n")
    pump(host, { bob, cara })
    eq("host has the chat", host.chat[#host.chat], "Bob: hello   there")
    eq("cara has the chat", cara.chat[#cara.chat], "Bob: hello   there")
    host:say("hi")
    pump(host, { bob, cara })
    eq("bob has the host's chat", bob.chat[#bob.chat], "Alice: hi")

    --cara leaves the setup: her seat is open again
    cara:close()
    pump(host, { bob })
    eq("cara's seat open again", cfg.players[4].peer, nil)
    SETUP.removePlayer(cfg, 4)
    host:setLobby(cfg)
    pump(host, { bob })
    eq("bob sees the seat gone", #bob.cfg.players, 3)

    --the game starts
    local state = GAME.newGame(SETUP.copy(cfg), GAME.newRandom(2024))
    host:startGame(state)
    pump(host, { bob })
    eq("bob is in the game", bob.status, "game")
    eq("bob has the same game", fingerprint(bob.state), fingerprint(state))
    check("bob controls his seat", bob:controls(bob.state.players[2]))
    check("bob doesn't control alice", not bob:controls(bob.state.players[1]))
    check("host controls alice", host:controls(state.players[1]))
    check("host doesn't control bob's seat", not host:controls(state.players[2]))
    check("host doesn't control the computer", not host:controls(state.players[3]))

    --out of turn: refused, and bob is put right
    local bobSeat = bob.state.players[2]
    if bob.state.activePlayer ~= bobSeat then
        bob:sendAction({ op = "endTurn", args = {} }, "sneaky")
        pump(host, { bob })
        check("out-of-turn action refused", findEvent(SESSION.takeEvents(bob), "rejected"))
        eq("bob still has the host's game", fingerprint(bob.state), fingerprint(state))
    end

    --play: alice and the computer on the host, bob over the network
    local rounds, bobTurns, same = 0, 0, true
    while not GAME.isOver(state) and rounds < 60 do
        rounds = rounds + 1
        local p = state.activePlayer --[[@as GAME.PLAYER]]
        if p.config.peer == bob.id then
            bobTurns = bobTurns + 1
            clientTurn(bob)
            pump(host, { bob })
        else
            local lines = AI.act(state, p.config.ai or "greedy")
            host:changed(lines)
            pump(host, { bob })
        end
        if fingerprint(bob.state) ~= fingerprint(state) then same = false; break end
    end
    check("bob played turns", bobTurns > 3, bobTurns)
    check("host and bob kept the same game throughout", same)
    check("bob's actions are in the shared log", (function()
        for _, l in ipairs(bob.log) do if l:find("Bob did") then return true end end
    end)())

    --bob drops out: a computer takes his seat; he comes back and has it again
    if not GAME.isOver(state) then
        bob:close()
        pump(host, {})
        local seat = state.players[2]
        eq("dropped seat played by a computer", seat.config.ai, "greedy")
        eq("dropped seat remembers bob", seat.config.dropped, "Bob")
        local bob2 = SESSION.Client:new(net.join(), "Bob")
        pump(host, { bob2 })
        eq("bob back in the game", bob2.status, "game")
        eq("bob has his seat back", seat.config.peer, bob2.id)
        eq("no computer on his seat", seat.config.ai, nil)
        check("bob controls his seat again", bob2:controls(bob2.state.players[2]))
        eq("bob back with the same game", fingerprint(bob2.state), fingerprint(state))
        local watcher = SESSION.Client:new(net.join(), "Dan")
        pump(host, { bob2, watcher })
        eq("latecomer watches", watcher.status, "game")
        check("watcher controls nobody", not watcher:controls(watcher.state.activePlayer))
    end

    --the host stops
    host:close()
    pump(host, { bob })
end

---------------------------------------------------------------------------- network seats in the setup

do
    local cfg = SETUP.defaultConfig()
    local pc = cfg.players[1]
    for _ = 1, 3 do SETUP.cycleControl(pc, 1) end
    check("network isn't offered unless hosting", not pc.remote)
    SETUP.cycleControl(pc, -1, true)
    check("network offered when hosting", pc.remote and not pc.ai)
    pc.peer = 7
    local back = assert(SETUP.parse(SETUP.serialize(cfg)))
    check("a saved setup keeps network seats", back.players[1].remote and not back.players[1].ai)
    eq("but not who was connected", back.players[1].peer, nil)
    SETUP.cycleControl(pc, 1, true)
    check("stepping off network clears the seat", not pc.remote and pc.peer == nil)
end

---------------------------------------------------------------------------- versions

do
    local net = newNetwork()
    local host = SESSION.Host:new(net.host)
    host:setLobby(GAME.newConfig())
    local t = net.join()
    t:send(SESSION.pack({ t = "hello", protocol = 999, name = "Old" }))
    host:update()
    local got = t:poll()
    local refused
    for _, ev in ipairs(got) do
        local m = ev.data and SESSION.unpack(ev.data)
        if m and m.t == "refused" then refused = m end
    end
    check("another version refused", refused)
    host:update()
    check("junk ignored", pcall(function()
        local t2 = net.join()
        t2:send("drakon1:{;s1:t")
        t2:send("lol")
        host:update()
    end))
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
