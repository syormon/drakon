--drives the setup screen with simulated clicks and typing, checks each step worked, and saves
--pictures to the save folder (%APPDATA%\LOVE\drakon).
--love . --run tools/setupdemo.lua

local m = ...
local GAME, SETUP, SETUPVIEW = m.game, m.setup, m.setupview
local TOP = 40

local failures = 0
---print a check and count failures
---@param name string
---@param cond any
local function check(name, cond)
    print((cond and "ok    " or "FAIL  ") .. name)
    if not cond then failures = failures + 1 end
end

local canvas = love.graphics.newCanvas(love.graphics.getDimensions())
---draw the view to a canvas, and save it as setup_<save>.png if given
---@param v SETUPVIEW
---@param save? string
local function render(v, save)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0.17, 0.15, 0.14)
    v:draw(TOP)
    love.graphics.setCanvas()
    if save then canvas:newImageData():encode("png", "setup_" .. save .. ".png") end
end
---click the hit area of this kind (row i, part) on the screen as drawn now
---@param v SETUPVIEW
---@param kind string
---@param i? integer
---@param part? string
---@param button? integer
---@return boolean found
local function click(v, kind, i, part, button)
    render(v)
    for _, h in ipairs(v.hits) do
        if h.kind == kind and h.i == i and (part == nil or h.part == part) then
            v:mousepressed(h.x + math.floor(h.w / 2), h.y + math.floor(h.h / 2), button or 1)
            return true
        end
    end
    print("  (no " .. kind .. " " .. tostring(i) .. " " .. tostring(part) .. " on screen)")
    return false
end
---type text into the cell being edited
---@param v SETUPVIEW
---@param text string
local function typeText(v, text)
    for ch in text:gmatch(".") do v:textinput(ch) end
end
---@param v SETUPVIEW
---@return string
local function said(v) return v.message and v.message.text or "" end

local v = SETUPVIEW:new(SETUP.defaultConfig(), false)
local p = v.cfg.players
render(v, "default")

--rename Alice
click(v, "name", 1, "type")
check("typing a name", v.edit and v.edit.kind == "name")
for _ = 1, 5 do v:keypressed("backspace") end
typeText(v, "Ann")
v:keypressed("return")
check("renamed: " .. p[1].name, p[1].name == "Ann")

--hero, colour, plays
local hero = p[1].hero
click(v, "hero", 1, "next")
check("hero stepped", p[1].hero == (hero + 1) % 7)
click(v, "hero", 1, "prev")
check("and back", p[1].hero == hero)
local color = p[2].colorIndex
click(v, "color", 2, "next", 2)   --right click steps back
check("colour changed", p[2].colorIndex ~= color)
click(v, "control", 2, "next")
check("Bram now random", p[2].ai == "random")

--join a team, set its gold by typing
click(v, "team", 3, "next")
check("Cora joined a team", SETUP.sharing(v.cfg, "team", p[3].team) == 2)
click(v, "gold", 3, "type")
v:keypressed("backspace")
typeText(v, "8x")                  --the letter is ignored
v:keypressed("return")
check("team gold 8", p[3].team.goldToWin == 8)

--tiles via the wheel isn't clickable here; use > twice
click(v, "tiles", 4, "next"); click(v, "tiles", 4, "next")
check("Dmitri's hand 6", p[4].hand.tileCount == 6)

--options
click(v, "option", 2)
check("double gold on", v.cfg.options.doubleGold)
click(v, "number", 1, "next")
check("big dungeon rounds 1", v.cfg.options.bigDungeonRounds == 1)
render(v, "edited")

--add, move, remove
click(v, "addComputer")
check("added: " .. said(v), #p == 5 and p[5].ai == "greedy")
click(v, "twoTeams")
check("odd players refused: " .. said(v), v.message.error)
click(v, "up", 5)
check("moved up", p[4].name == "Player 5")
click(v, "remove", 4)
check("removed", #p == 4 and p[4].name == "Dmitri")

--two Teams
click(v, "twoTeams")
check("asks for the gold", v.edit and v.edit.kind == "twoTeams")
v:keypressed("backspace"); typeText(v, "6"); v:keypressed("return")
check("two teams: " .. said(v), p[1].team == p[3].team and p[2].team == p[4].team and p[1].team.goldToWin == 6)
render(v, "twoteams")

--a problem blocks starting
p[2].initial = "A"
click(v, "start")
check("duplicate initials stop it: " .. said(v), not v.started and v.message.error)
p[2].initial = "B"

--save, change, load (keeping any setup you saved yourself)
local yours = love.filesystem.read("setup.dsc")
click(v, "save")
check("saved: " .. said(v), love.filesystem.getInfo("setup.dsc") ~= nil)
v.cfg.players[1].name = "Changed"
click(v, "load")
check("loaded: " .. said(v), v.cfg.players[1].name == "Ann" and v.cfg.players[1].team == v.cfg.players[3].team)
if yours then love.filesystem.write("setup.dsc", yours) else love.filesystem.remove("setup.dsc") end

--start
v:keypressed("return")
check("started", v.started ~= nil)
local s = GAME.newGame(SETUP.copy(v.started), function(lo) return lo end)
check("the game has the setup", s.players[1].name == "Ann" and s.config.options.doubleGold
      and s.players[1].team.goldToWin == 6)

--Esc goes back only when a game is running
local v2 = SETUPVIEW:new(SETUP.defaultConfig(), true)
check("Esc back to the game", v2:keypressed("escape") and v2.back)
local v3 = SETUPVIEW:new(SETUP.defaultConfig(), false)
check("no game: Esc not used here", not v3:keypressed("escape"))

print(failures == 0 and "all setup checks passed" or (failures .. " failed"))
if failures > 0 then error("setup demo failed") end
