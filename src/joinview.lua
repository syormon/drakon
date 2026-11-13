--the join screen, after the original Connect dialog, also used to start hosting. Joining:
--your name, the host's address (port 5229 unless another is given, "address:port") and the
--password they chose. Hosting: the password others will need (may be left empty). Click a
--field (or Tab) to type in it; Enter goes; Esc goes back. The name and address are
--remembered in network.txt (the password isn't).

local UI = require('src.ui')
local WSLINK = require('src.wslink')

---a field to type in
---@class JOINVIEW.FIELD
---@field key "name"|"address"|"password"
---@field label string
---@field text string
---@field max integer

---what was typed, checked
---@class JOINVIEW.TARGET
---@field mode "join"|"host"
---@field name string
---@field address? string
---@field password string

---the join screen
---@class JOINVIEW
---@field mode "join"|"host"
---@field fields {[string]:JOINVIEW.FIELD} by key
---@field focus string key of the field being typed in
---@field message {text:string, error?:boolean}|nil
---@field connecting boolean waiting for an answer
---@field request "connect"|"cancel"|nil what main.lua should do
---@field hits {x:number, y:number, w:number, h:number, kind:string, key?:string}[]
local lib = {}

local SAVE_FILE = "network.txt"
---the fields shown, in order
---@type {[string]:string[]}
local SHOWN = { join = { "name", "address", "password" }, host = { "password" } }

---@param name string the name to offer (the setup's first person)
---@param hosting? boolean starting to host (else joining)
---@return JOINVIEW
function lib:new(name, hosting)
    local saved = {}
    local text = love.filesystem.getInfo(SAVE_FILE) and love.filesystem.read(SAVE_FILE) or ""
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do saved[#saved + 1] = line end
    local mode = hosting and "host" or "join"
    local o = {
        mode = mode,
        fields = {
            name = { key = "name", label = "Your name", text = (saved[1] or "") ~= "" and saved[1] or name, max = 24 },
            address = { key = "address", label = "Host address", text = saved[2] or "", max = 120 },
            password = { key = "password", label = "Password", text = "", max = 64 },
        },
        focus = "password",
        message = nil,
        connecting = false,
        request = nil,
        hits = {},
    }
    --start on the first field still empty
    for _, key in ipairs(SHOWN[mode]) do
        if o.fields[key].text == "" then o.focus = key; break end
    end
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param text string
---@param isError? boolean
function lib:setMessage(text, isError) self.message = { text = text, error = isError } end

---@param key string
---@return string
function lib:value(key)
    return (self.fields[key].text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---what to join or host, checked; or nil and what is missing
---@return JOINVIEW.TARGET|nil
---@return string? err
function lib:target()
    local password = self.fields.password.text
    if self.mode == "host" then return { mode = "host", name = "", password = password } end
    local name = self:value("name")
    if name == "" then return nil, "Type your name" end
    local address = self:value("address")
    local url, err = WSLINK.url(address)
    if not url then return nil, err end
    return { mode = "join", name = name, address = address, password = password }
end

---remember what was typed for next time (not the password)
function lib:remember()
    love.filesystem.write(SAVE_FILE, self:value("name") .. "\n" .. self:value("address") .. "\n")
end

---try to go: sets request, or explains what's missing
function lib:connect()
    if self.connecting then return end
    local t, err = self:target()
    if not t then return self:setMessage(err or "Check what you typed", true) end
    if self.mode == "join" then self:remember() end
    self.request = "connect"
end

---@param self JOINVIEW
---@param x number
---@param y number
---@param w number
---@param h number
---@param kind string
---@param key? string
local function hit(self, x, y, w, h, kind, key)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, kind = kind, key = key }
end

---@param self JOINVIEW
---@param x number
---@param y number
---@param label string
---@param kind string
---@param primary? boolean
---@return number x where the next button goes
local function button(self, x, y, label, kind, primary)
    local w = UI.font(14):getWidth(label) + 32
    UI.box(x, y, w, 34, primary and { 0.45, 0.36, 0.18 } or { 0.30, 0.26, 0.20 }, 5)
    UI.text(label, x + 16, y + 8, 14, primary and UI.COLOR.accent or UI.COLOR.text)
    hit(self, x, y, w, 34, kind)
    return x + w + 12
end

---@param top number y the screen starts at
function lib:draw(top)
    self.hits = {}
    local w = love.graphics.getWidth()
    local pw = math.min(560, w - 40)
    local left = math.floor((w - pw) / 2)
    local y = top + 40
    UI.box(left - 24, y - 20, pw + 48, 420, UI.COLOR.panel, 10)
    UI.outline(left - 24, y - 20, pw + 48, 420, UI.COLOR.border, 1, 10)
    UI.text(self.mode == "host" and "Host a game" or "Join a game", left, y, 22, UI.COLOR.accent)
    y = y + 50
    for _, key in ipairs(SHOWN[self.mode]) do
        local f = self.fields[key]
        UI.text(f.label, left, y + 8, 14, UI.COLOR.dim)
        local fx, fw = left + 140, pw - 140
        local on = (key == self.focus) and not self.connecting
        UI.box(fx, y, fw, 34, on and UI.COLOR.cardActive or UI.COLOR.card, 5)
        if on then UI.outline(fx, y, fw, 34, UI.COLOR.accent, 1, 5) end
        local caret = (on and love.timer.getTime() % 1 < 0.5) and "_" or ""
        local shown = key == "password" and ("*"):rep(#f.text) or f.text
        UI.text(shown .. caret, fx + 10, y + 8, 15, UI.COLOR.text, fw - 20)
        hit(self, fx, y, fw, 34, "field", key)
        y = y + 48
    end
    y = y + 6
    local go = self.mode == "host" and "Host (Enter)" or "Connect (Enter)"
    local bx = button(self, left + 140, y, self.connecting and "Connecting..." or go, "connect", true)
    button(self, bx, y, self.connecting and "Cancel (Esc)" or "Back (Esc)", "cancel")
    y = y + 56
    local help
    if self.mode == "host" then
        help = ("Others join your game with this password (or none, if you leave it empty). They type "
            .. "this computer's address, shown on your setup screen once you host. On the same network "
            .. "(home Wi-Fi) that is all it takes; over the internet, your router must forward TCP port %d "
            .. "to this computer. Players can join from the web version too: on an https page (GitHub Pages) it needs "
            .. "a secure address, so put a proxy with a certificate (e.g. nginx) in front."):format(WSLINK.PORT)
    else
        help = ("Type the host's address and the password they chose: their computer's address (port %d "
            .. "unless they give another, as address:port), or their secure address if they have one "
            .. "(e.g. game.example.com; the web version on GitHub Pages needs that)."):format(WSLINK.PORT)
    end
    UI.text(help, left, y, 13, UI.COLOR.dim, pw)
    if self.message then
        UI.text(self.message.text, left, y + UI.textHeight(help, 13, pw) + 14, 14,
            self.message.error and UI.COLOR.bad or UI.COLOR.good, pw)
    end
    love.graphics.setFont(UI.font(12))
end

---@param mx number
---@param my number
function lib:mousepressed(mx, my)
    for n = #self.hits, 1, -1 do
        local r = self.hits[n]
        if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
            if r.kind == "field" then self.focus = r.key --[[@as string]]
            elseif r.kind == "connect" then self:connect()
            elseif r.kind == "cancel" then self.request = "cancel" end
            return
        end
    end
end

---@param t string
function lib:textinput(t)
    if self.connecting then return end
    local f = self.fields[self.focus]
    if #f.text < f.max then f.text = f.text .. t:gsub("[\t\r\n]", "") end
end

---@param key love.KeyConstant
function lib:keypressed(key)
    if key == "escape" then self.request = "cancel"; return end
    if self.connecting then return end
    local f = self.fields[self.focus]
    local shown = SHOWN[self.mode]
    local at = 1
    for i, k in ipairs(shown) do if k == self.focus then at = i end end
    if key == "return" or key == "kpenter" then self:connect()
    elseif key == "tab" or key == "down" then self.focus = shown[at % #shown + 1]
    elseif key == "up" then self.focus = shown[(at - 2) % #shown + 1]
    elseif key == "backspace" then
        local t = f.text
        local cut = #t
        while cut > 0 and t:byte(cut) >= 0x80 and t:byte(cut) < 0xC0 do cut = cut - 1 end
        f.text = t:sub(1, math.max(0, cut - 1))
    elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl") then
        self:textinput((love.system.getClipboardText() or ""):gsub("[\r\n]", ""))
    end
end

return lib
