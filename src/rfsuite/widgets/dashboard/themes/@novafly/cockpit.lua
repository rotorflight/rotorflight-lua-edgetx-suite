-- NovaFly-Cockpit als Theme der Rotorflight-Suite fuer EdgeTX. Alles Feste kommt fertig gesetzt aus einem Skript;
-- hier steht nur, was sich aendert. Der Schirm wird EINMAL gebaut: jede Ziffer hat ihren festen Baustein, der Bild, Ort und
-- Sichtbarkeit selbst nachfragt. Ein neuer Wert baut nichts neu - ein Bau haelt den Sender rund eine Sekunde auf.
-- Der Ordner des Themes: mitgeliefert liegt es bei den Themes der Suite, als eigenes Theme des Piloten unter user/dashboard.
-- THEME_PFAD ist der Schluessel, unter dem die Suite seine Einstellungen fuehrt. Die Wurzeln der Karte nennt nur die Suite
-- (rfsuite.paths), dieses Skript schreibt sie nicht aus
local PFADE = rfsuite and rfsuite.paths or {}
local ORDNER, THEME_PFAD = PFADE.core and (PFADE.core .. "/widgets/dashboard/themes/@novafly/") or nil, "system/@novafly"
if ORDNER == nil or loadScript(ORDNER .. "init.lua", "t") == nil then
    if PFADE.user then ORDNER, THEME_PFAD = PFADE.user .. "/dashboard/novafly/", "user/novafly" end
end
local floor, byte, max, min = math.floor, string.byte, math.max, math.min

local RGB = lcd.RGB
local FARBE = {w = RGB(245, 248, 252), d = RGB(120, 132, 145), g = RGB(90, 255, 70), y = RGB(240, 210, 30),
               o = RGB(255, 130, 20), r = RGB(255, 80, 80)}
local C_GRAY, C_RED, C_GREEN = RGB(52, 56, 64), RGB(225, 40, 40), RGB(40, 180, 55)
local SYS_KLEIN = SMLSIZE or 0

local function sx(v) return floor(v * 800 / 480 + 0.5) end
local function sy(v) return floor(v * 480 / 320 + 0.5) end

local GAUGE = {cx = 239.5, cy = 171.5, d0 = 180, d1 = 0}
local BEZUG_OHNE_FLUG = 2000
local ARM = {x = sx(14), y = sy(14), w = sx(94), h = sy(28)}
local GRIFF = {x = 20, y = {21, 28, 35}, w = {12, 16, 12}, dick = 2}
local BATT = {x = 140, y = 294, bw = 13.2, bh = 5, gap = 1, n = 5}
local LUECKE = max(2, sx(4))
-- Felder mit Zahlen: Mitte in Bezugspunkten (480 x 320), Stufe der Schrift, Art, Einheit
local FELD = {
    timer = {64, 82, "xl", "timer"},
    bank = {40, 222, "s", "mitte"},
    rate = {86, 222, "s", "mitte"},
    rpm = {241, 116, "xl", "mitte"},
    bec = {417, 98, "xl", "wert2", "xlV"},
    tx = {417, 151, "xl", "wert2", "xlV"},
    amp = {417, 204, "xl", "wert2", "xlA"},
    pack = {214, 286, "xxl", "wert2", "xxlV"},
    pct = {307, 286, "xxl", "wert2", "xxlP"},
    temp = {422, 296, "xl", "wert2", "xlC"},
    zelle = {422, 286, "xl", "wert2", "xlV"},
}
local REIHE = {"timer", "bank", "rate", "rpm", "bec", "tx", "amp", "pack", "pct", "temp", "zelle"}
local REIHE_F = {}
for i = 1, #REIHE do REIHE_F[i] = REIHE[i] .. "F" end
-- je Feld: wie viele Ziffern es hoechstens zeigt, und welche Zeichen daneben vorkommen (58 Doppelpunkt, 46 Punkt, 45 Minus)
local STELLEN = {timer = 5, bank = 1, rate = 1, rpm = 5, bec = 3, tx = 3, amp = 4, pack = 3, pct = 3, temp = 3, zelle = 3}
local ZEICHEN = {timer = {58}, bec = {46}, tx = {46}, amp = {46, 45}, pack = {46}, temp = {45}, zelle = {46}}
local QUELLEN = {"voltage", "current", "rpm", "bec_voltage", "esc_temp", "mcu_temp", "pid_profile", "rate_profile",
                 "1RSS", "VFR", "RQly", "RT%", "CPU%"}

local function suiteModul(pfad)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, pfad)
        if ok and type(m) == "table" then return m end
    end
    return nil
end

-- die Suite laedt diese Datei bei jedem Wechsel der Flugphase neu; was geladen und gezeigt ist, bleibt in einem Modul des
-- Themes stehen, das der Lader der Suite haelt und beim Wechsel zu einem anderen Theme mit dessen Modulen wieder freigibt
-- (runtime.lua releaseUnusedThemes). Ohne den Lader (eine Probe am PC) in einem Globalen
local G = suiteModul(ORDNER .. "zustand.lua")
if G == nil then
    G = _G.NOVAFLY_THEME
    if type(G) ~= "table" then
        G = {}
        _G.NOVAFLY_THEME = G
    end
end
if G.anz == nil then G.anz, G.gesehen, G.lage, G.rpmHoch = {}, {}, {}, 0 end
local anz, gesehen, lage = G.anz, G.gesehen, G.lage
local D, ML = G.D, G.ML

-- eine Zeile ins Log der Suite (lib/log.lua, Stufe debug), jede nur einmal je geladener Datei
local gemerkt = {}
local function merken(text)
    text = tostring(text)
    if gemerkt[text] then return end
    gemerkt[text] = true
    local Log = suiteModul("lib/log.lua")
    if Log and type(Log.emit) == "function" then pcall(Log.emit, "novafly", text, "debug") end
end

local function laden(datei)
    local chunk = loadScript(ORDNER .. datei)
    if not chunk then merken(datei .. " fehlt") return nil end
    local ok, tab = pcall(chunk)
    if ok and type(tab) == "table" then return tab end
    merken(datei .. ": " .. tostring(tab))
    return nil
end

local FORMAT = {[0] = "%.0f", "%.1f", "%.2f"}
local function fmt(v, d)
    if v == nil then return nil end
    return string.format(FORMAT[d or 0], v)
end

local function fmtT(sec)
    sec = max(0, floor(sec + 0.5))
    return string.format("%02d:%02d", floor(sec / 60), sec % 60)
end

local function cellKey(v)
    if v == nil then return "w" end
    if v < 3.45 then return "r" end
    if v < 3.65 then return "o" end
    if v < 3.75 then return "y" end
    return "g"
end

local function ohneNull(key, v)
    if v == nil then return nil end
    if v ~= 0 then gesehen[key] = true end
    if v == 0 and not gesehen[key] then return nil end
    return v
end

local function rpmGrad(v)
    local voll = max(BEZUG_OHNE_FLUG, G.rpmHoch) * 1.25
    if v < 0 then v = 0 elseif v > voll then v = voll end
    local d = floor(GAUGE.d0 + (GAUGE.d1 - GAUGE.d0) * v / voll + 0.5)
    if d < 0 then d = 0 elseif d > 180 then d = 180 end
    return d - d % 2
end

local function zahlBreite(text, Z)
    local marke, li, re = 0, nil, nil
    for i = 1, #text do
        local c = byte(text, i)
        local a, b, adv
        if c >= 48 and c <= 57 then
            a, b, adv = marke, marke + Z.adv, Z.adv
        else
            local e = Z[c]
            if e then a, b, adv = marke + e[2], marke + e[2] + e[4], e[1] end
        end
        if adv then
            if li == nil or a < li then li = a end
            if re == nil or b > re then re = b end
            marke = marke + adv
        end
    end
    if li == nil then return 0, 0 end
    return re - li, li
end

-- legt fuer ein Feld fest, wo jede Ziffer, jedes Zeichen und die Einheit stehen und welches Bild sie zeigen; gerufen nur,
-- wenn sich Text oder Farbe des Felds geaendert haben
local function setzen(name, text, fk)
    local L = lage[name]
    if L == nil then
        L = {dx = {}, df = {}, zx = {}, zy = {}, zf = {}, zda = {}, nd = 0}
        lage[name] = L
    end
    L.text, L.fk = text, fk
    for c in pairs(L.zda) do L.zda[c] = false end
    if text == nil then
        L.nd, L.da = 0, false
        return
    end
    local f = FELD[name]
    local stufe = f[3]
    local Z = D.zahl[stufe]
    local zb, li = zahlBreite(text, Z)
    local links, oben
    if f[4] == "wert2" then
        local e = D.einheit[f[5]]
        links = sx(f[1]) - floor((zb + LUECKE + e[1]) / 2)
        oben = sy(f[2]) - floor(Z.h / 2)
        L.ux, L.uy = links + zb + LUECKE, oben + e[2]
    elseif f[4] == "timer" then
        links, oben = sx(f[1]) - floor(zb / 2), sy(f[2] + 14) + floor(Z.h / 2) - Z.h
    else
        links, oben = sx(f[1]) - floor(zb / 2), sy(f[2]) - floor(Z.h / 2)
    end
    local pfad, marke, nd = ORDNER .. "z/" .. stufe .. fk .. "/", links - li, 0
    for i = 1, #text do
        local c = byte(text, i)
        if c >= 48 and c <= 57 then
            nd = nd + 1
            L.dx[nd], L.df[nd] = marke + Z.zx, pfad .. c .. ".png"
            marke = marke + Z.adv
        else
            local e = Z[c]
            if e then
                L.zx[c], L.zy[c], L.zf[c], L.zda[c] = marke + e[2], oben + e[3], pfad .. c .. ".png", true
                marke = marke + e[1]
            end
        end
    end
    L.nd, L.dy, L.da = nd, oben + Z.zy, true
end

local dJetzt = nil
local function g(k) return tonumber(dJetzt[k]) end

-- liest den Zustand der Suite und legt in anz und lage ab, was auf dem Schirm steht
local function stand(state)
    dJetzt = state.derived or {}
    local link = state.rfConnected == true
    local pack, cell, rpm, temp, mcutemp, bec, bank, rate, last, cpu, timer, rssi, vfr, scharf
    if link then
        pack = ohneNull("pack", g("voltage") or tonumber(state.voltage))
        local zellen = tonumber(state.batteryCellCount)
        if pack ~= nil and zellen ~= nil and zellen >= 1 then cell = pack / zellen end
        rssi, vfr = g("1RSS"), g("VFR") or g("RQly")
        rpm = g("rpm") or tonumber(state.rpm)
        if rpm and rpm > G.rpmHoch then G.rpmHoch = rpm end
        temp = ohneNull("temp", g("esc_temp"))
        mcutemp = g("mcu_temp")
        if mcutemp ~= nil and (mcutemp < 10 or mcutemp > 130) then mcutemp = nil end
        if state.armed ~= nil then scharf = (state.armed == true) end
        bec = ohneNull("bec", g("bec_voltage"))
        bank, rate = g("pid_profile") or tonumber(state.profile), g("rate_profile")
        last = ohneNull("last", g("current"))
        -- die Last im Kopf: zuerst RT Load, sonst CPU Load; das Wort davor folgt dem Sensor, der liefert, und bleibt stehen
        cpu = g("RT%")
        if cpu ~= nil then
            anz.lastWort = "RT"
        else
            cpu = g("CPU%")
            if cpu ~= nil then anz.lastWort = "CPU" end
        end
        if cpu ~= nil and (cpu < 0 or cpu > 100) then cpu = nil end
        timer = tonumber(state.flightSeconds)
    end
    local tx = nil
    local ok, tv = pcall(getValue, "tx-voltage")
    if ok and type(tv) == "number" and tv > 0 then tx = tv end

    anz.arm = (not link) and "link" or ((scharf == true) and "scharf" or ((scharf == false) and "sicher" or "unbekannt"))
    anz.armFarbe = (scharf == true and link) and C_GREEN or ((scharf == false and link) and C_RED or C_GRAY)
    anz.timer, anz.timerF = timer and fmtT(timer) or nil, "g"
    local bf = (bank ~= nil and rate ~= nil and bank ~= rate) and "r" or "g"
    anz.bank, anz.bankF = fmt(bank), bf
    anz.rate, anz.rateF = fmt(rate), bf
    anz.rpm, anz.rpmF = fmt(rpm), "g"
    anz.bec, anz.becF = fmt(bec, 1), (bec and bec >= 5.0) and "g" or "y"
    anz.tx, anz.txF = fmt(tx, 1), tx and ((tx >= 7.4) and "g" or ((tx >= 7.0) and "y" or "r")) or "g"
    anz.amp, anz.ampF = fmt(last, 1), "g"
    local ck = cellKey(cell)
    anz.pack, anz.packF = fmt(pack, 1), ck
    local p = nil
    if cell then
        p = (cell - 3.5) / 0.7 * 100
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
    end
    anz.pct, anz.pctF = fmt(p), ck
    anz.temp, anz.tempF = fmt(temp), temp and ((temp < 60) and "g" or ((temp < 80) and "y" or "r")) or "g"
    anz.zelle, anz.zelleF = (temp == nil) and fmt(cell, 2) or nil, ck
    anz.balken, anz.balkenFarbe = 0, FARBE[ck]
    if cell then
        local a = (cell - 3.5) / 0.7
        if a < 0 then a = 0 elseif a > 1 then a = 1 end
        anz.balken = floor(a * BATT.n + 0.5)
    end
    anz.mcu = "MCU " .. (mcutemp and (fmt(mcutemp) .. " \194\176C") or "--")
    anz.mcuFarbe = FARBE[mcutemp and ((mcutemp < 70) and "g" or ((mcutemp < 90) and "y" or "r")) or "d"]
    anz.cpu = (anz.lastWort or "CPU") .. " " .. (cpu and (fmt(cpu) .. " %") or "--")
    anz.cpuFarbe = FARBE[cpu and ((cpu < 50) and "g" or ((cpu < 80) and "y" or "r")) or "d"]
    anz.rssi = rssi and ("RSSI " .. fmt(rssi) .. "dB") or ""
    anz.vfr = vfr and ("VFR " .. fmt(vfr)) or ""
    anz.vfrFarbe = FARBE[vfr and ((vfr >= 90) and "w" or ((vfr >= 80) and "y" or "r")) or "w"]
    if rpm ~= nil then
        local grad = rpmGrad(rpm)
        if grad ~= anz.grad then
            local a = grad * math.pi / 180
            local rm, kante = D and D.zeiger.rm or 74, D and D.zeiger.kante or 96
            anz.grad = grad
            anz.nx = sx(GAUGE.cx + rm * math.cos(a)) - floor(kante / 2)
            anz.ny = sy(GAUGE.cy - rm * math.sin(a)) - floor(kante / 2)
            anz.nadel = ORDNER .. "n/" .. grad .. ".png"
        end
    else
        anz.grad = nil
    end

    if D then
        for i = 1, #REIHE do
            local name = REIHE[i]
            local t, f = anz[name], anz[REIHE_F[i]]
            local L = lage[name]
            if L == nil or L.text ~= t or L.fk ~= f then setzen(name, t, f) end
        end
    end
end

local function modellName()
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
    return nil
end

-- die festen Bausteine eines Zahlenfelds: je Stelle eine Ziffer, dazu seine Zeichen und seine Einheit; ox, oy ist der
-- Ursprung, wenn das Feld im Knopf zum Schirm BANK liegt
local function zahlKnoten(n, name, ox, oy)
    local L = lage[name]
    local f = FELD[name]
    local Z = D.zahl[f[3]]
    local ruhe = ORDNER .. "z/" .. f[3] .. "g/"
    local null = ruhe .. "48.png"
    for k = 1, STELLEN[name] do
        n[#n + 1] = {type = "image", w = Z.zw, h = Z.zh,
                     file = function() return L.df[k] or null end,
                     pos = function() return (L.dx[k] or 0) - ox, (L.dy or 0) - oy end,
                     visible = function() return k <= L.nd end}
    end
    local zs = ZEICHEN[name]
    if zs then
        for j = 1, #zs do
            local c = zs[j]
            local e = Z[c]
            if e then
                local leer = ruhe .. c .. ".png"
                n[#n + 1] = {type = "image", w = e[4], h = e[5],
                             file = function() return L.zf[c] or leer end,
                             pos = function() return (L.zx[c] or 0) - ox, (L.zy[c] or 0) - oy end,
                             visible = function() return L.zda[c] == true end}
            end
        end
    end
    if f[4] == "wert2" then
        local e = D.einheit[f[5]]
        n[#n + 1] = {type = "image", w = e[3], h = e[4], file = ORDNER .. "w/x/e_" .. f[5] .. ".png",
                     pos = function() return (L.ux or 0) - ox, (L.uy or 0) - oy end,
                     visible = function() return L.da == true end}
    end
end

local function festBild(n, tuer, ort, datei, sichtbar)
    local x, y = ort[1], ort[2]
    if tuer and tuer.lagen[ort] then n, x, y = tuer.kinder, x - tuer.dx, y - tuer.dy end
    n[#n + 1] = {type = "image", x = x, y = y, w = ort[3], h = ort[4], file = ORDNER .. datei, visible = sichtbar}
end

local function nameBauen(n, text)
    if not ML or text == nil then return end
    if #text > 16 then text = string.sub(text, 1, 16) end
    local zuege, marke, links, rechts = {}, 0, nil, nil
    for i = 1, #text do
        local c = byte(text, i)
        local e = ML[c]
        if e == nil then return end
        local adv, mitte, zi = e[5], 0, (c >= 48 and c <= 57)
        if zi then adv, mitte = ML.ziffer, floor((ML.ziffer - e[5]) / 2) end
        local a, b = marke, marke + adv
        if not zi then a, b = marke + mitte + e[1], marke + mitte + e[1] + e[3] end
        if e[3] > 0 or zi then
            if links == nil or a < links then links = a end
            if rechts == nil or b > rechts then rechts = b end
        end
        if e[3] > 0 then zuege[#zuege + 1] = {marke + mitte + e[1], e[2], c, e[3], e[4]} end
        marke = marke + adv
    end
    if links == nil then return end
    local px, py = sx(241) - floor((rechts - links) / 2) - links, sy(228) - floor(ML.hoehe / 2)
    for i = 1, #zuege do
        local z = zuege[i]
        n[#n + 1] = {type = "image", x = px + z[1], y = py + z[2], w = z[4], h = z[5], file = ORDNER .. "z/lw/" .. z[3] .. ".png"}
    end
end

local M = {}
local FARBWORT = {"blau", "tuerkis", "gruen", "gelb", "gold", "orange", "rot", "magenta", "violett", "silber"}
local FARBE_NR = {}
for i = 1, #FARBWORT do FARBE_NR[FARBWORT[i]] = i end
local farbe = "blau"

-- die Farbe steht in den Theme-Einstellungen der Suite: in den Standardwerten des Senders oder in den eigenen Werten des
-- Modells, wenn es welche hat. Die Suite reicht sie als state.themeConfig; ohne Eintrag oder mit einem fremden Wort gilt Blau.
-- Nach einem langen Druck gilt die neue Farbe sofort (G.farbeNeu), bis die Suite ihre Einstellungen neu gereicht hat: nach
-- einem Flug ohne Verbindung schiebt sie das Neuladen auf, und ohne das stuende das Cockpit auf der alten Farbe
local function farbeAus(state)
    local c = state and state.themeConfig
    local wort = type(c) == "table" and c.colour or nil
    local neu = G.farbeNeu
    if type(neu) == "table" then
        if wort ~= neu.vorher then G.farbeNeu = nil   -- die Suite hat neu geladen: ab jetzt gilt, was sie reicht
        else wort = neu.farbe end
    end
    if FARBE_NR[wort] then return wort end
    return "blau"
end

-- Wem die Farbe gehoert: dem Modell (eigene Werte eingeschaltet) oder dem Sender. Solange der Heli da ist, sieht das Theme
-- die Werte des Modells und merkt sich die Antwort (G.besitz). Nach dem Abstecken reicht die Suite dem Theme weiter die Werte
-- des Modells, zeigt sie ihm aber nicht mehr - dann gilt das Gemerkte, und gleiche Farben beweisen keinen gleichen Besitzer
local function besitzMerken(Lib, prefs)
    local session = rfsuite and rfsuite.session
    local id = type(session) == "table" and session.mcu_id or nil
    local modelPrefs = (id and type(session.modelPreferences) == "table") and session.modelPreferences or nil
    if modelPrefs == nil or Lib == nil or type(Lib.modelOverridesActive) ~= "function" then return end
    local dashboard = type(prefs) == "table" and type(prefs.dashboard) == "table" and prefs.dashboard or {}
    G.besitz = {id = id, modell = Lib.modelOverridesActive(dashboard, modelPrefs.dashboard) == true}
end

-- die neue Farbe in denselben Speicher, den die Einstellungsseite des Themes schreibt: in die eigenen Werte des Modells, wenn
-- sie der Farbe gehoeren, sonst in die Standardwerte des Senders. Die Suite liest ihre Einstellungen danach neu; bis dahin
-- zeigt das Cockpit die neue Farbe aus G.farbeNeu
local function farbeSpeichern(neu, state)
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
        G.farbeNeu = {farbe = neu, vorher = vorher}
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
        -- nichts gemerkt (kein Heli, seit das Theme geladen ist). Nach einem Flug ohne Verbindung haelt die Suite noch die Werte
        -- des letzten Modells, und eine Farbe, die nicht der Standard des Senders ist, kommt von einem Modell: beides heisst, der
        -- Standard wuerde hinter einem Cockpit geaendert, das nicht folgt - dann tut der Druck nichts
        if state and state.hadInflightFlight == true and state.rfConnected ~= true then return false end
        local dashboard = type(prefs.dashboard) == "table" and prefs.dashboard or {}
        local standard = dashboard["cfg_" .. string.gsub(THEME_PFAD, "[^%w]", "_") .. "_colour"]
        if (standard or "blau") ~= farbe then return false end
    end
    local Prefs = suiteModul("lib/preferences.lua")
    if Prefs == nil or type(Prefs.save) ~= "function" then return false end
    Lib.setThemeConfig(prefs, THEME_PFAD, {colour = neu}, nil)
    return Prefs.save(prefs) == true and gilt()
end

-- ein langer Druck auf den Kopf oben: die naechste Farbe der Reihe, mit Pieps, nur am Boden
local letzterState = nil
local function farbeWeiter()
    if anz.arm == "scharf" then return end
    local neu = FARBWORT[(FARBE_NR[farbe] or 1) % #FARBWORT + 1]
    local ton = _G.playTone
    if farbeSpeichern(neu, letzterState) and ton then pcall(ton, 880, 120, 0) end
end
local schritt = (D and ML ~= nil) and 2 or ((D and 1) or 0)

function M.sources() return QUELLEN end

local namenTakt = 0
local PAUSE = 300                                   -- in Hundertstelsekunden: im Betrieb ruft die Suite das Cockpit in kuerzeren Abstaenden
function M.renderKey(zone, state)
    local ok, grund = pcall(stand, state or {})
    if not ok then merken("stand: " .. tostring(grund)) end
    letzterState = state
    farbe = farbeAus(state)
    local jetzt = getTime and getTime() or 0
    if G.ruf and jetzt - G.ruf > PAUSE then namenTakt = 0 end   -- nach einer Pause den Namen des Modells gleich neu lesen
    G.ruf = jetzt
    namenTakt = namenTakt - 1
    if namenTakt <= 0 then                          -- der Name gehoert in den Schluessel, bevor gebaut wird: sonst baut die Suite zweimal
        namenTakt = 100
        anz.name = modellName()
        besitzMerken(suiteModul("app/pages/settings/dashboard/lib.lua"), rfsuite and rfsuite.preferences)
    end
    return "novafly|" .. farbe .. "|" .. schritt .. "|" .. tostring(anz.name)
end

local function bauen(zone, state, ctx)
    local n = {}
    farbe = farbeAus(state)
    n[#n + 1] = {type = "image", x = 0, y = 0, w = 800, h = 480, file = ORDNER .. "gfx/cockpit_" .. farbe .. ".png"}
    if schritt == 0 then              -- das Laden auf drei Aufrufe verteilt: je Aufruf hat ein Widget 20 000 Rechenschritte
        D = laden("daten.lua")
        G.D = D
        schritt = D and 1 or 0
        return n
    end
    if schritt == 1 then
        ML = laden("masse_l.lua") or false
        G.ML = ML
        schritt = 2
        return n
    end
    if G.sprache == nil then
        G.sprache = "en"
        local ok, e = pcall(getGeneralSettings)
        local s = ok and type(e) == "table" and type(e.language) == "string" and string.lower(e.language) or nil
        if s and D.worte[s] then G.sprache = s end
    end
    local sprache = G.sprache
    stand(state or {})
    anz.name = modellName()

    -- der Kopf oben ist im Vollbild ein Knopf wie in NovaFly: ein langer Druck schaltet die Farbe weiter. Sein Gesicht ist ein
    -- Ausschnitt des Grundbilds; was im Kopf steht, liegt darueber (Bilder und Texte nehmen keinen Druck)
    if ctx ~= nil and D.kopf then
        local k = D.kopf
        n[#n + 1] = {type = "box", x = k[1], y = k[2], w = k[3], h = k[4], borderPad = 0, children = {
            {type = "button", x = 0, y = 0, w = k[3], h = k[4], cornerRadius = 0, color = C_GRAY,
             children = {{type = "image", x = -10, y = -5, w = k[3], h = k[4], file = ORDNER .. "gfx/kopf_" .. farbe .. ".png"}},
             press = function() end, longpress = farbeWeiter}}}
    end

    local W, o = D.worte[sprache], "w/" .. sprache .. "/"
    -- das Feld BANK/RATE ist im Vollbild der Knopf zum Schirm BANK: sein Gesicht ist ein Ausschnitt des Grundbilds, die Woerter
    -- und Ziffern sind seine Kinder (ein Bild ueber einem Knopf naehme den Druck weg)
    local tuer = nil
    if ctx ~= nil and D.tuer then
        local t = D.tuer
        local kinder = {{type = "image", x = -10, y = -5, w = t[3], h = t[4], file = ORDNER .. "gfx/tuer_" .. farbe .. ".png"}}
        tuer = {kinder = kinder, dx = t[1] + 10, dy = t[2] + 5,
                lagen = {[W.bank] = true, [W.rate] = true, [D.frage.bank] = true, [D.frage.rate] = true}}
        n[#n + 1] = {type = "box", x = t[1], y = t[2], w = t[3], h = t[4], borderPad = 0, children = {
            {type = "button", x = 0, y = 0, w = t[3], h = t[4], cornerRadius = 0, color = C_GRAY, children = kinder,
             press = function() ctx.action("openView:novafly_bank") end}}}
    end
    festBild(n, tuer, W.bank, o .. "bank.png")
    festBild(n, tuer, W.rate, o .. "rate.png")
    festBild(n, tuer, W.bec, o .. "bec.png")
    festBild(n, tuer, W.tx, o .. "tx.png")
    festBild(n, tuer, W.esc, o .. "esc.png")
    festBild(n, tuer, W.rpm, o .. "rpm.png")
    festBild(n, tuer, W.timer, o .. "timer.png")
    festBild(n, tuer, W.escUnten, o .. "escUnten.png", function() return anz.temp ~= nil end)

    -- das ARM-Feld ist im Vollbild selbst der Knopf zum Schnellmenue der Suite; ein Rechteck darueber wuerde den Druck schlucken,
    -- darum sind die drei Striche Linien
    local armWorte, dx, dy = n, 0, 0
    if ctx ~= nil then
        -- die Woerter sind Kinder des Knopfs (ein Bild darueber naehme den Druck weg); Kinder sitzen im Inneren des Knopfs:
        -- Rand 2, Abstand 8 und 3 bei 800 Punkten Breite (etx_lv_theme, wie themes/deck/layout.lua buttonInset)
        armWorte, dx, dy = {}, ARM.x + 10, ARM.y + 5
        -- der Knopf sitzt in einem Kasten seiner Groesse: der schneidet den Rahmen ab, den EdgeTX um den Knopf unter Rad und
        -- ENTER zeichnet
        n[#n + 1] = {type = "box", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, borderPad = 0, children = {
            {type = "button", x = 0, y = 0, w = ARM.w, h = ARM.h, cornerRadius = 10, children = armWorte,
             color = function() return anz.armFarbe end, press = function() ctx.action("openView:menu") end}}}
    else
        n[#n + 1] = {type = "rectangle", x = ARM.x, y = ARM.y, w = ARM.w, h = ARM.h, filled = true, rounded = 10,
                     color = function() return anz.armFarbe end}
    end
    for _, name in ipairs({"link", "scharf", "sicher", "unbekannt"}) do
        local ort = D.arm[name]
        armWorte[#armWorte + 1] = {type = "image", x = ort[1] - dx, y = ort[2] - dy, w = ort[3], h = ort[4],
                                   file = ORDNER .. "w/x/arm_" .. name .. ".png", visible = function() return anz.arm == name end}
    end
    for k = 1, 3 do
        local y = sy(GRIFF.y[k]) + 1
        n[#n + 1] = {type = "line", x = 0, y = 0, w = 0, h = 0, thickness = sy(GRIFF.dick),
                     pts = {{sx(GRIFF.x), y}, {sx(GRIFF.x) + sx(GRIFF.w[k]), y}}, color = (k == 2) and FARBE.w or FARBE.d}
    end

    n[#n + 1] = {type = "label", x = sx(338) - 120, y = sy(18) - 8, w = 240, align = CENTER, font = SYS_KLEIN,
                 text = function() return anz.mcu end, color = function() return anz.mcuFarbe end}
    n[#n + 1] = {type = "label", x = sx(338) - 120, y = sy(32) - 8, w = 240, align = CENTER, font = SYS_KLEIN,
                 text = function() return anz.cpu end, color = function() return anz.cpuFarbe end}
    n[#n + 1] = {type = "label", x = sx(413) - 120, y = sy(22) - 10, w = 240, align = CENTER, font = 0,
                 text = function() return anz.rssi end, color = FARBE.w}
    n[#n + 1] = {type = "label", x = sx(413) - 120, y = sy(36) - 8, w = 240, align = CENTER, font = SYS_KLEIN,
                 text = function() return anz.vfr end, color = function() return anz.vfrFarbe end}

    festBild(n, tuer, D.timerLeerGross, "w/x/timer_leer_xl.png", function() return anz.timer == nil end)
    for i = 1, 3 do festBild(n, tuer, D.timerLeer[i], "w/x/timer_leer_std.png") end
    festBild(n, tuer, D.frage.bank, "w/x/frage_s.png", function() return anz.bank == nil end)
    festBild(n, tuer, D.frage.rate, "w/x/frage_s.png", function() return anz.rate == nil end)
    festBild(n, tuer, D.leer.bec, "w/x/leer_xl.png", function() return anz.bec == nil end)
    festBild(n, tuer, D.leer.tx, "w/x/leer_xl.png", function() return anz.tx == nil end)
    festBild(n, tuer, D.leer.amp, "w/x/leer_xl.png", function() return anz.amp == nil end)
    festBild(n, tuer, D.leer.temp, "w/x/leer_xl.png", function() return anz.temp == nil and anz.zelle == nil end)

    for i = 1, BATT.n do
        n[#n + 1] = {type = "rectangle", x = sx(BATT.x), y = sy(BATT.y - (i - 1) * (BATT.bh + BATT.gap)), w = sx(BATT.bw),
                     h = sy(BATT.bh), filled = true, color = function() return anz.balkenFarbe end,
                     visible = function() return anz.balken >= i end}
    end

    local kante = D.zeiger.kante
    n[#n + 1] = {type = "image", w = kante, h = kante, file = function() return anz.nadel end,
                 pos = function() return anz.nx or 0, anz.ny or 0 end, visible = function() return anz.grad ~= nil end}

    for i = 1, #REIHE do
        local name = REIHE[i]
        if tuer and (name == "bank" or name == "rate") then
            zahlKnoten(tuer.kinder, name, tuer.dx, tuer.dy)
        else
            zahlKnoten(n, name, 0, 0)
        end
    end
    nameBauen(n, anz.name)

    return n
end

function M.build(zone, state, ctx)
    local ok, n = pcall(bauen, zone, state, ctx)
    if ok then
        merken("build " .. tostring(zone and zone.w) .. "x" .. tostring(zone and zone.h) .. " ctx " .. tostring(ctx ~= nil) .. ": "
               .. #n .. " Bausteine")
        return n
    end
    merken("build: " .. tostring(n))
    return {{type = "label", x = 10, y = 10, w = 780, text = tostring(n), color = FARBE.r}}
end

return M
