-- VORFLUG: das Display links vom Cockpit (init.lua views; PAGE links oder ein Tipp auf den Akku), auf dem Grund des Cockpits,
-- die Linien laufen von rechts herein und klingen aus. Kopfband: links der Flugmodus, mittig der Modellname, rechts Link und
-- VFR je als fuenf Balken ohne Zahlen; links das Modellbild des Piloten mit weichem Rand, rechts der Akku (Stand, Spannung,
-- Zellen, Kapazitaet), Zelle und Verbrauch, offen zum rechten Rand; im Fussband vier Chips mit dem letzten Flug: Hoehe, Steigen,
-- Sinken, Flugzeit. Ein Tipp irgendwo oder RTN fuehrt zurueck: die ganze Seite ist ein Knopf, alles andere sind seine Kinder.
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

local FOTO = {x = 10, y = 66, h = 168}                 -- das Fotofeld, 4:3 aus der Hoehe; dieselben Masse hat der Fotorand (fotorand.png)
local BALKEN = {link = 398, vfr = 438, unten = 36}    -- je fuenf Empfangsbalken, beide Gruppen rechts oben nebeneinander
local LINK_STUFEN = {42, 50, 60, 70, 85}               -- je Balken; 42 ist die Warnschwelle des Senders
local VFR_STUFEN = {20, 40, 60, 80, 95}                -- Prozent je Balken
local KOPF_Y = 28                                      -- die Mitte des Kopfbands
local MODUS = {x = 12, wort = 16, wert = 34}           -- links im Kopfband: FLUGMODUS klein, darunter der Modus
local AKKU = {x = 246, y = 66, w = 234, h = 174}       -- die Umrandung rechts, offen zum Rand
local FUSS = {y = 262, h = 48, w = 112, luecke = 6, x = 10}
local SUITE_LOGO = "/widgets/dashboard/gfx/logo.png"   -- das Bild, das die Suite zeigt, wenn der Pilot keines hat: dann bleibt das Feld leer
local AKKU_PAUSE = 3                                   -- s bis zur naechsten Frage nach BATTERY_CONFIG, wenn eine scheiterte

local M = {}
function M.sources() return {"consumption", "smartconsumption", "1RSS", "VFR", "RQly", "link", "voltage", "fuel", "current", "altitude"} end

local function stufen(wert, liste)
    if wert == nil then return 0 end
    local n = 0
    for i = 1, #liste do if wert >= liste[i] then n = i end end
    return n
end

local function zahl(v, muster)                         -- Text und Farbe einer Zahl; ohne Wert "--" leise
    if v == nil then return "--", P.LEISE end
    if muster == nil then v = floor(v + 0.5) end
    local z = string.format(muster or "%d", v)
    if type(v) == "number" and v <= 0 and string.find(z, "^%-[0.]*$") then z = string.sub(z, 2) end   -- was auf null rundet, steht ohne Minus
    return z, FARBE.g
end

local function jetzt()                                 -- Sekunden seit dem Start des Senders
    if type(getTime) == "function" then return getTime() / 100 end
    return 0
end

local function heliJetzt()
    local se = rfsuite and rfsuite.session
    if type(se) ~= "table" or se.isConnected ~= true then return nil end
    return se.mcu_id
end

local function kapazitaet()                            -- die Kapazitaet des gewaehlten Akkus, wie die Suite sie haelt; sonst BATTERY_CONFIG je Heli einmal
    local se = rfsuite and rfsuite.session
    local bc = type(se) == "table" and (se.batteryConfig or se.battery_config) or nil
    local kap = type(bc) == "table" and tonumber(bc.batteryCapacity) or nil
    if kap ~= nil and kap > 0 then return kap, tonumber(bc.batteryCellCount) end
    local heli = heliJetzt()
    local a = G.vfAkku
    if a ~= nil and a.heli == heli and a.werte ~= nil then return tonumber(a.werte.batteryCapacity), tonumber(a.werte.batteryCellCount) end
    if heli ~= nil and P ~= nil and (a == nil or a.heli ~= heli or (a.werte == nil and not a.laeuft and jetzt() >= (a.ab or 0))) then
        local frage = {heli = heli, laeuft = true}
        G.vfAkku = frage
        if not P.lesen("battery_config", function(w)
            frage.laeuft = false
            if w ~= nil then frage.werte = w else frage.ab = jetzt() + AKKU_PAUSE end
        end) then frage.laeuft, frage.ab = false, jetzt() + AKKU_PAUSE end
    end
    return nil, nil
end

local function stand(state)
    local s = T.lesen(state)
    local d = state.derived or {}
    local akkuF = FARBE[T.akkuFarbe(T.akkuAnteil(state, s.pack, s.cellF or s.cell))] or FARBE.g
    local link = FARBE[T.linkFarbe(state, s.vfr)] or FARBE.w
    if link == FARBE.w then link = FARBE.g end                      -- gut heisst hier gruen wie die Zahlen
    anz.vfLinkF, anz.vfLinkN = link, stufen(tonumber(d.link), LINK_STUFEN)
    anz.vfVfrN = stufen(s.vfr, VFR_STUFEN)
    local modus = T.modusWort(s.flugmodus)
    anz.vfModus, anz.vfModusF = modus and T.wort(modus) or "--", modus and FARBE.g or P.LEISE
    anz.vfFuel, anz.vfFuelF = zahl(s.fuel ~= nil and floor(s.fuel + 0.5) or nil)
    if s.fuel ~= nil then anz.vfFuelF = akkuF end
    anz.vfPack, anz.vfPackF = zahl(s.pack, "%.1f")
    if s.pack ~= nil then anz.vfPackF = akkuF end
    local kap, zellenKap = kapazitaet()
    local zellen = s.zellen or zellenKap
    if zellen ~= nil and zellen <= 0 then zellen = nil end
    anz.vfZellen, anz.vfZellenF = (zellen ~= nil and tostring(floor(zellen)) or "--") .. "S  ", zellen ~= nil and FARBE.w or P.LEISE
    anz.vfKap, anz.vfKapF = zahl(kap ~= nil and kap > 0 and kap or nil)
    anz.vfZelle, anz.vfZelleF = zahl(s.cell, "%.2f")
    if s.cell ~= nil then anz.vfZelleF = akkuF end
    anz.vfMah, anz.vfMahF = zahl(s.verbrauch ~= nil and floor(s.verbrauch + 0.5) or nil)
    local fl, sz = G.letzterFlug or {}, G.sitzung or {}             -- der letzte Flug hier; ohne Flug die Hoechstwerte seit dem Start
    anz.vfHoeheE, anz.vfRateE = s.altFt and "ft" or "m", s.altFt and "ft/s" or "m/s"
    local sink = fl.sink or sz.sinkMax
    anz.vfAlt, anz.vfAltF = zahl(fl.alt or sz.altMax, "%.0f")
    anz.vfSteig, anz.vfSteigF = zahl(fl.steig or sz.steigMax, "%.1f")
    anz.vfSink, anz.vfSinkF = zahl(sink ~= nil and -sink or nil, "%.1f")
    local sek = fl.zeit
    anz.vfZeit, anz.vfZeitF = zahl(sek ~= nil and string.format("%d:%02d", floor(sek / 60), floor(sek % 60)) or nil, "%s")
    local bild = type(d.model_image) == "string" and d.model_image or nil
    if bild ~= nil and string.find(bild, SUITE_LOGO, 1, true) then bild = nil end
    anz.vfFoto = bild
end

local function namensSchrift(text, breite)             -- der Modellname so gross, wie er in die Breite passt
    for _, stufe in ipairs({F.l, F.std, F.s}) do
        if T.breite(text, stufe) <= breite then return stufe end
    end
    return F.s
end

local function knoten(farbe)                           -- haengt nur an Farbe und Sprache, in G gehalten wie bei BAENKE; der Bau in drei Teilen und dem Zusammensetzen
    local L = T.linien(farbe)
    local k = {}                                       -- die Kinder des einen Knopfs, um DX, DY zurueckgesetzt
    local teile = {}
    local a = AKKU
    teile[1] = function()                              -- Grund, Linien, Foto, Chips, Empfangsbalken
    k[#k + 1] = {type = "image", x = 0, y = 0, w = R.W, h = R.H, file = ORDNER .. R.GFX .. "grund.png"}
    R.seite(k, L, true, ORDNER, farbe)
    local fh = sy(FOTO.h)
    local fx, fy, fw = sx(FOTO.x), sy(FOTO.y), floor(fh * 4 / 3 + 0.5)
    k[#k + 1] = {type = "image", x = fx, y = fy, w = fw, h = fh, file = function() return anz.vfFoto or "" end,
                 visible = function() return anz.vfFoto ~= nil end}
    k[#k + 1] = {type = "image", x = fx, y = fy, w = fw, h = fh, file = ORDNER .. R.GFX .. "fotorand.png",
                 visible = function() return anz.vfFoto ~= nil end}
    P.chip(k, L, a.x, a.y, a.w, a.h, "rechts")
    for i = 1, 4 do
        local x = FUSS.x + (i - 1) * (FUSS.w + FUSS.luecke)
        local w = (i == 4) and (480 - x) or FUSS.w
        P.chip(k, L, x, FUSS.y, w, FUSS.h, i == 4 and "rechts" or nil)
    end
    P.empfang(k, BALKEN.link, BALKEN.unten, function() return anz.vfLinkN or 0 end, function() return anz.vfLinkF or FARBE.g end)
    P.empfang(k, BALKEN.vfr, BALKEN.unten, function() return anz.vfVfrN or 0 end, function() return anz.vfLinkF or FARBE.g end)
    for i = 1, #k do k[i].x = k[i].x - DX; k[i].y = k[i].y - DY end
    end

    local function v(name) return function() return anz[name] end end
    teile[2] = function()                              -- das Kopfband und der Akku
    P.wort(k, sx(MODUS.x), sy(MODUS.wort), T.wort("FLUGMODUS"), FARBE.w, F.xs, "links", DX, DY)
    P.zeile(k, sx(MODUS.x), sy(MODUS.wert), {{v("vfModus"), v("vfModusF"), F.s}}, "links", DX, DY)
    local name = anz.name or ""
    P.zeile(k, sx(240), sy(KOPF_Y), {{function() return anz.name or "" end, FARBE.w, namensSchrift(name, sx(280))}}, nil, DX, DY)
    local cx = sx(a.x + a.w / 2)
    P.wort(k, cx, sy(a.y + 17), T.wort("AKKU"), FARBE.w, F.s, nil, DX, DY)
    P.zeile(k, cx, sy(a.y + 45), {{v("vfFuel"), v("vfFuelF"), F.xl}, {"%", FARBE.w, F.s}}, nil, DX, DY)
    P.zeile(k, cx, sy(a.y + 74), {{v("vfPack"), v("vfPackF"), F.xs}, {"V  ", FARBE.w, F.xs}, {v("vfZellen"), v("vfZellenF"), F.xs},
                                  {v("vfKap"), v("vfKapF"), F.xs}, {"mAh", FARBE.w, F.xs}}, nil, DX, DY)
    end
    teile[3] = function()                              -- Zelle, Verbrauch und die vier Chips des letzten Flugs
    local lx, rx = sx(a.x + a.w / 4), sx(a.x + a.w * 3 / 4)
    P.wort(k, lx, sy(a.y + 108), T.wort("ZELLE"), FARBE.w, F.xs, nil, DX, DY)
    P.zeile(k, lx, sy(a.y + 133), {{v("vfZelle"), v("vfZelleF"), F.l}, {"V", FARBE.w, F.s}}, nil, DX, DY)
    P.wort(k, rx, sy(a.y + 108), T.wort("VERBRAUCH"), FARBE.w, F.xs, nil, DX, DY)
    P.zeile(k, rx, sy(a.y + 133), {{v("vfMah"), v("vfMahF"), F.l}, {"mAh", FARBE.w, F.s}}, nil, DX, DY)
    local chips = {{"HOEHE MAX", "vfAlt", "vfHoeheE"}, {"STEIGEN MAX", "vfSteig", "vfRateE"}, {"SINKEN MAX", "vfSink", "vfRateE"},
                   {"FLUGZEIT", "vfZeit", nil}}
    for i = 1, 4 do
        local x = FUSS.x + (i - 1) * (FUSS.w + FUSS.luecke)
        local w = (i == 4) and (480 - x) or FUSS.w
        local c = chips[i]
        P.wort(k, sx(x + w / 2), sy(FUSS.y + 13), T.wort(c[1]), FARBE.w, F.xs, nil, DX, DY)
        local einheit = c[3] and v(c[3]) or "min"
        P.zeile(k, sx(x + w / 2), sy(FUSS.y + 33), {{v(c[2]), v(c[2] .. "F"), F.std}, {einheit, FARBE.w, F.xs}}, nil, DX, DY)
    end
    end
    teile[4] = function() end                          -- der letzte Aufruf setzt nur zusammen: das erste Anlegen aller Bausteine hat einen Aufruf fuer sich
    return k, teile
end

local function anfangen(farbe)                         -- der Satz fuer diese Farbe und Sprache: aus G, sonst neu angelegt (noch ohne Bausteine)
    local schluessel = tostring(farbe) .. "|" .. tostring(T.sprache())
    local f = G.vfFertig
    if type(f) ~= "table" or f.schluessel ~= schluessel then
        local k, teile = knoten(farbe)
        f = {schluessel = schluessel, k = k, teile = teile, i = 1}
        G.vfFertig = f
    end
    return f
end

local function einTeil(f)                              -- baut den naechsten Teil; true, wenn alle da sind
    if f.teile ~= nil then
        f.teile[f.i]()
        f.i = f.i + 1
        if f.i == 2 then f.rahmen = {table.unpack(f.k)} end   -- nach dem ersten Teil: Grund, Linien, Foto, Chips und Balken - das zeigt die Seite, bis alle Teile da sind
        if f.i > #f.teile then f.teile = nil end
    end
    return f.teile == nil
end

local kaputt = nil                                     -- ein Bau, der abbrach: die Seite zeigt den Grund, bis die Datei neu geladen ist
local function steht(farbe)                            -- liegen alle Bausteine fuer diese Farbe und Sprache bereit?
    local f = G.vfFertig
    return P == nil or kaputt ~= nil or (type(f) == "table" and f.teile == nil and f.schluessel == tostring(farbe) .. "|" .. tostring(T.sprache()))
end

local aufbau, gelesen, letzterBau = 0, false, nil      -- letzterBau: der vorige Bau, ganz oder ein Teil, und wann
function M.renderKey(zone, state)                      -- wie BAENKE: solange der Schirm nicht ganz steht, je Aufruf ein neuer Schluessel
    G.takt = (G.takt or 0) + 1
    gelesen = true
    local ok, grund = pcall(stand, state or {})
    if not ok then T.merken("vorflug stand: " .. tostring(grund)) end
    local farbe = T.farbeAus(state)
    local key = "vorflug|" .. farbe .. "|" .. T.sprache() .. "|" .. tostring(anz.name) .. "|" .. tostring(anz.vfFoto)
    if steht(farbe) and (letzterBau == nil or letzterBau.ganz) then return key end
    aufbau = aufbau + 1
    return key .. "|aufbau " .. aufbau
end

local function bauen(children, zone, state, ctx)       -- je Aufruf ein Teil; der ganze Schirm erst, wenn renderKey die Werte gerechnet hat
    local t = jetzt()
    if letzterBau == nil or letzterBau.ganz or t - letzterBau.zeit > 2 then   -- die Seite geht auf (nicht der naechste Teil)
        collectgarbage("collect")                      -- erst Platz machen: die Suite und das Theme teilen sich den Speicher des Senders
    end
    local f = anfangen(T.farbeAus(state))
    local ganz = einTeil(f) and gelesen                -- der Grund mit dem Rahmen kommt ohne Werte aus, der ganze Schirm nicht
    local k = ganz and f.k or f.rahmen
    letzterBau = {ganz = ganz, zeit = t}
    children[#children + 1] = {type = "box", x = 0, y = 0, w = zone.w, h = zone.h, borderPad = 0, children = {   -- die ganze Seite ist ein Knopf: ein Tipp fuehrt zurueck zum Cockpit; der Kasten schneidet den Rahmen des Senders ab
        {type = "button", x = 0, y = 0, w = zone.w, h = zone.h, cornerRadius = 0, color = FARBE.schwarz, children = k,
         press = function() ctx.action("closeView") end}}}
    if ganz then T.merken("vorflug gebaut: " .. #k .. " Bausteine") end
end

function M.build(children, zone, state, ctx)
    if type(ctx) == "table" and type(ctx.keys) == "table" then ctx.keys.pageDown = "openView:novafly_vorflug" end   -- die Suite schliesst eine Ansicht mit ihrer Taste: so fuehren beide PAGE-Tasten zurueck; das Cockpit setzt sie bei seinem naechsten Bau neu
    local ok, grund = false, kaputt or "seiten.lua fehlt"
    if P ~= nil and kaputt == nil then ok, grund = pcall(bauen, children, zone, state, ctx) end
    if not ok then
        kaputt = tostring(grund)
        T.merken("vorflug build: " .. kaputt)
        children[#children + 1] = {type = "label", x = 10, y = 10, w = R.W - 20, text = kaputt, color = FARBE.r}
    end
end

if P ~= nil then
    G.vfVorbauen = function(farbe)                     -- fuer das Cockpit: ein Teil je ruhiger Runde, bevor die Seite aufgeht; true erst, wenn alle Teile schon da waren
        local f = anfangen(farbe)
        if f.teile == nil then return true end
        einTeil(f)
        return false
    end
else
    G.vfVorbauen = false
end

return M
