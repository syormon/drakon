--shared look for the screens: fonts, colours and small drawing helpers.
--everything is drawn on whole pixels so text and lines stay sharp.

local ASSETS = require('src.assets')

---@class UI
local lib = {}

---@alias UI.COLOR number[] r, g, b (and alpha) from 0 to 1

---@type {[string]:UI.COLOR}
lib.COLOR = {
    background = { 0.11, 0.10, 0.09 },
    board = { 0.15, 0.135, 0.12 },
    panel = { 0.085, 0.078, 0.07 },
    card = { 0.16, 0.145, 0.13 },
    cardActive = { 0.22, 0.19, 0.15 },
    border = { 0.30, 0.27, 0.23 },
    text = { 0.93, 0.90, 0.84 },
    dim = { 0.62, 0.58, 0.52 },
    faint = { 0.42, 0.39, 0.35 },
    accent = { 1.00, 0.80, 0.32 },
    good = { 0.45, 0.95, 0.55 },
    bad = { 1.00, 0.45, 0.40 },
    blue = { 0.40, 0.72, 1.00 },
    purple = { 0.80, 0.50, 1.00 },
    orange = { 1.00, 0.58, 0.20 },
    teal = { 0.30, 0.90, 0.85 },
}

---@type {[integer]:love.Font}
local fonts = {}

---the default font at a size, made once
---@param size integer
---@return love.Font
function lib.font(size)
    local f = fonts[size]
    if not f then
        f = love.graphics.newFont(size, "normal")
        fonts[size] = f
    end
    return f
end

---set a colour, with an optional alpha that replaces the colour's own
---@param c UI.COLOR
---@param alpha? number
function lib.color(c, alpha)
    love.graphics.setColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

---print text on whole pixels
---@param text string
---@param x number
---@param y number
---@param size integer font size
---@param c UI.COLOR
---@param width? number wrap at this width
---@param align? love.AlignMode
function lib.text(text, x, y, size, c, width, align)
    love.graphics.setFont(lib.font(size))
    lib.color(c)
    if width then
        love.graphics.printf(text, math.floor(x), math.floor(y), math.floor(width), align or "left")
    else
        love.graphics.print(text, math.floor(x), math.floor(y))
    end
end

---height of text wrapped at a width
---@param text string
---@param size integer
---@param width number
---@return number
function lib.textHeight(text, size, width)
    local f = lib.font(size)
    local _, lines = f:getWrap(text, math.floor(width))
    return #lines * f:getHeight()
end

---a filled rounded box
---@param x number
---@param y number
---@param w number
---@param h number
---@param c UI.COLOR
---@param radius? number default 6
function lib.box(x, y, w, h, c, radius)
    lib.color(c)
    love.graphics.rectangle("fill", math.floor(x), math.floor(y), math.floor(w), math.floor(h), radius or 6)
end

---a crisp rounded outline, inside the given rectangle
---@param x number
---@param y number
---@param w number
---@param h number
---@param c UI.COLOR
---@param width? integer line width, default 1
---@param radius? number default 6
function lib.outline(x, y, w, h, c, width, radius)
    width = width or 1
    local half = width / 2
    lib.color(c)
    love.graphics.setLineStyle("rough")
    love.graphics.setLineWidth(width)
    love.graphics.rectangle("line", math.floor(x) + half, math.floor(y) + half,
        math.floor(w) - width, math.floor(h) - width, radius or 6)
    love.graphics.setLineWidth(1)
end

---a key cap like [Enter]; returns its width
---@param key string
---@param x number
---@param y number
---@return number width
function lib.keycap(key, x, y)
    local f = lib.font(12)
    local w = f:getWidth(key) + 12
    lib.box(x, y, w, 20, lib.COLOR.border, 4)
    lib.box(x, y, w, 18, { 0.40, 0.36, 0.30 }, 4)
    lib.text(key, x + 6, y + 2, 12, lib.COLOR.text)
    return w
end

---a small label on a coloured background; returns its width
---@param label string
---@param x number
---@param y number
---@param c UI.COLOR
---@return number width
function lib.tag(label, x, y, c)
    local f = lib.font(11)
    local w = f:getWidth(label) + 10
    lib.box(x, y, w, 16, { c[1] * 0.35, c[2] * 0.35, c[3] * 0.35 }, 8)
    lib.text(label, x + 5, y + 1, 11, c)
    return w
end

---one of the game's small icons (the 064 set, drawn at its own size)
---@param name string file name without folder, e.g. "Icon_Gold.gif"
---@param x number
---@param y number
---@param scale? integer whole-number scale, default 1
function lib.icon(name, x, y, scale)
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(ASSETS.image("assets/images/064/" .. name), math.floor(x), math.floor(y), 0, scale or 1, scale or 1)
end

---@class UI.BUTTON
---@field x number
---@field y number
---@field w number
---@field h number
---@field label string

---a row of small buttons ending at `right` (the first label leftmost), lit up under the mouse;
---returns where each was drawn, for clicks (see lib.hit)
---@param labels string[]
---@param right number
---@param y number
---@return UI.BUTTON[]
function lib.buttonRow(labels, right, y)
    local f, h, gap = lib.font(15), 28, 4
    local widths, total = {}, 0
    for i, label in ipairs(labels) do
        widths[i] = math.max(h, f:getWidth(label) + 16)
        total = total + widths[i] + (i > 1 and gap or 0)
    end
    local mx, my = love.mouse.getPosition()
    local x = math.floor(right - total)
    ---@type UI.BUTTON[]
    local rects = {}
    for i, label in ipairs(labels) do
        local w = widths[i]
        local over = mx >= x and mx < x + w and my >= y and my < y + h
        lib.box(x, y, w, h, over and lib.COLOR.cardActive or lib.COLOR.card, 5)
        lib.outline(x, y, w, h, over and lib.COLOR.dim or lib.COLOR.border, 1, 5)
        lib.text(label, x + math.floor((w - f:getWidth(label)) / 2), y + math.floor((h - f:getHeight()) / 2), 15, lib.COLOR.text)
        rects[i] = { x = x, y = y, w = w, h = h, label = label }
        x = x + w + gap
    end
    return rects
end

---the label of the button at (x, y), if any
---@param rects UI.BUTTON[]|nil
---@param x number
---@param y number
---@return string|nil
function lib.hit(rects, x, y)
    for _, r in ipairs(rects or {}) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return r.label end
    end
end

return lib
