function love.conf(t)
    t.window.title = "RGB Suite"
    t.window.width = 720          -- CubeXX square; overridden to native on device
    t.window.height = 720
    t.window.resizable = true     -- lets desktop testing try other aspect ratios
    t.window.fullscreen = false
    t.window.vsync = 1
    t.window.msaa = 4             -- anti-alias the arrow triangles + rounded pills
    t.identity = "rgbsuite"
end
