-- NovaFly-Cockpit als Theme der Rotorflight-Suite fuer EdgeTX: ein Grund (gfx/grund.png), die Linien als Bausteine in der
-- gewaehlten Farbe (rahmen.lua, Farben aus farben.lua), die Werte in Senderschrift aus dem Zustand der Suite (teile.lua). Der
-- Schirm wird einmal gebaut; Text, Farbe und Ort eines Werts nennen Funktionen. Im Vollbild: langer Druck auf den Kopf schaltet
-- am Boden die Farbe, Tipp auf BANK oeffnet die Bankseite, Tipp auf den Akku die Seite davor, Tipp auf den Richtungsring setzt
-- den Bezug, das ARM-Feld oeffnet das Schnellmenue; die Seitentasten schalten die Seiten, wenn der Pilot sie auf Theme stellt.
local PFADE = rfsuite and rfsuite.paths or {}
local ORDNER, THEME_PFAD = PFADE.core and (PFADE.core .. "/widgets/dashboard/themes/@novafly/") or nil, "system/@novafly"
if ORDNER == nil or loadScript(ORDNER .. "init.lua", "t") == nil then
    if PFADE.user then ORDNER, THEME_PFAD = PFADE.user .. "/dashboard/novafly/", "user/novafly" end
end
local floor, max, min, sin, cos, rad = math.floor, math.max, math.min, math.sin, math.cos, math.rad

local function suiteModul(pfad)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, pfad)
        if ok and type(m) == "table" then return m end
    end
    return nil
end
local T = suiteModul(ORDNER .. "teile.lua")
if T == nil then
    local chunk = loadScript(ORDNER .. "teile.lua")
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    T = (ok and type(t) == "table") and t or nil
end
if T == nil then
    return {build = function() return {{type = "label", x = 10, y = 10, w = (tonumber(LCD_W) or 800) - 20, text = "teile.lua", color = lcd.RGB(255, 80, 80)}} end,
            renderKey = function() return "novafly|fehlt" end}
end
local G, R, FARBE, F = T.G, T.R, T.FARBE, T.F
local anz = G.anz
local sx, sy, px, py = R.sx, R.sy, R.px, R.py
local merken = T.merken

local GAUGE = {cx = px(400), cy = py(257)}                    -- die Mitte des Tachos (Vorlage 239,5 / 171,5)
local U = {   -- die Wertfelder: Mitte (Bildpunkte), Schrift, Einheit, Lage (mittig, links ab x, rechts bis x); aus der Ethos-Vorlage umgerechnet
    timer = {x = sx(64), y = sy(102), f = F.xl},      -- der Block FLUGTIMER, RATE, BANK steht mittig im linken Feld (oben 24, unten 25 Punkte Luft auf 800 x 480)
    rate = {x = sx(64), y = sy(161), f = F.l},        -- RATE in der Mitte zwischen FLUGTIMER und BANK, gleiche Luft (28 Punkte nach oben und unten)
    bank = {x = sx(64), y = sy(222), f = F.l},
    rpm = {x = px(400), y = sy(142), f = F.xl},
    bec = {x = sx(417), y = sy(102), f = F.xl, e = "V"},   -- BEC auf der Hoehe des Flugtimers; TX und ESC im selben Schritt darunter, bis zum Tank je 16 Punkte Luft
    tx = {x = sx(417), y = sy(155), f = F.xl, e = "V"},
    amp = {x = sx(417), y = sy(208), f = F.xl, e = "A"},
    cpu = {x = sx(331), y = sy(71), f = F.s, e = "%"},
    mcu = {x = sx(187), y = sy(59), f = F.s, e = "\194\176C"},
    pack = {x = sx(164), y = sy(289), f = F.xxl, e = "V", lage = "links"},      -- die Spannung beginnt nach der Batterie
    pct = {x = sx(346), y = sy(289), f = F.xxl, e = "%", lage = "rechts"},     -- der Stand endet vor der Linie
    temp = {x = sx(422), y = sy(290), f = F.xl, e = "\194\176C"},   -- auf der Hoehe von ALT gegenueber, gleiche Abstaende
    alt = {x = sx(56), y = sy(290), f = F.xl, e = "m"},                        -- die Hoehe links unten
    rssi = {x = sx(413), y = sy(22), f = F.std},
    vfr = {x = sx(413), y = sy(36), f = F.s},
    modell = {x = px(400), y = sy(228), f = F.l},                                    -- mittig unter dem Bogen
    labels = {{64, 77, "FLUGTIMER"}, {64, 137, "RATE"}, {64, 194, "BANK"}, {417, 77, "BEC"}, {417, 130, "TX"}, {417, 183, "ESC"},   -- die Beschriftungen in der kleinen Stufe (drei Groessen: klein, mittel, gross)
              {241, 176, "rpm"}, {143, 71, "MCU"}, {56, 268, "ALT"}},
    lastWort = {x = sx(289), y = sy(59), f = F.s},
    tempWort = {x = sx(421), y = sy(268), f = F.s},   -- das Wort ueber dem Feld unten rechts: ESC ueber der Temperatur, CELL ueber der Spannung je Zelle
    batt = {x = sx(140), y = 294, bw = sx(12), bh = sy(5), n = 5},              -- die Balken der Batterie, von unten nach oben
    tank = {x = sx(370), y = sy(231), bw = sx(23), bh = sy(7), schritt = sx(24), n = 4},   -- die Balken des Tanks unter ESC, frei
}
local ARM = {x = sx(14), y = sy(14), w = sx(94), h = sy(28)}
local KNOEPFE = {kopf = {px(293), py(12), px(307), py(60)}, bank = {px(33), py(276), px(153), py(66)}, akku = {px(212), py(387), px(374), py(80)},
                 ring = {px(212), py(11), px(67), py(60)}}   -- die Knoepfe im Vollbild: Kopf (Farbe), BANK, Akku (Seite davor), Richtungsring (Bezug); ihr Gesicht ist ein Ausschnitt des Grunds
local RING = {cx = px(245), cy = py(41), r = py(22), rand = math.max(1, py(2)), spitze = py(16), fuss = py(13), ecke = 145}   -- r 22: der Ring liegt ganz im Inneren seines Knopfs (Rand 5 oben und unten)
local DX, DY = R.KNOPF_DX, R.KNOPF_DY
local QUELLEN = {"voltage", "current", "fuel", "rpm", "bec_voltage", "esc_temp", "mcu_temp", "pid_profile", "rate_profile",
                 "1RSS", "VFR", "RQly", "RT%", "CPU%", "altitude", "consumption", "smartconsumption", "Yaw"}

local function modellName()
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
    return nil
end

local FARB_NAME = {}                                   -- je Wertfeld der Name seiner Farbe in anz (wie teile.lua wertKnoten)
for _, name in ipairs({"timer", "rpm", "bec", "tx", "amp", "cpu", "mcu", "pack", "pct", "temp", "alt", "rate", "bank"}) do FARB_NAME[name] = name .. "F" end

local function stand(state)   -- liest den Zustand der Suite (teile.lua T.lesen) und legt in anz und lage ab, was auf dem Schirm steht
    local s = T.lesen(state)
    if G.packFont == nil then   -- die grosse Schrift fuer Spannung und Stand: so gross, wie beide nebeneinander in das Mittelfeld der Fussreihe passen
        local breit = T.breite("88.8", F.xxl) + T.breite("100", F.xxl) + T.breite("V", F.xxl) + T.breite("%", F.xxl) + 2 * T.LUECKE
        G.packFont = (breit <= (U.pct.x - U.pack.x)) and F.xxl or F.xl
    end
    U.pack.f, U.pct.f = G.packFont, G.packFont
    local link = s.link
    local scharf = s.scharf
    anz.arm = (not link) and "link" or ((scharf == true) and "scharf" or ((scharf == false) and "sicher" or "unbekannt"))
    anz.armFarbe = (scharf == true and link) and FARBE.gruen or ((scharf == false and link) and FARBE.rot or FARBE.grau)
    anz.armText = (not link) and "NO LINK" or ((scharf == true) and "ARMED" or ((scharf == false) and "DISARMED" or "ARM ?"))
    anz.armTextF = (not link) and FARBE.r or FARBE.w
    local function wert(name, text, fk, einheit, font)
        if text == nil then
            anz[FARB_NAME[name]] = FARBE.d
            T.setzen(name, U[name], "--", nil, font)
        else
            anz[FARB_NAME[name]] = FARBE[fk] or FARBE.g
            T.setzen(name, U[name], text, einheit, font)
        end
    end
    wert("timer", s.timer and T.fmtT(s.timer) or nil, "g")
    local bf = (s.bank ~= nil and s.rate ~= nil and s.bank ~= s.rate) and "r" or "g"
    wert("bank", s.bank and T.fmt(s.bank) or nil, bf)
    wert("rate", s.rate and T.fmt(s.rate) or nil, bf)
    if s.bank == nil then T.setzen("bank", U.bank, "?", nil) end
    if s.rate == nil then T.setzen("rate", U.rate, "?", nil) end
    wert("rpm", s.rpm and T.fmt(s.rpm) or nil, "g")
    wert("bec", s.bec and T.fmt(s.bec, 1) or nil, (s.bec and s.bec >= 5.0) and "g" or "y", "V")
    local txWarn = G.txWarn or 7.0                     -- die Warnspannung des Senders selbst (getGeneralSettings), sonst 7,0 V
    wert("tx", s.tx and T.fmt(s.tx, 1) or nil, s.tx and ((s.tx >= txWarn + 0.4) and "g" or ((s.tx >= txWarn) and "y" or "r")) or "g", "V")
    wert("amp", s.last and T.fmt(s.last, 1) or nil, "g", "A")
    local anteil, rotAb = T.akkuAnteil(state, s.pack, s.cellF or s.cell)
    local ck = T.akkuFarbe(anteil, rotAb)
    wert("pack", s.pack and T.fmt(s.pack, 1) or nil, ck, "V", G.packFont)
    local p = nil
    if s.fuel ~= nil then p = s.fuel                  -- der Stand, wie die Suite ihn rechnet (derselbe wie die Balken im Tank)
    elseif anteil then p = anteil * 100 end
    if p ~= nil then
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
    end
    wert("pct", p and T.fmt(p) or nil, ck, "%", G.packFont)
    local tWarn, tKrit = T.stufen(state, "escTemp", 90, 110)
    if s.temp == nil and s.cell ~= nil then            -- ein ESC ohne Temperatur: im ESC-Feld steht die Spannung je Zelle in der Farbe des Akkus
        wert("temp", T.fmt(s.cell, 2), ck, "V")
        anz.tempWort = "CELL"                          -- in jeder Sprache gleich, wie ESC und BEC
    else
        wert("temp", s.temp and T.fmt(s.temp) or nil, s.temp and T.warmFarbe(s.temp, tWarn, tKrit) or "g", "\194\176C")
        anz.tempWort = "ESC"
    end
    wert("alt", s.alt and T.fmt(s.alt) or nil, "g", s.altFt and "ft" or "m")
    anz.balken, anz.balkenFarbe = 0, FARBE[ck]
    if anteil then
        local a = anteil
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
        anz.balken = floor(a * U.batt.n + 0.5)
    end
    anz.tank = 0                                       -- der Tank: der Verbrauch gegen die Akkukapazitaet; ohne Sensor leer
    if s.fuel then anz.tank = floor(s.fuel / (100 / U.tank.n)) end   -- je volles Viertel ein Balken
    local mWarn, mKrit = T.stufen(state, "mcuTemp", 80, 95)
    wert("mcu", s.mcutemp and T.fmt(s.mcutemp) or nil, s.mcutemp and T.warmFarbe(s.mcutemp, mWarn, mKrit) or "g", "\194\176C")
    wert("cpu", s.cpu and T.fmt(s.cpu) or nil, s.cpu and ((s.cpu < 50) and "g" or ((s.cpu < 80) and "y" or "r")) or "g", "%")
    anz.lastWort = (G.lastWort == "RT") and "RT" or "CPU"
    anz.rssi = s.rssi and ("RSSI " .. T.fmt(s.rssi) .. "dB") or ""
    anz.vfr = s.vfr and ("VFR " .. T.fmt(s.vfr)) or ""
    anz.vfrFarbe = FARBE[T.linkFarbe(state, s.vfr)]
    local a = T.rpmAnteil(s.rpm)   -- der Pfeil des Tachos: seine drei Ecken, nur neu gerechnet, wenn sich der Anteil geaendert hat
    if a == nil then anz.pfeilDa = false
    else
        local grad = floor(a * 200 + 0.5)              -- in Schritten von einem halben Prozent
        if grad ~= anz.pfeilGrad then
            anz.pfeilGrad = grad
            anz.pfeil = R.pfeilPunkte(R.GROSS, GAUGE.cx, GAUGE.cy, grad / 200)
        end
        anz.pfeilDa = true
    end
    if s.winkel == nil then anz.nadelDa = false   -- der Richtungspfeil im Ring (links vom Kopf): die Nadel in Richtung des Hecks gegen den Bezug, als Dreieck im Knopf
    else
        local w = floor(s.winkel + 0.5) % 360
        if w ~= anz.nadelGrad then
            anz.nadelGrad = w
            local ox, oy = KNOEPFE.ring[1] + DX, KNOEPFE.ring[2] + DY
            local function ecke(r, grad)
                local aa = rad(w + grad)
                return {floor(RING.cx + r * sin(aa) + 0.5) - ox, floor(RING.cy - r * cos(aa) + 0.5) - oy}
            end
            anz.nadel = {ecke(RING.spitze, 0), ecke(RING.fuss, RING.ecke), ecke(RING.fuss, -RING.ecke)}
        end
        anz.nadelDa = true
    end
end

local farbe = "blue"   -- die Farbe aus den Theme-Einstellungen der Suite (teile.lua T.farbeAus), dem Modell oder dem Sender; solange der Heli da ist, merkt sich das Theme den Besitzer (G.besitz)
local function besitzMerken(Lib, prefs)
    local session = rfsuite and rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    local modelPrefs = (id and type(session.modelPreferences) == "table") and session.modelPreferences or nil
    if modelPrefs == nil or Lib == nil or type(Lib.modelOverridesActive) ~= "function" then return end
    local dashboard = type(prefs) == "table" and type(prefs.dashboard) == "table" and prefs.dashboard or {}
    G.besitz = {id = id, modell = Lib.modelOverridesActive(dashboard, modelPrefs.dashboard) == true}
end

local function farbeSpeichern(neu, state)   -- die neue Farbe in denselben Speicher, den die Einstellungsseite schreibt (eigene Werte des Modells oder Standard des Senders); bis die Suite neu liest, zeigt das Cockpit G.farbeNeu
    local Lib = suiteModul("app/pages/settings/dashboard/lib.lua")
    local prefs = rfsuite and rfsuite.preferences
    if Lib == nil or type(Lib.setThemeConfig) ~= "function" or type(prefs) ~= "table" then return false end
    besitzMerken(Lib, prefs)
    local session = rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    local modelPrefs = (id and type(session.modelPreferences) == "table") and session.modelPreferences or nil
    local besitz = G.besitz
    local c = state and state.themeConfig
    local vorher = type(c) == "table" and c.colour or nil
    local function gilt()
        G.farbeNeu = {farbe = neu, vorher = vorher, id = id}   -- gilt nur fuer diesen Heli (oder ohne Heli), bis die Suite neu reicht
        farbe = neu
        return true
    end
    if type(besitz) == "table" and besitz.modell then                 -- die Farbe gehoert dem Modell
        if modelPrefs == nil or besitz.id ~= id then return false end   -- und das Modell ist nicht da: nichts schreiben
        if type(Lib.setEditScope) ~= "function" then return false end
        local MP = suiteModul("lib/model_preferences.lua")
        if MP == nil or type(MP.saveByMcuId) ~= "function" then return false end
        Lib.setEditScope("model")
        Lib.setThemeConfig(prefs, THEME_PFAD, {colour = neu}, modelPrefs)
        Lib.setEditScope(nil)
        return MP.saveByMcuId(id, modelPrefs) == true and gilt()
    end
    if besitz == nil then
        if state and state.hadInflightFlight == true and state.rfConnected ~= true then return false end   -- nichts gemerkt seit dem Laden: nach einem Flug ohne Verbindung wuerde der Standard hinter einem fremden Cockpit geaendert - der Druck tut nichts
        local dashboard = type(prefs.dashboard) == "table" and prefs.dashboard or {}
        local standard = dashboard["cfg_" .. string.gsub(THEME_PFAD, "[^%w]", "_") .. "_colour"]
        if T.FARBE_NR[standard] == nil then standard = "blue" end   -- ein fremdes Wort im Speicher gilt als blau, wie im Cockpit
        if standard ~= farbe then return false end
    end
    local Prefs = suiteModul("lib/preferences.lua")
    if Prefs == nil or type(Prefs.save) ~= "function" then return false end
    Lib.setThemeConfig(prefs, THEME_PFAD, {colour = neu}, nil)
    return Prefs.save(prefs) == true and gilt()
end

local letzterState = nil   -- ein langer Druck auf den Kopf oben: die naechste Farbe der Reihe, mit Pieps, nur am Boden; scharf oder ohne Speicher tut er nichts
local function ton(hz, ms) local t = _G.playTone if t then pcall(t, hz, ms, 0) end end
local function farbeWeiter()
    if anz.arm == "scharf" then return end
    local neu = T.FARBWORT[(T.FARBE_NR[farbe] or 1) % #T.FARBWORT + 1]
    if farbeSpeichern(neu, letzterState) then ton(880, 120) end
end
local function bezugSetzen()                           -- ein Tipp auf den Ring: der Heli zeigt jetzt nach vorn (nur am Boden)
    if T.bezugSetzen() then ton(880, 120) end
end

local M = {}
function M.sources() return QUELLEN end

local namenTakt = 0
local PAUSE = 300                                      -- in Hundertstelsekunden: im Betrieb ruft die Suite das Cockpit in kuerzeren Abstaenden
local geschluesselt, aufbau, fehlt = false, 0, nil     -- der erste Bau nach dem Einschalten verteilt sich auf drei Aufrufe (Rahmen, Mitte, Werte; einStueck)
function M.renderKey(zone, state)                      -- fehlt mehr als ein Stueck, traegt der Schluessel einen Zaehler; das letzte baut der Bau des fertigen Schirms, ein Farbwechsel bleibt ein Bau
    geschluesselt = true
    local ok, grund = pcall(stand, state or {})
    if not ok then merken("stand: " .. tostring(grund)) end
    letzterState = state
    farbe = T.farbeAus(state)
    G.farbeJetzt = farbe                                   -- fuer BAENKE: legt seine Bausteine schon beim Laden in dieser Farbe bereit
    local vb = G.bkVorbauen                            -- BAENKE vorab: 30 Runden nach dem Start die Datei einmal laden (sie legt G.bkVorbauen ab), dann je Runde ein Teil
    if vb == nil then
        G.bkZaehler = (G.bkZaehler or 0) + 1
        if G.bkZaehler >= 30 then
            G.bkVorbauen = false
            local chunk = loadScript(ORDNER .. "baenke.lua")
            if chunk then pcall(chunk) end
        end
    elseif vb ~= false and (getUsage == nil or getUsage() < 45) then   -- nur nach einer ruhigen Runde: der Vorab-Bau darf nie auf eine volle Runde der Suite fallen
        local ok, da = pcall(vb, farbe)
        if ok and da == true then                          -- BAENKE liegt bereit: danach VORFLUG, in einem Stueck
            local vf = G.vfVorbauen
            if vf == nil then
                G.vfVorbauen = false
                local chunk = loadScript(ORDNER .. "vorflug.lua")
                if chunk then pcall(chunk) end
            elseif vf ~= false then
                pcall(vf, farbe)
            end
        end
    end
    local jetzt = getTime and getTime() or 0
    if G.ruf and jetzt - G.ruf > PAUSE then namenTakt = 0 end   -- nach einer Pause den Namen des Modells gleich neu lesen
    G.ruf = jetzt
    namenTakt = namenTakt - 1
    if namenTakt <= 0 then                             -- der Name gehoert in den Schluessel, bevor gebaut wird: sonst baut die Suite zweimal
        namenTakt = 100
        anz.name = modellName()
        besitzMerken(suiteModul("app/pages/settings/dashboard/lib.lua"), rfsuite and rfsuite.preferences)
        local okg, gs = pcall(getGeneralSettings)      -- die Warnspannung des Senders fuer die Farbe seiner Akkuspannung
        local w = okg and type(gs) == "table" and tonumber(gs.battWarn) or nil
        if w and w > 0 then G.txWarn = w end
    end
    local key = "novafly|" .. farbe .. "|" .. T.sprache() .. "|" .. tostring(anz.name) .. "|" .. tostring(G.packFont)
    local ck = G.ck                                    -- ck.steht: der Schirm ist ganz gebaut, in dieser Farbe, Sprache und Schrift des Akkus
    if not (ck and ck.steht == farbe and ck.sprache == G.sprache and ck.packFont == G.packFont) and fehlt(farbe) > 1 then
        aufbau = aufbau + 1
        key = key .. "|aufbau " .. aufbau
    end
    return key
end

local function knopf(n, k, kinder, press, longpress)   -- ein Knopf im Kasten seiner Groesse (der Kasten schneidet den Rahmen von Rad und ENTER ab); kinder beginnen mit seinem Gesicht, um DX, DY zurueck
    n[#n + 1] = {type = "box", x = k[1], y = k[2], w = k[3], h = k[4], borderPad = 0, children = {
        {type = "button", x = 0, y = 0, w = k[3], h = k[4], cornerRadius = 0, color = FARBE.grau, children = kinder,
         press = press or function() end, longpress = longpress}}}
end

local function gesicht(k, datei)                       -- das Gesicht eines Knopfs: ein Ausschnitt des Grunds
    return {type = "image", x = -DX, y = -DY, w = k[3], h = k[4], file = ORDNER .. R.GFX .. datei}
end

local function rahmenBauen(f)                          -- Grund, Linien, Stacheln und der Absatz in der Farbe; die Batterie im Akku-Knopf
    local L = T.linien(f)
    local n = {{type = "image", x = 0, y = 0, w = R.W, h = R.H, file = ORDNER .. R.GFX .. "grund.png"}}
    R.cockpit(n, L)
    R.stacheln(n, ORDNER, f)
    local absatz, batterie = {}, {}
    R.absatz(absatz, ORDNER, f)
    R.batterie(batterie, L, KNOEPFE.akku[1] + DX, KNOEPFE.akku[2] + DY)   -- ihr Rahmen: das Gesicht des Akku-Knopfs verdeckt den Rahmen der Linien darunter
    return {farbe = f, n = n, absatz = absatz[1], batterie = batterie}
end

local function mitteBauen()                            -- Tacho, Tank, Beschriftungen und Woerter, Logo: in jeder Farbe und in Zone und Vollbild gleich
    local n = {}
    R.bogen(n, R.GROSS, GAUGE.cx, GAUGE.cy, ORDNER)   -- der Tacho: Bogen und Teilstriche, der Pfeil als Dreieck
    R.pfeil(n, function() return anz.pfeil end, function() return anz.pfeilDa == true end)
    for i = 1, U.tank.n do
        n[#n + 1] = {type = "rectangle", x = U.tank.x + (i - 1) * U.tank.schritt, y = U.tank.y, w = U.tank.bw, h = U.tank.bh, filled = true,
                     color = function() return anz.balkenFarbe end, visible = function() return anz.tank >= i end}
    end
    for _, l in ipairs(U.labels) do T.labelMittig(n, sx(l[1]), sy(l[2]), T.wort(l[3]), FARBE.w, F.s) end   -- die Beschriftungen in Senderschrift, die Woerter in der Sprache des Senders
    local tb = sx(52)                                 -- das Wort ueber dem Feld unten rechts wechselt mit dem Wert darunter
    n[#n + 1] = {type = "label", x = U.tempWort.x - tb, y = U.tempWort.y - floor(T.hoehe(F.s) / 2), w = 2 * tb, align = CENTER, font = F.s,
                 text = function() return anz.tempWort or "ESC" end, color = FARBE.w}
    n[#n + 1] = {type = "label", x = U.lastWort.x - px(14), y = U.lastWort.y - floor(T.hoehe(F.s) / 2), w = px(28), align = CENTER, font = F.s,
                 text = function() return anz.lastWort end, color = FARBE.w}
    local hb = R.GROSS800 and 120 or 66              -- RSSI und VFR oben rechts im Kopfband, wie im Theme fuer Ethos
    n[#n + 1] = {type = "label", x = U.rssi.x - hb, y = U.rssi.y - floor(T.hoehe(F.std) / 2), w = 2 * hb, align = CENTER, font = F.std,
                 text = function() return anz.rssi end, color = FARBE.w}
    n[#n + 1] = {type = "label", x = U.vfr.x - hb, y = U.vfr.y - floor(T.hoehe(F.s) / 2), w = 2 * hb, align = CENTER, font = F.s,
                 text = function() return anz.vfr end, color = function() return anz.vfrFarbe end}
    local lh = sy(24)                                 -- das Logo der Suite oben in der Mitte des Kopfbands, 400 : 84
    local lw = floor(lh * 400 / 84 + 0.5)
    n[#n + 1] = {type = "image", x = sx(240) - floor(lw / 2), y = sy(11), w = lw, h = lh, file = ORDNER .. R.GFX .. "rotorflight.png"}
    return n
end

local function werteBauen()                            -- die Werte: Zahl und Einheit je Feld (teile.lua wertKnoten)
    local n = {}
    for _, name in ipairs({"timer", "rpm", "bec", "tx", "amp", "cpu", "mcu", "pack", "pct", "temp", "alt", "rate", "bank"}) do
        T.wertKnoten(n, name, U[name])
    end
    return n
end

local function armWort(font, dx, dy)                   -- das Wort im ARM-Feld; im Vollbild als Kind seines Knopfs (Bild und Text nehmen keinen Druck)
    return {type = "label", x = ARM.x - dx, y = ARM.y + floor((ARM.h - T.hoehe(font)) / 2) - dy, w = ARM.w, align = CENTER,
            font = font, text = function() return anz.armText end, color = function() return anz.armTextF end}
end

local function armSchrift()                            -- die groesste Stufe, in der das laengste Wort ins ARM-Feld passt
    local armFont = F.l
    for _, stufe in ipairs({F.l, F.std, F.s}) do
        armFont = stufe
        if T.breite("DISARMED", stufe) <= ARM.w - 2 * DX - 4 then break end
    end
    return armFont
end

local function zoneBauen(font)                         -- im Zonenbild gibt es keine Knoepfe: das ARM-Feld, die Balken der Batterie und der Ring liegen frei
    local n = {{type = "rectangle", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, filled = true, rounded = py(10),
                color = function() return anz.armFarbe end}}
    for i = 1, U.batt.n do
        n[#n + 1] = {type = "rectangle", x = U.batt.x, y = sy(U.batt.y - (i - 1) * 6), w = U.batt.bw, h = U.batt.bh, filled = true,
                     color = function() return anz.balkenFarbe end, visible = function() return anz.balken >= i end}
    end
    n[#n + 1] = {type = "circle", x = RING.cx, y = RING.cy, radius = RING.r, filled = true, color = FARBE.ring}
    n[#n + 1] = {type = "circle", x = RING.cx, y = RING.cy, radius = RING.r - RING.rand, filled = true, color = FARBE.tief}
    return {n = n, arm = armWort(font, 0, 0)}
end

local function vollBauen(font)                         -- die Kinder der Knoepfe im Vollbild (die Knoepfe selbst baut jeder Bau)
    local ax, ay = KNOEPFE.akku[1] + DX, KNOEPFE.akku[2] + DY   -- die Balken der Batterie liegen im Akku-Knopf, darum als seine Kinder
    local batt = {}
    for i = 1, U.batt.n do
        batt[i] = {type = "rectangle", x = U.batt.x - ax, y = sy(U.batt.y - (i - 1) * 6) - ay, w = U.batt.bw,
                   h = U.batt.bh, filled = true, color = function() return anz.balkenFarbe end,
                   visible = function() return anz.balken >= i end}
    end
    local ox, oy = KNOEPFE.ring[1] + DX, KNOEPFE.ring[2] + DY   -- der Ring mit der Nadel, als Kinder des Knopfs (Kreise naehmen den Druck sonst weg)
    local ring = {gesicht(KNOEPFE.ring, "ring.png"),
                  {type = "circle", x = RING.cx - ox, y = RING.cy - oy, radius = RING.r, filled = true, color = FARBE.ring},
                  {type = "circle", x = RING.cx - ox, y = RING.cy - oy, radius = RING.r - RING.rand, filled = true, color = FARBE.tief},
                  {type = "triangle", x = 0, y = 0, w = 0, h = 0, color = FARBE.nadel,
                   pts = function() return anz.nadel end, visible = function() return anz.nadelDa == true end}}
    return {arm = {armWort(font, ARM.x + DX, ARM.y + DY)}, kopf = {gesicht(KNOEPFE.kopf, "kopf.png")},
            bank = {gesicht(KNOEPFE.bank, "tuer_bank.png")}, akku = gesicht(KNOEPFE.akku, "tuer_akku.png"), batt = batt, ring = ring}
end

local function festSchluessel() return tostring(T.sprache()) .. "|" .. tostring(G.packFont) end

fehlt = function(f)                                    -- wie viele Stuecke fuer diese Farbe noch fehlen: Rahmen, Mitte, Werte
    local ck, n = G.ck, 0
    if ck == nil or ck.rahmen == nil or ck.rahmen.farbe ~= f then n = n + 1 end
    local fest = ck and ck.fest
    if fest == nil or fest.schluessel ~= festSchluessel() then n = n + 2 elseif fest.werte == nil then n = n + 1 end
    return n
end

local function einStueck(f)                            -- baut das naechste fehlende Stueck; true, wenn danach keines mehr fehlt
    local ck = G.ck
    if ck == nil then
        ck = {}
        G.ck = ck                                      -- was nicht jeder Bau neu baut: Rahmen je Farbe, Mitte und Werte je Sprache und Schrift des Akkus (G uebersteht das Neuladen)
    end
    local s = festSchluessel()
    ck.steht = nil
    if ck.rahmen == nil or ck.rahmen.farbe ~= f then
        ck.rahmen = rahmenBauen(f)
    elseif ck.fest == nil or ck.fest.schluessel ~= s then
        ck.fest, ck.zone, ck.voll = {schluessel = s, mitte = mitteBauen(), font = armSchrift()}, nil, nil
    elseif ck.fest.werte == nil then
        ck.fest.werte = werteBauen()
    end
    return fehlt(f) == 0
end

local function zusammen(ck, ctx)                       -- der ganze Schirm aus den bereitliegenden Stuecken
    local r, fest = ck.rahmen, ck.fest
    local n = {}
    table.move(r.n, 1, #r.n, 1, n)
    if ctx ~= nil then                                 -- die Knoepfe des Vollbilds liegen ueber dem Rahmen (ein hohles Feld nimmt sonst den Druck)
        if ck.voll == nil then ck.voll = vollBauen(fest.font) end
        local v = ck.voll
        n[#n + 1] = {type = "box", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, borderPad = 0, children = {
            {type = "button", x = 0, y = 0, w = ARM.w, h = ARM.h, cornerRadius = py(10), children = v.arm,
             color = function() return anz.armFarbe end, press = function() ctx.action("openView:menu") end}}}
        knopf(n, KNOEPFE.kopf, v.kopf, function() end, farbeWeiter)
        knopf(n, KNOEPFE.bank, v.bank, function() ctx.action("openView:novafly_baenke") end)
        local akku = {v.akku, r.batterie[1], r.batterie[2]}
        table.move(v.batt, 1, #v.batt, 4, akku)
        knopf(n, KNOEPFE.akku, akku, function() ctx.action("openView:novafly_vorflug") end)
        knopf(n, KNOEPFE.ring, v.ring, bezugSetzen)
        if type(ctx.keys) == "table" then   -- die Seitentasten, sobald der Pilot sie auf Theme gestellt hat
            ctx.keys.pageDown = "openView:novafly_baenke"
            ctx.keys.pageUp = "openView:novafly_vorflug"
        end
    else
        if ck.zone == nil then ck.zone = zoneBauen(fest.font) end
        table.move(ck.zone.n, 1, #ck.zone.n, #n + 1, n)
    end
    n[#n + 1] = r.absatz
    if ctx == nil then n[#n + 1] = ck.zone.arm end
    table.move(fest.mitte, 1, #fest.mitte, #n + 1, n)
    table.move(fest.werte, 1, #fest.werte, #n + 1, n)
    local name = anz.name   -- der Modellname mittig unter dem Bogen, hoechstens 16 Zeichen
    if ck.name == nil or ck.name.text ~= name then
        local m = {}
        if name ~= nil then T.labelMittig(m, U.modell.x, U.modell.y, #name > 16 and string.sub(name, 1, 16) or name, FARBE.w, F.l) end
        ck.name = {text = name, knoten = m[1]}
    end
    if ck.name.knoten then n[#n + 1] = ck.name.knoten end
    return n
end

local function bauen(zone, state, ctx)
    farbe = T.farbeAus(state)
    G.farbeJetzt = farbe                                   -- fuer BAENKE: legt seine Bausteine schon beim Laden in dieser Farbe bereit
    if not geschluesselt then stand(state or {}) end       -- sonst hat renderKey den Stand eben gerechnet
    anz.name = modellName()
    if geschluesselt then
        einStueck(farbe)                                   -- je Aufruf hoechstens ein Stueck: EdgeTX gibt einem Widget je Aufruf eine feste Zahl Anweisungen
    else
        while not einStueck(farbe) do end                  -- ohne renderKey vorher (ein Pruefer ruft build allein): alles in einem Bau
    end
    local ck = G.ck
    if fehlt(farbe) > 0 then                               -- bis alle Stuecke da sind: der Grund mit dem Rahmen
        local n = {}
        table.move(ck.rahmen.n, 1, #ck.rahmen.n, 1, n)
        n[#n + 1] = ck.rahmen.absatz
        return n
    end
    ck.steht, ck.sprache, ck.packFont = farbe, G.sprache, G.packFont
    return zusammen(ck, ctx)
end

function M.build(zone, state, ctx)
    local ok, n = pcall(bauen, zone, state, ctx)
    if ok then
        merken("build " .. tostring(zone and zone.w) .. "x" .. tostring(zone and zone.h) .. " ctx " .. tostring(ctx ~= nil) .. ": "
               .. #n .. " Bausteine, Schrift " .. tostring(T.hoehe(F.s)) .. "/" .. tostring(T.hoehe(F.std)) .. "/" .. tostring(T.hoehe(F.l))
               .. "/" .. tostring(T.hoehe(F.xl)) .. "/" .. tostring(T.hoehe(F.xxl)) .. " hoch")
        return n
    end
    merken("build: " .. tostring(n))
    return {{type = "label", x = 10, y = 10, w = R.W - 20, text = tostring(n), color = FARBE.r}}
end

return M
