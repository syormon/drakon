--tests for the setup editing (src/setup.lua). Runs under plain Lua, from the repository's top folder:
--lua tests/test_setup.lua

package.path = "./?.lua;./src/?.lua;" .. package.path
local GAME = require('src.game')
local SETUP = require('src.setup')

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
---always the lowest value
---@param lo integer
---@return integer
local function rng(lo) return lo end

---------------------------------------------------------------------------- defaults and copying

do
    local cfg = SETUP.defaultConfig()
    eq("four players", #cfg.players, 4)
    check("Alice is a person, the rest computer players", not cfg.players[1].ai and cfg.players[2].ai == "greedy")
    check("everyone on their own team", #SETUP.teams(cfg) == 4 and #SETUP.hands(cfg) == 4)
    check("no problems", SETUP.problem(cfg) == nil)

    local a = cfg.players[1]
    cfg.players[2].team = a.team
    cfg.players[2].hand = a.hand
    local c = SETUP.copy(cfg)
    check("copy has its own players", c.players[1] ~= a and c.players[1].name == "Alice")
    check("shared team stays shared", c.players[1].team == c.players[2].team and c.players[1].team ~= a.team)
    check("shared hand stays shared", c.players[1].hand == c.players[2].hand and c.players[1].hand ~= a.hand)
    c.options.doubleGold = true
    check("options copied", cfg.options.doubleGold == false)
    local s = GAME.newGame(c, rng)
    check("game starts from the copy", s.players[1].hand == s.players[2].hand)
end

---------------------------------------------------------------------------- players

do
    local cfg = GAME.newConfig()
    local p1 = SETUP.addPlayer(cfg)
    local p2 = SETUP.addPlayer(cfg, "random")
    eq("named Player 1", p1.name, "Player 1")
    eq("named Player 2", p2.name, "Player 2")
    check("second is a computer player", p2.ai == "random" and not p1.ai)
    check("different initials", p1.initial ~= p2.initial, p1.initial .. p2.initial)
    SETUP.removePlayer(cfg, 1)
    local p3 = SETUP.addPlayer(cfg)
    eq("free colour reused", p3.colorIndex, 0)
    check("name not repeated", p3.name ~= p2.name, p3.name)
    check("move down", SETUP.movePlayer(cfg, 1, 1) and cfg.players[2] == p2)
    check("can't move past the end", not SETUP.movePlayer(cfg, 2, 1))

    SETUP.cycleHero(p3, 1)
    eq("hero steps", p3.hero, GAME.Hero.Amazon)
    SETUP.cycleHero(p3, -1); SETUP.cycleHero(p3, -1)
    eq("hero wraps", p3.hero, GAME.Hero.Wizard)

    p3.colorIndex = 0
    p2.colorIndex = 1
    SETUP.cycleColor(cfg, p3, 1)
    eq("colour skips one in use", p3.colorIndex, 2)
    SETUP.cycleColor(cfg, p3, -1)
    eq("and back past it", p3.colorIndex, 0)

    SETUP.cycleControl(p3, 1); eq("greedy", p3.ai, "greedy")
    SETUP.cycleControl(p3, 1); eq("random", p3.ai, "random")
    SETUP.cycleControl(p3, 1); eq("person", p3.ai, nil)

    check("rename", SETUP.rename(p3, "  Zed ") and p3.name == "Zed")
    check("no empty name", not SETUP.rename(p3, "   "))
    local own = SETUP.defaultConfig()
    local al = own.players[1]
    SETUP.rename(al, "Ann", own)
    check("own team and hand renamed too", al.team.name == "Ann" and al.hand.name == "Ann")
    own.players[2].team = al.team
    SETUP.rename(al, "Anna", own)
    check("a shared team keeps its name", al.team.name == "Ann" and al.hand.name == "Anna")
    check("initial upper-cased", SETUP.setInitial(p3, "q") and p3.initial == "Q")
end

---------------------------------------------------------------------------- teams and hands

do
    local cfg = SETUP.defaultConfig()
    local a, b, c = cfg.players[1], cfg.players[2], cfg.players[3]
    check("join the next team", SETUP.cycleTeam(cfg, 1, 1) and a.team == b.team)
    eq("three teams", #SETUP.teams(cfg), 3)
    check("leave it for a new one", SETUP.cycleTeam(cfg, 1, -1) and a.team ~= b.team)
    check("new team named after the player, if free", a.team.name == "Alice", a.team.name)
    eq("new team needs 5", a.team.goldToWin, 5)

    a.team = b.team
    check("renaming a shared team renames it for both", SETUP.renameTeam(cfg, a.team, "Reds") and b.team.name == "Reds")
    check("team names stay distinct", not SETUP.renameTeam(cfg, c.team, a.team.name))

    SETUP.setGold(a.team, 0); eq("gold at least 1", a.team.goldToWin, 1)
    SETUP.setGold(a.team, 500); eq("gold at most 99", a.team.goldToWin, 99)

    check("share a hand", SETUP.cycleHand(cfg, 3, 1) and SETUP.sharing(cfg, "hand", c.hand) == 2)
    SETUP.setTiles(c.hand, 25); eq("tiles at most 20", c.hand.tileCount, 20)
    check("a new own hand keeps the size", SETUP.cycleHand(cfg, 3, 1) and c.hand.tileCount == 20
          and SETUP.sharing(cfg, "hand", c.hand) == 1)

    local solo = GAME.newConfig()
    SETUP.addPlayer(solo)
    check("one player: nothing to switch to", not SETUP.cycleTeam(solo, 1, 1))
end

do --two Teams
    local cfg = SETUP.defaultConfig()
    SETUP.addPlayer(cfg)
    local ok, err = SETUP.twoTeams(cfg, 7)
    check("odd number refused", not ok and err == "Odd number of players")
    SETUP.removePlayer(cfg, 5)
    check("two teams", SETUP.twoTeams(cfg, 7))
    local p = cfg.players
    check("1 and 3 together", p[1].team == p[3].team and p[2].team == p[4].team and p[1].team ~= p[2].team)
    check("named after the first two", p[1].team.name == "Alice" and p[2].team.name == "Bram")
    eq("gold to win", p[4].team.goldToWin, 7)
    local s = GAME.newGame(SETUP.copy(cfg), rng)
    local names = {}
    for _, pl in ipairs(s.players) do names[pl.team.name] = true end
    check("game sees two teams", names.Alice and names.Bram and not names.Cora)
    check("game starts", s.activePlayer ~= nil)
end

---------------------------------------------------------------------------- checks

do
    local cfg = SETUP.defaultConfig()
    cfg.players[2].initial = "a"
    check("duplicate initials", (SETUP.problem(cfg) or ""):find("duplicate initials"))
    cfg.players[2].initial = "B"
    cfg.players[2].colorIndex = cfg.players[1].colorIndex
    check("duplicate colours", (SETUP.problem(cfg) or ""):find("duplicate color"))
    cfg.players[2].colorIndex = 9
    cfg.players[2].name = "Alice"
    check("duplicate names", (SETUP.problem(cfg) or ""):find("Two players are called"))
    check("no players", SETUP.problem(GAME.newConfig()) ~= nil)
    SETUP.setNumber(cfg, "bigDungeonRounds", 120); eq("rounds at most 99", cfg.options.bigDungeonRounds, 99)
    SETUP.setNumber(cfg, "turnTimeBonus", -3); eq("time at least 0", cfg.options.turnTimeBonus, 0)
end

---------------------------------------------------------------------------- saving

do
    local cfg = SETUP.defaultConfig()
    SETUP.twoTeams(cfg, 6)
    cfg.players[3].hand = cfg.players[1].hand
    cfg.players[1].hand.tileCount = 6
    cfg.players[2].ai = "random"
    cfg.players[4].name = "Dmitri the Bold"
    cfg.options.mindOrb = true
    cfg.options.bigDungeonRounds = 2
    local text = SETUP.serialize(cfg)
    local back, err = SETUP.parse(text)
    check("parses", back ~= nil, err)
    if back then
        eq("players", #back.players, 4)
        check("teams shared again", back.players[1].team == back.players[3].team and back.players[2].team == back.players[4].team)
        eq("team gold", back.players[2].team.goldToWin, 6)
        check("hand shared again", back.players[1].hand == back.players[3].hand and back.players[1].hand.tileCount == 6)
        eq("hero", back.players[2].hero, GAME.Hero.Wizard)
        eq("ai", back.players[2].ai, "random")
        eq("person", back.players[1].ai, nil)
        eq("name with spaces", back.players[4].name, "Dmitri the Bold")
        eq("colour", back.players[3].colorIndex, cfg.players[3].colorIndex)
        check("options", back.options.mindOrb == true and back.options.bigDungeonRounds == 2 and back.options.doubleGold == false)
        eq("same text again", SETUP.serialize(back), text)
    end
    check("rejects other files", not SETUP.parse("hello"))
    check("rejects bad lines", not SETUP.parse("drakon setup 1\nplayer\tonly-name\n"))
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
