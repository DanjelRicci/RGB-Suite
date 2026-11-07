-- draw.lua - renders the locked mockup in LOVE. Aspect-adaptive: every size is
-- derived from cq = min(width,height)/100 (the CSS cqmin the mockup used), so the
-- same layout fits a 1:1 CubeXX or a 16:9 handheld. Button-only, dark, no pointer.
--
-- Two row groups: the mode-specific top group (reserved to the tallest mode so it
-- never jumps) and the shared global group (Brightness + Low Battery) at a fixed
-- offset below a faint divider. Text is Roboto Mono with linear filtering.

local tables = require("tables")
local colour = require("colour")

local draw = {}

local FONT_REG  = "assets/fonts/RobotoMono-Regular.ttf"
local FONT_BOLD = "assets/fonts/RobotoMono-Bold.ttf"

-- palette (0-1)
local C_LABEL      = { 0x8b / 255, 0x92 / 255, 0xa3 / 255 }
local C_LABEL_SEL  = { 0xf5 / 255, 0xf7 / 255, 0xfb / 255 }
local C_CHILD      = { 0x6a / 255, 0x71 / 255, 0x80 / 255 }
local C_CHILD_SEL  = { 0xe6 / 255, 0xe9 / 255, 0xf0 / 255 }
local C_VALUE      = { 0xc6 / 255, 0xcb / 255, 0xd6 / 255 }
local C_ARROW      = { 0x6a / 255, 0x71 / 255, 0x80 / 255 } -- enabled, unselected
local C_ARROW_SEL  = { 0xec / 255, 0xee / 255, 0xf4 / 255 } -- enabled, selected (white)
local C_ARROW_OFF  = { 0x2c / 255, 0x31 / 255, 0x3c / 255 } -- at a list limit (greyed)
local C_SUB        = { 0x56 / 255, 0x5d / 255, 0x6d / 255 }
local C_HINT       = { 0x56 / 255, 0x5d / 255, 0x6d / 255 }
local C_HINT_B     = { 0x9a / 255, 0xa0 / 255, 0xad / 255 }
local C_ROWSEL     = { 1, 1, 1, 0.06 }
local C_DIVIDER    = { 0x26 / 255, 0x2b / 255, 0x36 / 255, 0.9 }
local C_MINI_BG    = { 0x17 / 255, 0x1a / 255, 0x23 / 255 }
local C_MINI_FILL  = { 0xec / 255, 0xee / 255, 0xf4 / 255 }
local C_MINI_READ  = { 0x6a / 255, 0x71 / 255, 0x80 / 255 } -- bar is a readout, not a control
local C_PILL_EDGE  = { 1, 1, 1, 0.16 }
local C_BG_TOP     = { 0x14 / 255, 0x12 / 255, 0x1c / 255 }
local C_BG_BOT     = { 0x07 / 255, 0x08 / 255, 0x0c / 255 }

-- RGB-spectrum wordmark stops (0-255): pink -> amber -> teal -> blue
local WORD_STOPS = {
    { 0.00, 255, 93, 143 },
    { 0.32, 255, 209, 102 },
    { 0.64, 75, 225, 201 },
    { 1.00, 106, 163, 255 },
}

local W, H, cq
local F = {}
local L = {}
local bgMesh, washShader, scanShader
local washT = 0
local washL, washR = { 0, 0, 0 }, { 0, 0, 0 }  -- animated edge colours (0-1)
local washFade = 0                              -- 0..1 cross-fade in/out of Screen React
local WASH_FADE_SECS = 0.4                       -- matches the HTML .wash opacity transition

-- Screen React wash (fragment shader): vivid colour hugging each edge with an
-- inverse-exponential fall-off (thin bright core, quick drop, long faint tail) and
-- a slight rounded bulge (elliptical radius, taller than wide). Mirrors the mockup.
local WASH_SRC = [[
    extern vec2 u_res;
    extern vec3 u_left;
    extern vec3 u_right;
    extern float u_k;
    extern float u_plateau;
    extern float u_rx;
    extern float u_ry;
    extern float u_fade;      // 0..1 cross-fade; also fades the whole wash out
    float edgeA(vec2 p, vec2 c){
        float dx = (p.x - c.x) / (u_rx * u_res.x);
        float dy = (p.y - c.y) / (u_ry * u_res.y);
        float d = sqrt(dx * dx + dy * dy);
        if (d >= 1.0) return 0.0;
        if (d <= u_plateau) return 1.0;
        return exp(-u_k * (d - u_plateau) / (1.0 - u_plateau));
    }
    // Output the dominant edge colour with the edge's alpha (transparent toward
    // the centre) so the wash blends over the app's real background, not black.
    vec4 effect(vec4 vc, Image tx, vec2 uv, vec2 sc){
        float aL = edgeA(sc, vec2(0.0, u_res.y * 0.5));
        float aR = edgeA(sc, vec2(u_res.x, u_res.y * 0.5));
        float a; vec3 c;
        if (aL >= aR) { a = aL; c = u_left; } else { a = aR; c = u_right; }
        return vec4(c, a * u_fade);
    }
]]

-- Subtle CRT scanlines over the whole screen (1px dark line every few px).
local SCAN_SRC = [[
    extern float u_period;
    extern float u_thick;
    extern float u_alpha;
    vec4 effect(vec4 vc, Image tx, vec2 uv, vec2 sc){
        float a = step(mod(sc.y, u_period), u_thick) * u_alpha;
        return vec4(0.0, 0.0, 0.0, a);
    }
]]

local function setC(c) love.graphics.setColor(c[1], c[2], c[3], c[4] or 1) end

local function newFont(path, size)
    -- linear (default) filtering -> smooth, anti-aliased text at native res
    return love.graphics.newFont(path, math.max(6, math.floor(size + 0.5)))
end

local function sampleWord(t)
    for i = 1, #WORD_STOPS - 1 do
        local a, b = WORD_STOPS[i], WORD_STOPS[i + 1]
        if t <= b[1] then
            local f = (t - a[1]) / (b[1] - a[1])
            return { a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f }
        end
    end
    local last = WORD_STOPS[#WORD_STOPS]
    return { last[2], last[3], last[4] }
end

-- Open chevron stroke (‹ › ^ v) - matches the mockup's guillemet arrows.
-- direction: "up" | "down" | "left" | "right"
--
-- These are strokes, not glyphs, so they don't scale with the font and they read
-- much heavier on the device than in the browser mockups, where the same arrow is
-- a real guillemet set at 3.2cq - about half the height this was drawing. Extents
-- AND stroke are scaled together so the mark keeps its proportion; the callers
-- below pass the original (pre-scale) sizes.
local ARROW_SCALE = 0.6

local function chevron(cx, cy, dir, w, h, col)
    w, h = w * ARROW_SCALE, h * ARROW_SCALE
    setC(col)
    love.graphics.setLineStyle("smooth")
    love.graphics.setLineJoin("miter")
    love.graphics.setLineWidth(math.max(1, 0.34 * ARROW_SCALE * cq))
    local pts
    if dir == "up" then pts = { cx - w, cy + h, cx, cy - h, cx + w, cy + h }
    elseif dir == "down" then pts = { cx - w, cy - h, cx, cy + h, cx + w, cy - h }
    elseif dir == "left" then pts = { cx + w, cy - h, cx - w, cy, cx + w, cy + h }
    else pts = { cx - w, cy - h, cx + w, cy, cx - w, cy + h } end
    love.graphics.line(pts)
end

function draw.load()
    W, H = love.graphics.getDimensions()
    cq = math.min(W, H) / 100

    F.word  = newFont(FONT_BOLD, 5.0 * cq)
    F.sub   = newFont(FONT_REG, 2.1 * cq)
    F.label = newFont(FONT_REG, 3.3 * cq)
    F.child = newFont(FONT_REG, 3.0 * cq)
    F.value = newFont(FONT_REG, 3.1 * cq)
    F.hint  = newFont(FONT_REG, 2.3 * cq)

    -- vertical background gradient (strip quad: TL,TR,BL,BR)
    bgMesh = love.graphics.newMesh({
        { 0, 0, 0, 0, C_BG_TOP[1], C_BG_TOP[2], C_BG_TOP[3], 1 },
        { W, 0, 1, 0, C_BG_TOP[1], C_BG_TOP[2], C_BG_TOP[3], 1 },
        { 0, H, 0, 1, C_BG_BOT[1], C_BG_BOT[2], C_BG_BOT[3], 1 },
        { W, H, 1, 1, C_BG_BOT[1], C_BG_BOT[2], C_BG_BOT[3], 1 },
    }, "strip", "static")

    -- Screen React wash + scanline shaders (created once, re-parametrised on resize).
    if not washShader then washShader = love.graphics.newShader(WASH_SRC) end
    if not scanShader then scanShader = love.graphics.newShader(SCAN_SRC) end
    washShader:send("u_res", { W, H })
    washShader:send("u_k", 5.4)
    washShader:send("u_plateau", 0.015)
    washShader:send("u_rx", 0.5)
    washShader:send("u_ry", 1.75)
    scanShader:send("u_period", math.max(2, math.floor(H / 240 + 0.5)))
    scanShader:send("u_thick", 1.0)
    scanShader:send("u_alpha", 0.18)

    -- layout regions
    local topbarH = 15 * cq
    local hintsH  = 11 * cq
    L.rowH  = 8 * cq
    L.gap   = 1.4 * cq
    L.pad   = 3 * cq
    L.menuW = math.min(82 * cq, 0.94 * W)
    L.menuX = (W - L.menuW) / 2

    local stageTop  = topbarH
    local stageH    = (H - hintsH) - stageTop
    local maxMode   = tables.maxModeRows()
    local divGap    = 4.4 * cq
    local maxGlobal = tables.maxGlobalRows()
    local rowsH     = (maxMode + maxGlobal) * L.rowH
    local nGaps     = (maxMode - 1) + (maxGlobal - 1)
    local block     = rowsH + nGaps * L.gap + divGap

    -- Five mode rows (Sparkle on Custom) plus three global rows overflow a square screen
    -- by ~3 cq. The rows keep their height; the gaps between them close up just enough
    -- instead. The subtitle's baseline sits right at the stage top, so the block moves
    -- down 2 cq into the hint bar's top padding (the hint text is centred in its 11 cq,
    -- well clear of that). A layout that already fits keeps its spacing and centring.
    if block > stageH then
        local top, bottom = stageTop + 2 * cq, H - hintsH + 2 * cq
        L.gap = math.max(0.5 * cq, (bottom - top - rowsH - divGap) / nGaps)
        block = rowsH + nGaps * L.gap + divGap
        stageTop, stageH = top, bottom - top
    end
    local modeH     = maxMode * L.rowH + (maxMode - 1) * L.gap
    local globalH   = maxGlobal * L.rowH + (maxGlobal - 1) * L.gap

    L.menuTop   = stageTop + math.max(0, (stageH - block) / 2)
    L.dividerY  = L.menuTop + modeH + divGap / 2
    L.globalTop = L.menuTop + modeH + divGap
    L.hintY     = H - hintsH / 2
end

function draw.update(dt)
    washT = washT + dt
    local t = washT
    -- Vivid edge colours (full lightness so the sticks read bright); the shader
    -- handles the fall-off toward the black centre.
    local Lh = colour.hsl2rgb((t * 22) % 360, 90, 52)
    local Rh = (tables.state.sticks < 2) and Lh or colour.hsl2rgb((t * 22 + 150) % 360, 90, 52)
    washL = { Lh[1] / 255, Lh[2] / 255, Lh[3] / 255 }
    washR = { Rh[1] / 255, Rh[2] / 255, Rh[3] / 255 }

    -- Cross-fade the wash in/out when entering/leaving Screen React.
    local target = (tables.state.mode == "Screen React") and 1 or 0
    local step = dt / WASH_FADE_SECS
    if washFade < target then washFade = math.min(target, washFade + step)
    elseif washFade > target then washFade = math.max(target, washFade - step) end
end

-- ---- value content drawers: each draws right-aligned ending at cRight, returns left x

local function drawPill(cRight, cy, rgb)
    local w, h = 17 * cq, 3.6 * cq
    local x, y = cRight - w, cy - h / 2
    colour.set(rgb)
    love.graphics.rectangle("fill", x, y, w, h, 1 * cq)
    setC(C_PILL_EDGE)
    love.graphics.setLineWidth(math.max(1, 0.3 * cq))
    love.graphics.rectangle("line", x, y, w, h, 1 * cq)
    return x
end

local function drawText(cRight, cy, text, font, col)
    love.graphics.setFont(font)
    setC(col)
    local w = font:getWidth(text)
    love.graphics.print(text, cRight - w, cy - font:getHeight() / 2)
    return cRight - w
end

local function ellipsize(font, text, maxW)
    if font:getWidth(text) <= maxW then return text, font:getWidth(text) end
    local s = text
    while #s > 1 and font:getWidth(s .. "...") > maxW do s = s:sub(1, #s - 1) end
    s = s .. "..."
    return s, font:getWidth(s)
end

local function drawCombo(cRight, cy, sel)
    local s = tables.state
    local f = tables.comboFields()
    local c = tables.combos[s[f[1]]]
    local a, b, name
    if c.custom then
        a = colour.fromHue(s[f[2]])
        b = colour.fromHue(s[f[3]])
        name = "Custom"
    else
        a, b, name = c.a, c.b, c.n
    end

    -- dual gradient pill (rounded, clipped via stencil)
    local w, h = 11 * cq, 3.6 * cq
    local x, y = cRight - w, cy - h / 2
    love.graphics.stencil(function()
        love.graphics.rectangle("fill", x, y, w, h, 1 * cq)
    end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    local n = 18
    for i = 0, n - 1 do
        local t = (n > 1) and (i / (n - 1)) or 0
        colour.set(colour.lerp(a, b, t))
        love.graphics.rectangle("fill", x + i * w / n, y, w / n + 1, h)
    end
    love.graphics.setStencilTest()
    setC(C_PILL_EDGE)
    love.graphics.setLineWidth(math.max(1, 0.3 * cq))
    love.graphics.rectangle("line", x, y, w, h, 1 * cq)

    -- name, ellipsized, to the pill's left
    local nameRight = x - 2 * cq
    local font = F.value
    local shown, sw = ellipsize(font, name, 26 * cq)
    love.graphics.setFont(font)
    setC(sel and C_LABEL_SEL or C_VALUE)
    love.graphics.print(shown, nameRight - sw, cy - font:getHeight() / 2)
    return nameRight - sw
end

local function drawBright(cRight, cy, sel)
    -- In Screen mode this row is a readout of the panel, not a control: the arrows
    -- are already greyed by canAdjust, and the fill drops to a muted grey so it
    -- doesn't read as something you can push.
    local readOnly = tables.brightFollowsScreen()
    local value = tables.effectiveBright()
    local font = F.value
    local numText = string.format("%d%%", math.floor(value * 100 + 0.5))
    love.graphics.setFont(font)
    setC((sel and not readOnly) and C_LABEL_SEL or C_VALUE)
    love.graphics.print(numText, cRight - font:getWidth(numText), cy - font:getHeight() / 2)

    local numLeft = cRight - 9 * cq          -- reserved width for "100%"
    local bw, bh = 17 * cq, 2.8 * cq
    local bRight = numLeft - 2 * cq
    local bx, by = bRight - bw, cy - bh / 2
    setC(C_MINI_BG)
    love.graphics.rectangle("fill", bx, by, bw, bh, 1.2 * cq)
    if value > 0 then
        setC(readOnly and C_MINI_READ or C_MINI_FILL)
        love.graphics.rectangle("fill", bx, by, math.max(bh, bw * value), bh, 1.2 * cq)
    end
    return bx
end

local function drawContent(key, cRight, cy, sel)
    local s = tables.state
    if key == "mode" then
        return drawText(cRight, cy, s.mode, F.value, sel and C_LABEL_SEL or C_VALUE)
    elseif key == "speed" then
        return drawText(cRight, cy, tables.speeds[s.speed], F.value, sel and C_LABEL_SEL or C_VALUE)
    elseif key == "lowbatt" then
        return drawText(cRight, cy, tables.lowbatt[s.lowbatt], F.value, sel and C_LABEL_SEL or C_VALUE)
    elseif key == "brightmode" then
        return drawText(cRight, cy, tables.brightmodes[s.brightmode], F.value, sel and C_LABEL_SEL or C_VALUE)
    elseif key == "colour" then
        return drawPill(cRight, cy, colour.fromHue(s.hue))
    elseif key == "lcolour" then
        return drawPill(cRight, cy, colour.fromHue(s[tables.comboFields()[2]]))
    elseif key == "rcolour" then
        return drawPill(cRight, cy, colour.fromHue(s[tables.comboFields()[3]]))
    elseif key == "combo" then
        return drawCombo(cRight, cy, sel)
    elseif key == "bright" then
        return drawBright(cRight, cy, sel)
    end
    return cRight
end

-- ---- one row at an explicit y

local function drawRow(y, key, sel, accent)
    local child = tables.isChild(key)
    local cy = y + L.rowH / 2

    if sel then
        setC(C_ROWSEL)
        love.graphics.rectangle("fill", L.menuX, y, L.menuW, L.rowH, 2 * cq)
        colour.set(accent)
        love.graphics.rectangle("fill", L.menuX, y + 1.2 * cq, 0.8 * cq, L.rowH - 2.4 * cq, 0.4 * cq)
    end

    -- label
    local lfont = child and F.child or F.label
    local lcol
    if child then lcol = sel and C_CHILD_SEL or C_CHILD
    else lcol = sel and C_LABEL_SEL or C_LABEL end
    love.graphics.setFont(lfont)
    setC(lcol)
    local lx = L.menuX + L.pad + (child and 2.4 * cq or 0)
    love.graphics.print(tables.labelOf(key), lx, cy - lfont:getHeight() / 2)

    -- value cluster: [<] content [>], right-aligned. Arrows are neutral white
    -- (bright when selected), greyed out when that direction has hit its limit.
    local canL, canR = tables.canAdjust(key)
    local base = sel and C_ARROW_SEL or C_ARROW
    local colL = canL and base or C_ARROW_OFF
    local colR = canR and base or C_ARROW_OFF
    local aw, ah = 0.9 * cq, 1.1 * cq
    local aGap = 1.6 * cq
    local rightEdge = L.menuX + L.menuW - L.pad

    local rax = rightEdge - aw
    chevron(rax, cy, "right", aw, ah, colR)
    local contentRight = rax - aw - aGap
    local contentLeft = drawContent(key, contentRight, cy, sel)
    local lax = contentLeft - aGap - aw
    chevron(lax, cy, "left", aw, ah, colL)
end

local function drawTopbar()
    local text = "RGB SUITE"
    local font = F.word
    love.graphics.setFont(font)
    local spacing = 0.2 * font:getWidth("A")
    local total = 0
    for i = 1, #text do
        total = total + font:getWidth(text:sub(i, i))
        if i < #text then total = total + spacing end
    end
    local x = W / 2 - total / 2
    local y = 5.5 * cq
    local acc = 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        local w = font:getWidth(ch)
        colour.set(sampleWord((acc + w / 2) / total))   -- 0-255 stops -> colour.set divides
        love.graphics.print(ch, x, y)
        x = x + w + spacing
        acc = acc + w + spacing
    end

    local sub = tables.deviceLabel()
    love.graphics.setFont(F.sub)
    setC(C_SUB)
    love.graphics.print(sub, W / 2 - F.sub:getWidth(sub) / 2, y + font:getHeight() + 1.4 * cq)
end

local function drawHints()
    local font = F.hint
    love.graphics.setFont(font)
    local h = 1.1 * cq
    local w = 0.95 * cq
    local pieces = {
        { tri = "up" }, { tri = "down" }, { txt = "Select" }, { gap = true },
        { tri = "left" }, { tri = "right" }, { txt = "Adjust" }, { gap = true },
        { txt = "L1+R1", b = true }, { txt = "Quit" }, { gap = true },
        { txt = "X", b = true }, { txt = "Info" },
    }
    local function pw(p)
        if p.gap then return 2.6 * cq
        elseif p.tri then return 2 * w + 1.1 * cq
        else return font:getWidth(p.txt) + 1.2 * cq end
    end
    local total = 0
    for _, p in ipairs(pieces) do total = total + pw(p) end

    local x = W / 2 - total / 2
    for _, p in ipairs(pieces) do
        if p.tri then
            chevron(x + w, L.hintY, p.tri, w, h, C_HINT_B)
        elseif p.txt then
            setC(p.b and C_HINT_B or C_HINT)
            love.graphics.print(p.txt, x + 0.4 * cq, L.hintY - font:getHeight() / 2)
        end
        x = x + pw(p)
    end
end

-- First-launch modal: a dark rounded card over a dim scrim reminding the user to
-- enable MustardOS's "User init scripts" so the daemon starts at boot, and to set its
-- RGB Mode to External so it stops writing the LEDs. Shown once, reopened by X.
local HINT_HEAD = "BEFORE YOU START"
local HINT_BODY = "Enable User init scripts in Advanced Settings so RGB Suite can load your lighting setup on boot."
local HINT_BODY2 = "Then set Mode to External in MustardOS's RGB Lights settings, so it leaves the lights to RGB Suite."
local HINT_FOOT = "Press any button to continue"
local HINT_CREDIT = "Made by SkyArcher, inspired by many"
local HINT_ACCENT = { 255, 209, 102 }   -- warm amber (the wordmark's amber stop)

-- The narrowest width that still wraps to the SAME number of lines - CSS text-wrap:
-- balance, by hand. Greedy wrapping fills each line to the brim and leaves whatever is
-- left on the last one, which stranded "Off." alone (device-reported 2026-09-12);
-- narrowing the measure spreads the words evenly instead. The card keeps its width and
-- its line count, so nothing around it moves. Cached: the answer only changes when the
-- measure does, and the card would otherwise re-run the search every frame.
local balanceCache = {}
local function balancedWidth(font, text, maxW)
    local key = text .. "@" .. math.floor(maxW)
    if balanceCache[key] then return balanceCache[key] end
    local _, lines = font:getWrap(text, maxW)
    local want = #lines
    local w = maxW
    if want >= 2 then
        local lo, hi = 1, maxW
        while hi - lo > 0.5 do
            local mid = (lo + hi) / 2
            local _, l = font:getWrap(text, mid)
            if #l <= want then hi = mid else lo = mid end
        end
        w = hi
    end
    balanceCache[key] = w
    return w
end

function draw.hintCard()
    love.graphics.setColor(0, 0, 0, 0.62)          -- dim scrim
    love.graphics.rectangle("fill", 0, 0, W, H)

    local cardW = math.min(74 * cq, 0.9 * W)
    local pad   = 4.5 * cq
    local innerW = cardW - 2 * pad
    local headFont, bodyFont, footFont = F.label, F.child, F.hint

    local _, bodyLines  = bodyFont:getWrap(HINT_BODY, innerW)
    local _, body2Lines = bodyFont:getWrap(HINT_BODY2, innerW)
    local lh     = bodyFont:getHeight() * 1.35
    local bodyH  = #bodyLines * lh
    local body2H = #body2Lines * lh
    -- Head, both paragraphs and the prompt are one message, so they sit close together
    -- (gapB separates the paragraphs); the credit line is a separate footer and needs
    -- the widest gap of all to read as one.
    local gap1, gapB, gap2, gap3 = 3.2 * cq, 2.2 * cq, 2.4 * cq, 4.2 * cq
    local cardH = pad + headFont:getHeight() + gap1 + bodyH + gapB + body2H + gap2
        + footFont:getHeight() + gap3 + footFont:getHeight() + pad
    local cardX = (W - cardW) / 2
    local cardY = (H - cardH) / 2

    setC({ 0x12 / 255, 0x14 / 255, 0x1c / 255, 0.98 })      -- panel
    love.graphics.rectangle("fill", cardX, cardY, cardW, cardH, 2.2 * cq)
    love.graphics.stencil(function()                        -- accent top strip (clipped to rounded corners)
        love.graphics.rectangle("fill", cardX, cardY, cardW, cardH, 2.2 * cq)
    end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    colour.set(HINT_ACCENT)
    love.graphics.rectangle("fill", cardX, cardY, cardW, 0.8 * cq)
    love.graphics.setStencilTest()
    setC(C_PILL_EDGE)                                       -- border
    love.graphics.setLineWidth(math.max(1, 0.3 * cq))
    love.graphics.rectangle("line", cardX, cardY, cardW, cardH, 2.2 * cq)

    local y = cardY + pad
    love.graphics.setFont(headFont); colour.set(HINT_ACCENT)
    love.graphics.printf(HINT_HEAD, cardX + pad, y, innerW, "center")
    y = y + headFont:getHeight() + gap1
    love.graphics.setFont(bodyFont); setC(C_VALUE)
    local bw = balancedWidth(bodyFont, HINT_BODY, innerW)
    love.graphics.printf(HINT_BODY, cardX + pad + (innerW - bw) / 2, y, bw, "center")
    y = y + bodyH + gapB
    local bw2 = balancedWidth(bodyFont, HINT_BODY2, innerW)
    love.graphics.printf(HINT_BODY2, cardX + pad + (innerW - bw2) / 2, y, bw2, "center")
    y = y + body2H + gap2
    love.graphics.setFont(footFont); setC(C_HINT_B)
    love.graphics.printf(HINT_FOOT, cardX + pad, y, innerW, "center")
    y = y + footFont:getHeight() + gap3
    setC(C_HINT)                                            -- dimmer than the prompt
    love.graphics.printf(HINT_CREDIT, cardX + pad, y, innerW, "center")

    love.graphics.setColor(1, 1, 1, 1)
end

function draw.render()
    -- background
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(bgMesh)                       -- default background, always the base
    if washFade > 0.001 then                         -- Screen React wash fades in/out over it
        washShader:send("u_left", washL)
        washShader:send("u_right", washR)
        washShader:send("u_fade", washFade)
        love.graphics.setShader(washShader)
        love.graphics.rectangle("fill", 0, 0, W, H)
        love.graphics.setShader()
    end

    drawTopbar()

    local mk = tables.modeKeys()
    local gk = tables.globalKeys()
    local sel = tables.state.sel
    local total = #mk + #gk
    if sel > total then sel = total; tables.state.sel = sel end
    local accent = tables.accent()

    for i, key in ipairs(mk) do
        drawRow(L.menuTop + (i - 1) * (L.rowH + L.gap), key, i == sel, accent)
    end

    if #gk > 0 then
        setC(C_DIVIDER)
        love.graphics.rectangle("fill", L.menuX + L.pad, L.dividerY, L.menuW - 2 * L.pad, math.max(1, 0.16 * cq))
        for j, key in ipairs(gk) do
            drawRow(L.globalTop + (j - 1) * (L.rowH + L.gap), key, (#mk + j) == sel, accent)
        end
    end

    drawHints()

    -- CRT scanlines over the whole screen (subtle, last so it covers everything)
    love.graphics.setShader(scanShader)
    love.graphics.rectangle("fill", 0, 0, W, H)
    love.graphics.setShader()

    love.graphics.setColor(1, 1, 1, 1)
end

return draw
