-- BAENKE: das Display rechts vom Cockpit (init.lua views; PAGE rechts oder ein Tipp auf BANK), auf dem Grund des Cockpits, die
-- Linien laufen von links herein. Oben der Antrieb der Bank (Governor, Solldrehzahl, Hochlauf, Gain), darunter vier Chips mit
-- der Drehrate je Achse und drei mit den Gains je Achse. Rechts ein stehender Drehzahlbalken: die gemessene Drehzahl gegen das
-- Soll der Bank, gruen bis zum Soll, gelb knapp darueber, rot zu hoch, mit der Marke der hoechsten Drehzahl dieser Bank. Die
-- Werte liest die Seite ueber den MSP-Dienst der Suite; ein Wechsel von Bank oder Rate liest neu. Ein Tipp oder RTN fuehrt zurueck.
local PFADE = rfsuite and rfsuite.paths or {}
local ORDNER = PFADE.core and (PFADE.core .. "/widgets/dashboard/themes/@novafly/") or nil
if ORDNER == nil or loadScript(ORDNER .. "init.lua", "t") == nil then
    if PFADE.user then ORDNER = PFADE.user .. "/dashboard/novafly/" end
end
local floor = math.floor

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
if T == nil then return {build = function(children) children[#children + 1] = {type = "label", x = 10, y = 10, w = (tonumber(LCD_W) or 800) - 20, text = "teile.lua fehlt", color = lcd.RGB(255, 80, 80)} end} end
local G, R, FARBE, F = T.G, T.R, T.FARBE, T.F
local anz = G.anz
local sx, sy = R.sx, R.sy
local DX, DY = R.KNOPF_DX, R.KNOPF_DY
local P = nil                                          -- die Bausteine der Seiten (seiten.lua)
do
    local chunk = loadScript(ORDNER .. "seiten.lua")
    local ok, bau = false, nil
    if chunk then ok, bau = pcall(chunk) end
    if ok and type(bau) == "function" then P = bau(T) end
end

local LINKS, RECHTS = 10, 376                          -- die Flucht der Chips: beide Reihen beginnen und enden gleich
local RATE_CHIP = {y = 66, h = 58, n = 4, luecke = 6}
local GAIN_CHIP = {y = 136, h = 104, n = 3, luecke = 6}
local BALKEN = {x = 440, w = 24, oben = 62, unten = 300, rand = 4}   -- der Rahmen des Balkens; die Saeule bleibt rand innerhalb
local ZONEN_X, ZONEN_W = 467, 3                        -- der Streifen der Zonen rechts am Balken
local SKALA, GELB_AB = 1.25, 1.08                      -- der Balken reicht bis 125 % der Solldrehzahl; gelb ab dem Soll, rot ab 108 %
local IST_X, IST_W = 386, 94                           -- die gemessene Drehzahl oben ueber dem Balken
local BANK_RX, BANK_Y, BANK_SCHRITT = 434, 150, 30     -- BANK 1 2 3 rechtsbuendig neben dem Balken
local FUSS_Y = 277
local RATE_TYP = {[0] = "NONE", "BETAFLIGHT", "RACEFLIGHT", "KISS", "ACTUAL", "QUICK", "ROTORFLIGHT"}
local GOV_MODUS = {[0] = "OFF", "LIMIT", "DIRECT", "ELECTRIC", "NITRO"}   -- gov_mode der Firmware; bei 3 und 4 regelt der FC die Drehzahl
local GOV_MODUS_ALT = {[0] = "OFF", "PASSTHROUGH", "STANDARD", "MODE1", "MODE2"}   -- unter API 12.09; ab 2 regelt der FC
local GRAD_S, GRAD = "\194\176/s", "\194\176"
local RATE_REGEL = {   -- rcRates je Ratentyp wie NovaFly: {mal, teiler, Stellen} fuer Achse 1-3 und Kollektiv, angezeigt roh * mal / teiler
    [0] = {{1, 1, 0}, {1, 1, 0}}, {{1, 100, 2}, {1, 100, 2}}, {{10, 1, 0}, {1, 4, 1}, GRAD_S}, {{1, 100, 2}, {1, 100, 2}},   -- NONE, BETAFLIGHT, RACEFLIGHT, KISS
    {{10, 1, 0}, {1, 4, 1}}, {{1, 100, 2}, {1, 100, 2}}, {{5, 1, 0}, {5, 40, 2}, GRAD_S}}   -- ACTUAL, QUICK, ROTORFLIGHT; das Kollektiv ist dort ein Winkel
local SCHUB, MUSTER = {[0] = 1, 10, 100}, {"%.1f", "%.2f"}
local RATE_ACHSEN = {"ROLL", "NICK", "HECK", "KOLL."}
local KETTE = {{"pid_tuning", "pid", "PID"}, {"rc_tuning", "rc", "RATEN"}, {"governor_config", "gov", "GOVERNOR"}, {"governor_profile", "govProfil", "GOVERNOR"}}
local FRIST, PAUSE = 14, 3                             -- eine Frage ohne Antwort ist nach 14 s verloren; nach einem Fehler liest der Takt nach 3 s neu
local GRUEN, GELB, ROT = R.rgb(R.GRUEN), R.rgb(R.GELB), R.rgb(R.ROT)

local M = {}
function M.sources() return {"rpm", "pid_profile", "rate_profile"} end

local function jetzt()                                 -- Sekunden seit dem Start des Senders
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

if G.bkLesen == nil then G.bkLesen = {gen = 0, laeuft = false, werte = {}} end   -- die Lesekette ueberlebt das Neuladen der Seite je Flugphase
local L = G.bkLesen
L.stand = L.stand or 0                                 -- zaehlt jede Aenderung an L.werte: nur dann rechnet stand() die Werte vom FC neu

local function kette(g, i)                             -- liest die vier Saetze nacheinander; ein Fehler steht im Fuss, die Kette laeuft weiter
    local glied = KETTE[i]
    if glied == nil then
        L.laeuft = false
        if L.kettenFehler then L.nochmal = jetzt() + PAUSE else L.werte.fehler, L.nochmal = nil, nil end
        L.stand = L.stand + 1
        return
    end
    L.gefragt, L.glied = jetzt(), i
    if not P.lesen(glied[1], function(w, grund)
        if g ~= L.gen then return end
        if w ~= nil then L.werte[glied[2]] = w
        else
            L.kettenFehler = true
            if grund ~= "cleared" then L.werte.fehler = glied[3] end   -- cleared: die Suite hat ihre Schlange geleert (scharf, Verbindung weg), kein Fehler des FC
        end
        L.stand = L.stand + 1
        kette(g, i + 1)
    end) then
        L.werte.fehler, L.laeuft, L.nochmal = "MSP", false, jetzt() + PAUSE
        L.stand = L.stand + 1
    end
end

local function anstossen(s, behalten)                  -- behalten: dieselbe Bank und Rate noch einmal, was schon gelesen ist, bleibt stehen
    if L.laeuft then return end
    L.laeuft, L.gen, L.kettenFehler, L.nochmal = true, L.gen + 1, false, nil
    if not behalten then
        L.werte = {}
        L.fuer = {bank = s.bank and floor(s.bank) or nil, rate = s.rate and floor(s.rate) or nil}
        L.stand = L.stand + 1
    end
    kette(L.gen, 1)
end

local function takt(s)                                 -- jeder Aufruf: ein Wechsel von Bank oder Rate liest neu; eine verlorene Frage und ein Fehler werden neu gelesen
    if P == nil then return end
    if L.neu then L.neu = false anstossen(s) return end
    if L.fuer == nil then return end
    local t = jetzt()
    if L.laeuft then
        if t - (L.gefragt or t) < FRIST then return end
        L.gen, L.laeuft = L.gen + 1, false
        L.werte.fehler, L.nochmal = KETTE[L.glied or 1][3], t + PAUSE
        L.stand = L.stand + 1
    end
    local bank, rate = s.bank and floor(s.bank) or nil, s.rate and floor(s.rate) or nil
    if bank ~= L.fuer.bank or rate ~= L.fuer.rate then anstossen(s)
    elseif L.nochmal ~= nil and t >= L.nochmal then anstossen(s, true) end
end

local function zahl(v)
    if v == nil then return "--", P.LEISE end
    return tostring(floor(v + 0.5)), FARBE.g
end

local function chipLage(c, i)                          -- x und Breite des i-ten Chips einer Reihe: alle in derselben Flucht LINKS..RECHTS
    local w = floor((RECHTS - LINKS - (c.n - 1) * c.luecke) / c.n)
    return LINKS + (i - 1) * (w + c.luecke), w
end

local function raten(r)                                -- die Zahl je Achse nach der Regel des Ratentyps wie NovaFly, mit Punkt wie die anderen Zahlen
    local regel = r.rates_type and RATE_REGEL[floor(r.rates_type)]
    for i = 1, 4 do
        local roh, m = r["rcRates_" .. i], regel and regel[i < 4 and 1 or 2]
        local z, e = nil, nil
        if roh ~= nil and m ~= nil then
            local schub = SCHUB[m[3]]
            local ganz = floor(roh / m[2] * schub * m[1] + 0.5)
            z = m[3] > 0 and string.format(MUSTER[m[3]], ganz / schub) or tostring(ganz)
            e = regel[3] and (i < 4 and regel[3] or GRAD) or nil
        end
        anz["bkRate" .. i], anz["bkRateF" .. i], anz["bkRateE" .. i] = z or "--", z and FARBE.g or P.LEISE, z and e or ""
    end
end

local BANK_F = {"bkBankF1", "bkBankF2", "bkBankF3"}    -- die Farbe von BANK 1 2 3 in anz
local PID_NAMEN = {}                                   -- je Achse und Gain: das Feld in anz, seine Farbe und das Feld im Satz PID_TUNING
for a = 0, 2 do
    for _, b in ipairs({"P", "I", "D", "F", "B", "O"}) do
        PID_NAMEN[#PID_NAMEN + 1] = {"bkP" .. a .. b, "bkP" .. a .. b .. "F", "pid_" .. a .. "_" .. b}
    end
end

local function werteVomFC(w, alt, uMin)                -- was aus den gelesenen Saetzen kommt; nur neu, wenn sich L.werte geaendert hat
    local g, p, r = w.gov or {}, w.govProfil or {}, w.rc or {}
    local m = g.gov_mode and floor(g.gov_mode)
    local modus = m and (alt and GOV_MODUS_ALT or GOV_MODUS)[m] or nil
    anz.bkGov, anz.bkGovF = modus or "--", modus and FARBE.g or P.LEISE
    anz.bkDz, anz.bkDzF = zahl(p.governor_headspeed)
    anz.bkDzE = p.governor_headspeed ~= nil and uMin or ""
    local hoch = g.gov_spoolup_time and string.format("%.1f", g.gov_spoolup_time / 10) or nil
    anz.bkHoch, anz.bkHochF, anz.bkHochE = hoch or "--", hoch and FARBE.g or P.LEISE, hoch and "s" or ""
    anz.bkGain, anz.bkGainF = zahl(p.governor_gain)
    raten(r)
    local pid = w.pid or {}
    for i = 1, #PID_NAMEN do
        local nm = PID_NAMEN[i]
        anz[nm[1]], anz[nm[2]] = zahl(pid[nm[3]])
    end
end

local function stand(state)
    local s = T.lesen(state)
    if P == nil then return end
    takt(s)
    local w = L.werte
    local g, p, r = w.gov or {}, w.govProfil or {}, w.rc or {}
    local alt = P.apiAlt()
    local regeltAb = alt and 2 or 3
    local m = g.gov_mode and floor(g.gov_mode)
    local uMin = (T.sprache() == "de") and "U/min" or "rpm"   -- die Einheit der Drehzahl: deutsch U/min, in jeder anderen Sprache rpm wie im Cockpit
    local fc = G.bkWerte
    if fc == nil or fc.stand ~= L.stand or fc.werte ~= w or fc.alt ~= alt or fc.uMin ~= uMin then
        werteVomFC(w, alt, uMin)
        G.bkWerte = {stand = L.stand, werte = w, alt = alt, uMin = uMin}
    end
    anz.bkIst, anz.bkIstF = zahl(s.rpm)
    anz.bkIstE = s.rpm ~= nil and uMin or ""
    local aktiv = s.bank and floor(s.bank) or nil
    for i = 1, 3 do anz[BANK_F[i]] = (aktiv == i) and FARBE.w or P.LEISE end
    local rate = s.rate and floor(s.rate) or nil
    local fuss = "RATE " .. (rate and tostring(rate) or "?")
    local typ = r.rates_type and RATE_TYP[floor(r.rates_type)] or nil
    if w.fehler ~= nil then   -- die rote Meldung braucht die Zeile: der Ratentyp bleibt weg, solange sie steht
        anz.bkFuss, anz.bkFehler = fuss, "MSP " .. T.wort(w.fehler)
    else
        anz.bkFuss, anz.bkFehler = fuss .. "   " .. (typ or ""), nil
    end
    local b = BALKEN                                   -- die Saeule gegen das Soll der Bank; ohne Soll gegen das Ende des Cockpit-Bogens
    local oben, unten = sy(b.oben), sy(b.unten)
    local soll = (m ~= nil and m >= regeltAb) and p.governor_headspeed or nil
    if soll ~= nil and soll <= 0 then soll = nil end
    local voll = soll and (soll * SKALA) or T.rpmVoll()
    local function yVon(v)
        local anteil = v / voll
        if anteil < 0 then anteil = 0 elseif anteil > 1 then anteil = 1 end
        return floor(unten - (unten - oben) * anteil + 0.5)
    end
    anz.bkSollDa = soll ~= nil
    if soll then anz.bkSollY, anz.bkGelbY, anz.bkSollText = yVon(soll), yVon(soll * GELB_AB), tostring(floor(soll + 0.5)) end
    local rpm = s.rpm
    anz.bkSaeuleDa = rpm ~= nil and rpm > 0
    if anz.bkSaeuleDa then
        local farbe = GRUEN
        if soll and rpm > soll * GELB_AB then farbe = ROT elseif soll and rpm > soll then farbe = GELB end
        local yOben, yUnten = yVon(rpm), sy(b.unten - b.rand)
        if yOben < sy(b.oben + b.rand) then yOben = sy(b.oben + b.rand) end
        anz.bkSaeuleF, anz.bkSaeuleY, anz.bkSaeuleH = farbe, yOben, math.max(0, yUnten - yOben)
        if anz.bkSaeuleH == 0 then anz.bkSaeuleDa = false end
    end
    local sl = aktiv and G.schlepp[aktiv]
    anz.bkSchleppDa = sl ~= nil and sl.max ~= nil and sl.max > 0
    if anz.bkSchleppDa then
        local y = yVon(sl.max)
        if y < sy(b.oben + b.rand) then y = sy(b.oben + b.rand) end
        anz.bkSchleppY = y - 1
    end
end

local function knoten(farbe)                           -- die Bausteine haengen nur an Farbe und Sprache: einmal gebaut, in G gehalten (uebersteht das Neuladen je Flugphase)
    local Lf = T.linien(farbe)
    local k = {}
    local teile = {}                                   -- der Bau in fuenf Teilen und dem Zusammensetzen, jeder klein genug fuer einen Aufruf
    teile[1] = function()                              -- Grund, Linien, Chips, Balken
    k[#k + 1] = {type = "image", x = 0, y = 0, w = R.W, h = R.H, file = ORDNER .. R.GFX .. "grund.png"}
    R.seite(k, Lf, false, ORDNER, farbe)
    for i = 1, 4 do
        local x, w = chipLage(RATE_CHIP, i)
        P.chip(k, Lf, x, RATE_CHIP.y, w, RATE_CHIP.h, i == 1 and "links" or nil)
    end
    for i = 1, 3 do
        local x, w = chipLage(GAIN_CHIP, i)
        P.chip(k, Lf, x, GAIN_CHIP.y, w, GAIN_CHIP.h, i == 1 and "links" or nil)
    end
    local b = BALKEN
    P.chip(k, Lf, b.x, b.oben, b.w, b.unten - b.oben)
    local zx, zw = sx(ZONEN_X), sx(ZONEN_X + ZONEN_W) - sx(ZONEN_X)
    local ganzUnten = sy(b.unten)
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = GRUEN, visible = function() return anz.bkSollDa == true end,
                 pos = function() return zx - DX, (anz.bkSollY or 0) - DY end, size = function() return zw, math.max(1, ganzUnten - (anz.bkSollY or 0)) end}
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = GELB, visible = function() return anz.bkSollDa == true end,
                 pos = function() return zx - DX, (anz.bkGelbY or 0) - DY end, size = function() return zw, math.max(1, (anz.bkSollY or 0) - (anz.bkGelbY or 0)) end}
    local ganzOben = sy(b.oben)
    k[#k + 1] = {type = "rectangle", x = zx, y = 0, w = zw, h = 1, filled = true, color = ROT, visible = function() return anz.bkSollDa == true end,
                 pos = function() return zx - DX, ganzOben - DY end, size = function() return zw, math.max(1, (anz.bkGelbY or 0) - ganzOben) end}
    local sx0, sw = sx(b.x + b.rand), sx(b.x + b.w - b.rand) - sx(b.x + b.rand)
    k[#k + 1] = {type = "rectangle", x = sx0, y = 0, w = sw, h = 1, filled = true, color = function() return anz.bkSaeuleF or GRUEN end,
                 visible = function() return anz.bkSaeuleDa == true end,
                 pos = function() return sx0 - DX, (anz.bkSaeuleY or 0) - DY end, size = function() return sw, math.max(1, anz.bkSaeuleH or 1) end}
    local mx, mw = sx(b.x - 4), sx(b.x + b.w + 4) - sx(b.x - 4)
    k[#k + 1] = {type = "rectangle", x = mx, y = 0, w = mw, h = 1, filled = true, color = FARBE.w, visible = function() return anz.bkSollDa == true end,
                 pos = function() return mx - DX, (anz.bkSollY or 0) - DY end}
    local kx0, kw = sx(b.x + 2), sx(b.x + b.w - 2) - sx(b.x + 2)
    k[#k + 1] = {type = "rectangle", x = kx0, y = 0, w = kw, h = 2, filled = true, color = FARBE.w, visible = function() return anz.bkSchleppDa == true end,
                 pos = function() return kx0 - DX, (anz.bkSchleppY or 0) - DY end}
    for i = 1, #k do
        if k[i].pos == nil then k[i].x = k[i].x - DX; k[i].y = k[i].y - DY end
    end
    end

    local function v(name) return function() return anz[name] end end
    local spalten = {{"GOVERNOR", "bkGov", nil}, {"DREHZAHL", "bkDz", "bkDzE"}, {"HOCHLAUF", "bkHoch", "bkHochE"}, {"GAIN", "bkGain", nil}}
    teile[2] = function()                              -- das Kopfband und IST
    for i = 1, 4 do                                    -- das Kopfband: Governor, Solldrehzahl, Hochlauf, Gain in der Flucht der vier Chips
        local x, w = chipLage(RATE_CHIP, i)
        if i == 1 then x, w = 0, x + w end
        local sp = spalten[i]
        P.wort(k, sx(x + w / 2), sy(18), T.wort(sp[1]), FARBE.w, F.xs, nil, DX, DY)
        local segs = {{v(sp[2]), v(sp[2] .. "F"), F.std}}
        if sp[3] then segs[2] = {v(sp[3]), FARBE.w, F.xs} end
        P.zeile(k, sx(x + w / 2), sy(35), segs, nil, DX, DY)
    end
    P.wort(k, sx(IST_X + IST_W / 2), sy(18), T.wort("IST"), FARBE.w, F.xs, nil, DX, DY)
    P.zeile(k, sx(IST_X + IST_W / 2), sy(35), {{v("bkIst"), v("bkIstF"), F.std}, {v("bkIstE"), FARBE.w, F.xs}}, nil, DX, DY)
    end
    teile[3] = function()                              -- die Raten
    for i = 1, 4 do                                    -- je Achse die Zahl, wie rfsuite und NovaFly sie zeigen: Drehrate, Faktor oder beim Kollektiv der Winkel
        local x, w = chipLage(RATE_CHIP, i)
        local y = RATE_CHIP.y
        if i == 1 then x, w = 0, x + w end
        P.wort(k, sx(x + w / 2), sy(y + 15), T.wort(RATE_ACHSEN[i]), FARBE.w, F.s, nil, DX, DY)
        P.zeile(k, sx(x + w / 2), sy(y + 40), {{v("bkRate" .. i), v("bkRateF" .. i), F.l}, {v("bkRateE" .. i), FARBE.w, F.xs}}, nil, DX, DY)
    end
    end
    local gachsen = {{"ROLL", 0}, {"NICK", 1}, {"HECK", 2}}
    teile[4] = function()                              -- die Gains
    for i = 1, 3 do                                    -- Gains je Achse: P I D F B O
        local x, w = chipLage(GAIN_CHIP, i)
        local y = GAIN_CHIP.y
        if i == 1 then x, w = 0, x + w end
        local a = gachsen[i]
        P.wort(k, sx(x + w / 2), sy(y + 13), T.wort(a[1]), FARBE.w, F.s, nil, DX, DY)
        local paare = {{10, 36, "P"}, {62, 36, "I"}, {10, 58, "D"}, {62, 58, "F"}, {10, 80, "B"}}
        if a[2] ~= 2 then paare[#paare + 1] = {62, 80, "O"} end
        for _, pr in ipairs(paare) do
            local name = "bkP" .. a[2] .. pr[3]
            k[#k + 1] = {type = "label", x = sx(x + pr[1]) - DX, y = sy(y + pr[2] - 7) - DY, w = 0, font = F.s, text = pr[3], color = FARBE.w}
            k[#k + 1] = {type = "label", x = sx(x + pr[1] + 16) - DX, y = sy(y + pr[2] - 8) - DY, w = 0, font = F.std, text = v(name), color = v(name .. "F")}
        end
    end
    end
    teile[5] = function()                              -- die Baenke, die Marke am Balken, die Fusszeile
    local hs = T.hoehe(F.s)
    for i = 1, 3 do
        local nr = i
        P.zeile(k, sx(BANK_RX), sy(BANK_Y + (i - 1) * BANK_SCHRITT) + floor(hs / 2), {{T.wort("BANK") .. " " .. i, function() return anz["bkBankF" .. nr] end, F.s}}, "rechts", DX, DY)
    end
    local hx = T.hoehe(F.xs)
    local sollLage = {}
    k[#k + 1] = {type = "label", x = 0, y = 0, w = 0, font = F.xs, color = FARBE.w, visible = function() return anz.bkSollDa == true end,
                 text = function() return anz.bkSollText or "" end,
                 pos = function()
                     local t = anz.bkSollText or ""
                     if sollLage.text ~= t then sollLage.text, sollLage.b = t, T.breite(t, F.xs) end
                     return sx(BANK_RX) - sollLage.b - DX, (anz.bkSollY or 0) - floor(hx / 2) - DY
                 end}
    k[#k + 1] = {type = "label", x = sx(140) - DX, y = sy(FUSS_Y) - DY, w = 0, font = F.s, color = FARBE.w, text = v("bkFuss")}
    k[#k + 1] = {type = "label", x = sx(290) - DX, y = sy(FUSS_Y) - DY, w = 0, font = F.s, color = FARBE.r,
                 text = function() return anz.bkFehler or "" end, visible = function() return anz.bkFehler ~= nil end}
    end
    teile[6] = function() end                          -- der letzte Aufruf setzt nur zusammen: das erste Anlegen aller Bausteine hat einen Aufruf fuer sich
    return k, teile
end

local function anfangen(farbe)                         -- der Satz fuer diese Farbe und Sprache: aus G, sonst neu angelegt (noch ohne Bausteine)
    local schluessel = tostring(farbe) .. "|" .. tostring(T.sprache())
    local f = G.bkFertig
    if type(f) ~= "table" or f.schluessel ~= schluessel then
        local k, teile = knoten(farbe)
        f = {schluessel = schluessel, k = k, teile = teile, i = 1}
        G.bkFertig = f
    end
    return f
end

local function einTeil(f)                              -- baut den naechsten Teil; true, wenn alle da sind
    if f.teile ~= nil then
        f.teile[f.i]()
        f.i = f.i + 1
        if f.i == 2 then f.rahmen = {table.unpack(f.k)} end   -- nach dem ersten Teil: Grund, Linien, Chips und Balken - das zeigt die Seite, bis alle Teile da sind
        if f.i > #f.teile then f.teile = nil end
    end
    return f.teile == nil
end

local kaputt = nil                                     -- ein Bau, der abbrach: die Seite zeigt den Grund, bis die Datei neu geladen ist
local function steht(farbe)                            -- liegen alle Bausteine fuer diese Farbe und Sprache bereit?
    local f = G.bkFertig
    return P == nil or kaputt ~= nil or (type(f) == "table" and f.teile == nil and f.schluessel == tostring(farbe) .. "|" .. tostring(T.sprache()))
end

local aufbau, gelesen, letzterBau = 0, false, nil      -- letzterBau: der vorige Bau, ganz oder ein Teil, und wann
function M.renderKey(zone, state)                      -- solange der Schirm nicht ganz steht, je Aufruf ein neuer Schluessel: die Suite merkt ihn gleich nach dem Bau (widgets/dashboard/views.lua viewKey)
    G.takt = (G.takt or 0) + 1
    gelesen = true                                     -- beim ersten Oeffnen fragt die Suite renderKey erst nach dem Bau; der ganze Schirm wartet darauf
    local ok, grund = pcall(stand, state or {})
    if not ok then T.merken("baenke stand: " .. tostring(grund)) end
    local farbe = T.farbeAus(state)
    local key = "baenke|" .. farbe .. "|" .. T.sprache()
    if steht(farbe) and (letzterBau == nil or letzterBau.ganz) then return key end
    aufbau = aufbau + 1
    return key .. "|aufbau " .. aufbau
end

local function bauen(children, zone, state, ctx)       -- eine Seite, die nicht bereitliegt: je Aufruf ein Teil, bis dahin der Grund mit dem Rahmen
    local t = jetzt()
    if letzterBau == nil or letzterBau.ganz or t - letzterBau.zeit > 2 then   -- die Seite geht auf (nicht der naechste Teil): Platz machen und neu lesen
        collectgarbage("collect")
        L.gen, L.laeuft, L.neu = L.gen + 1, false, true    -- eine Antwort fuer eine fruehere Oeffnung faellt weg
    end
    local farbe = T.farbeAus(state)
    G.farbeJetzt = farbe
    local f = anfangen(farbe)
    local ganz = einTeil(f) and gelesen                -- der Grund mit dem Rahmen kommt ohne Werte aus, der ganze Schirm nicht
    local k = ganz and f.k or f.rahmen
    letzterBau = {ganz = ganz, zeit = t}
    children[#children + 1] = {type = "box", x = 0, y = 0, w = zone.w, h = zone.h, borderPad = 0, children = {
        {type = "button", x = 0, y = 0, w = zone.w, h = zone.h, cornerRadius = 0, color = FARBE.schwarz, children = k,
         press = function() ctx.action("closeView") end}}}
    if ganz then T.merken("baenke gebaut: " .. #k .. " Bausteine") end
end

function M.build(children, zone, state, ctx)
    if type(ctx) == "table" and type(ctx.keys) == "table" then ctx.keys.pageUp = "openView:novafly_baenke" end   -- die Suite schliesst eine Ansicht mit ihrer Taste: so fuehren beide PAGE-Tasten zurueck; das Cockpit setzt sie bei seinem naechsten Bau neu
    local ok, grund = false, kaputt or "seiten.lua fehlt"
    if P ~= nil and kaputt == nil then ok, grund = pcall(bauen, children, zone, state, ctx) end
    if not ok then
        kaputt = tostring(grund)
        T.merken("baenke build: " .. kaputt)
        children[#children + 1] = {type = "label", x = 10, y = 10, w = R.W - 20, text = kaputt, color = FARBE.r}
    end
end

if P ~= nil then
    G.bkVorbauen = function(farbe)                     -- fuer das Cockpit: ein Teil je ruhiger Runde; true erst, wenn alle Teile schon da waren
        local f = anfangen(farbe)
        if f.teile == nil then return true end
        einTeil(f)
        return false
    end
else
    G.bkVorbauen = false
end

return M
