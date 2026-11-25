-- PREFLIGHT: the page left of the cockpit (init.lua views; PAGE left or a tap on the battery), on the cockpit's background,
-- the lines run in from the right and fade out. Head band: flight mode on the left, the model name centred, link and
-- VFR on the right as five bars each without numbers; on the left the pilot's model image with a soft edge, on the right the battery (level, voltage,
-- cells, capacity), cell and consumption, open to the right edge; in the foot band four chips with the last flight: altitude, climb,
-- sink, flight time. A tap anywhere or RTN leads back: the whole page is one button, everything else is its children.
local PATHS = rfsuite and rfsuite.paths or {}
local DIR = PATHS.core and (PATHS.core .. "/widgets/dashboard/themes/@nf/") or nil
if DIR == nil or loadScript(DIR .. "init.lua", "t") == nil then
    if PATHS.user then DIR = PATHS.user .. "/dashboard/nf/" end
end
local floor = math.floor

local function suiteModule(modPath)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, modPath)
        if ok and type(m) == "table" then return m end
    end
    return nil
end
local T = suiteModule(DIR .. "parts.lua")
if T == nil then
    local chunk = loadScript(DIR .. "parts.lua")
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    T = (ok and type(t) == "table") and t or nil
end
if T == nil then return {build = function(children) children[#children + 1] = {type = "label", x = 10, y = 10, w = (tonumber(LCD_W) or 800) - 20, text = "parts.lua", color = lcd.RGB(255, 80, 80)} end} end
local G, R, COLOUR, F = T.G, T.R, T.COLOUR, T.F
local disp = G.disp
local sx, sy = R.sx, R.sy
local DX, DY = R.BUTTON_DX, R.BUTTON_DY
local P = nil                                          -- the nodes of the pages (page.lua)
do
    local chunk = loadScript(DIR .. "page.lua")
    local ok, make = false, nil
    if chunk then ok, make = pcall(chunk) end
    if ok and type(make) == "function" then P = make(T) end
end

local PHOTO = {x = 10, y = 66, h = 168}                 -- the photo field, 4:3 from the height; the photo frame (photo_frame.png) has the same size
local BARS = {link = 398, vfr = 438, bottom = 36}    -- five signal bars each, both groups next to each other at the top right
local LINK_LEVELS = {42, 50, 60, 70, 85}               -- per bar; 42 is the radio's warning threshold
local VFR_LEVELS = {20, 40, 60, 80, 95}                -- percent per bar
local HEAD_Y = 28                                      -- the middle of the head band
local MODE = {x = 12, word = 16, val = 34}           -- left in the head band: FLIGHT MODE small, the mode below
local BATTERY = {x = 246, y = 66, w = 234, h = 174}       -- the border on the right, open to the edge
local FOOT = {y = 262, h = 48, w = 112, gap = 6, x = 10}
local SUITE_LOGO = "/widgets/dashboard/gfx/logo.png"   -- the image the suite shows when the pilot has none: then the field stays empty
local BATTERY_PAUSE = 3                                   -- s until the next request for BATTERY_CONFIG when one failed

local M = {}
function M.sources() return {"consumption", "smartconsumption", "1RSS", "VFR", "RQly", "link", "voltage", "fuel", "current", "altitude"} end

local function levels(val, list)
    if val == nil then return 0 end
    local n = 0
    for i = 1, #list do if val >= list[i] then n = i end end
    return n
end

local function num(v, pattern)                         -- text and colour of a number; without a value "--" muted
    if v == nil then return "--", P.MUTED end
    if pattern == nil then v = floor(v + 0.5) end
    local z = string.format(pattern or "%d", v)
    if type(v) == "number" and v <= 0 and string.find(z, "^%-[0.]*$") then z = string.sub(z, 2) end   -- what rounds to zero stands without a minus
    return z, COLOUR.g
end

local function now()                                 -- seconds since the radio started
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

local function heliNow()
    local se = rfsuite and rfsuite.session
    if type(se) ~= "table" or se.isConnected ~= true then return nil end
    return se.mcu_id
end

local function capacity()                            -- the capacity of the selected battery as the suite holds it; otherwise BATTERY_CONFIG once per heli
    local se = rfsuite and rfsuite.session
    local bc = type(se) == "table" and (se.batteryConfig or se.battery_config) or nil
    local cap = type(bc) == "table" and tonumber(bc.batteryCapacity) or nil
    if cap ~= nil and cap > 0 then return cap, tonumber(bc.batteryCellCount) end
    local heli = heliNow()
    local a = G.pfBattery
    if a ~= nil and a.heli == heli and a.values ~= nil then return tonumber(a.values.batteryCapacity), tonumber(a.values.batteryCellCount) end
    if heli ~= nil and P ~= nil and (a == nil or a.heli ~= heli or (a.values == nil and not a.running and now() >= (a.after or 0))) then
        local query = {heli = heli, running = true}
        G.pfBattery = query
        if not P.read("battery_config", function(w)
            query.running = false
            if w ~= nil then query.values = w else query.after = now() + BATTERY_PAUSE end
        end) then query.running, query.after = false, now() + BATTERY_PAUSE end
    end
    return nil, nil
end

local function refresh(state)
    local s = T.read(state)
    T.mspRelease()                                     -- the place at the MSP service goes back between reads
    local d = state.derived or {}
    local batteryF = COLOUR[T.batteryColour(T.batteryFraction(state, s.pack, s.cellF or s.cell))] or COLOUR.g
    local link = COLOUR[T.linkColour(state, s.vfr)] or COLOUR.w
    if link == COLOUR.w then link = COLOUR.g end                      -- good means green here, like the numbers
    disp.pfLinkF, disp.pfLinkN = link, levels(tonumber(d.link), LINK_LEVELS)
    disp.pfVfrN = levels(s.vfr, VFR_LEVELS)
    local mode = T.modeWord(s.fcMode)
    disp.pfMode, disp.pfModeF = mode or "--", mode and COLOUR.g or P.MUTED
    disp.pfFuel, disp.pfFuelF = num(s.fuel ~= nil and floor(s.fuel + 0.5) or nil)
    if s.fuel ~= nil then disp.pfFuelF = batteryF end
    disp.pfPack, disp.pfPackF = num(s.pack, "%.1f")
    if s.pack ~= nil then disp.pfPackF = batteryF end
    local cap, cellCap = capacity()
    local cells = s.cells or cellCap
    if cells ~= nil and cells <= 0 then cells = nil end
    disp.pfCells, disp.pfCellsF = (cells ~= nil and tostring(floor(cells)) or "--") .. "S  ", cells ~= nil and COLOUR.w or P.MUTED
    disp.pfCap, disp.pfCapF = num(cap ~= nil and cap > 0 and cap or nil)
    disp.pfCell, disp.pfCellF = num(s.cell, "%.2f")
    if s.cell ~= nil then disp.pfCellF = batteryF end
    disp.pfMah, disp.pfMahF = num(s.consumed ~= nil and floor(s.consumed + 0.5) or nil)
    local fl, sz = G.lastFlight or {}, G.sinceStart or {}             -- the last flight here; without a flight the peaks since power-on
    disp.pfAltE, disp.pfRateE = s.altFt and "ft" or "m", s.altFt and "ft/s" or "m/s"
    local sink = fl.sink or sz.sinkMax
    disp.pfAlt, disp.pfAltF = num(fl.alt or sz.altMax, "%.0f")
    disp.pfClimb, disp.pfClimbF = num(fl.climb or sz.climbMax, "%.1f")
    disp.pfSink, disp.pfSinkF = num(sink ~= nil and -sink or nil, "%.1f")
    local secs = fl.time
    disp.pfTime, disp.pfTimeF = num(secs ~= nil and string.format("%d:%02d", floor(secs / 60), floor(secs % 60)) or nil, "%s")
    local image = type(d.model_image) == "string" and d.model_image or nil
    if image ~= nil and string.find(image, SUITE_LOGO, 1, true) then image = nil end
    disp.pfPhoto = image
end

local function nameFont(text, textWidth)             -- the model name as large as fits the width
    for _, level in ipairs({F.l, F.std, F.s}) do
        if T.textWidth(text, level) <= textWidth then return level end
    end
    return F.s
end

local function node(colour)                           -- depends only on the colour, kept in G as on the banks page; the build in three parts and the assembly
    local L = T.lines(colour)
    local k = {}                                       -- the children of the one button, moved back by DX, DY
    local parts = {}
    local a = BATTERY
    parts[1] = function()                              -- background, lines, photo, chips, signal bars
    k[#k + 1] = {type = "image", x = 0, y = 0, w = R.W, h = R.H, file = DIR .. R.GFX .. "background.png"}
    R.page(k, L, true, DIR, colour)
    local fh = sy(PHOTO.h)
    local fx, fy, fw = sx(PHOTO.x), sy(PHOTO.y), floor(fh * 4 / 3 + 0.5)
    k[#k + 1] = {type = "image", x = fx, y = fy, w = fw, h = fh, file = function() return disp.pfPhoto or "" end,
                 visible = function() return disp.pfPhoto ~= nil end}
    k[#k + 1] = {type = "image", x = fx, y = fy, w = fw, h = fh, file = DIR .. R.GFX .. "photo_frame.png",
                 visible = function() return disp.pfPhoto ~= nil end}
    P.chip(k, L, a.x, a.y, a.w, a.h, "right")
    for i = 1, 4 do
        local x = FOOT.x + (i - 1) * (FOOT.w + FOOT.gap)
        local w = (i == 4) and (480 - x) or FOOT.w
        P.chip(k, L, x, FOOT.y, w, FOOT.h, i == 4 and "right" or nil)
    end
    P.signal(k, BARS.link, BARS.bottom, function() return disp.pfLinkN or 0 end, function() return disp.pfLinkF or COLOUR.g end)
    P.signal(k, BARS.vfr, BARS.bottom, function() return disp.pfVfrN or 0 end, function() return disp.pfLinkF or COLOUR.g end)
    for i = 1, #k do k[i].x = k[i].x - DX; k[i].y = k[i].y - DY end
    end

    local function v(name) return function() return disp[name] end end
    parts[2] = function()                              -- the head band and the battery
    P.word(k, sx(MODE.x), sy(MODE.word), "@i18n(widgets.dashboard.nf_flight_mode)@", COLOUR.w, F.xs, "left", DX, DY)
    P.row(k, sx(MODE.x), sy(MODE.val), {{v("pfMode"), v("pfModeF"), F.s}}, "left", DX, DY)
    local name = disp.name or ""
    P.row(k, sx(240), sy(HEAD_Y), {{function() return disp.name or "" end, COLOUR.w, nameFont(name, sx(280))}}, nil, DX, DY)
    local cx = sx(a.x + a.w / 2)
    P.word(k, cx, sy(a.y + 17), "@i18n(widgets.dashboard.nf_battery)@", COLOUR.w, F.s, nil, DX, DY)
    P.row(k, cx, sy(a.y + 45), {{v("pfFuel"), v("pfFuelF"), F.xl}, {"%", COLOUR.w, F.s}}, nil, DX, DY)
    P.row(k, cx, sy(a.y + 74), {{v("pfPack"), v("pfPackF"), F.xs}, {"V  ", COLOUR.w, F.xs}, {v("pfCells"), v("pfCellsF"), F.xs},
                                  {v("pfCap"), v("pfCapF"), F.xs}, {"mAh", COLOUR.w, F.xs}}, nil, DX, DY)
    end
    parts[3] = function()                              -- cell, consumption and the four chips of the last flight
    local lx, rx = sx(a.x + a.w / 4), sx(a.x + a.w * 3 / 4)
    P.word(k, lx, sy(a.y + 108), "@i18n(widgets.dashboard.nf_cell)@", COLOUR.w, F.xs, nil, DX, DY)
    P.row(k, lx, sy(a.y + 133), {{v("pfCell"), v("pfCellF"), F.l}, {"V", COLOUR.w, F.s}}, nil, DX, DY)
    P.word(k, rx, sy(a.y + 108), "@i18n(widgets.dashboard.nf_consumption)@", COLOUR.w, F.xs, nil, DX, DY)
    P.row(k, rx, sy(a.y + 133), {{v("pfMah"), v("pfMahF"), F.l}, {"mAh", COLOUR.w, F.s}}, nil, DX, DY)
    local chips = {{"@i18n(widgets.dashboard.nf_alt_max)@", "pfAlt", "pfAltE"}, {"@i18n(widgets.dashboard.nf_climb_max)@", "pfClimb", "pfRateE"}, {"@i18n(widgets.dashboard.nf_sink_max)@", "pfSink", "pfRateE"},
                   {"@i18n(widgets.dashboard.nf_flight_time)@", "pfTime", nil}}
    for i = 1, 4 do
        local x = FOOT.x + (i - 1) * (FOOT.w + FOOT.gap)
        local w = (i == 4) and (480 - x) or FOOT.w
        local c = chips[i]
        P.word(k, sx(x + w / 2), sy(FOOT.y + 13), c[1], COLOUR.w, F.xs, nil, DX, DY)
        local unit = c[3] and v(c[3]) or "min"
        P.row(k, sx(x + w / 2), sy(FOOT.y + 33), {{v(c[2]), v(c[2] .. "F"), F.std}, {unit, COLOUR.w, F.xs}}, nil, DX, DY)
    end
    end
    parts[4] = function() end                          -- the last call only assembles: the first creation of all nodes has a call of its own
    return k, parts
end

local function begin(colour)                         -- the set for this colour: from G, otherwise newly created (still without nodes)
    local cacheKey = tostring(colour)
    local f = G.pfDone
    if type(f) ~= "table" or f.cacheKey ~= cacheKey then
        local k, parts = node(colour)
        f = {cacheKey = cacheKey, k = k, parts = parts, i = 1}
        G.pfDone = f
    end
    return f
end

local function buildPart(f)                              -- builds the next part; true when all are there
    if f.parts ~= nil then
        f.parts[f.i]()
        f.i = f.i + 1
        if f.i == 2 then f.frame = {table.unpack(f.k)} end   -- after the first part: background, lines, photo, chips and bars - the page shows this until all parts are there
        if f.i > #f.parts then f.parts = nil end
    end
    return f.parts == nil
end

local broken = nil                                     -- a build that broke off: the page shows the background until the file is loaded again
local function ready(colour)                            -- are all nodes for this colour ready?
    local f = G.pfDone
    return P == nil or broken ~= nil or (type(f) == "table" and f.parts == nil and f.cacheKey == tostring(colour))
end

local buildCount, haveRead, lastBuild = 0, false, nil      -- lastBuild: the previous build, whole or a part, and when
function M.renderKey(zone, state)                      -- as on the banks page: while the screen is not complete, a new key per call
    G.tick = (G.tick or 0) + 1
    haveRead = true
    local ok, reason = pcall(refresh, state or {})
    if not ok then T.note("preflight refresh: " .. tostring(reason)) end
    local colour = T.colourFrom(state)
    local key = "preflight|" .. colour .. "|" .. tostring(disp.name) .. "|" .. tostring(disp.pfPhoto)
    if ready(colour) and (lastBuild == nil or lastBuild.whole) then return key end
    buildCount = buildCount + 1
    return key .. "|build " .. buildCount
end

local function buildScreen(children, zone, state, ctx)       -- one part per call; the whole screen only when renderKey has computed the values
    local t = now()
    if lastBuild == nil or lastBuild.whole or t - lastBuild.time > 2 then   -- the page opens (not the next part)
        collectgarbage("collect")                      -- make room first: the suite and the theme share the radio's memory
    end
    local f = begin(T.colourFrom(state))
    local whole = buildPart(f) and haveRead                -- the background with the frame needs no values, the whole screen does
    local k = whole and f.k or f.frame
    lastBuild = {whole = whole, time = t}
    children[#children + 1] = {type = "box", x = 0, y = 0, w = zone.w, h = zone.h, borderPad = 0, children = {   -- the whole page is one button: a tap leads back to the cockpit; the box cuts off the radio's frame
        {type = "button", x = 0, y = 0, w = zone.w, h = zone.h, cornerRadius = 0, color = COLOUR.black, children = k,
         press = function() ctx.action("closeView") end}}}
    if whole then T.note("preflight built: " .. #k .. " nodes") end
end

function M.build(children, zone, state, ctx)
    if type(ctx) == "table" and type(ctx.keys) == "table" then ctx.keys.pageDown = "openView:nf_preflight" end   -- the suite closes a view with its key: so both PAGE keys lead back; the cockpit sets them again on its next build
    local ok, reason = false, broken or "page.lua missing"
    if P ~= nil and broken == nil then ok, reason = pcall(buildScreen, children, zone, state, ctx) end
    if not ok then
        broken = tostring(reason)
        T.note("preflight build: " .. broken)
        children[#children + 1] = {type = "label", x = 10, y = 10, w = R.W - 20, text = "@i18n(widgets.dashboard.build_failed)@", color = COLOUR.r}
    end
end

if P ~= nil then
    G.pfPrebuild = function(colour)                     -- for the cockpit: one part per quiet round before the page opens; true only when all parts were already there
        local f = begin(colour)
        if f.parts == nil then return true end
        buildPart(f)
        return false
    end
else
    G.pfPrebuild = false
end

return M
