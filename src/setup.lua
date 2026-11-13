--game setup: the editing behind the setup screen, after the original Configure dialog
--(TConfigForm, TConfigPlayerForm and TConfigTeamForm). Pure Lua: no LÖVE calls.
--
--a configuration is game.newConfig()'s table. Players on the same team share one team table
--({ name, goldToWin }), and players sharing a hand share one hand table ({ name, tileCount }),
--as game.newGame expects. pc.ai is nil for a player at this computer, else an ai.LEVELS name.

local GAME = require('src.game')
local unpack = table.unpack or unpack

---@class SETUP
local lib = {}

lib.MAX_TILES = 20        --TileUpDown.Max in the player dialog
lib.MAX_GOLD = 99
lib.MAX_ROUNDS = 99       --BigDungeonUpDown.Max
lib.MAX_SECONDS = 9999    --StartTimeUpDown.Max / TurnTimeUpDown.Max

--the rule options, with the original check box captions, in the dialog's order.
---@type {key:string, label:string, fixed?:boolean, note?:string}[]
lib.OPTIONS = {
    { key = "expansionTiles", label = "Drakon Expansion #1", fixed = true,
        note = "always on: the basic set was never supported" },
    { key = "doubleGold", label = "Use Double Gold Tiles" },
    { key = "secretEscape", label = "Secret Passage -> Escape Tile" },
    { key = "dwarfEnhancement", label = "Dwarf Draws Before Discarding", note = "no effect yet" },
    { key = "secretStart", label = "Secret Passage -> Start Chamber" },
    { key = "emptyHand", label = "Empty Hand Can Draw One Tile" },
    { key = "stealAsLocked", label = "Lock Stolen Coins" },
    { key = "forceGoldTile", label = "Start With At Least One Gold Tile" },
    { key = "mindOrb", label = "Use Mind Orb Tiles" },
    { key = "separateTeamStart", label = "Start Teams in Separate Areas" },
}
---@type {key:string, label:string, max:integer, note?:string}[]
lib.NUMBERS = {
    { key = "bigDungeonRounds", label = "Big Dungeon Rounds:", max = lib.MAX_ROUNDS },
    { key = "startTimeLimit", label = "Starting Clock (secs):", max = lib.MAX_SECONDS, note = "no clock yet" },
    { key = "turnTimeBonus", label = "Per Turn Time (secs):", max = lib.MAX_SECONDS, note = "no clock yet" },
}

--who plays a seat: nil = a person at this computer, else a computer player level. A seat
--can also be played over the network (pc.remote), by whoever joins the hosted game.
---@type (string|false)[]
lib.CONTROLS = { false, "greedy", "random" }
lib.NETWORK = "network"
---@param ai string|nil
---@param remote? boolean played over the network
---@param joined? boolean someone has joined for it
---@return string
function lib.controlName(ai, remote, joined)
    if remote then return joined and "Network" or "Network (open)" end
    if not ai then return "Person" end
    return ai:sub(1, 1):upper() .. ai:sub(2) .. " AI"
end

---@param v number
---@param lo number
---@param hi number
---@return number
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------- the default game

---Alice (a person) against three greedy computer players, teams starting in separate areas
---@return GAME.CONFIG
function lib.defaultConfig()
    local cfg = GAME.newConfig()
    local heroes = { GAME.Hero.Knight, GAME.Hero.Wizard, GAME.Hero.Amazon, GAME.Hero.Dwarf }
    for i, name in ipairs({ "Alice", "Bram", "Cora", "Dmitri" }) do
        local pc = GAME.addPlayer(cfg, name)
        pc.hero = heroes[i]
        if i > 1 then pc.ai = "greedy" end
    end
    cfg.options.separateTeamStart = true   --(off in the original's defaults; on here)
    return cfg
end

---a copy to edit, so the game being played keeps its own. Shared team and hand tables stay
---shared in the copy.
---@param cfg GAME.CONFIG
---@return GAME.CONFIG
function lib.copy(cfg)
    local n = GAME.newConfig()
    for k, v in pairs(cfg.options) do n.options[k] = v end
    local teams, hands = {}, {}
    for _, pc in ipairs(cfg.players) do
        local c = {}
        for k, v in pairs(pc) do c[k] = v end
        teams[pc.team] = teams[pc.team] or { name = pc.team.name, goldToWin = pc.team.goldToWin }
        hands[pc.hand] = hands[pc.hand] or { name = pc.hand.name, tileCount = pc.hand.tileCount }
        c.team, c.hand = teams[pc.team], hands[pc.hand]
        n.players[#n.players + 1] = c
    end
    return n
end

---------------------------------------------------------------------------- teams and hands

---distinct team (or hand) tables, in the order players first use them.
---@param cfg GAME.CONFIG
---@param field "team"|"hand"
---@return table[]
local function distinct(cfg, field)
    local list, seen = {}, {}
    for _, pc in ipairs(cfg.players) do
        local t = pc[field]
        if not seen[t] then seen[t] = true; list[#list + 1] = t end
    end
    return list
end
---distinct teams, in the order players first use them
---@param cfg GAME.CONFIG
---@return GAME.TEAM[]
function lib.teams(cfg) return distinct(cfg, "team") end
---distinct hands, in the order players first use them
---@param cfg GAME.CONFIG
---@return GAME.HANDCONFIG[]
function lib.hands(cfg) return distinct(cfg, "hand") end

---@param list {name:string}[]
---@param name string
---@param except? table
---@return boolean|nil
local function nameTaken(list, name, except)
    for _, t in ipairs(list) do
        if t ~= except and t.name == name then return true end
    end
end
---a name not used by any team (hand) yet: the given one, with "-2" added until it is free
---(as game.addPlayer names teams).
---@param list {name:string}[]
---@param name string
---@return string
local function freeName(list, name)
    while nameTaken(list, name) do name = name .. "-2" end
    return name
end

---how many players use this team (hand)
---@param cfg GAME.CONFIG
---@param field "team"|"hand"
---@param t table
---@return integer
function lib.sharing(cfg, field, t)
    local n = 0
    for _, pc in ipairs(cfg.players) do if pc[field] == t then n = n + 1 end end
    return n
end

---step a player through the teams (hands) in use, plus a new one of their own when they
---share theirs, as picking from the dialog's team or hand list (or typing a new name) does.
---@param cfg GAME.CONFIG
---@param i integer player index
---@param field "team"|"hand"
---@param dir integer 1 or -1
---@param fresh fun(name:string, old:table):table makes a new team (hand)
---@return boolean changed
local function cycle(cfg, i, field, dir, fresh)
    local pc = cfg.players[i]
    local list = distinct(cfg, field)
    local choices = {}
    for _, t in ipairs(list) do choices[#choices + 1] = t end
    if lib.sharing(cfg, field, pc[field]) > 1 then choices[#choices + 1] = "new" end
    if #choices < 2 then return false end
    local at = 1
    for k, t in ipairs(choices) do if t == pc[field] then at = k end end
    local pick = choices[(at - 1 + dir) % #choices + 1]
    if pick == "new" then pick = fresh(freeName(list, pc.name), pc[field]) end
    pc[field] = pick
    return true
end

---step a player through the teams
---@param cfg GAME.CONFIG
---@param i integer
---@param dir? integer
---@return boolean changed
function lib.cycleTeam(cfg, i, dir)
    return cycle(cfg, i, "team", dir or 1, function(name)
        return { name = name, goldToWin = GAME.DEFAULT_GOLD_TO_WIN }
    end)
end
---step a player through the hands
---@param cfg GAME.CONFIG
---@param i integer
---@param dir? integer
---@return boolean changed
function lib.cycleHand(cfg, i, dir)
    return cycle(cfg, i, "hand", dir or 1, function(name, old)
        return { name = name, tileCount = old.tileCount }
    end)
end

---@param cfg GAME.CONFIG
---@param team GAME.TEAM
---@param name string
---@return true|nil ok
---@return string? err
function lib.renameTeam(cfg, team, name)
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil, "A team needs a name" end
    if nameTaken(lib.teams(cfg), name, team) then return nil, ('There is already a team called "%s"'):format(name) end
    team.name = name
    return true
end

---gold to win, kept between 1 and MAX_GOLD
---@param team GAME.TEAM
---@param v integer
function lib.setGold(team, v) team.goldToWin = clamp(v, 1, lib.MAX_GOLD) end
---hand size, kept between 0 and MAX_TILES
---@param hand GAME.HANDCONFIG
---@param v integer
function lib.setTiles(hand, v) hand.tileCount = clamp(v, 0, lib.MAX_TILES) end
---set a number option, kept in its range
---@param cfg GAME.CONFIG
---@param key string
---@param v integer
function lib.setNumber(cfg, key, v)
    for _, n in ipairs(lib.NUMBERS) do
        if n.key == key then cfg.options[key] = clamp(v, 0, n.max) end
    end
end

---------------------------------------------------------------------------- players

---@param cfg GAME.CONFIG
---@param except? GAME.PLAYERCONFIG
---@return {[integer]:boolean}
local function usedColors(cfg, except)
    local used = {}
    for _, pc in ipairs(cfg.players) do if pc ~= except then used[pc.colorIndex] = true end end
    return used
end

---add a player with the original defaults (own team, own hand of 4, no hero), named
---"Player N" and given the first colour nobody has.
---@param cfg GAME.CONFIG
---@param ai? string computer player level, nil for a person
---@return GAME.PLAYERCONFIG
function lib.addPlayer(cfg, ai)
    local names = {}
    for _, pc in ipairs(cfg.players) do names[pc.name] = true end
    local n = #cfg.players + 1
    while names["Player " .. n] do n = n + 1 end
    local pc = GAME.addPlayer(cfg, "Player " .. n)
    local used = usedColors(cfg, pc)
    for c = 0, #GAME.COLORS do
        if not used[c] then pc.colorIndex = c; break end
    end
    pc.ai = ai or nil
    return pc
end

---@param cfg GAME.CONFIG
---@param i integer
function lib.removePlayer(cfg, i)
    table.remove(cfg.players, i)
end

---move Up / Move Down: the order of play.
---@param cfg GAME.CONFIG
---@param i integer
---@param dir integer -1 up, 1 down
---@return boolean moved
function lib.movePlayer(cfg, i, dir)
    local j = i + dir
    if j < 1 or j > #cfg.players then return false end
    cfg.players[i], cfg.players[j] = cfg.players[j], cfg.players[i]
    return true
end

---@param pc GAME.PLAYERCONFIG
---@param dir? integer
function lib.cycleHero(pc, dir)
    pc.hero = (pc.hero + (dir or 1)) % (#GAME.HeroName + 1)
end

---next colour that nobody else has.
---@param cfg GAME.CONFIG
---@param pc GAME.PLAYERCONFIG
---@param dir? integer
---@return boolean changed
function lib.cycleColor(cfg, pc, dir)
    local used = usedColors(cfg, pc)
    local count = #GAME.COLORS + 1
    local c = pc.colorIndex
    for _ = 1, count do
        c = (c + (dir or 1)) % count
        if not used[c] then pc.colorIndex = c; return true end
    end
    return false
end

---step through person / greedy / random (/ network, when `network`: a game is being hosted)
---@param pc GAME.PLAYERCONFIG
---@param dir? integer
---@param network? boolean
function lib.cycleControl(pc, dir, network)
    local list = { unpack(lib.CONTROLS) }
    if network or pc.remote then list[#list + 1] = lib.NETWORK end
    local now = pc.remote and lib.NETWORK or pc.ai or false
    local at = 1
    for k, v in ipairs(list) do if v == now then at = k end end
    local v = list[(at - 1 + (dir or 1)) % #list + 1]
    if v == lib.NETWORK then
        pc.ai, pc.remote = nil, true
    else
        pc.ai, pc.remote, pc.peer = v or nil, nil, nil
    end
end

---rename a player. A team or hand that is theirs alone and still has their old name is
---renamed with them (if no other team or hand has the new name).
---@param pc GAME.PLAYERCONFIG
---@param name string
---@param cfg? GAME.CONFIG
---@return true|nil ok
---@return string? err
function lib.rename(pc, name, cfg)
    name = name:gsub("[\t\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil, "A player needs a name" end
    if cfg then
        for _, field in ipairs({ "team", "hand" }) do
            local t = pc[field]
            if t.name == pc.name and lib.sharing(cfg, field, t) == 1 and not nameTaken(distinct(cfg, field), name, t) then
                t.name = name
            end
        end
    end
    pc.name = name
    return true
end

---@param pc GAME.PLAYERCONFIG
---@param ch string
---@return true|nil ok
---@return string? err
function lib.setInitial(pc, ch)
    if ch == "" or ch:find("%s") then return nil, "An initial is one letter" end
    pc.initial = ch:upper()
    return true
end

---two Teams ($00D0768C): needs an even number of players. The first two players each get a
---new team named after them that needs `gold` to win; the rest join them in turn (players
---3, 5... with the first, 4, 6... with the second).
---@param cfg GAME.CONFIG
---@param gold? integer
---@return true|nil ok
---@return string? err
function lib.twoTeams(cfg, gold)
    local n = #cfg.players
    if n == 0 or n % 2 == 1 then return nil, "Odd number of players" end
    local a = { name = cfg.players[1].name, goldToWin = clamp(gold or GAME.DEFAULT_GOLD_TO_WIN, 1, lib.MAX_GOLD) }
    local b = { name = cfg.players[2].name, goldToWin = a.goldToWin }
    if b.name == a.name then b.name = b.name .. "-2" end
    for i, pc in ipairs(cfg.players) do pc.team = (i % 2 == 1) and a or b end
    return true
end

---------------------------------------------------------------------------- checking

---what stops the game starting, or nil. The OK button's checks ($00D07FEC) plus the game's
---own ($00BE3AF4).
---@param cfg GAME.CONFIG
---@return string|nil
function lib.problem(cfg)
    if #cfg.players == 0 then return "Add a player first" end
    local names, initials, colors = {}, {}, {}
    for _, pc in ipairs(cfg.players) do
        if names[pc.name] then return ('Two players are called "%s"'):format(pc.name) end
        names[pc.name] = true
        local init = (pc.initial or ""):upper()
        if initials[init] then return ("Two players have the initial %s (duplicate initials)"):format(init) end
        initials[init] = true
        if colors[pc.colorIndex] then
            return ("Two players are %s (duplicate color indexes)"):format(GAME.COLORS[pc.colorIndex])
        end
        colors[pc.colorIndex] = true
    end
    return nil
end

---why the network seats stop the game starting, or nil: a seat nobody has joined for yet,
---or network seats when no network game is hosted (`hosting` false)
---@param cfg GAME.CONFIG
---@param hosting boolean
---@return string|nil
function lib.seatProblem(cfg, hosting)
    for _, pc in ipairs(cfg.players) do
        if pc.remote and not hosting then
            return pc.name .. " plays over the network: host a network game first, or change who plays"
        end
        if pc.remote and not pc.peer then return "Waiting for someone to join for " .. pc.name end
    end
    return nil
end

---------------------------------------------------------------------------- saving

--a saved setup (the original saved .dsc files) is plain text: one "option" line per option
--and one "player" line per player, with tab-separated fields.
local PLAYER_FIELDS = { "name", "initial", "color", "hero", "team", "gold", "hand", "tiles", "ai" }

---@param cfg GAME.CONFIG
---@return string
function lib.serialize(cfg)
    local out = { "drakon setup 1" }
    local keys = {}
    for k in pairs(cfg.options) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = ("option\t%s\t%s"):format(k, tostring(cfg.options[k])) end
    for _, pc in ipairs(cfg.players) do
        out[#out + 1] = table.concat({ "player", pc.name, pc.initial or "", pc.colorIndex, GAME.HeroName[pc.hero],
            pc.team.name, pc.team.goldToWin, pc.hand.name, pc.hand.tileCount, pc.remote and lib.NETWORK or pc.ai or "" }, "\t")
    end
    return table.concat(out, "\n") .. "\n"
end

---split a line at tabs
---@param line string
---@return string[]
local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = part end
    return f
end

---read a saved setup
---@param text string
---@return GAME.CONFIG|nil cfg
---@return string? err
function lib.parse(text)
    local cfg = GAME.newConfig()
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    if lines[1] ~= "drakon setup 1" then return nil, "Not a saved Drakon setup" end
    local heroes, teams, hands = {}, {}, {}
    for k, v in pairs(GAME.HeroName) do heroes[v] = k end
    local levels = {}
    for _, v in ipairs(lib.CONTROLS) do if v then levels[v] = true end end
    for n = 2, #lines do
        local f = split(lines[n])
        if f[1] == "option" and f[2] and cfg.options[f[2]] ~= nil then
            local cur = cfg.options[f[2]]
            if type(cur) == "boolean" then cfg.options[f[2]] = (f[3] == "true")
            else cfg.options[f[2]] = tonumber(f[3]) or cur end
        elseif f[1] == "player" and #f >= 1 + #PLAYER_FIELDS then
            local name, init, color, hero, team, gold, hand, tileCount, ai = unpack(f, 2, 1 + #PLAYER_FIELDS)
            if name == "" then return nil, ("Line %d: a player with no name"):format(n) end
            teams[team] = teams[team] or { name = team, goldToWin = clamp(tonumber(gold) or 5, 1, lib.MAX_GOLD) }
            hands[hand] = hands[hand] or { name = hand, tileCount = clamp(tonumber(tileCount) or 4, 0, lib.MAX_TILES) }
            cfg.players[#cfg.players + 1] = {
                name = name, initial = (init ~= "") and init or name:sub(1, 1):upper(),
                colorIndex = clamp(math.floor(tonumber(color) or 0), 0, #GAME.COLORS),
                hero = heroes[hero] or GAME.Hero.None,
                team = teams[team], hand = hands[hand], ai = levels[ai] and ai or nil,
                remote = (ai == lib.NETWORK) or nil,
            }
        else
            return nil, ("Line %d is not understood"):format(n)
        end
    end
    cfg.options.expansionTiles = true
    return cfg
end

return lib
