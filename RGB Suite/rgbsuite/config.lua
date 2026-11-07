-- config.lua - the UI<->daemon contract.
-- Resolves the app paths, reads settings.cfg on launch, writes it on every
-- change, and pokes the rgb_suite daemon via `rgbctl.sh apply`.

local tables = require("tables")
local colour = require("colour")

local config = {}

-- Display <-> internal id maps.
local MODE_ID = {
    ["Off"] = "off", ["Static"] = "static", ["Breathing"] = "breathing",
    ["Combo"] = "combo", ["Theme"] = "theme", ["Colour Cycle"] = "cycle",
    ["Rainbow"] = "rainbow", ["Screen React"] = "react",
    ["Stick React"] = "stickreact", ["Sparkle"] = "sparkle",
}
local ID_MODE = {}
for k, v in pairs(MODE_ID) do ID_MODE[v] = k end

local SPEED_ID  = { "slow", "med", "fast" }
local SPEED_IDX = { slow = 1, med = 2, fast = 3 }
local LOWB_ID   = { "none", "dim", "off", "breathe" }
local LOWB_IDX  = { none = 1, dim = 2, off = 3, breathe = 4 }
local BRIM_ID   = { "direct", "screen" }
local BRIM_IDX  = { direct = 1, screen = 2 }

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function readFirstLine(path, default)
    local f = io.open(path, "r")
    if not f then return default end
    local v = f:read("*l")
    f:close()
    if v then v = v:gsub("%s+$", "") end
    return (v and v ~= "") and v or default
end

-- Present on TrimUI (Brick / Smart Pro) -> the daemon drives the led_anim backend.
local LED_SYSFS = "/sys/class/led_anim"
-- Otherwise the H700 serial MCU, if this board has the port at all.
local SERIAL_DEVICE = "/dev/ttyS5"

-- True when `path` is a directory. No luafilesystem in the LOVE build, so shell out
-- once at load; os.execute returns 0 (LuaJIT) or true (5.2+) on success.
local function isDir(path)
    local ok = os.execute('[ -d "' .. path .. '" ]')
    return ok == true or ok == 0
end

-- Same, for a character device (the serial port).
local function isCharDev(path)
    local ok = os.execute('[ -c "' .. path .. '" ]')
    return ok == true or ok == 0
end

-- --- Screen brightness ------------------------------------------------------
-- Brightness Mode = Screen follows the screen. muOS keeps the CURRENT level in its
-- own settings tree and the panel MAXIMUM in the device config: on a CubeXX that is
-- brightness=90 of bright=255, which is the 35% muOS itself shows. H700 has no
-- /sys/class/backlight at all, so the backlight class is only a fallback for boards
-- that do have one. Nothing found -> the Brightness Mode row is not offered.
-- Screen % -> LED %, before the gamma curve: a 1:1 map left the sticks far too dim
-- across the bottom of the range. See SCREEN_LED_FLOOR in bin/rgb_suite.sh, which
-- does this same arithmetic to pick the byte - if the two drift, the Brightness row
-- shows a number that isn't what's on the sticks.
local SCREEN_LED_FLOOR = 20

local MUOS_BRIGHT_VAL = "/opt/muos/config/settings/general/brightness"
local MUOS_BRIGHT_MAX = "/opt/muos/device/config/screen/bright"
local BACKLIGHT_GLOB  = "/sys/class/backlight"

local function readable(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

-- Directory listing without luafilesystem. io.popen is available in LOVE's LuaJIT;
-- guard it anyway so a locked-down build just reports nothing rather than erroring.
local function listDir(path)
    local ok, pipe = pcall(io.popen, 'ls -1 "' .. path .. '" 2>/dev/null')
    if not ok or not pipe then return {} end
    local out = {}
    for name in pipe:lines() do
        if name ~= "" then out[#out + 1] = name end
    end
    pipe:close()
    return out
end

-- A ceiling of 0, a missing file, or a key that holds a path instead of a number
-- (screen/colour beside it does exactly that) all mean "assume 0-255".
local function ceiling(path)
    local v = tonumber(readFirstLine(path, nil))
    if v and v > 0 then return math.floor(v) end
    return 255
end

-- Returns node, max. Order matters: muOS's own setting is the level the brightness
-- keys actually move, so it wins over any driver node that might be mid-ramp.
local function findBrightSource()
    if readable(MUOS_BRIGHT_VAL) then
        return MUOS_BRIGHT_VAL, ceiling(MUOS_BRIGHT_MAX)
    end
    for _, name in ipairs(listDir(BACKLIGHT_GLOB)) do
        local node = BACKLIGHT_GLOB .. "/" .. name .. "/brightness"
        if readable(node) then
            return node, ceiling(BACKLIGHT_GLOB .. "/" .. name .. "/max_brightness")
        end
    end
    return nil, 255
end

-- The LED level (0..1) the current screen brightness maps to - NOT the screen's own
-- level, which is only an input here.
--
-- Every step floors, because that is exactly what the daemon does with the same
-- file (POSIX shell has only integer division). Without matching it the row could
-- round 50.9% up to "51%" while the daemon rendered the 50% step - a readout
-- disagreeing with what is actually on the sticks.
function config.screenLedLevel()
    if not config.brightNode then return nil end
    local v = tonumber(readFirstLine(config.brightNode, nil))
    if not v then return nil end
    local pct = math.floor(v * 100 / config.brightMax)
    if pct > 100 then pct = 100 elseif pct < 0 then pct = 0 end
    return (SCREEN_LED_FLOOR + math.floor((100 - SCREEN_LED_FLOOR) * pct / 100)) / 100
end

-- --- Theme-colour resolution ------------------------------------------------
-- Theme mode lights the sticks to match the active muOS theme. In priority:
--   1. the theme's OWN RGB colour (rgb/colour_l) -- exactly what muOS's `murgb`
--      reads for its "theme" RGB mode, so we match the system (only the stock
--      theme ships this today);
--   2. else the theme's selection accent, parsed from its scheme .ini;
--   3. else amber.
local THEME_ROOT      = "/run/muos/storage/theme"
local THEME_NAME_FILE = "/opt/muos/config/theme/active"   -- GET_VAR config theme/active
local THEME_DEFAULT   = { 255, 170, 50 }

-- Parse "RRGGBB" (tolerates a #/0x prefix + surrounding space) to {r,g,b}; nil if
-- it isn't 6 hex digits.
local function hexToRGB(hex)
    if not hex then return nil end
    hex = hex:gsub("%s+", ""):gsub("^0[xX]", ""):gsub("^#", "")
    if not hex:match("^%x%x%x%x%x%x$") then return nil end
    return {
        tonumber(hex:sub(1, 2), 16),
        tonumber(hex:sub(3, 4), 16),
        tonumber(hex:sub(5, 6), 16),
    }
end

-- Skip near-white / near-black / near-grey so the sticks show a real accent, not a
-- wash. (value < ~0.20 or saturation < 0.30.)
local function isVivid(rgb)
    if not rgb then return false end
    local mx = math.max(rgb[1], rgb[2], rgb[3])
    local mn = math.min(rgb[1], rgb[2], rgb[3])
    if mx < 51 then return false end
    return (mx - mn) / mx >= 0.30
end

-- Read a muOS scheme .ini's "KEY = VALUE" lines into an UPPERCASE raw-string map.
-- Later calls override earlier keys (base scheme/global.ini, then the
-- resolution-specific <res>/scheme/default.ini).
local function loadScheme(map, path)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
        if k then map[k:upper()] = v end
    end
    f:close()
end

-- The theme's selection accent = how muOS paints the focused row: a visible, vivid
-- focus fill, else the focus text, else the focus indicator; a few broad keys cover
-- near-monochrome themes. nil if nothing vivid is found.
local function schemeAccent(dir, res)
    local map = {}
    loadScheme(map, dir .. "/scheme/global.ini")
    if res then loadScheme(map, dir .. "/" .. res .. "/scheme/default.ini") end
    local function col(k) return hexToRGB(map[k]) end
    -- Alpha may be decimal, malformed, or absent (treat absent/garbage as opaque).
    local function shown(k) return (tonumber(map[k .. "_ALPHA"] or "255") or 255) > 0 end

    local fb = col("LIST_FOCUS_BACKGROUND")
    if fb and shown("LIST_FOCUS_BACKGROUND") and isVivid(fb) then return fb end
    local ft = col("LIST_FOCUS_TEXT")
    if ft and isVivid(ft) then return ft end
    local fi = col("LIST_FOCUS_INDICATOR")
    if fi and shown("LIST_FOCUS_INDICATOR") and isVivid(fi) then return fi end
    for _, k in ipairs({ "HEADER_TEXT", "DATETIME_TEXT", "BATTERY_ACTIVE", "LIST_DEFAULT_TEXT" }) do
        local c = col(k)
        if c and isVivid(c) then return c end
    end
    return nil
end

local function resolveThemeColour()
    local active = readFirstLine(THEME_NAME_FILE, nil)
    if not (active and active ~= "") then return { THEME_DEFAULT[1], THEME_DEFAULT[2], THEME_DEFAULT[3] } end
    local dir = THEME_ROOT .. "/" .. active

    -- 1. the theme's own RGB colour (authoritative -- matches muOS's murgb).
    local own = hexToRGB(readFirstLine(dir .. "/rgb/colour_l", nil))
    if own then return own end

    -- 2. the theme's selection accent from its scheme (resolution from the live
    --    window, which main.lua has already sized to the screen).
    local res
    if love and love.graphics then
        local w, h = love.graphics.getDimensions()
        if w and h and w > 0 and h > 0 then res = math.floor(w) .. "x" .. math.floor(h) end
    end
    local accent = schemeAccent(dir, res)
    if accent then return accent end

    -- 3. default.
    return { THEME_DEFAULT[1], THEME_DEFAULT[2], THEME_DEFAULT[3] }
end

-- Right stick = first 8 LEDs in the serial packet; a = screen-left, b = right.
-- `mode` picks WHICH saved combo to resolve, so save() can write every mode's pair
-- on every write, regardless of the mode on screen.
local function comboColours(s, mode)
    local f = tables.comboFields(mode)
    local c = tables.combos[s[f[1]]]
    if c.custom then
        return colour.fromHue(s[f[2]]), colour.fromHue(s[f[3]])
    end
    return c.a, c.b
end

-- Perceived LED brightness is ~logarithmic, so a linear byte crams most of the
-- visible change into the bottom of the slider. Gamma-encode the 0..1 slider into
-- the 0..255 byte so equal slider steps feel like equal steps (min 1 when on).
local BRIGHT_GAMMA = 2.2
local function brightByte(b)
    if b <= 0 then return 0 end
    return math.max(1, math.floor(255 * b ^ BRIGHT_GAMMA + 0.5))
end

function config.load()
    local src = love.filesystem.getSource()
    config.appRoot = src:match("(.+)/[^/]+$") or src
    config.path    = config.appRoot .. "/settings.cfg"
    config.rgbctl  = config.appRoot .. "/bin/rgbctl.sh"

    local s = tables.state
    s.sticks = tonumber(readFirstLine("/opt/muos/device/config/board/stick", "2")) or 2
    if s.sticks < 1 then s.sticks = 1 end
    -- TrimUI led_anim backend: its zones aren't Anbernic "sticks", but both TrimUI
    -- devices have >=2 addressable side zones, so treat them as a 2-side device
    -- (enables Combo + L/R React split); firmware-anim modes are hidden below.
    s.sysfs = isDir(LED_SYSFS)
    if s.sysfs and s.sticks < 2 then s.sticks = 2 end
    s.serial = not s.sysfs and isCharDev(SERIAL_DEVICE)
    -- muOS's id for this board ("rgcubexx-h"); tables.deviceLabel() names it on screen.
    s.board = readFirstLine("/opt/muos/device/config/board/name", nil)
    s.themeRGB = resolveThemeColour()

    -- Stick React reads the analog axes off the legacy joystick node. The index is
    -- NOT stable across devices - a CubeXX on muOS exposes js1, with no js0 at all -
    -- so take the first js* that exists rather than assuming js0 the way most
    -- reference code does. Nothing found -> the mode isn't offered.
    s.stickInput = false
    for _, name in ipairs(listDir("/dev/input")) do
        if name:match("^js%d+$") then s.stickInput = true break end
    end

    config.brightNode, config.brightMax = findBrightSource()
    s.screenSrc       = config.brightNode ~= nil
    s.screenLed       = config.screenLedLevel()

    -- Parse any existing config into state.
    local f = io.open(config.path, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then
                if k == "mode" then s.mode = ID_MODE[v] or s.mode
                elseif k == "brightness" then s.bright = clamp(((tonumber(v) or 154) / 255) ^ (1 / BRIGHT_GAMMA), 0, 1)
                elseif k == "ui_bright" then s.bright = clamp(tonumber(v) or s.bright, 0, 1)
                elseif k == "bright_mode" then s.brightmode = BRIM_IDX[v] or s.brightmode
                elseif k == "speed" then s.speed = SPEED_IDX[v] or s.speed
                elseif k == "lowbatt_action" then s.lowbatt = LOWB_IDX[v] or s.lowbatt
                elseif k == "ui_hue" then s.hue = tonumber(v) or s.hue
                elseif k == "ui_combo" then s.combo = tonumber(v) or s.combo
                elseif k == "ui_customl" then s.customL = tonumber(v) or s.customL
                elseif k == "ui_customr" then s.customR = tonumber(v) or s.customR
                elseif k == "ui_pulse" then s.pulseCombo = tonumber(v) or s.pulseCombo
                elseif k == "ui_pulsel" then s.pulseL = tonumber(v) or s.pulseL
                elseif k == "ui_pulser" then s.pulseR = tonumber(v) or s.pulseR
                elseif k == "ui_spark" then s.sparkCombo = tonumber(v) or s.sparkCombo
                elseif k == "ui_sparkl" then s.sparkL = tonumber(v) or s.sparkL
                elseif k == "ui_sparkr" then s.sparkR = tonumber(v) or s.sparkR
                end
            end
        end
        f:close()
    end

    -- Sanity: nothing to follow -> Screen isn't selectable, so don't stay in it.
    if not s.screenSrc then s.brightmode = 1 end
    -- Sanity: single-stick devices can't use Combo.
    if s.sticks < 2 and s.mode == "Combo" then s.mode = "Static" end
    -- Sanity: the led_anim backend has no firmware animation, so those modes are hidden.
    if s.sysfs and (s.mode == "Breathing" or s.mode == "Colour Cycle" or s.mode == "Rainbow") then
        s.mode = "Static"
    end
    -- Sanity: no per-LED backend or no joystick node -> Stick React can't render.
    if s.mode == "Stick React" and (s.sysfs or not s.stickInput) then s.mode = "Static" end
    -- Sanity: Sparkle is drawn LED by LED too.
    if s.mode == "Sparkle" and s.sysfs then s.mode = "Static" end
    -- Sanity: Breathe Red is a firmware breath too; led_anim has no such option.
    if s.lowbatt > tables.lowbattCount() then s.lowbatt = 1 end
    if s.combo < 1 or s.combo > #tables.combos then s.combo = 1 end
    if s.pulseCombo < 1 or s.pulseCombo > #tables.combos then s.pulseCombo = 1 end
    if s.sparkCombo < 1 or s.sparkCombo > #tables.combos then s.sparkCombo = 1 end
    s.sel = 1
end

function config.save()
    if not config.path then return end
    local s = tables.state
    local comboL, comboR = comboColours(s, "Combo")
    local pulseBg, pulseFg = comboColours(s, "Stick React")
    local sparkBg, sparkFg = comboColours(s, "Sparkle")
    local lines = {
        "mode=" .. (MODE_ID[s.mode] or "off"),
        "brightness=" .. brightByte(s.bright),
        "speed=" .. (SPEED_ID[s.speed] or "med"),
        "colour=" .. colour.toStr(colour.fromHue(s.hue)),
        "combo_l=" .. colour.toStr(comboL),
        "combo_r=" .. colour.toStr(comboR),
        -- Stick React: a = the ring at rest, b = the directional pulse.
        "pulse_bg=" .. colour.toStr(pulseBg),
        "pulse_fg=" .. colour.toStr(pulseFg),
        -- Sparkle: a = the ring at rest, b = the glints.
        "spark_bg=" .. colour.toStr(sparkBg),
        "spark_fg=" .. colour.toStr(sparkFg),
        "theme_colour=" .. colour.toStr(s.themeRGB or { 255, 170, 50 }),
        "lowbatt_action=" .. (LOWB_ID[s.lowbatt] or "none"),
        "bright_mode=" .. (BRIM_ID[s.brightmode] or "direct"),
        -- UI-only restore keys (the daemon ignores unknown keys).
        "ui_bright=" .. string.format("%.4f", s.bright),
        "ui_hue=" .. s.hue,
        "ui_combo=" .. s.combo,
        "ui_customl=" .. s.customL,
        "ui_customr=" .. s.customR,
        "ui_pulse=" .. s.pulseCombo,
        "ui_pulsel=" .. s.pulseL,
        "ui_pulser=" .. s.pulseR,
        "ui_spark=" .. s.sparkCombo,
        "ui_sparkl=" .. s.sparkL,
        "ui_sparkr=" .. s.sparkR,
    }
    -- Write-then-rename, never in place. The daemon re-reads this file whenever we
    -- signal it, and an in-place rewrite leaves a window where it is empty or half
    -- written - the daemon then reads mode as missing, falls back to "off", blanks
    -- the sticks and exits. rename() is atomic, so it only ever sees a whole file.
    local tmp = config.path .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        if not os.rename(tmp, config.path) then os.remove(tmp) end
    end
end

-- Tell the daemon to re-read + re-render (non-blocking).
function config.apply()
    if not config.rgbctl then return end
    os.execute(string.format("%q apply >/dev/null 2>&1 &", config.rgbctl))
end

-- Write + apply in one call (used on every change).
function config.commit()
    config.save()
    config.apply()
end

-- First-launch hint: a marker file next to settings.cfg records that the user
-- has seen the "enable User init scripts" tip, so it shows only once. (A .muxapp
-- reinstall wipes the bundle and re-shows it, which is fine.)
local function hintPath() return (config.appRoot or ".") .. "/.hint_seen" end

function config.hintSeen()
    local f = io.open(hintPath(), "r")
    if f then f:close(); return true end
    return false
end

function config.markHintSeen()
    local f = io.open(hintPath(), "w")
    if f then f:write("1\n"); f:close() end
end

return config
