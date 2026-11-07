-- color.lua - color helpers shared by the UI and the config writer.
-- RGB triplets are kept in 0-255 range (like the serial protocol / mockup);
-- convert to LOVE's 0-1 only at draw time via color.set().

local color = {}

local function round(x) return math.floor(x + 0.5) end

-- HSL -> RGB (0-255), matching the mockup's hsl2rgb exactly.
function color.hsl2rgb(h, s, l)
    s = s / 100
    l = l / 100
    local a = s * math.min(l, 1 - l)
    local function k(n) return (n + h / 30) % 12 end
    local function f(n) return l - a * math.max(-1, math.min(k(n) - 3, math.min(9 - k(n), 1))) end
    return { round(f(0) * 255), round(f(8) * 255), round(f(4) * 255) }
end

-- Stick color from a hue on the scrub ring. A negative hue is the white stop
-- (all channels full) - hue alone can never reach white.
--
-- Lightness MUST stay at 50: above it the two lesser channels can never reach 0,
-- so every picked color carries a white pedestal (at L=58 it was a flat 49/255 on
-- every hue, i.e. 80% saturation instead of 100%). On screen that floor hides
-- against the dark UI, but the sticks emit it as white mixed into the hue, which
-- is what made Static and Custom Combo look washed out next to the Combo presets -
-- those are raw 100%-saturated triplets in tables.lua. Raising saturation alone
-- does not fix it: at S=100/L=58 the floor is still 41/255.
function color.fromHue(h)
    if h < 0 then return { 255, 255, 255 } end
    return color.hsl2rgb(h, 100, 50)
end

-- Multiply a color toward black (brightness preview). b in 0..1.
function color.dim(c, b)
    return { c[1] * b, c[2] * b, c[3] * b }
end

function color.clamp255(v)
    if v < 0 then return 0 elseif v > 255 then return 255 else return round(v) end
end

-- "R,G,B" for settings.cfg
function color.toStr(c)
    return string.format("%d,%d,%d", color.clamp255(c[1]), color.clamp255(c[2]), color.clamp255(c[3]))
end

-- Set the LOVE draw color from a 0-255 triplet (+ optional alpha).
function color.set(c, a)
    love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1)
end

-- Linear interpolate two 0-255 triplets.
function color.lerp(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

return color
