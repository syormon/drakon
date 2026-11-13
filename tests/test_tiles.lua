--tests for src/tiles.lua. Runs under plain Lua (no LÖVE needed), from the repository's top folder:
--lua tests/test_tiles.lua [path\to\Drakon.exe]
--with the exe path, it also checks every name and help text against the original.

package.path = "./?.lua;./src/?.lua;" .. package.path
local TILES = require('src.tiles')
local E, S = TILES.Effect, TILES.Style
local U, R, D, L = TILES.UP, TILES.RIGHT, TILES.DOWN, TILES.LEFT
local set = TILES.arrowSet

local passed, failed = 0, 0
---count a check, printing it when it fails
---@param name string
---@param cond any
---@param detail? any shown when it fails
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
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
---check that fn raises an error containing msg
---@param name string
---@param fn function
---@param msg string
local function errors(name, fn, msg)
    local ok, err = pcall(fn)
    check(name, not ok and tostring(err):find(msg, 1, true), err)
end

--tables are complete
eq("30 effects", TILES.EFFECT_COUNT, 30)
for e = 0, 29 do
    check("name " .. e, type(TILES.EffectName[e]) == "string")
    check("help " .. e, type(TILES.EffectHelp[e]) == "string")
end
check("no 31st name", TILES.EffectName[30] == nil)
eq("enum order: LockedChest", E.LockedChest, 12)
eq("enum order: WishingWell", E.WishingWell, 29)
eq("enum name lookup", TILES.EffectId[23], "Start")

--kind encoding (effect in bits 0-4, arrows in bits 5-8)
eq("makeKind", TILES.makeKind(E.LockedChest, set(U, D)), 12 + 5 * 32)
---@diagnostic disable-next-line: deprecated (the tests run under Lua 5.3+, where math.type exists)
eq("integer kinds", math.type and math.type(TILES.makeKind(E.Map, set(R, L))) or "integer", "integer")
for e = 0, 29 do
    for a = 0, 15 do
        local k = TILES.makeKind(e, a)
        check(("round trip %d/%d"):format(e, a), TILES.kindEffect(k) == e and TILES.kindArrows(k) == a)
    end
end
errors("invalid kind", function() TILES.kindEffect(30) end, "Invalid tile kind: 30")

--arrow styles
eq("no arrows", TILES.arrowsToStyle(0), S.None)
for d = 0, 3 do eq("one arrow " .. d, TILES.arrowsToStyle(set(d)), S.One) end
eq("up+right adjacent", TILES.arrowsToStyle(set(U, R)), S.TwoAdjacent)
eq("right+down adjacent", TILES.arrowsToStyle(set(R, D)), S.TwoAdjacent)
eq("down+left adjacent", TILES.arrowsToStyle(set(D, L)), S.TwoAdjacent)
eq("left+up adjacent (wraps)", TILES.arrowsToStyle(set(L, U)), S.TwoAdjacent)
eq("up+down opposite", TILES.arrowsToStyle(set(U, D)), S.TwoOpposite)
eq("right+left opposite", TILES.arrowsToStyle(set(R, L)), S.TwoOpposite)
eq("three arrows", TILES.arrowsToStyle(set(U, R, D)), S.Three)
errors("four arrows", function() TILES.arrowsToStyle(15) end, "Invalid tile arrows")

--rotation is clockwise and keeps the effect
local k = TILES.makeKind(E.Map, set(U))
eq("rotate 1: up -> right", TILES.kindArrows(TILES.rotateKind(k, 1)), set(R))
eq("rotate 2: up -> down", TILES.kindArrows(TILES.rotateKind(k, 2)), set(D))
eq("rotate -1 == rotate 3", TILES.rotateKind(k, -1), TILES.rotateKind(k, 3))
eq("rotate 4 is identity", TILES.rotateKind(k, 4), k)
eq("rotate keeps effect", TILES.kindEffect(TILES.rotateKind(k, 1)), E.Map)
for a = 0, 14 do
    local kk = TILES.makeKind(E.Empty, a)
    eq("rotation keeps style " .. a, TILES.kindStyle(TILES.rotateKind(kk, 1)), TILES.kindStyle(kk))
end

--directions
eq("opposite up", TILES.opposite(U), D)
eq("clockwise left", TILES.clockwise(L), U)
local x, y = TILES.neighbor(5, 5, U)
check("neighbor up is y-1", x == 5 and y == 4)
x, y = TILES.neighbor(5, 5, R)
check("neighbor right is x+1", x == 6 and y == 5)
eq("arrowsToString", TILES.arrowsToString(set(U, L)), "Up, Left")

--tile objects
local t = TILES.fromParts(E.Tornado, set(U, R))
eq("tile effect", t:effect(), E.Tornado)
eq("tile name", t:effectName(), "Tornado")
eq("tile style name", t:styleName(), "Two Adjacent Arrows")
check("tile exits", t:hasExit(U) and t:hasExit(R) and not t:hasExit(D))
t:setArrows(set(D, L))
eq("setArrows same style", t:arrows(), set(D, L))
errors("setArrows other style", function() t:setArrows(set(U, D)) end,
       "TTile.SetArrows: Cannot change arrow style")
local c = t:clone()
c:rotate(1)
check("clone is independent", c.kind ~= t.kind)
eq("tostring", tostring(TILES.fromParts(E.Start, set(U))), "Start [Up]")

--verbatim check against the original executable
local exePath = arg[1]
if exePath then
    local f = assert(io.open(exePath, "rb"))
    local exe = f:read("a") or f:read("*a")
    f:close()
    ---@param s string ASCII
    ---@return string
    local function utf16(s) return (s:gsub(".", "%0\0")) end  --all texts are plain ASCII
    for e = 0, 29 do
        check("name in exe: " .. TILES.EffectName[e], exe:find(utf16(TILES.EffectName[e]), 1, true))
        check("help in exe: " .. TILES.EffectName[e], exe:find(utf16(TILES.EffectHelp[e]), 1, true))
    end
    for s = 0, 4 do check("style name in exe " .. s, exe:find(utf16(TILES.StyleName[s]), 1, true)) end
else
    print("(skipping exe comparison: pass the path to Drakon.exe to include it)")
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
