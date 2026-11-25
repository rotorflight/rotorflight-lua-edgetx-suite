-- FRAME of the theme for EdgeTX: the cockpit's lines as nodes of the suite (lvgl) on the one background, in the chosen
-- colour; the sizes of the Ethos theme (480 x 320) scaled to the radio's screen (800 x 480, 480 x 320, 480 x 272). A line is four pixels of mid tone with two pixels
-- of bright core and one pixel of glow on each side. A field with rounded corners is one hollow node per layer, an open side lies
-- outside the screen; the middle field has no top edge, the notch lies there as a mask (gfx/notch_<colour>.png), its
-- lower corners are arcs. kx(c), ky(r) turn a line of the reference layout into the first column and row of its core.
local R = {}
local floor, sin, cos, rad, min, max = math.floor, math.sin, math.cos, math.rad, math.min, math.max

local W, H = tonumber(LCD_W) or 800, tonumber(LCD_H) or 480   -- the radio's screen size, read the usual way: the suite loads the theme in an environment of its own
local LARGE800 = W >= 700
R.W, R.H, R.LARGE800 = W, H, LARGE800
R.GFX = LARGE800 and "gfx/" or ("gfx_" .. W .. "x" .. H .. "/")   -- the image folder for this screen size

function R.sx(v) return floor(v * W / 480 + 0.5) end   -- sx, sy, kx, ky: positions in the 480 x 320 reference onto this screen; px, py: pixels of the 800 x 480 layout
function R.sy(v) return floor(v * H / 320 + 0.5) end
function R.kx(c) return floor(c * W / 480 + 1 / 3) end   -- first core column of a vertical line of the reference layout in column c
function R.ky(r) return floor(r * H / 320 + 0.25) end    -- first core row of a horizontal line of the reference layout in row r
function R.px(v) return floor(v * W / 800 + 0.5) end     -- pixels of the 800 x 480 layout in width
function R.py(v) return floor(v * H / 480 + 0.5) end     -- and in height; radii use py so that a circle stays round
local kx, ky, px, py = R.kx, R.ky, R.px, R.py

R.CORE, R.MID, R.GLOW = LARGE800 and 2 or 1, LARGE800 and 4 or 3, LARGE800 and 6 or 5   -- 480 screens as in the Ethos theme at 480 x 320: core 1, mid tone 3, glow 5
R.ROUND = LARGE800 and 7 or 5                  -- outer core radius at a corner of the reference layout with r 4 (6 pixels, the core 1.5 outside of it; at 480: r 4 and half the core)
R.GREEN, R.YELLOW, R.RED = {12, 228, 16}, {245, 224, 26}, {240, 35, 12}
R.NEEDLE, R.GREY = {255, 80, 80}, {134, 138, 145}
R.LARGE = {r = py(152), start = -104.4, stop = 104.4, foot = py(90), tip = py(132), ticks = "ticks_large.png", tickEdge = 2 * (py(152) + py(4)) + 2}   -- the two gauges: arc and arrow (LARGE) or bar (SMALL); angles as in Ethos (0 = top), green up to 78 %, yellow up to 90 %, then red
R.SMALL = {r = py(70), start = -135, stop = 100, barInner = py(48), barOuter = py(54), ticks = "ticks_small.png", tickEdge = 2 * (py(70) + py(4)) + 2}
R.FADE_LEFT = {{5, 394}, {55, 200}, {250, 225}, {255, 215}}   -- per line of a page: row of the reference layout and how far it reaches into the picture from the cockpit (as in the Ethos theme); the lowest one (314) is missing on the preflight page: it sat just below the last foot chip and doubled its edge
R.FADE_RIGHT = {{5, 394}, {55, 330}, {250, 225}, {255, 215}, {314, 120}}
R.FADE_SOFT = px(200)                     -- length of the gradient at the end of a line (Ethos 120)
R.NOTCH = {x = px(190), y = py(51), w = px(420), h = py(48)}
R.BUTTON_DX, R.BUTTON_DY = LARGE800 and 10 or 8, LARGE800 and 5 or 4   -- the children of a button sit inside it (800: border 2, padding 8 and 3; 480: 8 and 4, measured in the simulator): this far back

function R.rgb(t) return lcd.RGB(t[1], t[2], t[3]) end

function R.colours(e)                          -- {mid, core, glow} from colours.lua as radio colours
    return {mid = R.rgb(e.mid), core = R.rgb(e.core), glow = R.rgb(e.glow)}
end

local function rect(n, x, y, w, h, colour)
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, filled = true, color = colour}
end

function R.horizontal(n, F, k, x0, x1)        -- core in rows k and k+1, from column x0 to x1 (inclusive)
    rect(n, x0, k - 2, x1 - x0 + 1, R.GLOW, F.glow)
    rect(n, x0, k - 1, x1 - x0 + 1, R.MID, F.mid)
    rect(n, x0, k, x1 - x0 + 1, R.CORE, F.core)
end

function R.vertical(n, F, k, y0, y1)
    rect(n, k - 2, y0, R.GLOW, y1 - y0 + 1, F.glow)
    rect(n, k - 1, y0, R.MID, y1 - y0 + 1, F.mid)
    rect(n, k, y0, R.CORE, y1 - y0 + 1, F.core)
end

function R.field(n, F, x, y, w, h, r)   -- a field with round corners: x, y, w, h is the core (two pixels, inside at the edge), mid tone and glow one pixel further out each; r = outer core radius
    n[#n + 1] = {type = "rectangle", x = x - 2, y = y - 2, w = w + 4, h = h + 4, thickness = R.GLOW, rounded = r + 2, color = F.glow}
    n[#n + 1] = {type = "rectangle", x = x - 1, y = y - 1, w = w + 2, h = h + 2, thickness = R.MID, rounded = r + 1, color = F.mid}
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, thickness = R.CORE, rounded = r, color = F.core}
end

function R.corner(n, F, cx, cy, r, a0, a1)   -- a round corner alone: three arcs around cx, cy, a0 to a1 as in lvgl (0 right, clockwise); an arc with radius r matches the corner of a rounded rectangle
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r + 2, thickness = R.GLOW, startAngle = a0, endAngle = a1, color = F.glow}
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r + 1, thickness = R.MID, startAngle = a0, endAngle = a1, color = F.mid}
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r, thickness = R.CORE, startAngle = a0, endAngle = a1, color = F.core}
end

function R.frame(n, F, x, y, w, h)          -- a thin frame in the core only (the battery)
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, thickness = R.CORE, color = F.core}
end

function R.batteryIcon(n, F, dx, dy)            -- the battery: frame and cap (the cockpit draws its bars); dx, dy when it lies as a child of a button - in full screen the face of the battery button covers the frame below
    R.frame(n, F, kx(136) - dx, ky(267) - dy, kx(155) + 1 - kx(136) + 1, ky(301) + 1 - ky(267) + 1)
    rect(n, kx(142) - dx, ky(263) - 1 - dy, R.sx(8), ky(267) - (ky(263) - 1), F.core)
end

function R.cockpit(n, F)   -- the whole frame, open left and right, without a top line next to the middle field; in full screen a hollow field takes every press: the buttons come after the frame, the mask of the notch after the buttons
    local OUT = 40                            -- this far an open side lies outside the screen
    R.horizontal(n, F, ky(5), 0, W - 1)                                            -- the line at the top
    R.field(n, F, -OUT, ky(55), kx(116) + 1 + OUT, ky(250) + 1 - ky(55) + 1, R.ROUND)   -- the left field, open to the left
    R.field(n, F, kx(363), ky(55), W + OUT - kx(363), ky(250) + 1 - ky(55) + 1, R.ROUND)  -- the right field, open to the right
    local l, r, u = kx(121), kx(358) + 1, ky(252)   -- the middle field: sides at 121 and 358 from below the notch to the corners, bottom at 252, corners r 4 as arcs; first core column left, last right, first core row at the bottom
    local fromY, toY = R.NOTCH.y + R.NOTCH.h, u + 1 - R.ROUND     -- the sides: first row below the mask down to above the corner
    R.vertical(n, F, l, fromY, toY)
    R.vertical(n, F, r - 1, fromY, toY)
    R.horizontal(n, F, u, l + R.ROUND, r - R.ROUND)
    R.corner(n, F, l + R.ROUND, u + 2 - R.ROUND, R.ROUND, 90, 180)
    R.corner(n, F, r + 1 - R.ROUND, u + 2 - R.ROUND, R.ROUND, 0, 90)
    local top, height = ky(255), ky(314) + 1 - ky(255) + 1   -- the foot row (255 to 314): three fields, open left and right, corners r 4
    R.field(n, F, -OUT, top, kx(117) + 1 + OUT, height, R.ROUND)
    R.field(n, F, kx(121), top, kx(358) + 1 - kx(121) + 1, height, R.ROUND)
    R.field(n, F, kx(362), top, W + OUT - kx(362), height, R.ROUND)
    R.batteryIcon(n, F, 0, 0)                    -- the battery bottom left in the middle field of the foot row; the box around the tank gauge is gone
end

function R.notch(n, dir, colour)          -- the notch at the top of the middle field: the mask in the colour (only the lines, transparent elsewhere)
    n[#n + 1] = {type = "image", x = R.NOTCH.x, y = R.NOTCH.y, w = R.NOTCH.w, h = R.NOTCH.h,
                 file = dir .. R.GFX .. "notch_" .. colour .. ".png"}
end

function R.page(n, F, left, dir, colour)   -- the lines of a page (preflight four, banks five): into the picture from the cockpit, then fading (image gfx/fade_<colour>_l/_r.png in two lengths)
    for _, l in ipairs(left and R.FADE_LEFT or R.FADE_RIGHT) do
        local k, reach = ky(l[1]), R.sx(l[2])
        local soft = min(R.FADE_SOFT, floor(reach * 0.8))
        if left then
            R.horizontal(n, F, k, W - reach + soft, W - 1)
            n[#n + 1] = {type = "image", x = W - reach, y = k - 2, w = soft, h = R.GLOW,
                         file = dir .. R.GFX .. "fade_" .. colour .. "_l" .. soft .. ".png"}
        else
            R.horizontal(n, F, k, 0, reach - soft - 1)
            n[#n + 1] = {type = "image", x = reach - soft, y = k - 2, w = soft, h = R.GLOW,
                         file = dir .. R.GFX .. "fade_" .. colour .. "_r" .. soft .. ".png"}
        end
    end
end

function R.angle(a) return a - 90 + ((a - 90 < 0) and 360 or 0) end   -- Ethos angle (0 at the top) to lvgl (0 right), 0..360

local function arc(n, cx, cy, r, thick, a0, a1, colour)
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r, thickness = thick, startAngle = a0, endAngle = a1, color = colour}
end

function R.gaugeArc(n, kind, cx, cy, dir)   -- the arc of a gauge: green, yellow, red (Ethos: ring r-1 to r+1, here three pixels) and the ticks as an image
    local w = R.angle
    local g, y = kind.start + (kind.stop - kind.start) * 0.78, kind.start + (kind.stop - kind.start) * 0.90
    local a0, ag, ay, a1 = w(kind.start), w(g), w(y), w(kind.stop)
    if ag < a0 then ag = ag + 360 end         -- past 0 (right) lvgl keeps counting (135 to 405 in the suite's gauge.lua)
    if ay < ag then ay = ay + 360 end
    if a1 < ay then a1 = a1 + 360 end
    local r = kind.r + 2
    arc(n, cx, cy, r, 3, floor(a0 + 0.5), floor(ag + 0.5), R.rgb(R.GREEN))
    arc(n, cx, cy, r, 3, floor(ag + 0.5), floor(ay + 0.5), R.rgb(R.YELLOW))
    arc(n, cx, cy, r, 3, floor(ay + 0.5), floor(a1 + 0.5), R.rgb(R.RED))
    local half = floor(kind.tickEdge / 2)
    n[#n + 1] = {type = "image", x = cx - half, y = cy - half, w = kind.tickEdge, h = kind.tickEdge, file = dir .. R.GFX .. kind.ticks}
end

function R.arrowPoints(kind, cx, cy, fraction)   -- the three corners of the arrow (LARGE) for a fraction 0..1 of the arc, in screen pixels
    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    local a = kind.start + (kind.stop - kind.start) * fraction
    local w, w1, w2 = rad(a), rad(a - 7), rad(a + 7)
    return {{floor(cx + kind.foot * sin(w1) + 0.5), floor(cy - kind.foot * cos(w1) + 0.5)},
            {floor(cx + kind.foot * sin(w2) + 0.5), floor(cy - kind.foot * cos(w2) + 0.5)},
            {floor(cx + kind.tip * sin(w) + 0.5), floor(cy - kind.tip * cos(w) + 0.5)}}
end

function R.arrow(n, points, shown)        -- the cockpit's arrow: a triangle whose corners a function names
    n[#n + 1] = {type = "triangle", x = 0, y = 0, w = 0, h = 0, pts = points, color = R.rgb(R.NEEDLE), visible = shown}
end

function R.bars(n, F, kind, cx, cy, stop, shown)   -- the bar of the banks page: a ring inside the arc from the start to the value (lvgl angle named by a function)
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = kind.barOuter, thickness = kind.barOuter - kind.barInner,
                 startAngle = floor(R.angle(kind.start) + 0.5), endAngle = stop, color = F.mid, visible = shown}
end

function R.barAngle(kind, fraction)         -- the lvgl angle of the bar's end for a fraction 0..1
    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    local a = R.angle(kind.start) + (kind.stop - kind.start) * fraction
    return floor(a + 0.5)
end

R.SPIKES = {left = {{66, 24}, {240, 60}, {262, 45}}, right = {{66, 24}, {124, 60}, {136, 45}, {240, 24}}}   -- as in the Ethos theme: per row, how far a line of the pages reaches from the screen edge into the cockpit

function R.spikes(n, dir, colour)        -- the spikes: on the left the lines of the preflight page (battery box, last foot chip), on the right those of the banks page (chips); full at the edge, fading over their whole length
    for _, s in ipairs(R.SPIKES.left) do
        local w = R.sx(s[2])
        n[#n + 1] = {type = "image", x = 0, y = ky(s[1]) - 2, w = w, h = R.GLOW, file = dir .. R.GFX .. "fade_" .. colour .. "_r" .. w .. ".png"}
    end
    for _, s in ipairs(R.SPIKES.right) do
        local w = R.sx(s[2])
        n[#n + 1] = {type = "image", x = W - w, y = ky(s[1]) - 2, w = w, h = R.GLOW, file = dir .. R.GFX .. "fade_" .. colour .. "_l" .. w .. ".png"}
    end
end

return R
