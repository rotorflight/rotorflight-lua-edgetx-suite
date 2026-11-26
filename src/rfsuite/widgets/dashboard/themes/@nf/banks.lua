-- BANKS: the page right of the cockpit (init.lua views; PAGE right or a tap on BANK), on the cockpit's background, the
-- lines run in from the left. At the top the bank's drive (governor, target headspeed, spool-up, gain), below it four chips with
-- the rotation rate per axis and three with the gains per axis. On the right a standing headspeed bar: the measured headspeed against the
-- bank's target, green up to the target, yellow just above, red too high, with the mark of this bank's highest headspeed. The
-- page reads the values through the suite's MSP service; a change of bank or rate reads again. A tap or RTN leads back.
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

local LEFT_X, RIGHT_X = 10, 376                          -- the alignment of the chips: both rows start and end alike
local RATE_CHIP = {y = 66, h = 58, n = 4, gap = 6}
local GAIN_CHIP = {y = 136, h = 104, n = 3, gap = 6}
local BARS = {x = 440, w = 24, top = 62, bottom = 300, rim = 4}   -- the bar's frame; the column stays rim inside
local ZONES_X, ZONES_W = 467, 3                        -- the strip of the zones right of the bar
local SCALE, YELLOW_FROM = 1.25, 1.08                      -- the bar reaches up to 125 % of the target headspeed; yellow from the target, red from 108 %
local ACTUAL_X, ACTUAL_W = 386, 94                           -- the measured headspeed above the bar
local BANK_RX, BANK_Y, BANK_STEP = 434, 150, 30     -- BANK 1 2 3 right-aligned next to the bar
local FOOT_Y = 277
local RATE_TYPE = {[0] = "@i18n(widgets.dashboard.nf_rates_none)@", "@i18n(app.pages.flight_tuning_rates.betaflight):upper()@", "@i18n(app.pages.flight_tuning_rates.raceflight):upper()@", "@i18n(app.pages.flight_tuning_rates.kiss):upper()@", "@i18n(app.pages.flight_tuning_rates.actual):upper()@", "@i18n(app.pages.flight_tuning_rates.quick):upper()@", "@i18n(app.pages.flight_tuning_rates.rotorflight):upper()@"}   -- the names of the rates page, in capitals
local GOV_MODES = {[0] = "@i18n(app.pages.setup_governor.mode_off)@", "@i18n(app.pages.setup_governor.mode_limit)@", "@i18n(app.pages.setup_governor.mode_direct)@", "@i18n(app.pages.setup_governor.mode_electric)@", "@i18n(app.pages.setup_governor.mode_nitro)@"}   -- the firmware's gov_mode with the Governor page's names; at 3 and 4 the FC governs the headspeed
local DEG_S, DEG = "\194\176/s", "\194\176"
local RATE_RULE = {   -- rcRates per rates type: {times, divisor, decimals} for axes 1-3 and collective, shown raw * times / divisor
    [0] = {{1, 1, 0}, {1, 1, 0}}, {{1, 100, 2}, {1, 100, 2}}, {{10, 1, 0}, {1, 4, 1}, DEG_S}, {{1, 100, 2}, {1, 100, 2}},   -- NONE, BETAFLIGHT, RACEFLIGHT, KISS
    {{10, 1, 0}, {1, 4, 1}}, {{1, 100, 2}, {1, 100, 2}}, {{5, 1, 0}, {5, 40, 2}, DEG_S}}   -- ACTUAL, QUICK, ROTORFLIGHT; there the collective is an angle
local TENS, PATTERN = {[0] = 1, 10, 100}, {"%.1f", "%.2f"}
local RATE_AXES = {"@i18n(widgets.dashboard.nf_roll)@", "@i18n(widgets.dashboard.nf_pitch)@", "@i18n(widgets.dashboard.nf_tail)@", "@i18n(widgets.dashboard.nf_collective)@"}
local CHAIN = {{"pid_tuning", "pid", "PID"}, {"rc_tuning", "rc", "@i18n(widgets.dashboard.nf_rates)@"}, {"governor_config", "gov", "@i18n(widgets.dashboard.nf_governor)@"}, {"governor_profile", "govProfile", "@i18n(widgets.dashboard.nf_governor)@"}}
local DEADLINE, PAUSE = 14, 3                             -- a request without a reply is lost after 14 s; after an error the tick reads again after 3 s
local GREEN, YELLOW, RED = R.rgb(R.GREEN), R.rgb(R.YELLOW), R.rgb(R.RED)

local M = {}
function M.sources() return {"rpm", "pid_profile", "rate_profile"} end

local function now()                                 -- seconds since the radio started
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

if G.bkRead == nil then G.bkRead = {gen = 0, running = false, values = {}} end   -- the read chain survives the page's reload per flight phase
local L = G.bkRead
L.rev = L.rev or 0                                 -- counts every change to L.values: only then refresh() computes the values from the FC again

local function chain(g, i)                             -- reads the four records one after another; an error stands in the foot and the chain goes on, cleared ends it
    local item = CHAIN[i]
    if item == nil then
        L.running = false
        if L.chainFault then L.retryAt = now() + PAUSE else L.values.fault, L.retryAt = nil, nil end
        L.rev = L.rev + 1
        return
    end
    L.asked, L.item = now(), i
    if not P.read(item[1], function(w, reason)
        if g ~= L.gen then return end
        if reason == "cleared" then   -- the suite emptied its queue (armed, connection lost): the chain ends, the next tick on the ground reads again
            L.running, L.retryAt = false, now()
            L.rev = L.rev + 1
            return
        end
        if w ~= nil then L.values[item[2]] = w
        else
            L.chainFault = true
            L.values.fault = item[3]
        end
        L.rev = L.rev + 1
        chain(g, i + 1)
    end) then
        L.values.fault, L.running, L.retryAt = "MSP", false, now() + PAUSE
        L.rev = L.rev + 1
    end
end

local function kick(s, keep)                  -- keep: the same bank and rate once more, what is already read stays
    if L.running then return end
    L.running, L.gen, L.chainFault, L.retryAt = true, L.gen + 1, false, nil
    if not keep then
        L.values = {}
        L.readFor = {bank = s.bank and floor(s.bank) or nil, rate = s.rate and floor(s.rate) or nil}
        L.rev = L.rev + 1
    end
    chain(L.gen, 1)
end

local function tick(s)                                 -- every call: a change of bank or rate reads again; a lost request and an error are read again
    if P == nil then return end
    if s.isArmed == true then return end               -- armed: the suite keeps configuration traffic off the link, so the page asks nothing
    if L.fresh then L.fresh = false kick(s) return end
    if L.readFor == nil then return end
    local t = now()
    local bank, rate = s.bank and floor(s.bank) or nil, s.rate and floor(s.rate) or nil
    local changed = bank ~= L.readFor.bank or rate ~= L.readFor.rate
    if L.running then
        if not changed and t - (L.asked or t) < DEADLINE then return end
        L.gen, L.running = L.gen + 1, false            -- a lost request, or a chain for the bank or rate before: its replies no longer count
        if not changed then
            L.values.fault, L.retryAt = CHAIN[L.item or 1][3], t + PAUSE
            L.rev = L.rev + 1
        end
    end
    if changed then kick(s)
    elseif L.retryAt ~= nil and t >= L.retryAt then kick(s, true) end
end

local function num(v)
    if v == nil then return "--", P.MUTED end
    return tostring(floor(v + 0.5)), COLOUR.g
end

local function chipPlace(c, i)                          -- x and width of the i-th chip of a row: all in the same alignment LEFT_X..RIGHT_X
    local w = floor((RIGHT_X - LEFT_X - (c.n - 1) * c.gap) / c.n)
    return LEFT_X + (i - 1) * (w + c.gap), w
end

local function rates(r)                                -- the number per axis after the rule of the rates type, with a point like the other numbers
    local rule = r.rates_type and RATE_RULE[floor(r.rates_type)]
    for i = 1, 4 do
        local raw, m = r["rcRates_" .. i], rule and rule[i < 4 and 1 or 2]
        local z, e = nil, nil
        if raw ~= nil and m ~= nil then
            local tens = TENS[m[3]]
            local whole = floor(raw / m[2] * tens * m[1] + 0.5)
            z = m[3] > 0 and string.format(PATTERN[m[3]], whole / tens) or tostring(whole)
            e = rule[3] and (i < 4 and rule[3] or DEG) or nil
        end
        disp["bkRate" .. i], disp["bkRateF" .. i], disp["bkRateE" .. i] = z or "--", z and COLOUR.g or P.MUTED, z and e or ""
    end
end

local BANK_F = {"bkBankF1", "bkBankF2", "bkBankF3"}    -- the colour of BANK 1 2 3 in disp
local PID_NAMES = {}                                   -- per axis and gain: the field in disp, its colour and the field in the record PID_TUNING
for a = 0, 2 do
    for _, b in ipairs({"P", "I", "D", "F", "B", "O"}) do
        PID_NAMES[#PID_NAMES + 1] = {"bkP" .. a .. b, "bkP" .. a .. b .. "F", "pid_" .. a .. "_" .. b}
    end
end

local function govMode(g)                              -- gov_mode as the Governor page shows it (lib/governor.lua getEffectiveMode): OFF while the governor feature is off
    local m = g.gov_mode and floor(g.gov_mode)
    local session = rfsuite and rfsuite.session
    if m ~= nil and type(session) == "table" and session.governorFeature == false then return 0 end
    return m
end

local function valuesFromFc(w, m, rpmUnit, bankOk, rateOk)   -- what comes from the records read; only anew when L.values, the mode or what still matches has changed
    local g, p, r = w.gov or {}, bankOk and w.govProfile or {}, rateOk and w.rc or {}
    local mode = m and GOV_MODES[m] or nil
    disp.bkGov, disp.bkGovF = mode or "--", mode and COLOUR.g or P.MUTED
    disp.bkRpm, disp.bkRpmF = num(p.governor_headspeed)
    disp.bkRpmE = p.governor_headspeed ~= nil and rpmUnit or ""
    local spool = g.gov_spoolup_time and string.format("%.1f", g.gov_spoolup_time / 10) or nil
    disp.bkSpool, disp.bkSpoolF, disp.bkSpoolE = spool or "--", spool and COLOUR.g or P.MUTED, spool and "s" or ""
    disp.bkGain, disp.bkGainF = num(p.governor_gain)
    rates(r)
    local pid = bankOk and w.pid or {}
    for i = 1, #PID_NAMES do
        local nm = PID_NAMES[i]
        disp[nm[1]], disp[nm[2]] = num(pid[nm[3]])
    end
end

local function refresh(state)
    local s = T.read(state)
    if P == nil then return end
    T.mspRelease()                                     -- the place at the MSP service goes back between reads
    tick(s)
    local w = L.values
    local active, rate = s.bank and floor(s.bank) or nil, s.rate and floor(s.rate) or nil
    local rf = L.readFor or {}
    local bankOk, rateOk = rf.bank == active, rf.rate == rate   -- what was read for another bank or rate stays away (switched while armed: the page reads again on the ground)
    local g, p, r = w.gov or {}, bankOk and w.govProfile or {}, rateOk and w.rc or {}
    local m = govMode(g)
    local rpmUnit = "@i18n(widgets.dashboard.nf_rpm_unit)@"   -- the headspeed unit: U/min in the German package, rpm as in the cockpit in the English one
    local fc = G.bkValues
    if fc == nil or fc.rev ~= L.rev or fc.values ~= w or fc.mode ~= m or fc.rpmUnit ~= rpmUnit or fc.bankOk ~= bankOk or fc.rateOk ~= rateOk then
        valuesFromFc(w, m, rpmUnit, bankOk, rateOk)
        G.bkValues = {rev = L.rev, values = w, mode = m, rpmUnit = rpmUnit, bankOk = bankOk, rateOk = rateOk}
    end
    disp.bkActual, disp.bkActualF = num(s.rpm)
    disp.bkActualE = s.rpm ~= nil and rpmUnit or ""
    for i = 1, 3 do disp[BANK_F[i]] = (active == i) and COLOUR.w or P.MUTED end
    local foot = "@i18n(widgets.dashboard.nf_rate)@ " .. (rate and tostring(rate) or "?")
    local rateType = r.rates_type and RATE_TYPE[floor(r.rates_type)] or nil
    if w.fault ~= nil then   -- the red message needs the row: the rates type stays away while it stands
        disp.bkFoot, disp.bkError = foot, "MSP " .. w.fault
    else
        disp.bkFoot, disp.bkError = foot .. "   " .. (rateType or ""), nil
    end
    local b = BARS                                   -- the column against the bank's target; without a target against the end of the cockpit's arc
    local top, bottom = sy(b.top), sy(b.bottom)
    local target = (m ~= nil and m >= 3) and p.governor_headspeed or nil
    if target ~= nil and target <= 0 then target = nil end
    local full = target and (target * SCALE) or T.rpmFull()
    local function yFrom(v)
        local fraction = v / full
        if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
        return floor(bottom - (bottom - top) * fraction + 0.5)
    end
    disp.bkTargetShown = target ~= nil
    if target then disp.bkTargetY, disp.bkYellowY, disp.bkTargetText = yFrom(target), yFrom(target * YELLOW_FROM), tostring(floor(target + 0.5)) end
    local rpm = s.rpm
    disp.bkColumnShown = rpm ~= nil and rpm > 0
    if disp.bkColumnShown then
        local colour = GREEN
        if target and rpm > target * YELLOW_FROM then colour = RED elseif target and rpm > target then colour = YELLOW end
        local yTop, yBottom = yFrom(rpm), sy(b.bottom - b.rim)
        if yTop < sy(b.top + b.rim) then yTop = sy(b.top + b.rim) end
        disp.bkColumnF, disp.bkColumnY, disp.bkColumnH = colour, yTop, math.max(0, yBottom - yTop)
        if disp.bkColumnH == 0 then disp.bkColumnShown = false end
    end
    local sl = active and G.peak[active]
    disp.bkPeakShown = sl ~= nil and sl.max ~= nil and sl.max > 0
    if disp.bkPeakShown then
        local y = yFrom(sl.max)
        if y < sy(b.top + b.rim) then y = sy(b.top + b.rim) end
        disp.bkPeakY = y - 1
    end
end

local function node(colour)                           -- the nodes depend only on the colour: built once, kept in G (survives the reload per flight phase)
    local Lf = T.lines(colour)
    local k = {}
    local parts = {}                                   -- the build in five parts and the assembly, each small enough for one call
    parts[1] = function()                              -- background, lines, chips, bar
    k[#k + 1] = {type = "image", x = 0, y = 0, w = R.W, h = R.H, file = DIR .. R.GFX .. "background.png"}
    R.page(k, Lf, false, DIR, colour)
    for i = 1, 4 do
        local x, w = chipPlace(RATE_CHIP, i)
        P.chip(k, Lf, x, RATE_CHIP.y, w, RATE_CHIP.h, i == 1 and "left" or nil)
    end
    for i = 1, 3 do
        local x, w = chipPlace(GAIN_CHIP, i)
        P.chip(k, Lf, x, GAIN_CHIP.y, w, GAIN_CHIP.h, i == 1 and "left" or nil)
    end
    local b = BARS
    P.chip(k, Lf, b.x, b.top, b.w, b.bottom - b.top)
    local zx, zw = sx(ZONES_X), sx(ZONES_X + ZONES_W) - sx(ZONES_X)
    local bottommost = sy(b.bottom)
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = GREEN, visible = function() return disp.bkTargetShown == true end,
                 pos = function() return zx - DX, (disp.bkTargetY or 0) - DY end, size = function() return zw, math.max(1, bottommost - (disp.bkTargetY or 0)) end}
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = YELLOW, visible = function() return disp.bkTargetShown == true end,
                 pos = function() return zx - DX, (disp.bkYellowY or 0) - DY end, size = function() return zw, math.max(1, (disp.bkTargetY or 0) - (disp.bkYellowY or 0)) end}
    local topmost = sy(b.top)
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = RED, visible = function() return disp.bkTargetShown == true end,
                 pos = function() return zx - DX, topmost - DY end, size = function() return zw, math.max(1, (disp.bkYellowY or 0) - topmost) end}
    local sx0, sw = sx(b.x + b.rim), sx(b.x + b.w - b.rim) - sx(b.x + b.rim)
    k[#k + 1] = {type = "rectangle", x = sx0, y = 0, w = sw, h = 1, filled = true, color = function() return disp.bkColumnF or GREEN end,
                 visible = function() return disp.bkColumnShown == true end,
                 pos = function() return sx0 - DX, (disp.bkColumnY or 0) - DY end, size = function() return sw, math.max(1, disp.bkColumnH or 1) end}
    local mx, mw = sx(b.x - 4), sx(b.x + b.w + 4) - sx(b.x - 4)
    k[#k + 1] = {type = "rectangle", x = mx, y = 0, w = mw, h = 1, filled = true, color = COLOUR.w, visible = function() return disp.bkTargetShown == true end,
                 pos = function() return mx - DX, (disp.bkTargetY or 0) - DY end}
    local kx0, kw = sx(b.x + 2), sx(b.x + b.w - 2) - sx(b.x + 2)
    k[#k + 1] = {type = "rectangle", x = kx0, y = 0, w = kw, h = 2, filled = true, color = COLOUR.w, visible = function() return disp.bkPeakShown == true end,
                 pos = function() return kx0 - DX, (disp.bkPeakY or 0) - DY end}
    for i = 1, #k do
        if k[i].pos == nil then k[i].x = k[i].x - DX; k[i].y = k[i].y - DY end
    end
    end

    local function v(name) return function() return disp[name] end end
    local columns = {{"@i18n(widgets.dashboard.nf_governor)@", "bkGov", nil}, {"@i18n(widgets.dashboard.nf_headspeed)@", "bkRpm", "bkRpmE"}, {"@i18n(widgets.dashboard.nf_spoolup)@", "bkSpool", "bkSpoolE"}, {"@i18n(widgets.dashboard.nf_gain)@", "bkGain", nil}}
    parts[2] = function()                              -- the head band and ACTUAL
    for i = 1, 4 do                                    -- the head band: governor, target headspeed, spool-up, gain in the alignment of the four chips
        local x, w = chipPlace(RATE_CHIP, i)
        if i == 1 then x, w = 0, x + w end
        local sp = columns[i]
        P.word(k, sx(x + w / 2), sy(18), sp[1], COLOUR.w, F.xs, nil, DX, DY)
        local segs = {{v(sp[2]), v(sp[2] .. "F"), F.std}}
        if sp[3] then segs[2] = {v(sp[3]), COLOUR.w, F.xs} end
        P.row(k, sx(x + w / 2), sy(35), segs, nil, DX, DY)
    end
    P.word(k, sx(ACTUAL_X + ACTUAL_W / 2), sy(18), "@i18n(widgets.dashboard.nf_actual)@", COLOUR.w, F.xs, nil, DX, DY)
    P.row(k, sx(ACTUAL_X + ACTUAL_W / 2), sy(35), {{v("bkActual"), v("bkActualF"), F.std}, {v("bkActualE"), COLOUR.w, F.xs}}, nil, DX, DY)
    end
    parts[3] = function()                              -- the rates
    for i = 1, 4 do                                    -- per axis the number as rfsuite shows it: rotation rate, factor or for the collective the angle
        local x, w = chipPlace(RATE_CHIP, i)
        local y = RATE_CHIP.y
        if i == 1 then x, w = 0, x + w end
        P.word(k, sx(x + w / 2), sy(y + 15), RATE_AXES[i], COLOUR.w, F.s, nil, DX, DY)
        P.row(k, sx(x + w / 2), sy(y + 40), {{v("bkRate" .. i), v("bkRateF" .. i), F.l}, {v("bkRateE" .. i), COLOUR.w, F.xs}}, nil, DX, DY)
    end
    end
    local gainAxes = {{"@i18n(widgets.dashboard.nf_roll)@", 0}, {"@i18n(widgets.dashboard.nf_pitch)@", 1}, {"@i18n(widgets.dashboard.nf_tail)@", 2}}
    parts[4] = function()                              -- the gains
    for i = 1, 3 do                                    -- gains per axis: P I D F B O
        local x, w = chipPlace(GAIN_CHIP, i)
        local y = GAIN_CHIP.y
        if i == 1 then x, w = 0, x + w end
        local a = gainAxes[i]
        P.word(k, sx(x + w / 2), sy(y + 13), a[1], COLOUR.w, F.s, nil, DX, DY)
        local pairList = {{10, 36, "P"}, {62, 36, "I"}, {10, 58, "D"}, {62, 58, "F"}, {10, 80, "B"}}
        if a[2] ~= 2 then pairList[#pairList + 1] = {62, 80, "O"} end
        for _, pr in ipairs(pairList) do
            local name = "bkP" .. a[2] .. pr[3]
            k[#k + 1] = {type = "label", x = sx(x + pr[1]) - DX, y = sy(y + pr[2] - 7) - DY, w = 0, font = F.s, text = pr[3], color = COLOUR.w}
            k[#k + 1] = {type = "label", x = sx(x + pr[1] + 16) - DX, y = sy(y + pr[2] - 8) - DY, w = 0, font = F.std, text = v(name), color = v(name .. "F")}
        end
    end
    end
    parts[5] = function()                              -- the banks, the mark at the bar, the foot row
    local hs = T.height(F.s)
    for i = 1, 3 do
        local nr = i
        P.row(k, sx(BANK_RX), sy(BANK_Y + (i - 1) * BANK_STEP) + floor(hs / 2), {{"@i18n(widgets.dashboard.nf_bank)@" .. " " .. i, function() return disp["bkBankF" .. nr] end, F.s}}, "right", DX, DY)
    end
    local hx = T.height(F.xs)
    local targetPlace = {}
    k[#k + 1] = {type = "label", x = 0, y = 0, w = 0, font = F.xs, color = COLOUR.w, visible = function() return disp.bkTargetShown == true end,
                 text = function() return disp.bkTargetText or "" end,
                 pos = function()
                     local t = disp.bkTargetText or ""
                     if targetPlace.text ~= t then targetPlace.text, targetPlace.b = t, T.textWidth(t, F.xs) end
                     return sx(BANK_RX) - targetPlace.b - DX, (disp.bkTargetY or 0) - floor(hx / 2) - DY
                 end}
    k[#k + 1] = {type = "label", x = sx(140) - DX, y = sy(FOOT_Y) - DY, w = 0, font = F.s, color = COLOUR.w, text = v("bkFoot")}
    k[#k + 1] = {type = "label", x = sx(290) - DX, y = sy(FOOT_Y) - DY, w = 0, font = F.s, color = COLOUR.r,
                 text = function() return disp.bkError or "" end, visible = function() return disp.bkError ~= nil end}
    end
    parts[6] = function() end                          -- the last call only assembles: the first creation of all nodes has a call of its own
    return k, parts
end

local function begin(colour)                         -- the set for this colour: from G, otherwise newly created (still without nodes)
    local cacheKey = tostring(colour)
    local f = G.bkDone
    if type(f) ~= "table" or f.cacheKey ~= cacheKey then
        local k, parts = node(colour)
        f = {cacheKey = cacheKey, k = k, parts = parts, i = 1}
        G.bkDone = f
    end
    return f
end

local function buildPart(f)                              -- builds the next part; true when all are there
    if f.parts ~= nil then
        f.parts[f.i]()
        f.i = f.i + 1
        if f.i == 2 then f.frame = {table.unpack(f.k)} end   -- after the first part: background, lines, chips and bar - the page shows this until all parts are there
        if f.i > #f.parts then f.parts = nil end
    end
    return f.parts == nil
end

local broken = nil                                     -- a build that broke off: the page shows the background until the file is loaded again
local function ready(colour)                            -- are all nodes for this colour ready?
    local f = G.bkDone
    return P == nil or broken ~= nil or (type(f) == "table" and f.parts == nil and f.cacheKey == tostring(colour))
end

local buildCount, haveRead, lastBuild = 0, false, nil      -- lastBuild: the previous build, whole or a part, and when
function M.renderKey(zone, state)                      -- while the screen is not complete, a new key per call: the suite stores it right after the build (widgets/dashboard/views.lua viewKey)
    G.tick = (G.tick or 0) + 1
    haveRead = true                                     -- on first opening the suite asks renderKey only after the build; the whole screen waits for it
    local ok, reason = pcall(refresh, state or {})
    if not ok then T.note("banks refresh: " .. tostring(reason)) end
    local colour = T.colourFrom(state)
    local key = "banks|" .. colour
    if ready(colour) and (lastBuild == nil or lastBuild.whole) then return key end
    buildCount = buildCount + 1
    return key .. "|build " .. buildCount
end

local function buildScreen(children, zone, state, ctx)       -- a page that is not ready: one part per call, until then the background with the frame
    local t = now()
    if lastBuild == nil or lastBuild.whole or t - lastBuild.time > 2 then   -- the page opens (not the next part): make room and read again
        collectgarbage("collect")
        L.gen, L.running, L.fresh = L.gen + 1, false, true    -- a reply for an earlier opening is dropped
    end
    local colour = T.colourFrom(state)
    G.colourNow = colour
    local f = begin(colour)
    local whole = buildPart(f) and haveRead                -- the background with the frame needs no values, the whole screen does
    local k = whole and f.k or f.frame
    lastBuild = {whole = whole, time = t}
    children[#children + 1] = {type = "box", x = 0, y = 0, w = zone.w, h = zone.h, borderPad = 0, children = {
        {type = "button", x = 0, y = 0, w = zone.w, h = zone.h, cornerRadius = 0, color = COLOUR.black, children = k,
         press = function() ctx.action("closeView") end}}}
    if whole then T.note("banks built: " .. #k .. " nodes") end
end

function M.build(children, zone, state, ctx)
    if type(ctx) == "table" and type(ctx.keys) == "table" then ctx.keys.pageUp = "openView:nf_banks" end   -- the suite closes a view with its key: so both PAGE keys lead back; the cockpit sets them again on its next build
    local ok, reason = false, broken or "page.lua missing"
    if P ~= nil and broken == nil then ok, reason = pcall(buildScreen, children, zone, state, ctx) end
    if not ok then
        broken = tostring(reason)
        T.note("banks build: " .. broken)
        children[#children + 1] = {type = "label", x = 10, y = 10, w = R.W - 20, text = "@i18n(widgets.dashboard.build_failed)@", color = COLOUR.r}
    end
end

if P ~= nil then
    G.bkPrebuild = function(colour)                     -- for the cockpit: one part per quiet round; true only when all parts were already there
        local f = begin(colour)
        if f.parts == nil then return true end
        buildPart(f)
        return false
    end
else
    G.bkPrebuild = false
end

return M
