-- RGB Suite - standalone muOS RGB controller (JanTrueno RGB Controller modes +
-- Screen React), driving the sticks directly through its own daemon.
-- Credits: (c) Danjel Ricci. Original RGB Controller concept by JanTrueno.

local config = require("config")
local tables = require("tables")
local input = require("input")
local draw = require("draw")
local sound = require("soundmanager")

-- Brightness Mode = Screen turns the Brightness row into a live readout of the
-- panel backlight. The daemon reads the same node on its own clock; this poll is
-- only so the number on screen keeps up with the volume-key brightness combo.
local SCREEN_POLL = 0.25
local screenPoll = 0

local fadeDuration = 0.4
local fadeTimer = 0

local showHint = false          -- the "enable User init scripts" note
local HINT_ARM = 0.3            -- ignore presses this long so the press that opened it can't dismiss it
local hintTimer = 0             -- time the note has been up (armed after HINT_ARM)
local swallowInput = false      -- after dismissing the note, ignore the still-held
                                -- button until release so it doesn't also move/quit

function love.load()
    -- Fill the screen at native resolution on device; keep the conf window for
    -- desktop testing (set RGB_SUITE_DEV=1 to skip the resize).
    if not os.getenv("RGB_SUITE_DEV") then
        local dw, dh = love.window.getDesktopDimensions()
        love.window.setMode(dw, dh, { fullscreen = false, vsync = 1, msaa = 4 })
    end

    sound.load()
    config.load()
    input.load()
    draw.load()

    -- Make sure settings.cfg exists and the daemon is showing the current mode.
    config.commit()

    showHint = not config.hintSeen()
    hintTimer = 0

    sound.playIntro()
    fadeTimer = 0
end

local function dismissHint()
    if not showHint or hintTimer < HINT_ARM then return end
    showHint = false
    swallowInput = true
    config.markHintSeen()
    sound.playSelect()
end

function love.update(dt)
    if showHint then
        -- frozen; the *pressed callbacks below dismiss the note
        hintTimer = hintTimer + dt
    elseif swallowInput then
        -- the button that closed the note is still held: don't let it also drive
        -- the cursor / quit; resume input only once it's released
        if not input.actionHeld() then swallowInput = false end
    else
        if input.update(dt) == "info" then
            showHint = true
            hintTimer = 0
            sound.playSelect()
        end
    end

    if tables.state.screenSrc then
        screenPoll = screenPoll + dt
        if screenPoll >= SCREEN_POLL then
            screenPoll = 0
            -- keep the last good value on a failed read: muOS rewrites the file
            -- under a lock, so a poll can land mid-write, and blanking the readout
            -- for a frame would look like the brightness jumped
            local v = config.screenLedLevel()
            if v then tables.state.screenLed = v end
        end
    end

    draw.update(dt)
    if fadeTimer < fadeDuration then fadeTimer = fadeTimer + dt end
end

function love.draw()
    draw.render()
    if showHint then draw.hintCard() end
    if fadeTimer < fadeDuration then
        love.graphics.setColor(0, 0, 0, 1 - fadeTimer / fadeDuration)
        love.graphics.rectangle("fill", 0, 0, love.graphics.getDimensions())
        love.graphics.setColor(1, 1, 1, 1)
    end
end

-- Any button/key dismisses the first-launch note (gptokeyb maps the pad to keys
-- on device; the joystick callbacks cover a directly-read controller).
function love.keypressed() dismissHint() end
function love.gamepadpressed() dismissHint() end
function love.joystickpressed() dismissHint() end

function love.resize()
    draw.load()
end
