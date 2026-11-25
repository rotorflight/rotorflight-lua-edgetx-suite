-- @NF cockpit as a theme of the Rotorflight suite for EdgeTX: one background (gfx/background.png), the lines as nodes in the
-- chosen colour (frame.lua, colours from colours.lua), the values in the radio font from the suite's state (parts.lua). The
-- screen is built once; text, colour and place of a value are functions. In full screen: a long press on the head switches
-- the colour on the ground, a tap on BANK opens the banks page, a tap on the battery the page before, a tap on the direction
-- ring sets the reference, the ARM field opens the quick menu; the page keys switch the pages when the pilot sets them to Theme.
local PATHS = rfsuite and rfsuite.paths or {}
local DIR, THEME_PATH = PATHS.core and (PATHS.core .. "/widgets/dashboard/themes/@nf/") or nil, "system/@nf"
if DIR == nil or loadScript(DIR .. "init.lua", "t") == nil then
    if PATHS.user then DIR, THEME_PATH = PATHS.user .. "/dashboard/nf/", "user/nf" end
end
local floor, max, min, sin, cos, rad = math.floor, math.max, math.min, math.sin, math.cos, math.rad

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
if T == nil then
    return {build = function() return {{type = "label", x = 10, y = 10, w = (tonumber(LCD_W) or 800) - 20, text = "parts.lua", color = lcd.RGB(255, 80, 80)}} end,
            renderKey = function() return "nf|missing" end}
end
local G, R, COLOUR, F = T.G, T.R, T.COLOUR, T.F
local disp = G.disp
local sx, sy, px, py = R.sx, R.sy, R.px, R.py
local note = T.note

local GAUGE = {cx = px(400), cy = py(257)}                    -- the middle of the gauge (reference 239.5 / 171.5)
local U = {   -- the value fields: centre (pixels), font, unit, place (centred, left from x, right up to x); converted from the Ethos layout
    timer = {x = sx(64), y = sy(102), f = F.xl},      -- the block FLIGHT TIMER, RATE, BANK stands centred in the left field (24 pixels of air above, 25 below on 800 x 480)
    rate = {x = sx(64), y = sy(161), f = F.l},        -- RATE in the middle between FLIGHT TIMER and BANK, the same air (28 pixels up and down)
    bank = {x = sx(64), y = sy(222), f = F.l},
    rpm = {x = px(400), y = sy(142), f = F.xl},
    bec = {x = sx(417), y = sy(102), f = F.xl, e = "V"},   -- BEC at the height of the flight timer; TX and ESC below in the same step, 16 pixels of air each down to the tank
    tx = {x = sx(417), y = sy(155), f = F.xl, e = "V"},
    amp = {x = sx(417), y = sy(208), f = F.xl, e = "A"},
    cpu = {x = sx(331), y = sy(71), f = F.s, e = "%"},
    mcu = {x = sx(187), y = sy(59), f = F.s, e = "\194\176C"},
    pack = {x = sx(164), y = sy(289), f = F.xxl, e = "V", place = "left"},      -- the voltage begins after the battery
    pct = {x = sx(346), y = sy(289), f = F.xxl, e = "%", place = "right"},     -- the level ends before the line
    temp = {x = sx(422), y = sy(290), f = F.xl, e = "\194\176C"},   -- at the height of ALT opposite, the same spacing
    alt = {x = sx(56), y = sy(290), f = F.xl, e = "m"},                        -- the altitude bottom left
    rssi = {x = sx(413), y = sy(22), f = F.std},
    vfr = {x = sx(413), y = sy(36), f = F.s},
    model = {x = px(400), y = sy(228), f = F.l},                                    -- centred below the arc
    labels = {{64, 77, "@i18n(widgets.dashboard.nf_flight_timer)@"}, {64, 137, "RATE"}, {64, 194, "BANK"}, {417, 77, "BEC"}, {417, 130, "TX"}, {417, 183, "ESC"},   -- the labels in the small step (three sizes: small, medium, large)
              {241, 176, "rpm"}, {143, 71, "MCU"}, {56, 268, "ALT"}},
    loadWord = {x = sx(289), y = sy(59), f = F.s},
    tempWord = {x = sx(421), y = sy(268), f = F.s},   -- the word above the field bottom right: ESC above the temperature, CELL above the voltage per cell
    batt = {x = sx(140), y = 294, bw = sx(12), bh = sy(5), n = 5},              -- the battery's bars, from bottom to top
    tank = {x = sx(370), y = sy(231), bw = sx(23), bh = sy(7), step = sx(24), n = 4},   -- the tank's bars below ESC, free
}
local ARM = {x = sx(14), y = sy(14), w = sx(94), h = sy(28)}
local BUTTONS = {head = {px(293), py(12), px(307), py(60)}, bank = {px(33), py(276), px(153), py(66)}, battery = {px(212), py(387), px(374), py(80)},
                 ring = {px(212), py(11), px(67), py(60)}}   -- the buttons in full screen: head (colour), BANK, battery (page before), direction ring (reference); their face is a cut-out of the background
local RING = {cx = px(245), cy = py(41), r = py(22), rim = math.max(1, py(2)), tip = py(16), foot = py(13), corner = 145}   -- r 22: the ring lies wholly inside its button (rim 5 at top and bottom)
local DX, DY = R.BUTTON_DX, R.BUTTON_DY
local SOURCES = {"voltage", "current", "fuel", "rpm", "bec_voltage", "esc_temp", "mcu_temp", "pid_profile", "rate_profile",
                 "1RSS", "VFR", "RQly", "RT%", "CPU%", "altitude", "consumption", "smartconsumption", "Yaw"}

local function modelName()
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
    return nil
end

local COLOUR_NAME = {}                                   -- per value field the name of its colour in disp (as parts.lua valueNodes)
for _, name in ipairs({"timer", "rpm", "bec", "tx", "amp", "cpu", "mcu", "pack", "pct", "temp", "alt", "rate", "bank"}) do COLOUR_NAME[name] = name .. "F" end

local function refresh(state)   -- reads the suite's state (parts.lua T.read) and puts into disp and place what is on the screen
    local s = T.read(state)
    if G.packFont == nil then   -- the large font for voltage and level: as large as both fit side by side into the middle field of the foot row
        local wide = T.textWidth("88.8", F.xxl) + T.textWidth("100", F.xxl) + T.textWidth("V", F.xxl) + T.textWidth("%", F.xxl) + 2 * T.GAP
        G.packFont = (wide <= (U.pct.x - U.pack.x)) and F.xxl or F.xl
    end
    U.pack.f, U.pct.f = G.packFont, G.packFont
    local link = s.link
    local isArmed = s.isArmed
    disp.arm = (not link) and "link" or ((isArmed == true) and "armed" or ((isArmed == false) and "safe" or "unknown"))
    disp.armColour = (isArmed == true and link) and COLOUR.green or ((isArmed == false and link) and COLOUR.red or COLOUR.grey)
    disp.armText = (not link) and "NO LINK" or ((isArmed == true) and "ARMED" or ((isArmed == false) and "DISARMED" or "ARM ?"))
    disp.armTextF = (not link) and COLOUR.r or COLOUR.w
    local function value(name, text, fk, unit, font)
        if text == nil then
            disp[COLOUR_NAME[name]] = COLOUR.d
            T.set(name, U[name], "--", nil, font)
        else
            disp[COLOUR_NAME[name]] = COLOUR[fk] or COLOUR.g
            T.set(name, U[name], text, unit, font)
        end
    end
    value("timer", s.timer and T.fmtT(s.timer) or nil, "g")
    local bf = (s.bank ~= nil and s.rate ~= nil and s.bank ~= s.rate) and "r" or "g"
    value("bank", s.bank and T.fmt(s.bank) or nil, bf)
    value("rate", s.rate and T.fmt(s.rate) or nil, bf)
    if s.bank == nil then T.set("bank", U.bank, "?", nil) end
    if s.rate == nil then T.set("rate", U.rate, "?", nil) end
    value("rpm", s.rpm and T.fmt(s.rpm) or nil, "g")
    value("bec", s.bec and T.fmt(s.bec, 1) or nil, (s.bec and s.bec >= 5.0) and "g" or "y", "V")
    local txWarn = G.txWarn or 7.0                     -- the radio's own warning voltage (getGeneralSettings), otherwise 7.0 V
    value("tx", s.tx and T.fmt(s.tx, 1) or nil, s.tx and ((s.tx >= txWarn + 0.4) and "g" or ((s.tx >= txWarn) and "y" or "r")) or "g", "V")
    value("amp", s.current and T.fmt(s.current, 1) or nil, "g", "A")
    local fraction, redFrom = T.batteryFraction(state, s.pack, s.cellF or s.cell)
    local ck = T.batteryColour(fraction, redFrom)
    value("pack", s.pack and T.fmt(s.pack, 1) or nil, ck, "V", G.packFont)
    local p = nil
    if s.fuel ~= nil then p = s.fuel                  -- the level as the suite computes it (the same as the tank's bars)
    elseif fraction then p = fraction * 100 end
    if p ~= nil then
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
    end
    value("pct", p and T.fmt(p) or nil, ck, "%", G.packFont)
    local tWarn, tCrit = T.levels(state, "escTemp", 90, 110)
    if s.temp == nil and s.cell ~= nil then            -- an ESC without temperature: the ESC field shows the voltage per cell in the battery's colour
        value("temp", T.fmt(s.cell, 2), ck, "V")
        disp.tempWord = "CELL"                          -- the same in every language, like ESC and BEC
    else
        value("temp", s.temp and T.fmt(s.temp) or nil, s.temp and T.heatColour(s.temp, tWarn, tCrit) or "g", "\194\176C")
        disp.tempWord = "ESC"
    end
    value("alt", s.alt and T.fmt(s.alt) or nil, "g", s.altFt and "ft" or "m")
    disp.bars, disp.barColour = 0, COLOUR[ck]
    if fraction then
        local a = fraction
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
        disp.bars = floor(a * U.batt.n + 0.5)
    end
    disp.tank = 0                                       -- the tank: consumption against the battery capacity; empty without a sensor
    if s.fuel then disp.tank = floor(s.fuel / (100 / U.tank.n)) end   -- one bar per full quarter
    local mWarn, mCrit = T.levels(state, "mcuTemp", 80, 95)
    value("mcu", s.mcutemp and T.fmt(s.mcutemp) or nil, s.mcutemp and T.heatColour(s.mcutemp, mWarn, mCrit) or "g", "\194\176C")
    value("cpu", s.cpu and T.fmt(s.cpu) or nil, s.cpu and ((s.cpu < 50) and "g" or ((s.cpu < 80) and "y" or "r")) or "g", "%")
    disp.loadWord = (G.loadWord == "RT") and "RT" or "CPU"
    disp.rssi = s.rssi and ("RSSI " .. T.fmt(s.rssi) .. "dB") or ""
    disp.vfr = s.vfr and ("VFR " .. T.fmt(s.vfr)) or ""
    disp.vfrColour = COLOUR[T.linkColour(state, s.vfr)]
    local a = T.rpmFraction(s.rpm)   -- the gauge's arrow: its three corners, computed again only when the fraction has changed
    if a == nil then disp.arrowShown = false
    else
        local deg = floor(a * 200 + 0.5)              -- in steps of half a percent
        if deg ~= disp.arrowDeg then
            disp.arrowDeg = deg
            disp.arrow = R.arrowPoints(R.LARGE, GAUGE.cx, GAUGE.cy, deg / 200)
        end
        disp.arrowShown = true
    end
    if s.angle == nil then disp.needleShown = false   -- the direction arrow in the ring (left of the head): the needle toward the tail against the reference, as a triangle in the button
    else
        local w = floor(s.angle + 0.5) % 360
        if w ~= disp.needleDeg then
            disp.needleDeg = w
            local ox, oy = BUTTONS.ring[1] + DX, BUTTONS.ring[2] + DY
            local function corner(r, deg)
                local aa = rad(w + deg)
                return {floor(RING.cx + r * sin(aa) + 0.5) - ox, floor(RING.cy - r * cos(aa) + 0.5) - oy}
            end
            disp.needle = {corner(RING.tip, 0), corner(RING.foot, RING.corner), corner(RING.foot, -RING.corner)}
        end
        disp.needleShown = true
    end
end

local colour = "blue"   -- the colour from the suite's theme settings (parts.lua T.colourFrom), the model or the radio; while the heli is there the theme remembers the owner (G.owner)
local function noteOwner(Lib, prefs)
    local session = rfsuite and rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    local modelPrefs = (id and type(session.modelPreferences) == "table") and session.modelPreferences or nil
    if modelPrefs == nil or Lib == nil or type(Lib.modelOverridesActive) ~= "function" then return end
    local dashboard = type(prefs) == "table" and type(prefs.dashboard) == "table" and prefs.dashboard or {}
    G.owner = {id = id, model = Lib.modelOverridesActive(dashboard, modelPrefs.dashboard) == true}
end

local function saveColour(fresh, state)   -- the new colour into the same store the settings page writes (the model's own values or the radio's default); until the suite reads again the cockpit shows G.colourNew
    local Lib = suiteModule("app/pages/settings/dashboard/lib.lua")
    local prefs = rfsuite and rfsuite.preferences
    if Lib == nil or type(Lib.setThemeConfig) ~= "function" or type(prefs) ~= "table" then return false end
    noteOwner(Lib, prefs)
    local session = rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    local modelPrefs = (id and type(session.modelPreferences) == "table") and session.modelPreferences or nil
    local owner = G.owner
    local c = state and state.themeConfig
    local before = type(c) == "table" and c.colour or nil
    local function apply()
        G.colourNew = {colour = fresh, before = before, id = id}   -- applies only to this heli (or without a heli) until the suite passes it again
        colour = fresh
        return true
    end
    if type(owner) == "table" and owner.model then                 -- the colour belongs to the model
        if modelPrefs == nil or owner.id ~= id then return false end   -- and the model is not there: write nothing
        if type(Lib.setEditScope) ~= "function" then return false end
        local MP = suiteModule("lib/model_preferences.lua")
        if MP == nil or type(MP.saveByMcuId) ~= "function" then return false end
        Lib.setEditScope("model")
        Lib.setThemeConfig(prefs, THEME_PATH, {colour = fresh}, modelPrefs)
        Lib.setEditScope(nil)
        return MP.saveByMcuId(id, modelPrefs) == true and apply()
    end
    if owner == nil then
        if state and state.hadInflightFlight == true and state.rfConnected ~= true then return false end   -- nothing noted since loading: after a flight without connection the default behind another cockpit would change - the press does nothing
        local dashboard = type(prefs.dashboard) == "table" and prefs.dashboard or {}
        local standard = dashboard["cfg_" .. string.gsub(THEME_PATH, "[^%w]", "_") .. "_colour"]
        if T.COLOUR_INDEX[standard] == nil then standard = "blue" end   -- an unknown word in the store counts as blue, as in the cockpit
        if standard ~= colour then return false end
    end
    local Prefs = suiteModule("lib/preferences.lua")
    if Prefs == nil or type(Prefs.save) ~= "function" then return false end
    Lib.setThemeConfig(prefs, THEME_PATH, {colour = fresh}, nil)
    return Prefs.save(prefs) == true and apply()
end

local lastState = nil   -- a long press on the head at the top: the next colour of the row, with a beep, only on the ground; armed or without a store it does nothing
local function tone(hz, ms) local t = _G.playTone if t then pcall(t, hz, ms, 0) end end
local function nextColour()
    if disp.arm == "armed" then return end
    local fresh = T.COLOUR_WORDS[(T.COLOUR_INDEX[colour] or 1) % #T.COLOUR_WORDS + 1]
    if saveColour(fresh, lastState) then tone(880, 120) end
end
local function setRef()                           -- a tap on the ring: the heli now points forward (only on the ground)
    if T.setRef() then tone(880, 120) end
end

local M = {}
function M.sources() return SOURCES end

local nameTick = 0
local PAUSE = 300                                      -- in hundredths of a second: in operation the suite calls the cockpit at shorter intervals
local keyed, buildCount, missing = false, 0, nil     -- the first build after power-on spreads over three calls (frame, middle, values; buildPiece)
function M.renderKey(zone, state)                      -- if more than one piece is missing the key carries a counter; the build of the finished screen builds the last one, a change of colour stays one build
    keyed = true
    local ok, reason = pcall(refresh, state or {})
    if not ok then note("refresh: " .. tostring(reason)) end
    lastState = state
    colour = T.colourFrom(state)
    G.colourNow = colour                                   -- for the banks page: it prepares its nodes in this colour already while loading
    local vb = G.bkPrebuild                            -- the banks page ahead: 30 rounds after start load the file once (it leaves G.bkPrebuild), then one part per round
    if vb == nil then
        G.bkCounter = (G.bkCounter or 0) + 1
        if G.bkCounter >= 30 then
            G.bkPrebuild = false
            local chunk = loadScript(DIR .. "banks.lua")
            if chunk then pcall(chunk) end
        end
    elseif vb ~= false and (getUsage == nil or getUsage() < 45) then   -- only after a quiet round: the prebuild must never fall on a full round of the suite
        local ok, complete = pcall(vb, colour)
        if ok and complete == true then                          -- the banks page is ready: then the preflight page, in one piece
            local pf = G.pfPrebuild
            if pf == nil then
                G.pfPrebuild = false
                local chunk = loadScript(DIR .. "preflight.lua")
                if chunk then pcall(chunk) end
            elseif pf ~= false then
                pcall(pf, colour)
            end
        end
    end
    local now = getTime and getTime() or 0
    if G.lastCall and now - G.lastCall > PAUSE then nameTick = 0 end   -- after a pause read the model name again at once
    G.lastCall = now
    nameTick = nameTick - 1
    if nameTick <= 0 then                             -- the name belongs in the key before building: otherwise the suite builds twice
        nameTick = 100
        disp.name = modelName()
        noteOwner(suiteModule("app/pages/settings/dashboard/lib.lua"), rfsuite and rfsuite.preferences)
        local okg, gs = pcall(getGeneralSettings)      -- the radio's warning voltage for the colour of its battery voltage
        local w = okg and type(gs) == "table" and tonumber(gs.battWarn) or nil
        if w and w > 0 then G.txWarn = w end
    end
    local key = "nf|" .. colour .. "|" .. tostring(disp.name) .. "|" .. tostring(G.packFont)
    local ck = G.ck                                    -- ck.ready: the screen is fully built, in this colour and battery font
    if not (ck and ck.ready == colour and ck.packFont == G.packFont) and missing(colour) > 1 then
        buildCount = buildCount + 1
        key = key .. "|build " .. buildCount
    end
    return key
end

local function button(n, k, kids, press, longpress)   -- a button in a box of its size (the box cuts off the frame of wheel and ENTER); kids begin with its face, moved back by DX, DY
    n[#n + 1] = {type = "box", x = k[1], y = k[2], w = k[3], h = k[4], borderPad = 0, children = {
        {type = "button", x = 0, y = 0, w = k[3], h = k[4], cornerRadius = 0, color = COLOUR.grey, children = kids,
         press = press or function() end, longpress = longpress}}}
end

local function face(k, fileName)                       -- the face of a button: a cut-out of the background
    return {type = "image", x = -DX, y = -DY, w = k[3], h = k[4], file = DIR .. R.GFX .. fileName}
end

local function buildFrame(f)                          -- background, lines, spikes and the notch in the colour; the battery in the battery button
    local L = T.lines(f)
    local n = {{type = "image", x = 0, y = 0, w = R.W, h = R.H, file = DIR .. R.GFX .. "background.png"}}
    R.cockpit(n, L)
    R.spikes(n, DIR, f)
    local notch, batteryIcon = {}, {}
    R.notch(notch, DIR, f)
    R.batteryIcon(batteryIcon, L, BUTTONS.battery[1] + DX, BUTTONS.battery[2] + DY)   -- its frame: the face of the battery button covers the frame of the lines below
    return {colour = f, n = n, notch = notch[1], batteryIcon = batteryIcon}
end

local function buildMid()                            -- gauge, tank, labels and words, logo: the same in every colour and in zone and full screen
    local n = {}
    R.gaugeArc(n, R.LARGE, GAUGE.cx, GAUGE.cy, DIR)   -- the gauge: arc and ticks, the arrow as a triangle
    R.arrow(n, function() return disp.arrow end, function() return disp.arrowShown == true end)
    for i = 1, U.tank.n do
        n[#n + 1] = {type = "rectangle", x = U.tank.x + (i - 1) * U.tank.step, y = U.tank.y, w = U.tank.bw, h = U.tank.bh, filled = true,
                     color = function() return disp.barColour end, visible = function() return disp.tank >= i end}
    end
    for _, l in ipairs(U.labels) do T.labelCentred(n, sx(l[1]), sy(l[2]), l[3], COLOUR.w, F.s) end   -- the labels in the radio font, the words from the suite's translations
    local tb = sx(52)                                 -- the word above the field bottom right changes with the value below it
    n[#n + 1] = {type = "label", x = U.tempWord.x - tb, y = U.tempWord.y - floor(T.height(F.s) / 2), w = 2 * tb, align = CENTER, font = F.s,
                 text = function() return disp.tempWord or "ESC" end, color = COLOUR.w}
    n[#n + 1] = {type = "label", x = U.loadWord.x - px(14), y = U.loadWord.y - floor(T.height(F.s) / 2), w = px(28), align = CENTER, font = F.s,
                 text = function() return disp.loadWord end, color = COLOUR.w}
    local hb = R.LARGE800 and 120 or 66              -- RSSI and VFR at the top right in the head band, as in the Ethos theme
    n[#n + 1] = {type = "label", x = U.rssi.x - hb, y = U.rssi.y - floor(T.height(F.std) / 2), w = 2 * hb, align = CENTER, font = F.std,
                 text = function() return disp.rssi end, color = COLOUR.w}
    n[#n + 1] = {type = "label", x = U.vfr.x - hb, y = U.vfr.y - floor(T.height(F.s) / 2), w = 2 * hb, align = CENTER, font = F.s,
                 text = function() return disp.vfr end, color = function() return disp.vfrColour end}
    local lh = sy(24)                                 -- the suite's logo at the top in the middle of the head band, 400 : 84
    local lw = floor(lh * 400 / 84 + 0.5)
    n[#n + 1] = {type = "image", x = sx(240) - floor(lw / 2), y = sy(11), w = lw, h = lh, file = DIR .. R.GFX .. "rotorflight.png"}
    return n
end

local function buildValues()                            -- the values: number and unit per field (parts.lua valueNodes)
    local n = {}
    for _, name in ipairs({"timer", "rpm", "bec", "tx", "amp", "cpu", "mcu", "pack", "pct", "temp", "alt", "rate", "bank"}) do
        T.valueNodes(n, name, U[name])
    end
    return n
end

local function armLabel(font, dx, dy)                   -- the word in the ARM field; in full screen as a child of its button (image and text take no press)
    return {type = "label", x = ARM.x - dx, y = ARM.y + floor((ARM.h - T.height(font)) / 2) - dy, w = ARM.w, align = CENTER,
            font = font, text = function() return disp.armText end, color = function() return disp.armTextF end}
end

local function armFontFit()                            -- the largest step in which the longest word fits into the ARM field
    local armFont = F.l
    for _, level in ipairs({F.l, F.std, F.s}) do
        armFont = level
        if T.textWidth("DISARMED", level) <= ARM.w - 2 * DX - 4 then break end
    end
    return armFont
end

local function buildZone(font)                         -- the zone picture has no buttons: the ARM field, the battery's bars and the ring lie free
    local n = {{type = "rectangle", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, filled = true, rounded = py(10),
                color = function() return disp.armColour end}}
    for i = 1, U.batt.n do
        n[#n + 1] = {type = "rectangle", x = U.batt.x, y = sy(U.batt.y - (i - 1) * 6), w = U.batt.bw, h = U.batt.bh, filled = true,
                     color = function() return disp.barColour end, visible = function() return disp.bars >= i end}
    end
    n[#n + 1] = {type = "circle", x = RING.cx, y = RING.cy, radius = RING.r, filled = true, color = COLOUR.ring}
    n[#n + 1] = {type = "circle", x = RING.cx, y = RING.cy, radius = RING.r - RING.rim, filled = true, color = COLOUR.deep}
    return {n = n, arm = armLabel(font, 0, 0)}
end

local function buildFull(font)                         -- the kids of the buttons in full screen (every build builds the buttons themselves)
    local ax, ay = BUTTONS.battery[1] + DX, BUTTONS.battery[2] + DY   -- the battery's bars lie in the battery button, hence as its children
    local batt = {}
    for i = 1, U.batt.n do
        batt[i] = {type = "rectangle", x = U.batt.x - ax, y = sy(U.batt.y - (i - 1) * 6) - ay, w = U.batt.bw,
                   h = U.batt.bh, filled = true, color = function() return disp.barColour end,
                   visible = function() return disp.bars >= i end}
    end
    local ox, oy = BUTTONS.ring[1] + DX, BUTTONS.ring[2] + DY   -- the ring with the needle as children of the button (circles would otherwise take the press)
    local ring = {face(BUTTONS.ring, "ring.png"),
                  {type = "circle", x = RING.cx - ox, y = RING.cy - oy, radius = RING.r, filled = true, color = COLOUR.ring},
                  {type = "circle", x = RING.cx - ox, y = RING.cy - oy, radius = RING.r - RING.rim, filled = true, color = COLOUR.deep},
                  {type = "triangle", x = 0, y = 0, w = 0, h = 0, color = COLOUR.needle,
                   pts = function() return disp.needle end, visible = function() return disp.needleShown == true end}}
    return {arm = {armLabel(font, ARM.x + DX, ARM.y + DY)}, head = {face(BUTTONS.head, "head.png")},
            bank = {face(BUTTONS.bank, "door_bank.png")}, battery = face(BUTTONS.battery, "door_battery.png"), batt = batt, ring = ring}
end

local function fixedKey() return tostring(G.packFont) end

missing = function(f)                                    -- how many pieces are still missing for this colour: frame, middle, values
    local ck, n = G.ck, 0
    if ck == nil or ck.frame == nil or ck.frame.colour ~= f then n = n + 1 end
    local fixed = ck and ck.fixed
    if fixed == nil or fixed.cacheKey ~= fixedKey() then n = n + 2 elseif fixed.values == nil then n = n + 1 end
    return n
end

local function buildPiece(f)                            -- builds the next missing piece; true when none is missing afterwards
    local ck = G.ck
    if ck == nil then
        ck = {}
        G.ck = ck                                      -- what not every build builds anew: frame per colour, middle and values per battery font (G survives the reload)
    end
    local s = fixedKey()
    ck.ready = nil
    if ck.frame == nil or ck.frame.colour ~= f then
        ck.frame = buildFrame(f)
    elseif ck.fixed == nil or ck.fixed.cacheKey ~= s then
        ck.fixed, ck.zone, ck.full = {cacheKey = s, mid = buildMid(), font = armFontFit()}, nil, nil
    elseif ck.fixed.values == nil then
        ck.fixed.values = buildValues()
    end
    return missing(f) == 0
end

local function assemble(ck, ctx)                       -- the whole screen from the pieces lying ready
    local r, fixed = ck.frame, ck.fixed
    local n = {}
    table.move(r.n, 1, #r.n, 1, n)
    if ctx ~= nil then                                 -- the full-screen buttons lie above the frame (a hollow field otherwise takes the press)
        if ck.full == nil then ck.full = buildFull(fixed.font) end
        local v = ck.full
        n[#n + 1] = {type = "box", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, borderPad = 0, children = {
            {type = "button", x = 0, y = 0, w = ARM.w, h = ARM.h, cornerRadius = py(10), children = v.arm,
             color = function() return disp.armColour end, press = function() ctx.action("openView:menu") end}}}
        button(n, BUTTONS.head, v.head, function() end, nextColour)
        button(n, BUTTONS.bank, v.bank, function() ctx.action("openView:nf_banks") end)
        local battery = {v.battery, r.batteryIcon[1], r.batteryIcon[2]}
        table.move(v.batt, 1, #v.batt, 4, battery)
        button(n, BUTTONS.battery, battery, function() ctx.action("openView:nf_preflight") end)
        button(n, BUTTONS.ring, v.ring, setRef)
        if type(ctx.keys) == "table" then   -- the page keys, as soon as the pilot has set them to Theme
            ctx.keys.pageDown = "openView:nf_banks"
            ctx.keys.pageUp = "openView:nf_preflight"
        end
    else
        if ck.zone == nil then ck.zone = buildZone(fixed.font) end
        table.move(ck.zone.n, 1, #ck.zone.n, #n + 1, n)
    end
    n[#n + 1] = r.notch
    if ctx == nil then n[#n + 1] = ck.zone.arm end
    table.move(fixed.mid, 1, #fixed.mid, #n + 1, n)
    table.move(fixed.values, 1, #fixed.values, #n + 1, n)
    local name = disp.name   -- the model name centred below the arc, at most 16 characters
    if ck.name == nil or ck.name.text ~= name then
        local m = {}
        if name ~= nil then T.labelCentred(m, U.model.x, U.model.y, #name > 16 and string.sub(name, 1, 16) or name, COLOUR.w, F.l) end
        ck.name = {text = name, node = m[1]}
    end
    if ck.name.node then n[#n + 1] = ck.name.node end
    return n
end

local function buildScreen(zone, state, ctx)
    colour = T.colourFrom(state)
    G.colourNow = colour                                   -- for the banks page: it prepares its nodes in this colour already while loading
    if not keyed then refresh(state or {}) end       -- otherwise renderKey has just computed the state
    disp.name = modelName()
    if keyed then
        buildPiece(colour)                                   -- at most one piece per call: EdgeTX gives a widget a fixed number of instructions per call
    else
        while not buildPiece(colour) do end                  -- without renderKey before (a checker calls build alone): everything in one build
    end
    local ck = G.ck
    if missing(colour) > 0 then                               -- until all pieces are there: the background with the frame
        local n = {}
        table.move(ck.frame.n, 1, #ck.frame.n, 1, n)
        n[#n + 1] = ck.frame.notch
        return n
    end
    ck.ready, ck.packFont = colour, G.packFont
    return assemble(ck, ctx)
end

function M.build(zone, state, ctx)
    local ok, n = pcall(buildScreen, zone, state, ctx)
    if ok then
        note("build " .. tostring(zone and zone.w) .. "x" .. tostring(zone and zone.h) .. " ctx " .. tostring(ctx ~= nil) .. ": "
               .. #n .. " nodes, font " .. tostring(T.height(F.s)) .. "/" .. tostring(T.height(F.std)) .. "/" .. tostring(T.height(F.l))
               .. "/" .. tostring(T.height(F.xl)) .. "/" .. tostring(T.height(F.xxl)) .. " high")
        return n
    end
    note("build: " .. tostring(n))
    return {{type = "label", x = 10, y = 10, w = R.W - 20, text = tostring(n), color = COLOUR.r}}
end

return M
