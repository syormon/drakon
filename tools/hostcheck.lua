--hosts a game (as Host a game... does) for a while, for checking that others can join it,
--e.g. the web version through wasm/joincheck.html, or node wasm/joincheck.mjs. Answers chat,
--and quits once a joined player has chatted and left (or after the time is up).
--love . --run tools/hostcheck.lua   [DRAKON_PORT=5229 DRAKON_PASSWORD=secret DRAKON_SECONDS=60]

local SETUP = require('src.setup')
local SESSION = require('src.session')
local WSLINK = require('src.wslink')

local port = tonumber(os.getenv("DRAKON_PORT") or "") or WSLINK.PORT
local password = os.getenv("DRAKON_PASSWORD") or "secret"
local seconds = tonumber(os.getenv("DRAKON_SECONDS") or "") or 60

local link, err = WSLINK.host(port, password)
if not link then error(err) end
local host = SESSION.Host:new(link, "Host")
local cfg = SETUP.defaultConfig()
table.remove(cfg.players, 4)
cfg.players[2].ai, cfg.players[2].remote = nil, true
host:setLobby(cfg)
print(("hosting on port %d (address %s); waiting %d s"):format(port, tostring(WSLINK.localAddress()), seconds))
io.stdout:flush()

local t0 = love.timer.getTime()
local chatted, joined = false, false
while love.timer.getTime() - t0 < seconds do
    host:update()
    for _, e in ipairs(SESSION.takeEvents(host)) do
        print(e.type .. ": " .. tostring(e.text))
        if e.type == "joined" then joined = true end
        if e.type == "chat" and not e.text:find("^Host:") then
            chatted = true
            host:say("hello back")
        end
        if e.type == "left" and chatted then t0 = -math.huge end
    end
    io.stdout:flush()
    love.timer.sleep(0.01)
end
for _ = 1, 20 do host:update(); love.timer.sleep(0.01) end
host:close()
print(joined and chatted and "a player joined and chatted" or "nobody joined and chatted")
