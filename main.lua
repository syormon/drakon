--Drakon (LÖVE version): the game, the original help sheet and a view of the draw deck.
--
--Left/Right, 1-3 or click a tab   switch view: Help, Deck, Game
--Up/Down / mouse wheel            scroll
--+ / - / Ctrl+wheel, 0, or the    zoom the game board or the Deck view's tiles; 0 goes back
--  - / + buttons (top right)
--S                                save a screenshot to the save folder
--F12 (or --debug)                 debug: also show the 064 and 128 image sets
--help view: Z switches between fitting the window and actual size
--deck view: R reshuffle, G toggle double gold, M toggle Mind Control Orb;
--hover over a tile to read its rules
--game view: starts on the setup screen (players, teams, rules); in a game N starts again
--with the same setup and C changes it; click a blue room to move; click a hand tile, rotate (R / right click / wheel), click a square
--to place it; Enter passes to the next player
--network games (setup screen): Host a game... (with a password; others join this computer
--over WebSockets, from the desktop or the web version) or Join a game...; Tab chats.
--
--run with --screenshot <view> to open that view, save a screenshot and quit (used for checks).

if os.getenv("LUADEBUG_PORT") then
    require("luadebug").start()
end
local VERSION = require('version')
local ASSETS = require('src.assets')
local DECK = require('src.deck')
local TILEART = require('src.tileart')
local GAME = require('src.game')
local GAMEVIEW = require('src.gameview')
local UI = require('src.ui')

---the views, in tab order (the image sets only in debug mode)
---@type string[]
local SETS = { "Help", "Deck", "Game" }
---@type string[]
local DEBUG_SETS = { "064", "128", "Help", "Deck", "Game" }
local ROOT = "assets/images/"
local HEADER_H = 40
local debugMode = false
---@type {x:number, w:number, index:integer}[]
local tabRects = {}

--help view: the original player aid, fitted to the window width unless shown at actual size
local HELP_IMAGE = "assets/images/Help/DrakonHelp.png"
---@type love.Image|nil
local helpImage
local helpActualSize = false

local current, scroll = 1, 0
local entries = {}       --{ name =, image = } for the current set
local loadTime = 0
local errors = {}
local screenshotMode, screenshotFrames = false, 0
local runScript = nil
local setupShot = false   -- --screenshot Setup: the setup screen
local font

--deck view
---Deck view tile sizes for + / - (whole-number scales of the image sets, so they stay sharp)
---@type integer[]
local DECK_SIZES = { 32, 64, 128, 256 }
local deckTile = 64
---the Deck view's zoom buttons, as drawn
---@type UI.BUTTON[]|nil
local deckZoomRects = nil
local deckOptions = { doubleGold = false, mindOrb = true }
local deckTiles, startTile = {}, nil
local hovered = nil
local hoveredSince = 0   --when the mouse came onto the hovered tile (its animation starts then)

---@return boolean
local function isDeckView() return SETS[current] == "Deck" end
---@return boolean
local function isGameView() return SETS[current] == "Game" end
---@return boolean
local function isHelpView() return SETS[current] == "Help" end

--game view: the setup screen first, then the game it sets up
local SETUPVIEW = require('src.setupview')
local SETUP = require('src.setup')
local JOINVIEW = require('src.joinview')
local SESSION = require('src.session')
local WSLINK = require('src.wslink')
local gameState, gameView, setupView, joinView
local gameConfig = SETUP.defaultConfig()   --the setup the current game was started from
---@type SESSION.HOST|SESSION.CLIENTSESSION|nil the network game: hosting, or joined
local net = nil
--web version: love.js only delivers typed text while text input is switched on (it types
--into a hidden input box, which also brings up a phone's keyboard)
local textInputOn = false

---@return boolean
local function isClient() return net ~= nil and net.role == "client" end

---the name this computer goes by in a network game: its first person's
---@param cfg GAME.CONFIG
---@return string
local function localName(cfg)
    for _, pc in ipairs(cfg.players) do
        if not pc.ai and not pc.remote then return pc.name end
    end
    return "Host"
end

---start a game with `cfg` (default gameConfig; in screenshot mode, play 12 turns first)
---@param cfg? GAME.CONFIG
local function newGame(cfg)
    gameState = GAME.newGame(SETUP.copy(cfg or gameConfig), GAME.newRandom(love.math.random(1, 2147483646)))
    gameView = GAMEVIEW:new(gameState, net)
    setupView = nil
    if net and net.role == "host" then net:startGame(gameState) end
    if screenshotMode then
        --demo for screenshots: everyone plays 12 turns (Alice as a greedy computer player too)
        local AI = require('src.ai')
        for _ = 1, 12 do
            if GAME.isOver(gameState) then break end
            for _, line in ipairs(AI.act(gameState, AI.levelOf(gameState.activePlayer) or "greedy")) do
                gameView.log[#gameView.log + 1] = line
            end
            while #gameView.log > 8 do table.remove(gameView.log, 1) end
        end
    end
end
---show the setup screen, starting from gameConfig
local function openSetup()
    setupView = SETUPVIEW:new(gameConfig, gameState ~= nil, net)
    if net and net.role == "host" then
        setupView.address = WSLINK.localAddress()
    end
end

---leave the network game (stop hosting, or leave the host) and go back to the setup on
---this computer, saying why
---@param text? string
---@param isError? boolean
local function endNetwork(text, isError)
    local wasClient = isClient()
    if net then net:close() end
    net = nil
    joinView = nil
    if wasClient then gameState, gameView = nil, nil end
    if gameView then gameView.net = nil end
    --network seats are played here from now on (or wait for the next hosting)
    local cfg = setupView and not wasClient and setupView.cfg or gameConfig
    for _, pc in ipairs(cfg.players) do pc.peer = nil end
    setupView = SETUPVIEW:new(cfg, gameState ~= nil)
    if text then setupView:setMessage(text, isError) end
end

---start hosting from the setup screen: others connect to this computer (port 5229) with
---the password chosen on the host screen
---@param password string
local function startHosting(password)
    local link, err = WSLINK.host(WSLINK.PORT, password)
    if not link then return setupView:setMessage(err or "Could not start hosting", true) end
    local host = SESSION.Host:new(link, localName(setupView.cfg))
    host.port = WSLINK.PORT
    setupView.address = WSLINK.localAddress()
    net = host
    setupView.net = host
    host:setLobby(setupView.cfg)
    setupView:setMessage("Hosting. Set a seat's Plays to Network (or Add network seat) for each player who will join.")
end

---after the join screen handled some input: connect, or go back
local function afterJoin()
    if not joinView then return end
    local r = joinView.request
    joinView.request = nil
    if r == "cancel" then
        if net then net:close(); net = nil end
        joinView = nil
        if not setupView then openSetup() end
    elseif r == "connect" then
        local t = joinView:target()
        if not t then return end
        if t.mode == "host" then
            --hosting: the setup screen (under this one) carries on, as the host
            joinView = nil
            return startHosting(t.password)
        end
        local link, err = WSLINK.join(t.address --[[@as string]], t.password)
        if not link then return joinView:setMessage(err or "Could not connect", true) end
        net = SESSION.Client:new(link, t.name)
        joinView.connecting = true
        joinView:setMessage("Connecting to " .. tostring(t.address) .. "...")
    end
end

---after the setup screen handled some input: start the game it set up, go back, or take
---a network step.
local function afterSetup()
    if not setupView then return end
    local r = setupView.request
    setupView.request = nil
    if r == "host" then joinView = JOINVIEW:new(localName(setupView.cfg), true); return
    elseif r == "stopHosting" then return endNetwork("Stopped hosting.")
    elseif r == "leave" then return endNetwork("Left the network game.")
    elseif r == "join" then joinView = JOINVIEW:new(localName(setupView.cfg)); return
    end
    if setupView.started then
        gameConfig = setupView.started
        newGame()
    elseif setupView.back then
        setupView = nil
        --the game goes on for everyone
        if net and net.role == "host" and gameState then net:startGame(gameState, true) end
    end
end

---after the game screen handled some input: if quitting was confirmed, the game ends and
---the setup screen comes back (a joined player leaves the network game)
local function afterGame()
    if not (gameView and gameView.request == "quit") then return end
    gameView.request = nil
    if isClient() then return endNetwork("Left the network game.") end
    gameState, gameView = nil, nil
    openSetup()
    setupView:setMessage("Game ended.")
end

---react to what came in from the network
---@param ev SESSION.EVENT
local function onNetEvent(ev)
    if not net then return end
    if net.role == "host" then
        if setupView and ev.text and (ev.type == "joined" or ev.type == "left") then setupView:setMessage(ev.text) end
        --what a joined player did, along the bottom of the board
        if gameView and not setupView and ev.type ~= "chat" and ev.text then gameView:setMessage(ev.text) end
        return
    end
    if ev.type == "closed" then
        if joinView then
            joinView.connecting = false
            joinView:setMessage(ev.text or "Could not connect.", true)
            net = nil
        else
            endNetwork(ev.text, true)
        end
    elseif ev.type == "lobby" then
        joinView, gameView, gameState = nil, nil, nil
        if setupView and setupView.net == net then
            setupView.cfg = net.cfg
        else
            setupView = SETUPVIEW:new(net.cfg, false, net)
        end
    elseif ev.type == "game" then
        joinView, setupView = nil, nil
        if ev.fresh or not gameView then
            gameState = net.state --[[@as GAME.STATE]]   --(a "game" event comes with one)
            gameView = GAMEVIEW:new(gameState, net)
            local p = gameState.activePlayer
            if p and net:controls(p) then gameView:setMessage(p.name .. ", your turn.") end
        else
            gameState = net.state --[[@as GAME.STATE]]
            gameView:replaceState(gameState)
        end
        --someone else acted: say what they did
        local line = net.log[#net.log]
        if line and not GAME.isOver(gameState) and not net:controls(gameState.activePlayer) then gameView:setMessage(line) end
    elseif ev.type == "rejected" and gameView then
        gameView:setMessage(ev.text or "The host didn't accept that", true)
    end
end

---shuffle a deck for the Deck view
local function buildDeck()
    deckTiles = DECK.build(deckOptions, love.math.random)
    startTile = DECK.startTile()
end

---switch view
---@param index integer index into SETS
local function loadSet(index)
    current = index
    scroll = 0
    entries, errors = {}, {}
    if isDeckView() then buildDeck() return end
    if isHelpView() then
        if not helpImage then
            helpImage = love.graphics.newImage(HELP_IMAGE, { mipmaps = true })
            helpImage:setFilter("linear", "linear")
            helpImage:setMipmapFilter("linear")
        end
        return
    end
    if isGameView() then
        if screenshotMode and not setupShot then newGame() elseif not gameState then openSetup() end
        return
    end
    local dir = ROOT .. SETS[index]
    local files = love.filesystem.getDirectoryItems(dir)
    table.sort(files)
    local t0 = love.timer.getTime()
    for _, f in ipairs(files) do
        local ok, img = pcall(ASSETS.image, dir .. "/" .. f)
        if ok then
            entries[#entries + 1] = { name = f:gsub("%.%w+$", ""), image = img }
        else
            errors[#errors + 1] = f .. ": " .. tostring(img)
        end
    end
    loadTime = love.timer.getTime() - t0
end

---@param args string[] command line: --screenshot <view>, --run <script>
function love.load(args)
    font = love.graphics.newFont(12)
    love.graphics.setFont(font)
    for _, a in ipairs(args) do
        if a == "--debug" then debugMode = true end
    end
    for i, a in ipairs(args) do
        if a == "--screenshot" and (args[i + 1] == "064" or args[i + 1] == "128") then debugMode = true end
    end
    if debugMode then SETS = DEBUG_SETS end
    local start = #SETS   --the game
    for i, a in ipairs(args) do
        if a == "--screenshot" then
            screenshotMode = true
            for j, s in ipairs(SETS) do
                if s == args[i + 1] then start = j end
            end
            if args[i + 1] == "Setup" then setupShot = true; start = #SETS end
        elseif a == "--run" then
            runScript = args[i + 1]
        end
    end
    loadSet(start)
    if runScript then
        --development checks (tools/*.lua): the script gets the modules and quits when done
        local ok, err = pcall(love.filesystem.load(runScript), { game = GAME, gameview = GAMEVIEW, tiles = require('src.tiles'),
                                                             setup = SETUP, setupview = SETUPVIEW })
        if not ok then print("ERROR", err) end
        love.event.quit(ok and 0 or 1)
    end
end

--grid layout: cells fit the largest image in the set, capped at 160px; anything bigger
--than a cell is scaled down to fit it (each image on its own).
local CELL_MAX = 160
---@return number cellW
---@return number cellH
---@return integer cols
local function layout()
    local w = love.graphics.getWidth()
    local maxW, maxH = 0, 0
    for _, e in ipairs(entries) do
        maxW = math.max(maxW, math.min(e.image:getWidth(), CELL_MAX))
        maxH = math.max(maxH, math.min(e.image:getHeight(), CELL_MAX))
    end
    local cellW = math.max(maxW, 120) + 16
    local cellH = maxH + 34
    local cols = math.max(1, math.floor((w - 20) / cellW))
    return cellW, cellH, cols
end

---scale that fits an image in a grid cell
---@param img love.Image
---@return number
local function fitScale(img)
    return math.min(1, CELL_MAX / img:getWidth(), CELL_MAX / img:getHeight())
end

---deck view: the Start tile, then every tile of the shuffled deck in draw order.
---@return TILES.TILE[] list Start tile first
---@return fun(i:integer):number, number position of the i-th tile
local function deckPositions()
    local cols = math.max(1, math.floor((love.graphics.getWidth() - 20) / (deckTile + 6)))
    local list = { startTile }
    for _, t in ipairs(deckTiles) do list[#list + 1] = t end
    local top = 84 - scroll
    return list, function(i)
        --leave a gap after the Start tile so the deck starts on a new row
        local slot = (i == 1) and 0 or (i - 2 + cols)
        return 10 + (slot % cols) * (deckTile + 6), top + math.floor(slot / cols) * (deckTile + 6)
    end
end

---Deck view: one zoom step in (steps > 0) or out; 0 goes back to 64 pixels. The tile at the
---top of the window stays in view.
---@param steps integer
local function zoomDeck(steps)
    local old = deckTile
    if steps == 0 then
        deckTile = 64
    elseif steps > 0 then
        for _, size in ipairs(DECK_SIZES) do if size > deckTile then deckTile = size; break end end
    else
        for i = #DECK_SIZES, 1, -1 do if DECK_SIZES[i] < deckTile then deckTile = DECK_SIZES[i]; break end end
    end
    if deckTile == old then return end
    --keep roughly the same tiles on screen: scroll by the same share of the (new) height
    local oldCols = math.max(1, math.floor((love.graphics.getWidth() - 20) / (old + 6)))
    local newCols = math.max(1, math.floor((love.graphics.getWidth() - 20) / (deckTile + 6)))
    local firstRow = math.floor(scroll / (old + 6))
    scroll = math.max(0, math.floor(firstRow * oldCols / newCols) * (deckTile + 6))
end

---the Deck view, with the rules of the tile under the mouse
local function drawDeck()
    local list, pos = deckPositions()
    local mx, my = love.mouse.getPosition()
    local was = hovered
    hovered = nil
    local counts = DECK.countByEffect(deckTiles)
    UI.text(("Start tile (begins on the board)          Deck: %d tiles, shuffled.  Double gold: %s (G)   Mind Control Orb: %s (M)   R: reshuffle")
        :format(#deckTiles, deckOptions.doubleGold and "on" or "off", deckOptions.mindOrb and "on" or "off"), 10, 54, 13, UI.COLOR.text)
    for i, t in ipairs(list) do
        local x, y = pos(i)
        local over = mx >= x and mx < x + deckTile and my >= y and my < y + deckTile
        if over and t ~= was then hoveredSince = love.timer.getTime() end
        love.graphics.setColor(1, 1, 1)
        TILEART.draw(t, x, y, deckTile, over and love.timer.getTime() - hoveredSince or nil)
        if over then
            hovered = t
            love.graphics.setColor(1, 0.9, 0.4)
            love.graphics.rectangle("line", x - 1, y - 1, deckTile + 2, deckTile + 2)
        end
    end
    --the zoom buttons, top right, with the size beside them
    deckZoomRects = UI.buttonRow({ "-", "+" }, love.graphics.getWidth() - 10, 48)
    local zoomText = ("%d px   0: back to 64"):format(deckTile)
    local zx = deckZoomRects[1].x - 10 - UI.font(12):getWidth(zoomText)
    UI.box(zx - 6, 53, UI.font(12):getWidth(zoomText) + 12, 18, UI.COLOR.background, 4)
    UI.text(zoomText, zx, 55, 12, UI.COLOR.dim)
    --rules panel
    local h = love.graphics.getHeight()
    love.graphics.setColor(0.1, 0.09, 0.08, 0.95)
    love.graphics.rectangle("fill", 0, h - 70, love.graphics.getWidth(), 70)
    if hovered then
        local e = hovered:effect()
        UI.text(("%s  (%s; %d in this deck)"):format(hovered:effectName(), hovered:styleName(), counts[e] or 0),
            10, h - 64, 15, UI.COLOR.accent)
        UI.text(hovered:helpText(), 10, h - 42, 13, UI.COLOR.text, love.graphics.getWidth() - 20)
    else
        UI.text("Hover over a tile to read its rules.", 10, h - 64, 15, UI.COLOR.accent)
    end
end

---the help view: the player aid, fitted to the window width (or at actual size), scrolled
local function drawHelp()
    local w, h = love.graphics.getDimensions()
    local img = helpImage --[[@as love.Image]]   --(loaded when the view opens)
    local iw, ih = img:getDimensions()
    local scale = helpActualSize and 1 or math.min(1, (w - 40) / iw)
    local dw, dh = iw * scale, ih * scale
    local maxScroll = math.max(0, dh + 40 - (h - HEADER_H))
    scroll = math.min(scroll, maxScroll)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, math.floor(math.max(20, (w - dw) / 2)), HEADER_H + 20 - scroll, 0, scale, scale)
end

---the header: one tab per view, and the keys that work everywhere
local function drawHeader()
    local w = love.graphics.getWidth()
    UI.box(0, 0, w, HEADER_H, UI.COLOR.panel, 0)
    UI.box(0, HEADER_H - 1, w, 1, UI.COLOR.border, 0)
    UI.text("DRAKON", 16, 10, 18, UI.COLOR.accent)
    local x = 120
    tabRects = {}
    for i, name in ipairs(SETS) do
        local label = name
        if name == "Game" and joinView then label = "Join game"
        elseif name == "Game" and setupView then label = net and "Network setup" or "Game setup"
        elseif name == "Game" and net then label = "Network game" end
        local tw = UI.font(14):getWidth(label) + 28
        if i == current then
            UI.box(x, 6, tw, HEADER_H - 12, UI.COLOR.cardActive, 6)
            UI.outline(x, 6, tw, HEADER_H - 12, UI.COLOR.accent, 1, 6)
        end
        UI.text(label, x + 14, 11, 14, i == current and UI.COLOR.text or UI.COLOR.dim)
        tabRects[#tabRects + 1] = { x = x, w = tw, index = i }
        x = x + tw + 6
    end
    local hint = "Left / Right: switch view     S: screenshot     v" .. VERSION
    if isHelpView() then hint = "Z: " .. (helpActualSize and "fit the window" or "actual size") .. "     wheel: scroll     " .. hint end
    if debugMode then hint = hint .. "     F12: debug off" end
    UI.text(hint, w - 16 - UI.font(12):getWidth(hint), 13, 12, UI.COLOR.faint)
end

---draw the current view
function love.draw()
    UI.color(UI.COLOR.background)
    love.graphics.rectangle("fill", 0, 0, love.graphics.getDimensions())
    love.graphics.setFont(font)
    if isDeckView() then drawDeck() end
    if isHelpView() then drawHelp() end
    if isGameView() then
        if joinView then joinView:draw(40)
        elseif setupView then setupView:draw(40)
        elseif gameView then gameView:draw(40) end
    end
    local cellW, cellH, cols = layout()
    local top = HEADER_H + 14 - scroll
    for i, e in ipairs(entries) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local x, y = 10 + col * cellW, top + row * cellH
        if y + cellH > 0 and y < love.graphics.getHeight() then
            local scale = fitScale(e.image)
            local iw, ih = e.image:getWidth() * scale, e.image:getHeight() * scale
            --checkerboard behind the image so transparency is visible
            love.graphics.setColor(0.32, 0.30, 0.28)
            love.graphics.rectangle("fill", x + (cellW - 16 - iw) / 2, y, iw, ih)
            love.graphics.setColor(1, 1, 1)
            love.graphics.draw(e.image, x + (cellW - 16 - iw) / 2, y, 0, scale, scale)
            UI.text(e.name, x, y + ih + 4, 12, UI.COLOR.dim, cellW - 16, "center")
        end
    end
    drawHeader()
    if #entries > 0 then
        local info = ("%d loaded, %d failed, %.0f ms"):format(#entries, #errors, loadTime * 1000)
        UI.text(info, 16, love.graphics.getHeight() - 22, 12, UI.COLOR.faint)
    end
    if #errors > 0 then
        love.graphics.setColor(1, 0.4, 0.4)
        love.graphics.printf(table.concat(errors, "\n"), 10, love.graphics.getHeight() - 20 * #errors - 10,
                             love.graphics.getWidth() - 20)
    end
    love.graphics.setColor(1, 1, 1)
end

---save the screen to viewer_<view>.png
---@param quit boolean quit afterwards
local function saveScreenshot(quit)
    local name = ("viewer_%s.png"):format((isGameView() and setupView) and "Setup" or SETS[current])
    love.graphics.captureScreenshot(function(data)
        data:encode("png", name)
        print("Saved " .. love.filesystem.getSaveDirectory() .. "/" .. name)
        if quit then love.event.quit() end
    end)
end

---@param dt number seconds since the last frame
function love.update(dt)
    if net then
        net:update()
        if net.role == "host" and setupView then
            net.name = localName(setupView.cfg)
            net:setLobby(setupView.cfg)
        end
        for _, ev in ipairs(SESSION.takeEvents(net)) do onNetEvent(ev) end
    end
    if WSLINK.isWeb() then
        --typing into something: the join screen, a setup cell or chat
        local typing = isGameView() and (joinView ~= nil or (setupView ~= nil and setupView.edit ~= nil)
            or (gameView ~= nil and setupView == nil and gameView.chatting ~= nil)) or false
        if typing ~= textInputOn then
            love.keyboard.setTextInput(typing)
            textInputOn = typing
        end
    end
    local playing = gameView and not setupView and not joinView
    --(a network game goes on while another view is looked at)
    if playing and not screenshotMode and (isGameView() or net) then gameView:update(dt) end
    if screenshotMode then
        screenshotFrames = screenshotFrames + 1
        if screenshotFrames == 3 then saveScreenshot(true) end
    end
end

---@param key love.KeyConstant
function love.keypressed(key)
    if isGameView() and joinView then
        joinView:keypressed(key)
        afterJoin()
        return
    end
    if isGameView() and gameView and not setupView and (gameView.chatting or gameView.confirmQuit) then
        gameView:keypressed(key)   --typing a chat line, or answering "Quit this game?"
        afterGame()
        return
    end
    if isGameView() and setupView then
        local used = setupView:keypressed(key)
        afterSetup()
        if used then return end
    end
    if key == "right" then loadSet(current % #SETS + 1)
    elseif key == "left" then loadSet((current - 2) % #SETS + 1)
    elseif key == "down" then scroll = scroll + 100
    elseif key == "up" then scroll = math.max(0, scroll - 100)
    elseif key == "s" then saveScreenshot(false)
    elseif key == "f12" then
        --debug mode: the image sets come and go; stay on the same view
        local name = SETS[current]
        debugMode = not debugMode
        SETS = debugMode and DEBUG_SETS or { "Help", "Deck", "Game" }
        for i, v in ipairs(SETS) do if v == name then current = i end end
        if not debugMode and (name == "064" or name == "128") then loadSet(1) end
    elseif isHelpView() and key == "z" then helpActualSize = not helpActualSize
    elseif key == "escape" then
        --in a game: drop a half-made pick, or ask whether to quit it (back to the setup)
        if isGameView() and gameView and not setupView then
            if not gameView:cancel() then gameView:askQuit() end
            return
        end
        love.event.quit()
    elseif isGameView() and setupView then return
    elseif isGameView() and key == "n" and not isClient() then
        --a network game starts again with its seats as they are now
        newGame(net and gameState and gameState.config or nil)
    elseif isGameView() and key == "c" and not isClient() then openSetup()
    elseif isGameView() then gameView:keypressed(key)
    elseif isDeckView() and key == "r" then buildDeck()
    elseif isDeckView() and key == "g" then deckOptions.doubleGold = not deckOptions.doubleGold; buildDeck()
    elseif isDeckView() and key == "m" then deckOptions.mindOrb = not deckOptions.mindOrb; buildDeck()
    elseif isDeckView() and (key == "=" or key == "+" or key == "kp+") then zoomDeck(1)
    elseif isDeckView() and (key == "-" or key == "kp-") then zoomDeck(-1)
    elseif isDeckView() and (key == "0" or key == "kp0") then zoomDeck(0)
    else
        local n = tonumber(key)
        if n and n >= 1 and n <= #SETS then loadSet(n) end
    end
end

---@param t string
function love.textinput(t)
    if not isGameView() then return end
    if joinView then joinView:textinput(t)
    elseif setupView then setupView:textinput(t)
    elseif gameView then gameView:textinput(t) end
end

---@param x number
---@param y number
---@param button integer
function love.mousepressed(x, y, button)
    if y < HEADER_H then
        for _, t in ipairs(tabRects) do
            if x >= t.x and x < t.x + t.w and t.index ~= current then loadSet(t.index) end
        end
        return
    end
    local zoom = isDeckView() and button == 1 and UI.hit(deckZoomRects, x, y)
    if zoom then zoomDeck(zoom == "+" and 1 or -1) return end
    if isGameView() and joinView then joinView:mousepressed(x, y); afterJoin()
    elseif isGameView() and setupView then setupView:mousepressed(x, y, button); afterSetup()
    elseif isGameView() and gameView then
        gameView:mousepressed(x, y, button)
        afterGame()
    end
end

---@param dy number
function love.wheelmoved(_, dy)
    if isGameView() and joinView then return end
    if isGameView() and setupView then setupView:wheelmoved(dy) return end
    if isGameView() and gameView and gameView:wheelmoved(dy) then return end
    if isDeckView() and love.keyboard.isDown("lctrl", "rctrl") then
        if dy ~= 0 then zoomDeck(dy > 0 and 1 or -1) end
        return
    end
    scroll = math.max(0, scroll - dy * 60)
end

---whether the game screen is showing (not the setup or join screens)
---@return boolean
local function playingView()
    return isGameView() and gameView ~= nil and not setupView and not joinView
end

---dragging the game board
---@param x number
---@param y number
---@param dx number
---@param dy number
function love.mousemoved(x, y, dx, dy)
    if playingView() then gameView:mousemoved(x, y, dx, dy) end
end

---@param button integer
function love.mousereleased(_, _, button)
    if playingView() then gameView:mousereleased(button) end
end

---closing the window: tell the others in a network game
function love.quit()
    if net then net:close() end
    return false
end
