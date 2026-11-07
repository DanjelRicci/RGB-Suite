-- tables.lua - the mode/row model + live UI state + small logic helpers.
-- Mirrors the locked mockup (MODES / ROWS / COMBOS / rowKeys / accent).

local color = require("color")

local tables = {}

-- Display names; internal ids are mapped in config.lua.
tables.modes = {
    "Off", "Static", "Breathing", "Combo",
    "Theme", "Color Cycle", "Rainbow", "Sparkle", "Screen React", "Stick React",
}

-- Mode-specific rows only (the top group). Mode is prepended in modeKeys();
-- "combo" also brings the two color rows on Custom, right under it. Brightness +
-- Low Battery are NOT here - they are the shared global group (see globalKeys()).
tables.rows = {
    ["Off"]          = {},
    ["Static"]       = { "color" },
    ["Breathing"]    = { "color", "speed" },
    ["Combo"] = { "combo" },
    ["Theme"]        = {},
    ["Color Cycle"]  = { "speed" },
    ["Rainbow"]      = { "speed" },
    ["Sparkle"]      = { "combo", "speed" },
    ["Screen React"] = {},
    ["Stick React"]  = { "combo" },
}

tables.speeds = { "Slow", "Medium", "Fast" }
tables.lowbatt = { "None", "Dim 50%", "Off", "Breathe Red" }

-- Low Battery choices offered right now. Breathe Red is the H700 firmware breath, which
-- the led_anim backend doesn't have (the same reason Breathing is hidden there), so a
-- TrimUI board stops at Off.
function tables.lowbattCount()
    return tables.state.sysfs and 3 or #tables.lowbatt
end

-- Where the LED brightness comes from. "Direct" = the Brightness slider below it.
-- "Screen" = follow the panel backlight, so the sticks dim with the screen. Only
-- offered when config.load() actually found a backlight to read (state.screenSrc).
tables.brightmodes = { "Direct", "Screen" }

-- The 14 muOS presets from common/colour.c, + Custom. a = left stick (screen
-- left), b = right stick, matching the mockup's left-to-right swatch gradient.
tables.combos = {
    { n = "Switch",       a = { 255, 0, 0 },     b = { 0, 0, 255 } },
    { n = "Melon",        a = { 255, 0, 0 },     b = { 0, 255, 0 } },
    { n = "Neon",         a = { 255, 0, 30 },    b = { 0, 228, 54 } },
    { n = "Tropical",     a = { 255, 69, 0 },    b = { 0, 255, 0 } },
    { n = "Cotton Candy", a = { 255, 236, 39 },  b = { 255, 119, 168 } },
    { n = "Sunset",       a = { 255, 94, 19 },   b = { 138, 43, 226 } },
    { n = "Aurora",       a = { 0, 255, 127 },   b = { 64, 64, 255 } },
    { n = "Cyberpunk",    a = { 0, 255, 255 },   b = { 255, 0, 180 } },
    { n = "Lava",         a = { 255, 30, 0 },    b = { 255, 200, 0 } },
    { n = "Ocean",        a = { 0, 105, 148 },   b = { 64, 224, 208 } },
    { n = "Forest",       a = { 34, 139, 34 },   b = { 101, 67, 33 } },
    { n = "Galaxy",       a = { 72, 0, 255 },    b = { 255, 0, 200 } },
    { n = "Strawberry",   a = { 220, 20, 60 },   b = { 255, 182, 193 } },
    { n = "Vaporwave",    a = { 255, 113, 206 }, b = { 1, 205, 254 } },
    { n = "Custom",       custom = true },
}

-- Combo, Stick React and Sparkle all choose from tables.combos, but they mean
-- different things by it - Combo: left stick / right stick; Stick React: resting
-- ring / pulse highlight; Sparkle: resting ring / glints - and each keeps its OWN
-- selection, so picking Cyberpunk in one doesn't disturb the others. The row keys
-- stay shared ("combo"/"lcolor"/"rcolor"); this table says which state fields
-- those rows are pointing at right now.
local COMBO_FIELDS = {
    ["Combo"]       = { "combo",      "customL", "customR" },
    ["Stick React"] = { "pulseCombo", "pulseL",  "pulseR"  },
    ["Sparkle"]     = { "sparkCombo", "sparkL",  "sparkR"  },
}

function tables.usesCombo(mode) return COMBO_FIELDS[mode] ~= nil end

function tables.comboFields(mode)
    return COMBO_FIELDS[mode or tables.state.mode] or COMBO_FIELDS["Combo"]
end

-- The combos[] entry the current mode's Combination row is showing.
function tables.comboSel(mode)
    local f = tables.comboFields(mode)
    return tables.state[f[1]]
end

tables.labelFor = {
    mode = "Mode", color = "Color", combo = "Combination", speed = "Speed",
    brightmode = "Brightness Mode", bright = "Brightness",
    lcolor = "L Color", rcolor = "R Color", lowbatt = "Low Battery",
}

-- Stick React and Sparkle reuse the Combo rows, so their two swatches need their own
-- names: they are not two sticks, they are the ring at rest and what lights up on it.
local PAIR_LABEL = {
    ["Stick React"] = { lcolor = "Ring Color", rcolor = "Pulse Color" },
    ["Sparkle"]     = { lcolor = "Ring Color", rcolor = "Sparkle Color" },
}

function tables.labelOf(key)
    local names = PAIR_LABEL[tables.state.mode]
    if names and names[key] then return names[key] end
    return tables.labelFor[key]
end

-- Live state (defaults match the mockup's `st`).
tables.state = {
    mode = "Static",
    hue = 192,          -- Static/Breathing color: -1 = white, else 0..352 step 8
    combo = 1,          -- 1..#combos (Custom is last)
    customL = 328,      -- Custom Combo left hue (-1 = white)
    customR = 168,      -- Custom Combo right hue (-1 = white)
    pulseCombo = 8,     -- Stick React combo index, independent of `combo` (8 = Cyberpunk)
    pulseL = 192,       -- Stick React Custom resting-ring hue
    pulseR = 328,       -- Stick React Custom pulse hue
    sparkCombo = 12,    -- Sparkle combo index, independent of the others (12 = Galaxy)
    sparkL = 272,       -- Sparkle Custom resting-ring hue
    sparkR = -1,        -- Sparkle Custom glint hue (-1 = white: plain glitter)
    stickInput = false, -- true when a /dev/input/js* node was found at load
    speed = 2,          -- 1..3 -> Slow/Medium/Fast
    bright = 0.8,       -- 0..1 (x255 for the serial protocol) - the Direct value
    brightmode = 2,     -- 1..2 -> Direct/Screen (global); load drops to Direct without a backlight
    screenLed = nil,    -- LED level the screen maps to, 0..1; nil until one is read
    screenSrc = false,  -- true when a readable backlight was found at load
    lowbatt = 1,        -- 1..4 -> None/Dim 50%/Off/Breathe Red (global)
    sel = 1,            -- selected row index
    sticks = 2,         -- read from the device
    themeRGB = { 255, 170, 50 }, -- overwritten at load by config.resolveThemeColor()
    sysfs = false,      -- true on TrimUI (led_anim backend); hides firmware-anim modes
    serial = false,     -- true when the H700 serial port exists (and led_anim doesn't)
    board = nil,        -- muOS board id, e.g. "rgcubexx-h"; nil when not on a device
}

function tables.isChild(key) return key == "lcolor" or key == "rcolor" end

-- Readable names for the RGB boards, keyed by the id muOS reports in board/name. A
-- board missing here is shown by its muOS id instead: still correct, just less tidy.
local BOARD_NAMES = {
    ["rgcubexx-h"] = "RG CubeXX",
    ["rg40xx-h"]   = "RG40XX H",
    ["rg40xx-v"]   = "RG40XX V",
}

-- Subtitle under the wordmark: this device, then how its LEDs are driven. Follows
-- the daemon's DETECT_BACKEND order - led_anim first, then serial, else nothing.
function tables.deviceLabel()
    local s = tables.state
    local name = s.board and (BOARD_NAMES[s.board] or s.board) or "Unknown device"
    local backend = s.sysfs and "LED ANIM" or (s.serial and "SERIAL" or "UNSUPPORTED")
    return (name .. " - " .. backend):upper()
end

-- Screen mode hands the slider to the panel, so the Brightness row stops being an
-- input and starts being a readout. Falls back to the manual value if the backlight
-- read failed this frame, so the row never blanks out.
function tables.brightFollowsScreen()
    return tables.state.screenSrc and tables.state.brightmode == 2
end

-- The 0..1 the Brightness row displays (and, in Direct, the one that ships).
function tables.effectiveBright()
    local s = tables.state
    if tables.brightFollowsScreen() and s.screenLed then return s.screenLed end
    return s.bright
end

-- Whether the highlighted row can still move left / right. Wrapping rows (mode,
-- combo, hue) are always both-true; clamped rows gray the arrow at their limit.
function tables.canAdjust(key)
    local s = tables.state
    if key == "speed" then return s.speed > 1, s.speed < 3
    elseif key == "lowbatt" then return s.lowbatt > 1, s.lowbatt < tables.lowbattCount()
    elseif key == "brightmode" then return s.brightmode > 1, s.brightmode < #tables.brightmodes
    elseif key == "bright" then
        if tables.brightFollowsScreen() then return false, false end
        return s.bright > 0, s.bright < 1
    end
    return true, true
end

-- Modes offered right now. Combo needs two sticks; Breathing/Color Cycle/Rainbow are
-- H700 firmware animations with no usable equivalent on the TrimUI led_anim backend,
-- so they're hidden there.
local ANIM_MODE = { ["Breathing"] = true, ["Color Cycle"] = true, ["Rainbow"] = true }
function tables.availableModes()
    local s = tables.state
    local out = {}
    for _, m in ipairs(tables.modes) do
        -- Stick React and Sparkle render LED by LED (serial mode 1), which the
        -- led_anim backend can't do; Stick React also needs the analog axes.
        local hide = (m == "Combo" and s.sticks < 2) or (s.sysfs and ANIM_MODE[m])
            or (m == "Stick React" and (s.sysfs or not s.stickInput))
            or (m == "Sparkle" and s.sysfs)
        if not hide then out[#out + 1] = m end
    end
    return out
end

-- Top group: Mode + the mode-specific rows.
function tables.modeKeys()
    local s = tables.state
    local keys = { "mode" }
    if tables.usesCombo(s.mode) then
        keys[#keys + 1] = "combo"
        if tables.combos[tables.comboSel()].custom then
            keys[#keys + 1] = "lcolor"
            keys[#keys + 1] = "rcolor"
        end
        -- anything after the pair (Sparkle's Speed) sits below its color rows
        for _, k in ipairs(tables.rows[s.mode]) do
            if k ~= "combo" then keys[#keys + 1] = k end
        end
    else
        for _, k in ipairs(tables.rows[s.mode]) do keys[#keys + 1] = k end
    end
    return keys
end

-- Bottom group: the shared globals. Hidden entirely when the sticks are Off.
-- Brightness Mode only appears where there is a backlight to follow; on a device
-- without one the row would be a switch with one working position.
function tables.globalKeys()
    if tables.state.mode == "Off" then return {} end
    if tables.state.screenSrc then return { "brightmode", "bright", "lowbatt" } end
    return { "bright", "lowbatt" }
end

-- Full navigable list (top group then global group).
function tables.rowKeys()
    local keys = tables.modeKeys()
    for _, k in ipairs(tables.globalKeys()) do keys[#keys + 1] = k end
    return keys
end

-- Global rows the layout must reserve room for. Fixed for the session (screenSrc
-- is decided once, at load), so the block never breathes.
function tables.maxGlobalRows()
    return tables.state.screenSrc and 3 or 2
end

-- Tallest top-group among available modes, so the global group sits at a fixed
-- offset and never breathes as the mode changes.
function tables.maxModeRows()
    local best = 1
    for _, m in ipairs(tables.availableModes()) do
        -- Mode + its rows, plus the two color rows a Combination brings on Custom.
        local n = 1 + #tables.rows[m] + (tables.usesCombo(m) and 2 or 0)
        if n > best then best = n end
    end
    return best
end

-- Highlight/accent color = a preview of what the current mode drives.
function tables.accent()
    local s = tables.state
    if s.mode == "Static" or s.mode == "Breathing" then
        return color.fromHue(s.hue)
    elseif tables.usesCombo(s.mode) then
        local f = tables.comboFields()
        local c = tables.combos[s[f[1]]]
        return c.custom and color.fromHue(s[f[2]]) or c.a
    elseif s.mode == "Theme" then
        return s.themeRGB or { 255, 170, 50 }
    elseif s.mode == "Off" then
        return { 58, 63, 76 }
    else
        return { 75, 225, 201 }
    end
end

return tables
