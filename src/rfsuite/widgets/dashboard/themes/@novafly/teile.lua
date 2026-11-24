-- TEILE des Themes fuer EdgeTX: was das Cockpit (cockpit.lua) und die zwei Seiten (vorflug.lua, baenke.lua) gemeinsam brauchen -
-- den Ordner, die Schriften des Senders und ihre Masse, die Farben, die Woerter, die Linienfarben, das Lesen des Zustands der
-- Suite (stand) mit allem, was ueber den Augenblick hinaus zaehlt (Schleppmonitor, der laufende und der letzte Flug, die Uhr je
-- Bank, der Bezug des Richtungspfeils), und die Bausteine fuer Beschriftungen und Werte. Ein Wert ist ein label, dessen Text,
-- Farbe und Ort Funktionen nennen, die nur lesen, was stand() gerechnet hat. Was das Neuladen ueberleben muss, liegt in zustand.lua.
local PFADE = rfsuite and rfsuite.paths or {}
local ORDNER = PFADE.core and (PFADE.core .. "/widgets/dashboard/themes/@novafly/") or nil
if ORDNER == nil or loadScript(ORDNER .. "init.lua", "t") == nil then
    if PFADE.user then ORDNER = PFADE.user .. "/dashboard/novafly/" end
end
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local RGB = lcd.RGB

local T = {ORDNER = ORDNER}
T.FARBE = {w = RGB(245, 248, 252), d = RGB(120, 132, 145), g = RGB(90, 255, 70), y = RGB(240, 210, 30), o = RGB(255, 130, 20),
           r = RGB(255, 80, 80), schwarz = RGB(0, 0, 0), grau = RGB(52, 56, 64), rot = RGB(225, 40, 40), gruen = RGB(40, 180, 55),
           ring = RGB(0, 152, 224), tief = RGB(8, 8, 10), nadel = RGB(255, 255, 255)}
local F_S = SMLSIZE or 0   -- die fuenf Stufen der Senderschrift (Ethos: FONT_S, FONT_STD, FONT_L, FONT_XL, FONT_XXL); fehlt eine, nimmt sie die naechste
T.F = {s = F_S, xs = rawget(_G, "TINSIZE") or F_S, std = 0, l = MIDSIZE or 0, xl = DBLSIZE or MIDSIZE or 0, xxl = XXLSIZE or DBLSIZE or 0}
T.LUECKE = 4                                  -- die Einheit dicht an ihrer Zahl
T.BEZUG_OHNE_FLUG = 2000
T.VFR_GELB, T.VFR_ROT = 90, 80

local function suiteModul(pfad)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, pfad)
        if ok and type(m) == "table" then return m end
    end
    return nil
end

local gemerkt = {}   -- eine Zeile ins Log der Suite (lib/log.lua, Stufe debug), jede nur einmal je geladener Datei; mit dem Lua-Speicher dahinter
function T.merken(text)
    text = tostring(text)
    if gemerkt[text] then return end
    gemerkt[text] = true
    local Log = suiteModul("lib/log.lua")
    if Log and type(Log.emit) == "function" then pcall(Log.emit, "novafly", text .. " (Lua " .. floor(collectgarbage("count")) .. " KB)", "debug") end
end

local function laden(datei)
    local chunk = loadScript(ORDNER .. datei)
    if not chunk then T.merken(datei .. " fehlt") return nil end
    local ok, tab = pcall(chunk)
    if ok and type(tab) == "table" then return tab end
    T.merken(datei .. ": " .. tostring(tab))
    return nil
end

function T.modul(datei)   -- ein Modul des Themes: ueber den Lader der Suite (gemerkt, mit dem Theme wieder freigegeben), sonst direkt geladen
    return suiteModul(ORDNER .. datei) or laden(datei)
end

local G = suiteModul(ORDNER .. "zustand.lua")   -- die Suite laedt die Dateien des Themes bei jedem Wechsel der Flugphase neu; was bleiben muss, liegt in zustand.lua, das der Lader der Suite haelt (runtime.lua releaseUnusedThemes)
if G == nil then
    G = _G.NOVAFLY_THEME
    if type(G) ~= "table" then
        G = {}
        _G.NOVAFLY_THEME = G
    end
end
T.G = G
if G.anz == nil then
    G.anz, G.lage, G.gesehen, G.rpmHoch, G.schlepp, G.hoehe, G.linien = {}, {}, {}, 0, {}, {}, {}
    G.flug = {laeuft = false, ende = false, mahStart = nil, stromMax = nil, bank = {0, 0, 0}, uhr = nil}
    G.letzterFlug = {}
    G.richtung = {bezug = nil, gefasst = false}
end
if G.sitzung == nil then G.sitzung = {} end   -- Hoehe und Steigen/Sinken seit dem Start, scharf oder nicht: VORFLUG zeigt sie, solange kein Flug aufgezeichnet ist
if G.breiten == nil then G.breiten = {} end   -- gemessene Breiten je Schrift und Text (T.breite)
local anz, lage = G.anz, G.lage

T.R = G.R or T.modul("rahmen.lua")
G.R = T.R
if T.R and T.R.px then T.LUECKE = T.R.px(4) end   -- die Luecke in Bildpunkten dieses Schirms (800 x 480: 4)
T.FARBEN = G.FARBEN or T.modul("farben.lua") or {}
G.FARBEN = T.FARBEN
T.W = G.W or T.modul("woerter.lua") or {}
G.W = T.W

T.FARBWORT = {"blue", "turquoise", "green", "yellow", "gold", "orange", "red", "magenta", "violet", "silver"}   -- die gespeicherten Werte der Farbe sind englisch, wie jeder Wert in den Einstellungen der Suite (configure.lua dieselbe Reihe)
T.FARBE_NR = {}
for i = 1, #T.FARBWORT do T.FARBE_NR[T.FARBWORT[i]] = i end

function T.farbeAus(state)   -- die Farbe steht in den Theme-Einstellungen der Suite (state.themeConfig); nach einem langen Druck gilt die neue sofort (G.farbeNeu), bis die Suite ihre Einstellungen neu gereicht hat
    local c = state and state.themeConfig
    local wort = type(c) == "table" and c.colour or nil
    local neu = G.farbeNeu
    if type(neu) == "table" then
        local session = rfsuite and rfsuite.session
        local id = type(session) == "table" and session.mcu_id or nil
        if wort ~= neu.vorher or id ~= neu.id then G.farbeNeu = nil else wort = neu.farbe end
    end
    if T.FARBE_NR[wort] then return wort end
    return "blue"
end

function T.linien(farbe)                      -- Mittelton, Kern und Schein der Linien als Farben des Senders, einmal je Farbe
    local l = G.linien[farbe]
    if l == nil then
        l = T.R.farben(T.FARBEN[farbe] or T.FARBEN.blue or {mitte = {2, 117, 194}, kern = {141, 255, 255}, schein = {1, 35, 58}})
        G.linien[farbe] = l
    end
    return l
end

function T.sprache()                          -- die Sprache des Senders; eine ohne Woerter zeigt Englisch
    if G.sprache == nil then
        G.sprache = "en"
        local ok, e = pcall(getGeneralSettings)
        local s = ok and type(e) == "table" and type(e.language) == "string" and string.lower(e.language) or nil
        if s and T.W[s] then G.sprache = s end
    end
    return G.sprache
end

function T.wort(text)                         -- ein festes Wort in der Sprache des Senders; ohne Eintrag bleibt es, wie es ist
    local t = T.W[T.sprache()]
    return (t and t[text]) or text
end

local SCHAETZ_H = {}   -- die Masse der Senderschrift: die Hoehe je Stufe einmal gemessen (lcd.sizeText), Breiten je Text; ohne lcd.sizeText geschaetzt
SCHAETZ_H[T.F.xxl], SCHAETZ_H[T.F.xl], SCHAETZ_H[T.F.l], SCHAETZ_H[T.F.std], SCHAETZ_H[T.F.s] = 64, 32, 24, 16, 13
local function messen(text, font)
    if lcd and type(lcd.sizeText) == "function" then
        local ok, w, h = pcall(lcd.sizeText, text, font)
        if ok and type(w) == "number" and type(h) == "number" and h > 0 then return w, h end
    end
    local h = SCHAETZ_H[font] or 16
    return floor(#tostring(text) * h * 0.55 + 0.5), h
end
function T.hoehe(font)
    local h = G.hoehe[font]
    if h == nil then
        local _, hh = messen("0", font)
        h = hh
        G.hoehe[font] = h
    end
    return h
end
local BREITEN_HOECHSTENS = 64   -- je Schrift so viele gemessene Texte in G.breiten; darueber beginnt die Liste der Schrift neu
function T.breite(text, font)
    if text == nil then return (messen(text, font)) end
    local f = font or -1
    local je = G.breiten[f]
    local w = je and je.w[text]
    if w == nil then
        w = messen(text, font)
        if je == nil or je.n >= BREITEN_HOECHSTENS then
            je = {w = {}, n = 0}
            G.breiten[f] = je
        end
        je.w[text], je.n = w, je.n + 1
    end
    return w
end

function T.label(n, x, y, text, farbe, font, w, align)   -- Bausteine: eine Beschriftung links an x (w 0 = so breit wie der Text), mittig um cx, rechts endend an xe; y ist die Mitte der Zeile
    n[#n + 1] = {type = "label", x = x, y = y - floor(T.hoehe(font) / 2), w = w or 0, text = text, color = farbe, font = font, align = align or LEFT}
end
function T.labelMittig(n, cx, cy, text, farbe, font)
    T.label(n, cx - floor(T.breite(text, font) / 2), cy, text, farbe, font)
end
function T.labelRechts(n, xe, cy, text, farbe, font)
    T.label(n, xe - T.breite(text, font), cy, text, farbe, font)
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

local ANTEIL_ORANGE, ANTEIL_GELB, ANTEIL_ROT_ZELLE = (3.65 - 3.5) / 0.7, (3.75 - 3.5) / 0.7, (3.45 - 3.5) / 0.7   -- Grenzen von der Suite (themeConfig.v_min/v_max, state.alerts: warn gelb, critical rot); ohne Angaben Werkswerte und die Zelle 3,5 bis 4,2 V, rot unter 3,45 V
function T.akkuAnteil(state, pack, cell)
    local c = state and state.themeConfig
    local vmin, vmax = type(c) == "table" and tonumber(c.v_min) or nil, type(c) == "table" and tonumber(c.v_max) or nil
    if pack and cell and vmin and vmax and vmax > vmin then return (pack - vmin) / (vmax - vmin), 0 end
    if cell then return (cell - 3.5) / 0.7, ANTEIL_ROT_ZELLE end
    return nil, 0
end
function T.akkuFarbe(anteil, rot)
    if anteil == nil then return "w" end
    if anteil < rot then return "r" end
    if anteil < ANTEIL_ORANGE then return "o" end
    if anteil < ANTEIL_GELB then return "y" end
    return "g"
end
function T.stufen(state, name, warn, krit)
    local a = state and state.alerts
    local s = type(a) == "table" and a[name] or nil
    if type(s) == "table" then
        if tonumber(s.warn) then warn = tonumber(s.warn) end
        if tonumber(s.critical) then krit = tonumber(s.critical) end
    end
    return warn, krit
end
function T.warmFarbe(v, warn, krit)
    if v == nil then return "d" end
    if v >= krit then return "r" end
    if v >= warn then return "y" end
    return "g"
end
function T.linkFarbe(state, vfr)             -- die Farbe des Links nach den Stufen der Link-Ansage: bis warn gelb, bis critical rot
    local lWarn, lKrit = T.stufen(state, "lq", 70, 50)
    if vfr == nil then return "w" end
    if vfr > lWarn then return "w" end
    if vfr > lKrit then return "y" end
    return "r"
end

local function ohneNull(key, v)
    if v == nil then return nil end
    if v ~= 0 then G.gesehen[key] = true end
    if v == 0 and not G.gesehen[key] then return nil end
    return v
end

local function zeit()                         -- Sekunden seit dem Start des Senders
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

function T.hoeheMerken(t, alt, jetzt)   -- die hoechste Hoehe und das staerkste Steigen und Sinken, gerechnet aus der Hoehe ueber mindestens eine halbe Sekunde (t = G.flug oder G.sitzung)
    if t.altMax == nil or alt > t.altMax then t.altMax = alt end
    if t.altZeit == nil then t.altVor, t.altZeit = alt, jetzt
    elseif jetzt - t.altZeit >= 0.5 then
        local rate = (alt - t.altVor) / (jetzt - t.altZeit)
        if t.steigMax == nil or rate > t.steigMax then t.steigMax = rate end
        if t.sinkMax == nil or rate < t.sinkMax then t.sinkMax = rate end
        t.altVor, t.altZeit = alt, jetzt
    end
end

local MODUS_QUELLEN = {"Mode", "5121"}   -- der Flugmodus-Sensor von Rotorflight: CRSF "Mode", S.Port 0x5121; die Bits wie die Firmware (runtime_config.h)
function T.flugmodus()   -- der Sensor wird einmal gesucht (getFieldInfo), ohne ihn alle 5 s neu; getValue einer fehlenden Quelle hiesse sonst 0 = ACRO
    if G.modusId == nil or (G.modusId == false and zeit() >= (G.modusWieder or 0)) then
        G.modusId = false
        if type(getFieldInfo) == "function" then
            for _, name in ipairs(MODUS_QUELLEN) do
                local ok, fi = pcall(getFieldInfo, name)
                if ok and type(fi) == "table" and fi.id ~= nil then G.modusId = fi.id break end
            end
        end
        if G.modusId == false then G.modusWieder = zeit() + 5 end
    end
    if not G.modusId then return nil end
    local ok, v = pcall(getValue, G.modusId)
    return ok and tonumber(v) or nil
end

function T.modusWort(v)   -- der Flugmodus aus den Bits (ANGLE 2, HORIZON 4, RESCUE 32) wie die Ethos-Fassung: RESCUE liegt mit ANGLE an und geht vor, HORIZON vor ANGLE, sonst Acro
    if v == nil then return nil end
    v = floor(v)
    if floor(v / 32) % 2 == 1 then return "RETTUNG" end
    if floor(v / 4) % 2 == 1 then return "HORIZONT" end
    if floor(v / 2) % 2 == 1 then return "WINKEL" end
    return "ACRO"
end

local function richtungTakt(grad, scharf)   -- der Richtungspfeil: der Bezug wird beim Scharfmachen gefasst und haelt den Flug ueber; am Boden folgt er dem Heli, ein Tipp setzt ihn
    local r = G.richtung
    if grad == nil then
        if not r.gefasst then r.bezug = nil end
        return
    end
    if scharf then
        if not r.gefasst then r.bezug = grad end
        r.gefasst = true
    else
        r.gefasst = false
        if r.bezug == nil then r.bezug = grad end
    end
end
function T.bezugSetzen()
    if G.s and G.s.grad ~= nil and G.s.scharf ~= true then
        G.richtung.bezug = G.s.grad
        return true
    end
    return false
end

function T.lesen(state)   -- liest den Zustand der Suite: s ist der Augenblick (G.s), dazu laufen Schleppmonitor, Flug und Uhren mit
    local d = state.derived or {}
    local function g(k) return tonumber(d[k]) end
    local s = {link = state.rfConnected == true}
    if s.link then
        s.pack = ohneNull("pack", g("voltage") or tonumber(state.voltage))
        s.zellen = tonumber(state.batteryCellCount)
        if s.pack ~= nil and s.zellen ~= nil and s.zellen >= 1 then s.cell = s.pack / s.zellen end
        if s.cell ~= nil then
            local f = G.cellF
            if f == nil or abs(s.cell - f) > 0.3 then f = s.cell else f = f * 0.9 + s.cell * 0.1 end
            G.cellF = f
            s.cellF = f
        end
        s.rssi, s.vfr = g("1RSS"), g("VFR") or g("RQly")
        s.rpm = g("rpm") or tonumber(state.rpm)
        if s.rpm and s.rpm > G.rpmHoch then G.rpmHoch = s.rpm end
        s.temp = ohneNull("temp", g("esc_temp"))
        s.mcutemp = g("mcu_temp")
        if s.mcutemp ~= nil and (s.mcutemp < 10 or s.mcutemp > 130) then s.mcutemp = nil end
        if state.armed ~= nil then s.scharf = (state.armed == true) end
        s.bec = ohneNull("bec", g("bec_voltage"))
        s.bank, s.rate = g("pid_profile") or tonumber(state.profile), g("rate_profile")
        s.last = ohneNull("last", g("current"))
        s.fuel = g("fuel")
        if s.fuel ~= nil and (s.fuel < 0 or s.fuel > 100) then s.fuel = nil end
        s.verbrauch = g("consumption") or g("smartconsumption")
        local alt = g("altitude")
        local loc = rfsuite and rfsuite.preferences and rfsuite.preferences.localizations   -- die Hoehe in der Einheit der Suite: rfsuite.preferences.localizations.altitude_unit 1 = Fuss
        s.altFt = (type(loc) == "table" and tonumber(loc.altitude_unit) == 1) or false
        if alt ~= nil and s.altFt then alt = alt * 3.28084 end
        s.alt = ohneNull("alt", alt)
        if s.alt ~= nil then T.hoeheMerken(G.sitzung, s.alt, zeit()) end
        local cpu = g("RT%")
        if cpu ~= nil then G.lastWort = "RT" else
            cpu = g("CPU%")
            if cpu ~= nil then G.lastWort = "CPU" end
        end
        if cpu ~= nil and (cpu < 0 or cpu > 100) then cpu = nil end
        s.cpu = cpu
        s.timer = tonumber(state.flightSeconds)
        s.flugmodus = T.flugmodus()
        local grad = g("Yaw")
        if grad ~= nil then s.grad = grad % 360 end
    end
    local ok, tv = pcall(getValue, "tx-voltage")
    if ok and type(tv) == "number" and tv > 0 then s.tx = tv end
    if s.scharf == true and s.rpm ~= nil and s.rpm > 0 and s.bank ~= nil then   -- der Schleppmonitor: je Bank Min und Max der Drehzahl, solange scharf
        local b = floor(s.bank)
        local sl = G.schlepp[b]
        if sl == nil then G.schlepp[b] = {min = s.rpm, max = s.rpm}
        else
            if s.rpm < sl.min then sl.min = s.rpm end
            if s.rpm > sl.max then sl.max = s.rpm end
        end
    end
    local flug = G.flug   -- der Flug: Strom-Hoechstwert, Verbrauch und die Uhr je Bank laufen mit, bis der Heli entschaerft
    if s.scharf == true then
        if not flug.laeuft then
            flug.laeuft, flug.mahStart, flug.stromMax, flug.bank, flug.uhr = true, s.verbrauch, nil, {0, 0, 0}, nil
            flug.altMax, flug.steigMax, flug.sinkMax, flug.altVor, flug.altZeit = nil, nil, nil, nil, nil
            for k in pairs(G.schlepp) do G.schlepp[k] = nil end
        end
        if s.last ~= nil and (flug.stromMax == nil or s.last > flug.stromMax) then flug.stromMax = s.last end
        local jetzt, b = zeit(), s.bank and floor(s.bank) or nil
        if flug.uhr ~= nil and s.rpm ~= nil and s.rpm > 0 and b ~= nil and flug.bank[b] ~= nil then
            flug.bank[b] = flug.bank[b] + max(0, jetzt - flug.uhr)
        end
        flug.uhr = jetzt
        if s.alt ~= nil then T.hoeheMerken(flug, s.alt, jetzt) end   -- die hoechste Hoehe und das staerkste Steigen und Sinken des Flugs
    elseif flug.laeuft then
        flug.laeuft, flug.ende, flug.uhr = false, true, nil
        G.letzterFlug = {strom = flug.stromMax, bank = s.bank and floor(s.bank) or nil,
                         mah = (s.verbrauch ~= nil and flug.mahStart ~= nil) and (s.verbrauch - flug.mahStart) or nil,
                         alt = flug.altMax, steig = flug.steigMax, sink = flug.sinkMax, zeit = flug.bank[1] + flug.bank[2] + flug.bank[3]}
    end
    richtungTakt(s.grad, s.scharf == true)
    local r = G.richtung
    s.winkel = (r.bezug ~= nil and s.grad ~= nil) and (s.grad - r.bezug) % 360 or nil
    G.s = s
    return s
end

function T.rpmVoll() return max(T.BEZUG_OHNE_FLUG, G.rpmHoch) * 1.25 end   -- das Ende des Bogens: die hoechste geflogene Drehzahl liegt bei 0,8
function T.rpmAnteil(v)
    if v == nil then return nil end
    local voll = T.rpmVoll()
    if v < 0 then v = 0 elseif v > voll then v = voll end
    return v / voll
end

function T.setzen(name, feld, text, einheit, font)   -- wo Zahl und Einheit eines Wertfelds stehen: mittig um x, ab x (lage links) oder bis x (lage rechts); gerechnet nur, wenn Text oder Schrift wechseln; feld = {x, y, f, e, lage}
    local L = lage[name]
    if L == nil then
        L = {}
        lage[name] = L
    end
    font = font or feld.f
    if L.text == text and L.font == font and L.einheit == einheit then return end
    L.text, L.font, L.einheit = text, font, einheit
    local zb = T.breite(text, font)
    local eb = einheit and T.breite(einheit, font) or 0
    local luecke = einheit and T.LUECKE or 0
    local links
    if feld.lage == "links" then links = feld.x
    elseif feld.lage == "rechts" then links = feld.x - (zb + luecke + eb)
    else links = feld.x - floor((zb + luecke + eb) / 2) end
    L.x, L.y = links, feld.y - floor(T.hoehe(font) / 2)
    L.ux, L.da = links + zb + luecke, einheit ~= nil
end

function T.wertKnoten(n, name, feld, dx, dy)   -- ein Wertfeld als Bausteine: die Zahl und, wenn es eine gibt, die Einheit in Weiss daneben; dx, dy, wenn das Feld in einem Knopf liegt
    dx, dy = dx or 0, dy or 0
    if lage[name] == nil then T.setzen(name, feld, "--", nil) end
    local L, farbe = lage[name], name .. "F"
    n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = feld.f,
                 text = function() return L.text or "" end, color = function() return anz[farbe] or T.FARBE.d end,
                 pos = function() return (L.x or 0) - dx, (L.y or 0) - dy end}
    if feld.e then
        n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = feld.f, color = T.FARBE.w,
                     text = function() return L.einheit or "" end, visible = function() return L.da == true end,
                     pos = function() return (L.ux or 0) - dx, (L.y or 0) - dy end}
    end
end

return T
