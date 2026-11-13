--drawing tiles with the original artwork.
--
--image sets live in assets/images/<size>, where <size> is the tile size in pixels. Only the
--064 and 128 sets are kept; other sizes are drawn from the nearest set at or above them
--(128 for anything over 64), scaled. A tile is drawn as:
--* the room, Tile_<exits>.gif, where <exits> is Y/N for Up, Right, Down, Left
--(Small Rooms use Tile_Small_<exits>.gif and only come with two adjacent exits);
--* the chamber's icon, centred on top (Empty Chamber and Small Room have none).

local ASSETS = require('src.assets')
local TILES = require('src.tiles')
local E = TILES.Effect

---@class TILEART
local lib = {}

---@type integer[]
lib.SIZES = { 64, 128 }   --the image sets kept

---the image set used for a tile drawn `size` pixels wide.
---@param size integer tile size in pixels
---@return 64|128
function lib.setFor(size) return size > 64 and 128 or 64 end

--icon file for each effect (names as in the original asset folders).
---@type {[TILES.EFFECT]:string}
lib.ICON = {
    [E.Base] = "BaseStructure", [E.Destroy] = "DestroyChamber", [E.DrakonMoves] = "DrakonMoves",
    [E.DrakonsBargain] = "DrakonsBargain", [E.DrakonsDue] = "DraconsDue", [E.Escape] = "Escape",
    [E.OneGold] = "FindGold1", [E.TwoGold] = "FindGold2", [E.Float] = "FloatingRoom",
    [E.FriendlyVisit] = "FriendlyVisit", [E.HeavyGale] = "HeavyGale", [E.LockedChest] = "LockedChest",
    [E.MagicHarp] = "MagicHarp", [E.MagicShift] = "MagicalShift", [E.MagicVortex] = "MagicalVortex",
    [E.Map] = "MapChamber", [E.MasterKey] = "MasterKey", [E.MindOrb] = "MindControlOrb",
    [E.MovingTiles] = "MovingChambers", [E.Rotate] = "RotateChamber", [E.Passage] = "SecretPassage",
    [E.Start] = "Start", [E.StealLeft] = "StealLeft", [E.StealRight] = "StealRight",
    [E.StrongWind] = "StrongWind", [E.Void] = "TheVoid", [E.Tornado] = "Tornado",
    [E.WishingWell] = "WishingWell",
}

---image folder for a tile size, e.g. "assets/images/128/"
---@param size integer
---@return string
local function folder(size) return ("assets/images/%03d/"):format(lib.setFor(size)) end

---"YNNY" style code for an arrow set, in Up, Right, Down, Left order.
---@param arrows TILES.ARROWS
---@return string
function lib.exitCode(arrows)
    local s = ""
    for d = 0, 3 do s = s .. (TILES.hasArrow(arrows, d) and "Y" or "N") end
    return s
end

---room picture for a tile's exits (Tile_YNNY.gif...)
---@param tile TILES.TILE
---@param size integer
---@return love.Image
function lib.roomImage(tile, size)
    local small = tile:effect() == E.SmallRoom and "Small_" or ""
    return ASSETS.image(folder(size) .. "Tile_" .. small .. lib.exitCode(tile:arrows()) .. ".gif")
end

---chamber icon, or nil for chambers without one
---@param tile TILES.TILE
---@param size integer
---@return love.Image|nil
function lib.iconImage(tile, size)
    local name = lib.ICON[tile:effect()]
    return name and ASSETS.image(folder(size) .. "Icon_" .. name .. ".gif")
end

---the back of a tile
---@param size integer
---@return love.Image
function lib.backImage(size)
    return ASSETS.image(folder(size) .. "Tile_Back.gif")
end

---hero token for a colour name (game.COLORS), or "Drakon", from the set for `size`.
---@param colorName string a GAME.COLORS name, or "Drakon"
---@param size integer
---@return love.Image
function lib.tokenImage(colorName, size)
    return ASSETS.image(folder(size) .. "Char_" .. colorName .. ".gif")
end

---size of a token drawn for this tile size
---@param colorName string
---@param size integer
---@return number width
---@return number height
function lib.tokenSize(colorName, size)
    local img = lib.tokenImage(colorName, size)
    local k = size / lib.setFor(size)
    return img:getWidth() * k, img:getHeight() * k
end

---------------------------------------------------------------------------- animation

--the original artwork has no animations, so the chamber icons are animated in code: each
--effect has a short looping motion that fits its picture. Only the icon moves; the room
--stays still. Offsets are fractions of the tile size, angles in radians.

---how the icon is drawn at one moment
---@class TILEART.POSE
---@field dx? number sideways shift, fraction of the tile size
---@field dy? number downward shift, fraction of the tile size
---@field r? number rotation
---@field sx? number horizontal scale
---@field sy? number vertical scale
---@field glow? number 0-1: extra brightness drawn over the icon

local TAU = math.pi * 2

---0 to 1 and back, smoothly, once per `period` seconds
---@param t number
---@param period number
---@return number
local function wave(t, period)
    return 0.5 - 0.5 * math.cos(TAU * (t % period) / period)
end

---a hop: up quickly and down again, then a pause; 0 on the ground, 1 at the top
---@param t number
---@param period number
---@return number
local function hop(t, period)
    local f = (t % period) / period
    if f > 0.4 then return 0 end
    return math.sin(math.pi * f / 0.4)
end

---quarter turns with a pause after each, eased: the Rotate Chamber's motion
---@param t number
---@return number
local function quarterTurns(t)
    local step, f = math.floor(t / 0.9), (t % 0.9) / 0.9
    local ease = f < 0.45 and 0.5 - 0.5 * math.cos(math.pi * f / 0.45) or 1
    return (step + ease) * math.pi / 2
end

---@type {[TILES.EFFECT]:fun(t:number):TILEART.POSE}
lib.ANIMATION = {
    --coins spin like a coin on its edge
    [E.OneGold] = function(t) return { sx = math.cos(TAU * t / 1.4) } end,
    [E.TwoGold] = function(t) return { sx = math.cos(TAU * t / 1.4) } end,
    --a coin is lost: the hand bobs and dips
    [E.DrakonsDue] = function(t) return { dy = 0.04 * hop(t, 1.2), r = -0.12 * hop(t, 1.2) } end,
    --swirls and storms turn
    [E.Void] = function(t)
        local p = 0.9 + 0.1 * wave(t, 1.6)
        return { r = -TAU * t / 3, sx = p, sy = p }
    end,
    [E.Tornado] = function(t) return { dx = 0.04 * math.sin(TAU * t / 0.9), r = 0.15 * math.sin(TAU * t / 0.45) } end,
    [E.StrongWind] = function(t) return { dx = 0.035 * math.sin(TAU * t / 1.2), sx = 1 + 0.06 * wave(t, 0.6) } end,
    [E.HeavyGale] = function(t)
        return { dx = 0.05 * math.sin(TAU * t / 0.8), sx = 1 + 0.1 * wave(t, 0.4), sy = 1 - 0.05 * wave(t, 0.4) }
    end,
    [E.Rotate] = function(t) return { r = quarterTurns(t) } end,
    [E.MovingTiles] = function(t) return { r = TAU * t / 3 } end,
    --magic glows
    [E.MagicShift] = function(t) return { dy = -0.025 * wave(t, 1.6), glow = 0.35 * wave(t, 1.6) } end,
    [E.Escape] = function(t) return { glow = 0.5 * wave(t, 1.4) } end,
    --things that move about
    [E.DrakonMoves] = function(t) return { dy = -0.06 * hop(t, 1.0) } end,
    [E.Start] = function(t) return { dy = -0.05 * hop(t, 1.3) } end,
    [E.DrakonsBargain] = function(t) return { dx = 0.03 * math.sin(TAU * t / 1.6), r = 0.08 * math.sin(TAU * t / 1.6) } end,
    [E.Float] = function(t) return { dy = -0.05 * wave(t, 1.8) } end,
    [E.LockedChest] = function(t) return { dy = -0.03 * hop(t, 1.5), sy = 1 - 0.06 * hop(t + 0.75, 1.5) } end,
    [E.MasterKey] = function(t) return { r = 0.35 * math.sin(TAU * t / 1.4) } end,
    [E.Map] = function(t) return { r = 0.12 * math.sin(TAU * t / 1.8), dy = -0.015 * wave(t, 0.9) } end,
    [E.StealLeft] = function(t) return { dx = -0.06 * wave(t, 1.2) } end,
    [E.StealRight] = function(t) return { dx = 0.06 * wave(t, 1.2) } end,
    [E.FriendlyVisit] = function(t) return { dy = 0.025 * math.sin(TAU * t / 0.5) } end,
    [E.Base] = function(t) local p = 1 + 0.05 * wave(t, 1.6); return { sx = p, sy = p } end,
}

---------------------------------------------------------------------------- part-of-icon animations

--some animations move only part of an icon: the swirl inside the Mind Control Orb, the
--skull's eyes... These use small pixel shaders that sample the icon's own pixels (with
--nearest filtering, so they stay crisp). Positions are fractions of the icon, measured on
--the 128 set; the 064 set has the same pictures at half size.

---@type {[string]:love.Shader}
local shaders = {}

local SHADER_CODE = {
    --turn everything inside an ellipse; `twist` turns the middle further than the edge
    swirl = [[
        uniform vec2 center;
        uniform vec2 radius;
        uniform float angle;
        uniform float twist;
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec2 d = (tc - center) / radius;
            float r = length(d);
            if (r < 1.0) {
                float a = -(angle + twist * (1.0 - r));
                d = vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
                tc = center + d * radius;
            }
            return Texel(tex, tc) * color;
        }
    ]],
    --a portal seen at an angle: the rim (outside `inner`, in the ellipse's own units) turns
    --round the ellipse with a highlight sweeping along it, while the tunnel inside stays put
    portal = [[
        uniform vec2 center;
        uniform vec2 radius;
        uniform float angle;
        uniform float inner;
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec2 d = (tc - center) / radius;
            float r = length(d);
            if (r < inner) return Texel(tex, tc) * color;
            float a = -angle;
            vec2 e = vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
            vec4 p = Texel(tex, center + e * radius);
            float theta = atan(d.y, d.x);
            float sweep = max(0.0, sin(theta * 2.0 - angle * 3.0));
            p.rgb = min(vec3(1.0), p.rgb * (1.0 + 0.35 * sweep * sweep));
            return p * color;
        }
    ]],
    --light grey strings inside a box vibrate: each string's middle jumps a whole pixel to
    --either side and back, quickly, while its ends stay fixed; neighbouring strings are out
    --of step
    strings = [[
        uniform vec4 box;          // x0, y0, x1, y1
        uniform float amount;      // largest shift at the middle of a string, in texels
        uniform float phase;
        uniform float texelWidth;  // 1 / the icon's width in pixels
        bool isString(vec4 p) {
            return p.a > 0.5 && p.r > 0.55 && p.g > 0.55 && p.b > 0.5 && abs(p.r - p.g) < 0.2;
        }
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 here = Texel(tex, tc);
            if (tc.x < box.x || tc.x > box.z || tc.y < box.y || tc.y > box.w) return here * color;
            float bow = sin(3.14159 * (tc.y - box.y) / (box.w - box.y));
            float string = floor(tc.x * 16.0);
            float shift = floor(amount * bow * sin(phase + string * 1.9) + 0.5);
            vec4 moved = Texel(tex, vec2(tc.x - shift * texelWidth, tc.y));
            if (isString(moved)) return moved * color;
            if (isString(here)) return vec4(0.0);
            return here * color;
        }
    ]],
    --dark pixels inside two boxes (the eyes) glow red
    eyes = [[
        uniform vec4 left;     // x0, y0, x1, y1
        uniform vec4 right;
        uniform float glow;
        bool inBox(vec2 p, vec4 b) { return p.x >= b.x && p.x <= b.z && p.y >= b.y && p.y <= b.w; }
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 p = Texel(tex, tc);
            float lum = dot(p.rgb, vec3(0.3, 0.59, 0.11));
            if (p.a > 0.5 && lum < 0.3 && (inBox(tc, left) || inBox(tc, right))) {
                p.rgb = mix(p.rgb, vec3(1.0, 0.12, 0.05) * (0.75 + 0.5 * (0.3 - lum)), glow);
            }
            return p * color;
        }
    ]],
    --one side of a diagonal line: part 0 = the hole (y - x above `cut`, tested at the middle
    --of each art pixel so none is split), 1 = the door, 2 = the door's outline in black
    split = [[
        uniform float cut;
        uniform int part;
        uniform float texSize;
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 p = Texel(tex, tc);
            vec2 mid = (floor(tc * texSize) + 0.5) / texSize;
            bool hole = (mid.y - mid.x) > cut;
            if (part == 0 && !hole) return vec4(0.0);
            if (part > 0 && hole) return vec4(0.0);
            if (part == 2) return vec4(0.0, 0.0, 0.0, p.a) * color;
            return p * color;
        }
    ]],
}

---a shader, made the first time it is needed
---@param name string
---@return love.Shader
local function shader(name)
    local s = shaders[name]
    if not s then
        s = love.graphics.newShader(SHADER_CODE[name])
        shaders[name] = s
    end
    return s
end

---a pixel of the 128-set icon as a fraction of its size
---@param px number
---@param size number icon width (or height) in the 128 set
---@return number
local function frac(px, size) return px / size end

---draws an icon at (x, y) scaled by k, with the animation at time t
---@alias TILEART.SPECIAL fun(icon:love.Image, x:number, y:number, k:number, t:number)

---the Secret Passage's door, in pixels of each set's icon (the sets are drawn differently):
---its corners at the bottom and right ends of the hinge and at the left (across from the
---bottom), and the hole's far corner, where the door's left corner lands when shut
---@type {[integer]:{width:integer, bottom:number[], right:number[], left:number[], hole:number[]}}
local PASSAGE = {
    [32] = { width = 32, bottom = { 21.75, 23.25 }, right = { 29.75, 15.25 }, left = { 8, 9.5 }, hole = { 4, 18.5 } },
    [64] = { width = 64, bottom = { 41.75, 45.25 }, right = { 54.5, 32.5 }, left = { 19, 22.5 }, hole = { 11.5, 36.5 } },
}

---@type {[TILES.EFFECT]:TILEART.SPECIAL}
lib.SPECIAL = {
    --the green swirl inside the orb turns; the ring and the glint stay put
    [E.MindOrb] = function(icon, x, y, k, t)
        local s = shader("swirl")
        s:send("center", { frac(32, 64), frac(33, 64) })
        s:send("radius", { frac(12.5, 64), frac(12.5, 64) })
        s:send("angle", TAU * t / 4)
        s:send("twist", 1.6)
        love.graphics.setShader(s)
        love.graphics.draw(icon, x, y, 0, k, k)
        love.graphics.setShader()
    end,
    --a warp portal: the dark tunnel in the middle holds still while the rim's streaks flow
    --round the oval (turned in the plane of the ellipse, as the vortex is seen at an angle),
    --with a highlight sweeping along them
    [E.MagicVortex] = function(icon, x, y, k, t)
        local s = shader("portal")
        s:send("center", { frac(32, 64), frac(25, 48) })
        s:send("radius", { frac(32, 64), frac(15.5, 48) })
        s:send("angle", TAU * t / 2.2)
        s:send("inner", 0.5)
        love.graphics.setShader(s)
        love.graphics.draw(icon, x, y, 0, k, k)
        love.graphics.setShader()
    end,
    --the strings vibrate; the frame stays still
    [E.MagicHarp] = function(icon, x, y, k, t)
        local s = shader("strings")
        s:send("box", { frac(25, 64), frac(11, 64), frac(47, 64), frac(45, 64) })
        s:send("amount", 1.45)
        s:send("phase", TAU * t * 3.5)
        s:send("texelWidth", 1 / icon:getWidth())
        love.graphics.setShader(s)
        love.graphics.draw(icon, x, y, 0, k, k)
        love.graphics.setShader()
    end,
    --the skull's eyes light up red, hold, then fade out, and stay dark for a moment
    [E.Destroy] = function(icon, x, y, k, t)
        local f = t % 2.6
        local glow = f < 0.35 and f / 0.35 or f < 0.8 and 1 or f < 1.9 and 1 - (f - 0.8) / 1.1 or 0
        local s = shader("eyes")
        s:send("left", { frac(21, 64), frac(24, 64), frac(31, 64), frac(32, 64) })
        s:send("right", { frac(35, 64), frac(24, 64), frac(45, 64), frac(32, 64) })
        s:send("glow", glow)
        love.graphics.setShader(s)
        love.graphics.draw(icon, x, y, 0, k, k)
        love.graphics.setShader()
        if glow > 0 then
            --a soft red halo around each eye
            local r, g, b, a = love.graphics.getColor()
            local w = icon:getWidth() * k
            love.graphics.setBlendMode("add")
            for _, ex in ipairs({ 26, 40 }) do
                for ring = 3, 1, -1 do
                    love.graphics.setColor(1, 0.1, 0.05, a * glow * 0.12)
                    love.graphics.circle("fill", x + w * ex / 64, y + w * 28 / 64, w * (2 + ring * 2) / 64)
                end
            end
            love.graphics.setBlendMode("alpha")
            love.graphics.setColor(r, g, b, a)
        end
    end,
    --the trapdoor swings shut over the hole (the black area) and back: it turns on a hinge
    --along its whole right side (the lower-right edge, on the floor), from leaning open as
    --drawn down to lying flat over the hole; easing in and out, with a pause shut and a pause
    --open
    [E.Passage] = function(icon, x, y, k, t)
        local f = t % 2.6
        local shut
        if f < 0.4 then
            shut = 0                                                  --open, as drawn
        elseif f < 1.05 then
            shut = 0.5 - 0.5 * math.cos(math.pi * (f - 0.4) / 0.65)   --swinging shut
        elseif f < 1.6 then
            shut = 1                                                  --lying shut
        elseif f < 2.25 then
            shut = 0.5 + 0.5 * math.cos(math.pi * (f - 1.6) / 0.65)   --swinging open
        else
            shut = 0
        end
        local g = PASSAGE[icon:getWidth()] or PASSAGE[64]
        local u = icon:getWidth() / g.width
        --the hinge runs from the door's bottom corner (hx, hy) along (gx, gy) to its right corner
        local hx, hy = g.bottom[1] * u, g.bottom[2] * u
        local gx, gy = g.right[1] * u - hx, g.right[2] * u - hy
        --across the door, from the hinge to its far edge: (ox, oy) open as drawn; shut, it
        --lies flat along (fx, fy), reaching the hole's far corner. Open is that floor
        --direction tipped up by `lift` towards the vertical (0, wy)
        local ox, oy = g.left[1] * u - hx, g.left[2] * u - hy
        local fx, fy = g.hole[1] * u - hx, g.hole[2] * u - hy
        local lift = math.acos(ox / fx)
        local wy = (oy - fy * math.cos(lift)) / math.sin(lift)
        --the linear map taking (g, o) to (g, c) for the door turned down by `turn` from flat:
        --[a b; d e] = [g c] [g o]^-1
        local det = gx * oy - ox * gy
        ---@param turn number
        ---@return number a, number b, number d, number e
        local function map(turn)
            local cx, cy = fx * math.cos(turn), fy * math.cos(turn) + wy * math.sin(turn)
            return (gx * oy - cx * gy) / det, (cx * gx - gx * ox) / det,
                   (gy * oy - cy * gy) / det, (cy * gx - gy * ox) / det
        end
        local a, b, d, e = map(lift * (1 - shut))
        local door = love.math.newTransform()
        door:setMatrix(a, b, 0, hx - a * hx - b * hy,
                       d, e, 0, hy - d * hx - e * hy,
                       0, 0, 1, 0,
                       0, 0, 0, 1)
        love.graphics.push()
        love.graphics.translate(x, y)
        love.graphics.scale(k, k)
        if shut > 0 then
            --the part of the hole the door hid, now uncovered: black where the door lands
            --shut (its corners, pulled in a little so none shows past the shut door)
            local cr, cg, cb, ca = love.graphics.getColor()
            love.graphics.setColor(0, 0, 0, ca)
            local points = {}
            for _, st in ipairs({ { 0.1, 0.1 }, { 0.9, 0.1 }, { 0.9, 0.9 }, { 0.1, 0.9 } }) do
                points[#points + 1] = hx + st[1] * gx + st[2] * fx
                points[#points + 1] = hy + st[1] * gy + st[2] * fy
            end
            love.graphics.polygon("fill", points)
            love.graphics.setColor(cr, cg, cb, ca)
        end
        local s = shader("split")
        s:send("cut", frac(3.5, 64))   --(the hole's black starts 4 pixels below the line y = x)
        s:send("texSize", icon:getWidth())
        love.graphics.setShader(s)
        s:send("part", 0)
        love.graphics.draw(icon)                                      --the hole
        s:send("part", 1)
        love.graphics.applyTransform(door)
        love.graphics.draw(icon)                                      --the door
        love.graphics.setShader()
        love.graphics.pop()
    end,
    --sparkles twinkle on the water and around the well
    [E.WishingWell] = function(icon, x, y, k, t)
        love.graphics.draw(icon, x, y, 0, k, k)
        local r, g, b, a = love.graphics.getColor()
        local w = icon:getWidth() * k
        local px = math.max(1, math.floor(w / 64 + 0.5))   --one art pixel on screen
        local SPARKS = { { 27, 36, 0 }, { 33, 35, 0.45 }, { 38, 37, 0.9 }, { 22, 30, 1.3 },
                         { 44, 26, 0.2 }, { 30, 37, 1.7 }, { 41, 34, 1.1 } }
        for _, sp in ipairs(SPARKS) do
            local f = ((t + sp[3]) % 1.9) / 1.9
            local size = f < 0.35 and math.sin(math.pi * f / 0.35) or 0
            if size > 0 then
                local cx = math.floor(x + w * sp[1] / 64)
                local cy = math.floor(y + w * sp[2] / 64)
                local arm = math.floor(size * 3 + 0.5) * px
                love.graphics.setColor(1, 1, 1, a * (0.6 + 0.4 * size))
                love.graphics.rectangle("fill", cx - arm, cy, 2 * arm + px, px)
                love.graphics.rectangle("fill", cx, cy - arm, px, 2 * arm + px)
                love.graphics.setColor(0.7, 0.9, 1, a)
                love.graphics.rectangle("fill", cx, cy, px, px)
            end
        end
        love.graphics.setColor(r, g, b, a)
    end,
}

---the icon's pose for a tile at time `t`, or nil if it doesn't move (or has a SPECIAL animation)
---@param tile TILES.TILE
---@param t number seconds since the animation started
---@return TILEART.POSE|nil
function lib.pose(tile, t)
    local f = lib.ANIMATION[tile:effect()]
    return f and f(t)
end

---draw a tile with its top-left corner at (x, y), `size` pixels wide (scaled from its set).
---with `time`, the chamber icon plays its looping animation
---@param tile TILES.TILE
---@param x number
---@param y number
---@param size integer
---@param time? number seconds since the animation started
function lib.draw(tile, x, y, size, time)
    local k = size / lib.setFor(size)
    love.graphics.draw(lib.roomImage(tile, size), x, y, 0, k, k)
    local icon = lib.iconImage(tile, size)
    if not icon then return end
    local iw, ih = icon:getDimensions()
    local special = time and lib.SPECIAL[tile:effect()]
    if special and time then
        special(icon, math.floor(x + (size - iw * k) / 2), math.floor(y + (size - ih * k) / 2), k, time)
        return
    end
    local pose = time and lib.pose(tile, time)
    if not pose then
        love.graphics.draw(icon, math.floor(x + (size - iw * k) / 2), math.floor(y + (size - ih * k) / 2), 0, k, k)
        return
    end
    --centred on the tile, so turns and flips happen about the icon's middle; shifts are
    --rounded to whole pixels so a moving icon stays as crisp as a still one
    local cx = math.floor(x + size / 2 + (pose.dx or 0) * size + 0.5)
    local cy = math.floor(y + size / 2 + (pose.dy or 0) * size + 0.5)
    local sx, sy = (pose.sx or 1) * k, (pose.sy or 1) * k
    love.graphics.draw(icon, cx, cy, pose.r or 0, sx, sy, iw / 2, ih / 2)
    if pose.glow and pose.glow > 0 then
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setBlendMode("add")
        love.graphics.setColor(r, g, b, a * pose.glow)
        love.graphics.draw(icon, cx, cy, pose.r or 0, sx, sy, iw / 2, ih / 2)
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(r, g, b, a)
    end
end

return lib
