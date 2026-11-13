---LÖVE settings
---@param t table
function love.conf(t)
    t.identity = "drakon"
    t.version = "11.5"
    t.window.title = "Drakon"
    t.window.icon = "assets/icon.png"
    t.window.width = 1280
    t.window.height = 800
    t.window.resizable = true
    t.window.minwidth = 800
    t.window.minheight = 600
end
