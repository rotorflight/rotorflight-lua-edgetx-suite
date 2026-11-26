-- PARTS of the theme for EdgeTX: what the cockpit (cockpit.lua) and the two pages (preflight.lua, banks.lua) share - the
-- folder, the radio's fonts and their sizes, the colours, the line colours, the reading of the suite's state
-- (refresh) with everything that counts beyond the moment (peak monitor, the current and the last flight, the clock per
-- bank, the reference of the direction arrow), and the nodes for labels and values. A value is a label whose text,
-- colour and place are functions that only read what refresh() computed. What must survive a reload lives in state.lua.
local PATHS = rfsuite and rfsuite.paths or {}
local DIR = PATHS.core and (PATHS.core .. "/widgets/dashboard/themes/@nf/") or nil
if DIR == nil or loadScript(DIR .. "init.lua", "t") == nil then
    if PATHS.user then DIR = PATHS.user .. "/dashboard/nf/" end
end
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local RGB = lcd.RGB

local T = {DIR = DIR}
T.COLOUR = {w = RGB(245, 248, 252), d = RGB(120, 132, 145), g = RGB(90, 255, 70), y = RGB(240, 210, 30), o = RGB(255, 130, 20),
           r = RGB(255, 80, 80), black = RGB(0, 0, 0), grey = RGB(52, 56, 64), red = RGB(225, 40, 40), green = RGB(40, 180, 55),
           ring = RGB(0, 152, 224), deep = RGB(8, 8, 10), needle = RGB(255, 255, 255)}
local F_S = SMLSIZE or 0   -- the five steps of the radio font (as the Ethos sizes FONT_S, FONT_STD, FONT_L, FONT_XL, FONT_XXL); a missing one takes the next
T.F = {s = F_S, xs = rawget(_G, "TINSIZE") or F_S, std = 0, l = MIDSIZE or 0, xl = DBLSIZE or MIDSIZE or 0, xxl = XXLSIZE or DBLSIZE or 0}
T.GAP = 4                                  -- the unit close to its number
T.REF_WITHOUT_FLIGHT = 2000

local function suiteModule(modPath)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, modPath)
        if ok and type(m) == "table" then return m end
    end
    return nil
end

local noted = {}   -- one line into the suite's log (lib/log.lua, level debug), each only once per loaded file; with the Lua memory after it
function T.note(text)
    text = tostring(text)
    if noted[text] then return end
    noted[text] = true
    local Log = suiteModule("lib/log.lua")
    if Log and type(Log.emit) == "function" then pcall(Log.emit, "nf", text .. " (Lua " .. floor(collectgarbage("count")) .. " KB)", "debug") end
end

local function loadFile(fileName)
    local chunk = loadScript(DIR .. fileName)
    if not chunk then T.note(fileName .. " missing") return nil end
    local ok, tab = pcall(chunk)
    if ok and type(tab) == "table" then return tab end
    T.note(fileName .. ": " .. tostring(tab))
    return nil
end

function T.module(fileName)   -- a module of the theme: through the suite's loader (kept, released with the theme), otherwise loaded directly
    return suiteModule(DIR .. fileName) or loadFile(fileName)
end

function T.mspSlot()   -- the theme's place at the suite's MSP service and its count of awaited replies, in a global: a fresh load finds it again
    local m = _G.NF_MSP
    if type(m) ~= "table" then
        m = {pending = 0}
        _G.NF_MSP = m
    end
    return m
end

function T.mspRelease()   -- called from the theme's own passes, never from a reply: once no reply is awaited the place goes back, the global with it
    local m = _G.NF_MSP
    if type(m) == "table" and (m.pending or 0) <= 0 then
        local k = m.client
        _G.NF_MSP = nil
        if k ~= nil and type(k.release) == "function" then pcall(k.release, k) end
    end
end

local G = suiteModule(DIR .. "state.lua")   -- the suite reloads the theme's files on every change of flight phase; what must stay lives in state.lua, which the suite's loader keeps (runtime.lua releaseUnusedThemes)
if G == nil then
    G = _G.NF_THEME
    if type(G) ~= "table" then
        G = {}
        _G.NF_THEME = G
    end
end
T.G = G
if G.disp == nil then
    G.disp, G.place, G.seen, G.rpmHigh, G.peak, G.height, G.lines = {}, {}, {}, 0, {}, {}, {}
    G.flight = {running = false, stop = false, mahStart = nil, currentMax = nil, bank = {0, 0, 0}, clock = nil}
    G.lastFlight = {}
    G.direction = {ref = nil, captured = false}
end
if G.sinceStart == nil then G.sinceStart = {} end   -- altitude and climb/sink since power-on, armed or not: the preflight page shows them as long as no flight is recorded
if G.widths == nil then G.widths = {} end   -- measured widths per font and text (T.textWidth)
local disp, place = G.disp, G.place

T.R = G.R or T.module("frame.lua")
G.R = T.R
if T.R and T.R.px then T.GAP = T.R.px(4) end   -- the gap in pixels of this screen (800 x 480: 4)
T.COLOURS = G.COLOURS or T.module("colours.lua") or {}
G.COLOURS = T.COLOURS

T.COLOUR_WORDS = {"blue", "turquoise", "green", "yellow", "gold", "orange", "red", "magenta", "violet", "silver"}   -- the stored colour values are English, like every value in the suite's settings (configure.lua has the same order)
T.COLOUR_INDEX = {}
for i = 1, #T.COLOUR_WORDS do T.COLOUR_INDEX[T.COLOUR_WORDS[i]] = i end

function T.colourFrom(state)   -- the colour lives in the suite's theme settings (state.themeConfig); after a long press the new one applies at once (G.colourNew) until the suite has passed its settings again
    local c = state and state.themeConfig
    local word = type(c) == "table" and c.colour or nil
    local fresh = G.colourNew
    if type(fresh) == "table" then
        local session = rfsuite and rfsuite.session
        local id = type(session) == "table" and session.mcu_id or nil
        if word ~= fresh.before or id ~= fresh.id then G.colourNew = nil else word = fresh.colour end
    end
    if T.COLOUR_INDEX[word] then return word end
    return "blue"
end

function T.lines(colour)                      -- mid tone, core and glow of the lines as radio colours, once per colour
    local l = G.lines[colour]
    if l == nil then
        l = T.R.colours(T.COLOURS[colour] or T.COLOURS.blue or {mid = {2, 117, 194}, core = {141, 255, 255}, glow = {1, 35, 58}})
        G.lines[colour] = l
    end
    return l
end

local EST_H = {}   -- the size of the radio font: the height per step measured once (lcd.sizeText), widths per text; without lcd.sizeText estimated
EST_H[T.F.xxl], EST_H[T.F.xl], EST_H[T.F.l], EST_H[T.F.std], EST_H[T.F.s] = 64, 32, 24, 16, 13
local function measure(text, font)
    if lcd and type(lcd.sizeText) == "function" then
        local ok, w, h = pcall(lcd.sizeText, text, font)
        if ok and type(w) == "number" and type(h) == "number" and h > 0 then return w, h end
    end
    local h = EST_H[font] or 16
    return floor(#tostring(text) * h * 0.55 + 0.5), h
end
function T.height(font)
    local h = G.height[font]
    if h == nil then
        local _, hh = measure("0", font)
        h = hh
        G.height[font] = h
    end
    return h
end
local WIDTHS_MAX = 64   -- per font this many measured texts in G.widths; beyond that the font's list starts again
function T.textWidth(text, font)
    if text == nil then return (measure(text, font)) end
    local f = font or -1
    local perFont = G.widths[f]
    local w = perFont and perFont.w[text]
    if w == nil then
        w = measure(text, font)
        if perFont == nil or perFont.n >= WIDTHS_MAX then
            perFont = {w = {}, n = 0}
            G.widths[f] = perFont
        end
        perFont.w[text], perFont.n = w, perFont.n + 1
    end
    return w
end

function T.label(n, x, y, text, colour, font, w, align)   -- nodes: a label left at x (w 0 = as wide as the text) or centred on cx; y is the middle of the row
    n[#n + 1] = {type = "label", x = x, y = y - floor(T.height(font) / 2), w = w or 0, text = text, color = colour, font = font, align = align or LEFT}
end
function T.labelCentred(n, cx, cy, text, colour, font)
    T.label(n, cx - floor(T.textWidth(text, font) / 2), cy, text, colour, font)
end

local FORMAT = {[0] = "%.0f", "%.1f", "%.2f"}
function T.fmt(v, d)
    if v == nil then return nil end
    return string.format(FORMAT[d or 0], v)
end
function T.fmtT(sec)
    sec = max(0, floor(sec + 0.5))
    return string.format("%02d:%02d", floor(sec / 60), sec % 60)
end

local FRACTION_ORANGE, FRACTION_YELLOW, FRACTION_RED_CELL = (3.65 - 3.5) / 0.7, (3.75 - 3.5) / 0.7, (3.45 - 3.5) / 0.7   -- limits from the suite (themeConfig.v_min/v_max, state.alerts: warn yellow, critical red); without them defaults and the cell 3.5 to 4.2 V, red below 3.45 V
function T.batteryFraction(state, pack, cell)
    local c = state and state.themeConfig
    local vmin, vmax = type(c) == "table" and tonumber(c.v_min) or nil, type(c) == "table" and tonumber(c.v_max) or nil
    if pack and cell and vmin and vmax and vmax > vmin then return (pack - vmin) / (vmax - vmin), 0 end
    if cell then return (cell - 3.5) / 0.7, FRACTION_RED_CELL end
    return nil, 0
end
function T.batteryColour(fraction, red)
    if fraction == nil then return "w" end
    if fraction < red then return "r" end
    if fraction < FRACTION_ORANGE then return "o" end
    if fraction < FRACTION_YELLOW then return "y" end
    return "g"
end
function T.levels(state, name, warn, crit)
    local a = state and state.alerts
    local s = type(a) == "table" and a[name] or nil
    if type(s) == "table" then
        if tonumber(s.warn) then warn = tonumber(s.warn) end
        if tonumber(s.critical) then crit = tonumber(s.critical) end
    end
    return warn, crit
end
function T.heatColour(v, warn, crit)
    if v == nil then return "d" end
    if v >= crit then return "r" end
    if v >= warn then return "y" end
    return "g"
end
function T.linkColour(state, vfr)             -- the link colour after the levels of the link callout: up to warn yellow, up to critical red
    local lWarn, lCrit = T.levels(state, "lq", 70, 50)
    if vfr == nil then return "w" end
    if vfr > lWarn then return "w" end
    if vfr > lCrit then return "y" end
    return "r"
end

local function nonZero(key, v)
    if v == nil then return nil end
    if v ~= 0 then G.seen[key] = true end
    if v == 0 and not G.seen[key] then return nil end
    return v
end

local function time()                         -- seconds since the radio started
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

function T.noteAltitude(t, alt, now)   -- the highest altitude and the strongest climb and sink, computed from the altitude over at least half a second (t = G.flight or G.sinceStart)
    if t.altMax == nil or alt > t.altMax then t.altMax = alt end
    if t.altTime == nil then t.altPrev, t.altTime = alt, now
    elseif now - t.altTime >= 0.5 then
        local rate = (alt - t.altPrev) / (now - t.altTime)
        if t.climbMax == nil or rate > t.climbMax then t.climbMax = rate end
        if t.sinkMax == nil or rate < t.sinkMax then t.sinkMax = rate end
        t.altPrev, t.altTime = alt, now
    end
end

local MODE_SOURCES = {"Mode", "5121"}   -- the Rotorflight flight mode sensor: CRSF "Mode", S.Port 0x5121; the bits as in the firmware (runtime_config.h)
function T.fcMode()   -- the sensor is looked up once (getFieldInfo), without it again every 5 s; getValue of a missing source would read 0 = ACRO
    if G.modeId == nil or (G.modeId == false and time() >= (G.modeRetry or 0)) then
        G.modeId = false
        if type(getFieldInfo) == "function" then
            for _, name in ipairs(MODE_SOURCES) do
                local ok, fi = pcall(getFieldInfo, name)
                if ok and type(fi) == "table" and fi.id ~= nil then G.modeId = fi.id break end
            end
        end
        if G.modeId == false then G.modeRetry = time() + 5 end
    end
    if not G.modeId then return nil end
    local ok, v = pcall(getValue, G.modeId)
    return ok and tonumber(v) or nil
end

function T.modeWord(v)   -- the flight mode from the bits (ANGLE 2, HORIZON 4, RESCUE 32) as in the Ethos theme: RESCUE comes with ANGLE and wins, HORIZON before ANGLE, otherwise Acro
    if v == nil then return nil end
    v = floor(v)
    if floor(v / 32) % 2 == 1 then return "@i18n(widgets.dashboard.nf_rescue)@" end
    if floor(v / 4) % 2 == 1 then return "@i18n(widgets.dashboard.nf_horizon)@" end
    if floor(v / 2) % 2 == 1 then return "@i18n(widgets.dashboard.nf_angle)@" end
    return "@i18n(widgets.dashboard.nf_acro)@"
end

local function directionTick(deg, isArmed)   -- the direction arrow: the reference is taken when arming and holds for the flight; on the ground it follows the heli, a tap sets it
    local r = G.direction
    if deg == nil then
        if not r.captured then r.ref = nil end
        return
    end
    if isArmed then
        if not r.captured then r.ref = deg end
        r.captured = true
    else
        r.captured = false
        if r.ref == nil then r.ref = deg end
    end
end
function T.setRef()
    if G.s and G.s.deg ~= nil and G.s.isArmed ~= true then
        G.direction.ref = G.s.deg
        return true
    end
    return false
end

local function fcIdentity()   -- what was recorded for one FC goes when another one connects (session.mcu_id); a reconnect of the same FC keeps it
    local session = rfsuite and rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    if id == nil or id == G.mcuId then return end
    if G.mcuId ~= nil then
        G.lastFlight, G.sinceStart, G.rpmHigh, G.cellF, G.bkValues = {}, {}, 0, nil, nil
        for k in pairs(G.seen) do G.seen[k] = nil end
        for k in pairs(G.peak) do G.peak[k] = nil end
        G.flight = {running = false, stop = false, mahStart = nil, currentMax = nil, bank = {0, 0, 0}, clock = nil}
        G.direction = {ref = nil, captured = false}
        local L = G.bkRead   -- the banks page keeps this table: emptied in place, it reads the new FC at once
        if type(L) == "table" then L.values, L.fresh, L.gen, L.running, L.rev = {}, true, (L.gen or 0) + 1, false, (L.rev or 0) + 1 end
    end
    G.mcuId = id
end

function T.read(state)   -- reads the suite's state: s is the moment (G.s), and peak monitor, flight and clocks run along
    fcIdentity()
    local d = state.derived or {}
    local function g(k) return tonumber(d[k]) end
    local s = {link = state.rfConnected == true}
    if s.link then
        s.pack = nonZero("pack", g("voltage") or tonumber(state.voltage))
        s.cells = tonumber(state.batteryCellCount)
        if s.pack ~= nil and s.cells ~= nil and s.cells >= 1 then s.cell = s.pack / s.cells end
        if s.cell ~= nil then
            local f = G.cellF
            if f == nil or abs(s.cell - f) > 0.3 then f = s.cell else f = f * 0.9 + s.cell * 0.1 end
            G.cellF = f
            s.cellF = f
        end
        s.rssi, s.vfr = g("1RSS"), g("VFR") or g("RQly")
        s.rpm = g("rpm") or tonumber(state.rpm)
        if s.rpm and s.rpm > G.rpmHigh then G.rpmHigh = s.rpm end
        s.temp = nonZero("temp", g("esc_temp"))
        s.mcutemp = g("mcu_temp")
        if s.mcutemp ~= nil and (s.mcutemp < 10 or s.mcutemp > 130) then s.mcutemp = nil end
        if state.armedSeen == true then s.isArmed = (state.armed == true) end   -- armed starts false and is false again on every reconnect: only armedSeen says the arm sensor has answered (runtime.lua)
        s.bec = nonZero("bec", g("bec_voltage"))
        s.bank, s.rate = g("pid_profile") or tonumber(state.profile), g("rate_profile")
        s.current = nonZero("current", g("current"))
        s.fuel = g("fuel")
        if s.fuel ~= nil and (s.fuel < 0 or s.fuel > 100) then s.fuel = nil end
        s.consumed = g("consumption") or g("smartconsumption")
        local alt = g("altitude")
        local loc = rfsuite and rfsuite.preferences and rfsuite.preferences.localizations   -- the altitude in the suite's unit: rfsuite.preferences.localizations.altitude_unit 1 = feet
        s.altFt = (type(loc) == "table" and tonumber(loc.altitude_unit) == 1) or false
        if alt ~= nil and s.altFt then alt = alt * 3.28084 end
        s.alt = nonZero("alt", alt)
        if s.alt ~= nil then T.noteAltitude(G.sinceStart, s.alt, time()) end
        local cpu = g("RT%")
        if cpu ~= nil then G.loadWord = "RT" else
            cpu = g("CPU%")
            if cpu ~= nil then G.loadWord = "CPU" end
        end
        if cpu ~= nil and (cpu < 0 or cpu > 100) then cpu = nil end
        s.cpu = cpu
        s.timer = tonumber(state.flightSeconds)
        s.fcMode = T.fcMode()
        local deg = g("Yaw")
        if deg ~= nil then s.deg = deg % 360 end
    end
    local ok, tv = pcall(getValue, "tx-voltage")
    if ok and type(tv) == "number" and tv > 0 then s.tx = tv end
    if s.isArmed == true and s.rpm ~= nil and s.rpm > 0 and s.bank ~= nil then   -- the peak monitor: per bank min and max of the headspeed while armed
        local b = floor(s.bank)
        local sl = G.peak[b]
        if sl == nil then G.peak[b] = {min = s.rpm, max = s.rpm}
        else
            if s.rpm < sl.min then sl.min = s.rpm end
            if s.rpm > sl.max then sl.max = s.rpm end
        end
    end
    local flight = G.flight   -- the flight: peak current, consumption and the clock per bank run along until the heli is disarmed
    if s.isArmed == true then
        if not flight.running then
            flight.running, flight.mahStart, flight.currentMax, flight.bank, flight.clock = true, s.consumed, nil, {0, 0, 0}, nil
            flight.altMax, flight.climbMax, flight.sinkMax, flight.altPrev, flight.altTime = nil, nil, nil, nil, nil
            for k in pairs(G.peak) do G.peak[k] = nil end
        end
        if s.current ~= nil and (flight.currentMax == nil or s.current > flight.currentMax) then flight.currentMax = s.current end
        local now, b = time(), s.bank and floor(s.bank) or nil
        if flight.clock ~= nil and s.rpm ~= nil and s.rpm > 0 and b ~= nil and flight.bank[b] ~= nil then
            flight.bank[b] = flight.bank[b] + max(0, now - flight.clock)
        end
        flight.clock = now
        if s.alt ~= nil then T.noteAltitude(flight, s.alt, now) end   -- the highest altitude and the strongest climb and sink of the flight
    elseif flight.running and s.isArmed == false then   -- the flight ends on a confirmed disarm
        flight.running, flight.stop, flight.clock = false, true, nil
        G.lastFlight = {peakCurrent = flight.currentMax, bank = s.bank and floor(s.bank) or nil,
                         mah = (s.consumed ~= nil and flight.mahStart ~= nil) and (s.consumed - flight.mahStart) or nil,
                         alt = flight.altMax, climb = flight.climbMax, sink = flight.sinkMax, time = flight.bank[1] + flight.bank[2] + flight.bank[3]}
    elseif flight.running then
        flight.clock = nil                             -- link lost, arm state unknown: the flight stays open and the gap counts for no bank
    end
    directionTick(s.deg, s.isArmed == true)
    local r = G.direction
    s.angle = (r.ref ~= nil and s.deg ~= nil) and (s.deg - r.ref) % 360 or nil
    G.s = s
    return s
end

function T.rpmFull() return max(T.REF_WITHOUT_FLIGHT, G.rpmHigh) * 1.25 end   -- the end of the arc: the highest headspeed flown sits at 0.8
function T.rpmFraction(v)
    if v == nil then return nil end
    local full = T.rpmFull()
    if v < 0 then v = 0 elseif v > full then v = full end
    return v / full
end

function T.set(name, field, text, unit, font)   -- where number and unit of a value field stand: centred on x, from x (place left) or up to x (place right); computed only when text or font change; field = {x, y, f, e, place}
    local L = place[name]
    if L == nil then
        L = {}
        place[name] = L
    end
    font = font or field.f
    if L.text == text and L.font == font and L.unit == unit then return end
    L.text, L.font, L.unit = text, font, unit
    local zb = T.textWidth(text, font)
    local eb = unit and T.textWidth(unit, font) or 0
    local gap = unit and T.GAP or 0
    local left
    if field.place == "left" then left = field.x
    elseif field.place == "right" then left = field.x - (zb + gap + eb)
    else left = field.x - floor((zb + gap + eb) / 2) end
    L.x, L.y = left, field.y - floor(T.height(font) / 2)
    L.ux, L.hasUnit = left + zb + gap, unit ~= nil
end

function T.valueNodes(n, name, field, dx, dy)   -- a value field as nodes: the number and, if there is one, the unit in white next to it; dx, dy when the field lies in a button
    dx, dy = dx or 0, dy or 0
    if place[name] == nil then T.set(name, field, "--", nil) end
    local L, colour = place[name], name .. "F"
    n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = field.f,
                 text = function() return L.text or "" end, color = function() return disp[colour] or T.COLOUR.d end,
                 pos = function() return (L.x or 0) - dx, (L.y or 0) - dy end}
    if field.e then
        n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = field.f, color = T.COLOUR.w,
                     text = function() return L.unit or "" end, visible = function() return L.hasUnit == true end,
                     pos = function() return (L.ux or 0) - dx, (L.y or 0) - dy end}
    end
end

return T
