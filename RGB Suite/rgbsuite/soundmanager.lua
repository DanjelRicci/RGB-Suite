-- soundmanager.lua - original synthesized "mellow pluck" UI cues (warm kalimba
-- feel; generated from scratch, no third-party pack). One cue for navigation
-- (up/down) and one for value-adjust (left/right); adjust sits a minor third
-- higher (it changes settings) and is quieter as it fires rapidly while scrubbing.
-- "blocked" answers a press into a greyed chevron: same instrument, a fourth below
-- the nav cue and shorter, so a refusal never sounds like a change. It must stay at
-- or above A4 - the handheld speaker rolls off under ~400Hz, and an earlier D4
-- version was inaudible on device despite firing correctly.

local soundmanager = {}

local sounds = {}
local volumes = { move = 0.4, adjust = 0.28, blocked = 0.30, select = 0.5, intro = 0.85 }

function soundmanager.load()
    sounds.move   = love.audio.newSource("assets/sounds/move.wav", "static")    -- up/down (D5)
    sounds.adjust = love.audio.newSource("assets/sounds/adjust.wav", "static")  -- left/right (F5)
    sounds.blocked = love.audio.newSource("assets/sounds/blocked.wav", "static") -- limit hit (A4)
    sounds.select = love.audio.newSource("assets/sounds/select.wav", "static")
    sounds.intro  = love.audio.newSource("assets/sounds/intro.wav", "static")

    for key, sound in pairs(sounds) do
        if volumes[key] then sound:setVolume(volumes[key]) end
    end
end

local function play(name)
    local s = sounds[name]
    if s then s:stop(); s:play() end
end

function soundmanager.playUp()     play("move") end
function soundmanager.playDown()   play("move") end
function soundmanager.playLeft()   play("adjust") end
function soundmanager.playRight()  play("adjust") end
function soundmanager.playBlocked() play("blocked") end
function soundmanager.playSelect() play("select") end
function soundmanager.playIntro()  play("intro") end

return soundmanager
