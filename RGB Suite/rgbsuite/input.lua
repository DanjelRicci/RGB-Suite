-- input.lua - button-only control. Up/Down move the highlight, Left/Right change
-- the highlighted row's value, L1+R1 quits. Keyboard arrows mirror it for desktop.

local tables = require("tables")
local config = require("config")
local sound = require("soundmanager")

local input = {}

-- Auto-repeat, split into two timings. A single delay for both meant a direction
-- held a fraction too long stepped twice, which is very easy to do on a d-pad, so
-- the FIRST repeat now waits twice as long as the ones after it.
local REPEAT_DELAY = 0.26  -- hold this long before a held direction repeats at all
local REPEAT_RATE  = 0.13  -- and this long between each repeat after that
local sinceMove = REPEAT_DELAY
local repeating = false    -- true once the held direction has actually repeated
local lastDir              -- direction that produced the last action, nil if released
-- Re-opens the boot-persistence note, on the button labelled X.
--
-- Device-confirmed 2026-09-11: muOS on the CubeXX maps the face buttons by their
-- PRINTED LABEL, not by SDL's positional convention - so "x" is the X button, and
-- SDL's usual "north = y" rule does NOT hold here ("y" turned out to be the button
-- labelled Y). Do not "correct" this to "y".
local BTN_INFO = "x"

local joystick

function input.load()
    local js = love.joystick.getJoysticks()
    if #js > 0 then joystick = js[1] end
end

local function pad(btn) return joystick and joystick:isGamepadDown(btn) end
local function key(k) return love.keyboard.isDown(k) end

local function held()
    return {
        up    = pad("dpup") or key("up"),
        down  = pad("dpdown") or key("down"),
        left  = pad("dpleft") or key("left"),
        right = pad("dpright") or key("right"),
        quit  = (pad("leftshoulder") and pad("rightshoulder")) or key("escape"),
        info  = pad(BTN_INFO) or key("x"),
    }
end

-- True while ANY control input.update() reacts to is physically held. Checks the
-- two shoulders INDIVIDUALLY (not the L1+R1 quit combo), so dismissing the
-- first-launch note on the first shoulder press keeps swallowing until BOTH are
-- released - otherwise completing the combo would still quit. Used by main.lua.
function input.actionHeld()
    return pad("dpup") or pad("dpdown") or pad("dpleft") or pad("dpright")
        or pad("leftshoulder") or pad("rightshoulder") or pad(BTN_INFO)
        or key("up") or key("down") or key("left") or key("right")
        or key("escape") or key("x")
end

local function wrap(i, n) return ((i - 1) % n) + 1 end

-- Scrub the stick colour over the hue grid (8-deg steps, 0..352) plus a white
-- stop (-1) tucked in past either end - a pure hue can never reach white.
local function scrubHue(cur, dir)
    if cur < 0 then return (dir > 0) and 0 or 352 end
    local n = cur + dir * 8
    if n < 0 or n > 352 then return -1 end
    return n
end

-- Move the selection, keeping it inside the current mode's rows.
local function move(dir)
    local keys = tables.rowKeys()
    tables.state.sel = wrap(tables.state.sel + dir, #keys)
    if dir < 0 then sound.playUp() else sound.playDown() end
end

-- Change the value of the highlighted row.
local function adjust(dir)
    local s = tables.state
    local k = tables.rowKeys()[s.sel]

    -- Pressing into a greyed chevron gets its own cue and changes nothing. This is
    -- the single gate for every clamped row, so it also stops the pointless
    -- settings.cfg write + daemon poke a no-op used to trigger.
    local canL, canR = tables.canAdjust(k)
    if (dir < 0 and not canL) or (dir > 0 and not canR) then
        sound.playBlocked()
        return
    end

    if k == "mode" then
        local list = tables.availableModes()
        local idx = 1
        for i, m in ipairs(list) do if m == s.mode then idx = i break end end
        s.mode = list[wrap(idx + dir, #list)]
        s.sel = 1
    elseif k == "colour" then
        s.hue = scrubHue(s.hue, dir)
    elseif k == "combo" then
        local f = tables.comboFields()
        s[f[1]] = wrap(s[f[1]] + dir, #tables.combos)
    elseif k == "lcolour" then
        local f = tables.comboFields()
        s[f[2]] = scrubHue(s[f[2]], dir)
    elseif k == "rcolour" then
        local f = tables.comboFields()
        s[f[3]] = scrubHue(s[f[3]], dir)
    elseif k == "speed" then
        s.speed = math.max(1, math.min(3, s.speed + dir))
    elseif k == "brightmode" then
        s.brightmode = math.max(1, math.min(#tables.brightmodes, s.brightmode + dir))
    elseif k == "bright" then
        -- the greyed-chevron gate above already covers Screen mode, where both
        -- directions are refused
        s.bright = math.max(0, math.min(1, math.floor((s.bright + dir * 0.05) * 100 + 0.5) / 100))
    elseif k == "lowbatt" then
        s.lowbatt = math.max(1, math.min(tables.lowbattCount(), s.lowbatt + dir))
    end

    -- keep selection valid if the row set changed (e.g. Custom on/off)
    local keys = tables.rowKeys()
    if s.sel > #keys then s.sel = #keys end

    if dir < 0 then sound.playLeft() else sound.playRight() end
    config.commit()
end

function input.update(dt)
    sinceMove = sinceMove + dt
    local h = held()

    if h.quit then love.event.quit() return end
    -- caller opens the note; input stays frozen while it is up, so the press that
    -- opened it cannot also drive the menu underneath
    if h.info then return "info" end

    local dir
    if h.up then dir = "up"
    elseif h.down then dir = "down"
    elseif h.left then dir = "left"
    elseif h.right then dir = "right" end

    -- nothing held: forget the hold so the next press acts at once instead of
    -- inheriting a repeat that was already in flight
    if not dir then
        lastDir, repeating = nil, false
        return
    end

    if dir == lastDir then
        -- still holding the same way: wait out the long delay, then repeat quickly
        if sinceMove < (repeating and REPEAT_RATE or REPEAT_DELAY) then return end
        repeating = true
    else
        -- a fresh press, or a change of direction mid-hold: act immediately, but
        -- keep a floor so a pad that bounces off for one frame can't double-step
        if sinceMove < REPEAT_RATE then return end
        repeating = false
    end

    if dir == "up" then move(-1)
    elseif dir == "down" then move(1)
    elseif dir == "left" then adjust(-1)
    else adjust(1) end

    lastDir = dir
    sinceMove = 0
end

return input
