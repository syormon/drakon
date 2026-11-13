--runs every tests/test_*.lua inside LÖVE, on LuaJIT (close to the Lua 5.1 the web version
--runs on), as the plain-Lua runs (lua tests/...) use a newer Lua.
--love . --run tools/lovetests.lua

local files = love.filesystem.getDirectoryItems("tests")
table.sort(files)
local bad = 0
local realPrint, realExit = print, os.exit
for _, f in ipairs(files) do
    if f:match("^test_.*%.lua$") then
        local last = ""
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            last = table.concat(parts, " ")
            if last:match("^FAIL") then realPrint("  " .. last) end
        end
        rawset(os, "exit", function(code) error({ exit = code }, 0) end)   --(a test's exit ends just that test)
        arg = {}
        local chunk, err = love.filesystem.load("tests/" .. f)
        local ok, res = false, err
        if chunk then ok, res = pcall(chunk) end
        print = realPrint
        rawset(os, "exit", realExit)
        if not ok and not (type(res) == "table" and res.exit == 0) then
            bad = bad + 1
            print(("%s: %s"):format(f, type(res) == "table" and ("exit " .. tostring(res.exit) .. ", " .. last) or tostring(res)))
        else
            print(("%s: %s"):format(f, last))
            if last:match("[1-9]%d* failed") then bad = bad + 1 end
        end
    end
end
print(bad == 0 and "all test files passed under LuaJIT" or (bad .. " test files FAILED under LuaJIT"))
if bad > 0 then error("tests failed") end
