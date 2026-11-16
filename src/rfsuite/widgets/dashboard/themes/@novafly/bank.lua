-- BANK als Schirm des NovaFly-Themes der Rotorflight-Suite fuer EdgeTX. Karten, Knoepfe und Woerter kommen als Bilder aus einem
-- Skript. Gelesen wird die Bank, auf der der FC steht; gestellt wird mit Minus und Plus; gespeichert wird der
-- ganze Satz der Bank mit der einen Aenderung, zurueckgelesen und verglichen, dann gesichert. Geschrieben wird nur am Boden.
-- Der Ordner des Themes: mitgeliefert liegt es bei den Themes der Suite, als eigenes Theme des Piloten unter user/dashboard.
-- Die Wurzeln der Karte nennt nur die Suite (rfsuite.paths), dieses Skript schreibt sie nicht aus
local PFADE = rfsuite and rfsuite.paths or {}
local ORDNER = PFADE.core and (PFADE.core .. "/widgets/dashboard/themes/@novafly/") or nil
if ORDNER == nil or loadScript(ORDNER .. "init.lua", "t") == nil then
    ORDNER = PFADE.user and (PFADE.user .. "/dashboard/novafly/") or ORDNER
end
local floor, byte = math.floor, string.byte
local RGB = lcd.RGB
local zeit = getTime or function() return 0 end
local SYS_KLEIN = SMLSIZE or 0

local function suiteModul(pfad)
    if rfsuite and type(rfsuite.require) == "function" then
        local ok, m = pcall(rfsuite.require, pfad)
        if ok and type(m) == "table" then return m end
    end
    return nil
end

-- Die Suite laedt diese Datei bei jedem Wechsel der Flugphase neu. Der Schirm, den es schon gibt, bleibt dabei bestehen:
-- mit allem, was er vom FC gelesen hat, und mit seinen offenen Fragen an den FC. Er liegt in einem Modul des Themes, das
-- der Lader der Suite haelt und beim Wechsel zu einem anderen Theme mit dessen Modulen freigibt (runtime.lua
-- releaseUnusedThemes); ohne den Lader (eine Probe am PC) in einem Globalen
local MERK = suiteModul(ORDNER .. "bank_zustand.lua")
if MERK == nil then
    MERK = _G.NOVAFLY_BANK
    if type(MERK) ~= "table" then
        MERK = {}
        _G.NOVAFLY_BANK = MERK
    end
end
if type(MERK.M) == "table" and MERK.suite == rfsuite and MERK.msp == (rfsuite and rfsuite.msp) then
    return MERK.M
end

local ZEITABLAUF, NEUVERSUCH, OFFEN_NACH, WEG_NACH = 1400, 300, 100, 1000   -- in Hundertstelsekunden
local VENTIL = 3000               -- Hundertstel: so lange wartet ein zweites SPEICHERN auf einen Schreibvorgang, der noch laeuft
local FELD_DZ, FELD_PROZENT = "governor_headspeed", "governor_max_throttle"
local GRENZE_PROZENT = {min = 10, max = 100, step = 1}        -- der Bereich der Firmware fuer Max-Gas, wie die Governor-Seite der Suite
local STATUS_LAENGE = 24                                       -- bis current_pid_profile_index
local STELLEN = 6                                              -- Bausteine fuer die Zahl je Karte

local D, S, T = nil, nil, nil
local sprache = nil
local ctxJetzt = nil
local offen = nil                 -- die Lesefrage eines Vorgangs, die in der Schlange der Suite steht: ihr Kunde und ihre Nummer
local kette, kettenNr = nil, 0    -- der Schreibvorgang, der dem FC gehoert: ab dem Schreibbefehl laeuft er zu Ende, auch wenn der Schirm aufgibt

local gesehen = {}                -- je Bank, was der FC zuletzt nannte: bleibt, solange das Theme geladen ist und der FC derselbe
local kennung = nil               -- die Kennung (mcu_id) des FC, von dem gesehen stammt
local simSatz = nil               -- nur im Simulator: der zuletzt geschriebene Satz, damit das Ruecklesen ihn dort wiederfindet
local bank, govModus = nil, nil
local govLesen, govGelesen, govVersuche = false, false, 0
local zustand, meldung, hinweis = "laedt", "", ""
local meldungGelb = false         -- die Meldung ist kein Fehler des FC: das Modell ist scharf, und scharf fragt BANK nicht
local scharfVorher = nil          -- die Lage scharf im Takt davor
local laeuft, start, vorgang = false, 0, 0
local wahl, radBank, stellt = nil, nil, false
local soll, sollBank = nil, nil
local erstlesungWiederholt = false
local neuVersuchAb, letzteBank = 0, nil
local speicherStufe, speicherBis = nil, 0
local arbeitSeit = nil
local letzterTakt = nil
local lage = {verbunden = false, scharf = nil, bank = nil, rpm = nil}
local warVerbunden, weg, zu = false, false, false   -- der Heli war da, seit der Schirm offen ist; er ist weg; der Schirm ist zu

local anz = {band = false, text = "", textFarbe = 0, klein = false, balken = nil, stufe = 0, speichernGruen = false, stellBank = nil,
             {}, {}, {}}

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

local api, kunde, grenzeDz = {}, nil, nil
local function apiHolen(name)
    if api[name] == nil then
        local m = nil
        if rfsuite and type(rfsuite.require) == "function" then
            local ok, r = pcall(rfsuite.require, "tasks/msp/api/" .. name .. ".lua")
            if ok and type(r) == "table" then m = r end
        end
        api[name] = m or false
    end
    return api[name] or nil
end

local function kundeHolen()
    if kunde == nil and rfsuite and type(rfsuite.msp) == "table" and type(rfsuite.msp.register) == "function" then
        local ok, k = pcall(rfsuite.msp.register, "novafly-theme")
        if ok and type(k) == "table" then kunde = k end
    end
    return kunde
end

-- Ein neuer Vorgang: die Rueckrufe des alten laufen ins Leere, und seine Lesefrage, die noch in der Schlange der Suite steht,
-- geht raus (die Suite sendet ihre Schlange sonst spaeter weiter). Ein Schreibbefehl wird nie abgebrochen: ab dem Einreihen
-- gehoert der Vorgang dem FC (kette in speichern), Ruecklesen, Vergleich und Sichern laufen zu Ende, nur die Anzeige folgt dem Schirm
local function neuerVorgang()
    vorgang = vorgang + 1
    local alt = offen
    offen = nil
    if alt ~= nil and type(alt.kunde) == "table" and type(alt.kunde.cancel) == "function" then
        pcall(alt.kunde.cancel, alt.kunde, alt.id)
    end
    return vorgang
end

local function prozent() return govModus == 1 or govModus == 2 end
local function feld() return prozent() and FELD_PROZENT or FELD_DZ end
local function wertVon(g)
    if g == nil or govModus == nil then return nil end
    if prozent() then return g.maxgas end
    return g.drehzahl
end

local function grenzen()
    if prozent() then return GRENZE_PROZENT end
    if grenzeDz == nil then
        grenzeDz = false
        if rfsuite and type(rfsuite.require) == "function" then
            local ok, m = pcall(rfsuite.require, "lib/governor_fields.lua")
            local h = ok and type(m) == "table" and m.headspeed or nil
            if type(h) == "table" and type(h.min) == "number" and type(h.max) == "number" then grenzeDz = h end
        end
    end
    return grenzeDz or nil
end

local function grundtext(g)
    g = tostring(g)
    if g == "unavailable" or g == "released" then g = "msp_nicht_bereit" end
    return (T and T.grund[g]) or g
end

-- eine Frage an den FC ueber den MSP-Dienst der Suite; schreibt = die Bytes des Satzes, sonst wird gelesen. Eine Frage eines
-- Vorgangs wird als offen gemerkt, bis sie beantwortet ist, damit ein neuer Vorgang sie aus der Schlange nehmen kann;
-- nebenbei = eine Frage, die zu keinem Vorgang gehoert (der Governor-Modus) und stehen bleibt
local function fragen(name, schreibt, fertig, fehler, antwortSim, nebenbei)
    local a, k = apiHolen(name), kundeHolen()
    if a == nil or k == nil then fehler("msp_nicht_bereit") return false end
    local einmal, meine = false, nil
    local function erledigt()
        einmal = true
        if offen ~= nil and offen.id == meine then offen = nil end
    end
    local ok, id, grund = pcall(k.request, k, {
        command = schreibt and a.writeCommand or a.command,
        payload = schreibt or nil,
        isWrite = schreibt ~= nil,
        simulatorResponse = schreibt and {} or (antwortSim or a.simulatorResponse),
        onReply = function(buf)
            if einmal then return end
            erledigt()
            fertig(buf)
        end,
        onError = function(g)
            if einmal then return end
            erledigt()
            if g == "refused" or g == "no_simulator_response" then g = schreibt and "schreiben_abgelehnt" or "lesefehler" end
            fehler(g)
        end,
    })
    if not ok or id == nil then
        einmal = true
        fehler(ok and (grund or "nicht_eingereiht") or "load_fehler")
        return false
    end
    meine = id
    if not einmal and not nebenbei then offen = {kunde = k, id = id} end
    return true
end

-- eigen = eine Frage des Schreibvorgangs: kein neuer Vorgang nimmt sie aus der Schlange
local function statusLesen(fertig, fehler, eigen)
    local sim = nil
    local a = apiHolen("status")
    if a and type(a.simulatorResponse) == "table" then      -- der Simulator meldet die Bank, die auch die Telemetrie nennt
        sim = {}
        for i = 1, #a.simulatorResponse do sim[i] = a.simulatorResponse[i] end
        sim[STATUS_LAENGE] = (lage.bank or 1) - 1
    end
    return fragen("status", nil, function(buf)
        if type(buf) ~= "table" or #buf < STATUS_LAENGE then fehler("unvollstaendig") return end
        local st = a.parse(buf)
        if type(st) ~= "table" or st.current_pid_profile_index == nil or st.flight_mode_flags == nil then
            fehler("unvollstaendig")
            return
        end
        fertig(st.current_pid_profile_index + 1, floor(st.flight_mode_flags) % 2 == 1)
    end, fehler, sim, eigen)
end

local function satzLesen(fertig, fehler, eigen)
    local a = apiHolen("governor_profile")
    return fragen("governor_profile", nil, function(buf)
        local satz = a.parse(buf)
        if type(satz) ~= "table" or satz[FELD_DZ] == nil or satz[FELD_PROZENT] == nil then fehler("unvollstaendig") return end
        fertig(satz)
    end, fehler, simSatz, eigen)
end

local function satzSchreiben(bytes, fertig, fehler, eigen)
    return fragen("governor_profile", bytes, function()
        simSatz = bytes
        fertig()
    end, fehler, nil, eigen)
end

local function gleich(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function schreibsperre()                 -- unbekannte Arm-Lage zaehlt als scharf
    if not lage.verbunden then return "arm_unbekannt" end
    if lage.scharf == false then return nil end
    if lage.scharf == true then return "armiert" end
    return "arm_unbekannt"
end

local function geaendert()
    if soll == nil or sollBank == nil then return false end
    local g = gesehen[sollBank]
    return g ~= nil and wertVon(g) ~= nil and soll ~= wertVon(g)
end

-- Scharf laesst die Suite MSP ruhen: eine Frage bekommt dann keine Antwort, obwohl der FC da ist. Was scharf am Lesen
-- scheitert, heisst darum nicht "FC antwortet nicht", sondern wie beim Speichern: scharf, zuerst entschaerfen
local function fehlerMelden(g)
    local scharf = (lage.scharf == true)
    if scharf then g = "armiert" end
    zustand, meldung, meldungGelb, laeuft = "fehler", grundtext(g), scharf, false
end

local function lesen()
    if lage.scharf == true then                -- scharf wird gar nicht gefragt; der Takt versucht es alle 3 s, bis entschaerft ist
        neuerVorgang()                         -- eine Frage, die noch offen ist, laeuft ins Leere und geht aus der Schlange
        fehlerMelden("armiert")
        return
    end
    if zustand ~= "bereit" and zustand ~= "fehler" then zustand = "laedt" end   -- ein Fehler bleibt stehen, bis der FC antwortet
    laeuft, start = true, zeit()
    local dieser = neuerVorgang()
    local function rot(g) if dieser == vorgang then fehlerMelden(g) end end
    local ok = statusLesen(function(b)
        if dieser ~= vorgang then return end
        start = zeit()
        bank = b
        satzLesen(function(satz)
            if dieser ~= vorgang then return end
            start = zeit()
            statusLesen(function(b2)       -- erst wenn STATUS danach dieselbe Bank nennt, gehoert der Satz dieser Bank
                if dieser ~= vorgang then return end
                if b2 ~= bank then
                    if not erstlesungWiederholt then erstlesungWiederholt = true; lesen(); return end
                    bank = (b2 >= 1 and b2 <= 3) and b2 or nil
                    zustand, meldung, laeuft = "bereit", "", false   -- zu bedienen; die Karte bleibt ungelesen bis zum naechsten Wechsel
                    return
                end
                gesehen[bank] = gesehen[bank] or {}
                gesehen[bank].drehzahl, gesehen[bank].maxgas = satz[FELD_DZ], satz[FELD_PROZENT]
                zustand, meldung, laeuft = "bereit", "", false   -- bereit erst, wenn der Satz da ist und zu dieser Bank gehoert
            end, rot)
        end, rot)
    end, rot)
    if ok == false then laeuft = false end
end

-- der Schirm ist offen, solange Takte kommen; verlassen() setzt letzterTakt zurueck
local function schirmOffen()
    return letzterTakt ~= nil and zeit() - letzterTakt <= OFFEN_NACH
end

local function speichern()
    if laeuft then hinweis = T.k_warten; return end
    if kette ~= nil then                        -- ein Schreibvorgang gehoert noch dem FC (der Schirm hat ihn vielleicht schon aufgegeben)
        if zeit() - kette.seit < VENTIL then hinweis = T.k_warten; return end
        kette = nil                             -- das Ventil: nach 30 s darf ein neuer anfangen; der alte hoert auf, sobald der neue schreibt
    end
    if zustand ~= "bereit" then return end
    if not geaendert() then hinweis = T.f_nichts_geaendert; return end
    local sperre = schreibsperre()
    if sperre then hinweis = grundtext(sperre); return end
    local a = apiHolen("governor_profile")
    if a == nil then hinweis = grundtext("msp_nicht_bereit"); return end

    local b, wert, f = sollBank, soll, feld()   -- das Feld jetzt festhalten: wechselt der Governor-Modus, gehoert die Zahl der alten Einheit
    laeuft, start = true, zeit()
    local dieser = neuerVorgang()
    hinweis = T.k_warten
    speicherStufe, speicherBis = 0, 0
    local meine = nil                           -- die Nummer der eigenen Kette, sobald der Schreibbefehl in der Schlange steht
    local function zeigt() return dieser == vorgang end   -- der Schirm zeigt diesen Vorgang noch
    -- die Kette lebt, bis sie fertig ist oder ein neuerer Schreibvorgang (nach dem Ventil) seinen Schreibbefehl abgesetzt hat
    local function lebt() return meine ~= nil and (kette == nil or kette.nr == meine) end
    local function rot(g)
        if not zeigt() then return end
        laeuft, hinweis, speicherStufe = false, grundtext(g), nil
    end
    local function daneben()
        gesehen[b] = nil
        soll, sollBank, speicherStufe = nil, nil, nil
        lesen()
        hinweis = grundtext("abweichung")
    end
    -- das Ende der Kette. Zeigt der Schirm sie nicht mehr (Zeitablauf, neu geoeffnet), holt er sich den Stand frisch vom FC;
    -- ist er zu, gibt er jetzt seinen Platz beim Dienst frei
    local function ketteEnde(g)
        if kette ~= nil and kette.nr == meine then kette = nil end
        if zeigt() then return end
        if schirmOffen() then
            gesehen[b] = nil
            if g == nil and sollBank == b and soll == wert then soll, sollBank = nil, nil end
            hinweis = g and grundtext(g) or ""
            if not laeuft then lesen() end
        elseif kette == nil and kunde ~= nil then
            if type(kunde.release) == "function" then pcall(kunde.release, kunde) end
            kunde = nil
        end
    end
    local function ende(g) rot(g); ketteEnde(g) end
    local function endeDaneben()
        if zeigt() then
            if kette ~= nil and kette.nr == meine then kette = nil end
            daneben()
            return
        end
        ketteEnde("abweichung")
    end
    -- der Schalter lag um, waehrend geschrieben wurde: welche Bank den Satz hat, weiss niemand - nichts gilt mehr als gelesen,
    -- nichts wird gesichert, der Schirm liest die Bank, auf der der FC jetzt steht, neu
    local function bankGewechselt(b2)
        gesehen[b] = nil
        if type(b2) == "number" then gesehen[b2] = nil end
        soll, sollBank = nil, nil
        ende("abweichung")
    end
    local ok = statusLesen(function(steht, scharf)
        if not zeigt() then return end
        start = zeit()
        if steht ~= b or feld() ~= f then daneben(); return end
        if scharf then rot("armiert"); return end
        satzLesen(function(alt)                  -- der ganze Satz, wie er jetzt im FC steht
            if not zeigt() then return end
            start = zeit()
            local sperre2 = schreibsperre()
            if sperre2 then rot(sperre2); return end
            local altBytes = a.buildWritePayload(alt)
            local vorher = alt[f]
            alt[f] = wert
            local neuBytes = a.buildWritePayload(alt)
            alt[f] = vorher
            if altBytes == nil or neuBytes == nil then rot("unvollstaendig"); return end
            -- ab hier gehoert der Vorgang dem FC: Ruecklesen, Vergleich, Rueckweg oder Sichern laufen zu Ende, auch wenn der
            -- Schirm aufgibt oder zugeht; nur die Anzeige folgt dem Schirm. Diese Fragen nimmt kein neuer Vorgang aus der Schlange
            speicherStufe = 1
            kettenNr = kettenNr + 1
            meine = kettenNr
            kette = {nr = meine, seit = zeit()}
            satzSchreiben(neuBytes, function()
                if not lebt() then return end
                if zeigt() then start, speicherStufe = zeit(), 2 end
                satzLesen(function(nachher)      -- ruecklesen, dann erst STATUS: was der FC anders uebernahm, wird nie dauerhaft
                    if not lebt() then return end
                    if zeigt() then start = zeit() end
                    local unveraendert = gleich(a.buildWritePayload(nachher), neuBytes)
                    statusLesen(function(steht2, scharf2)   -- nach dem Schreiben fragt der FC selbst: Bank und scharf
                        if not lebt() then return end
                        if zeigt() then start = zeit() end
                        -- MSP traegt beim Governor-Satz keine Banknummer: Lesen und Schreiben treffen die Bank, auf der der FC
                        -- gerade steht. Lag der Schalter seit dem ersten STATUS um, kann der Satz in der neuen Bank stehen, und
                        -- ein Rueckweg traefe sie auch - darum ab hier kein Schreiben mehr und nichts sichern
                        if steht2 ~= b then bankGewechselt(steht2); return end
                        if scharf2 then ende("armiert"); return end   -- scharf wird nichts mehr geschrieben: kein Rueckweg, kein Sichern
                        if not unveraendert then   -- der alte Satz geht zurueck in den FC, die Bank ist noch dieselbe
                            satzSchreiben(altBytes, function() if lebt() then endeDaneben() end end,
                                          function() if lebt() then ende("abweichung") end end, true)
                            return
                        end
                        fragen("eeprom_write", {}, function()
                            if not lebt() then return end
                            if zeigt() then start, speicherStufe = zeit(), 3 end
                            satzLesen(function(gp)
                                if not lebt() then return end
                                if gp[f] ~= wert then endeDaneben(); return end
                                if zeigt() then
                                    laeuft = false
                                    gesehen[b] = gesehen[b] or {}
                                    if f == FELD_PROZENT then gesehen[b].maxgas = wert else gesehen[b].drehzahl = wert end
                                    soll, sollBank, hinweis = nil, nil, ""
                                    speicherStufe, speicherBis = 4, zeit() + 200
                                    local ton = _G.playTone
                                    if ton then pcall(ton, 880, 120, 0) end
                                end
                                ketteEnde(nil)
                            end, function(g) if lebt() then ende(g) end end, true)
                        end, function(g) if lebt() then ende(g == "schreiben_abgelehnt" and "eeprom_fehler" or g) end end, nil, true)
                    end, function(g) if lebt() then ende(g) end end, true)
                end, function() if lebt() then ende("ruecklesen_offen") end end, true)
            end, function(g) if lebt() then ende(g) end end, true)
        end, rot)
    end, rot)
    if ok == false then laeuft = false end
end

local function stellbar(i)                     -- nur die Bank, auf der der FC steht, und nur wenn geschrieben werden darf
    if i == nil or bank ~= i or lage.bank ~= i then return false end
    if zustand ~= "bereit" or laeuft then return false end
    if govModus == nil or gesehen[i] == nil or wertVon(gesehen[i]) == nil or grenzen() == nil then return false end
    return schreibsperre() == nil
end

local function stellen(i, richtung)
    if not stellbar(i) then return end
    local g = grenzen()
    local schrittweite = (type(g.step) == "number" and g.step > 0) and g.step or 1
    if soll == nil or sollBank ~= i then soll, sollBank = wertVon(gesehen[i]), i end
    soll = math.max(g.min, math.min(g.max, soll + richtung * schrittweite))
    hinweis = ""
end

local function ausloesen(name, n)
    if name == "speichern" then speichern(); return end
    local i = lage.bank
    if name == "minus" or name == "plus" then
        if i == nil then return end
        if not stellbar(i) then
            stellt = false
            local sperre = schreibsperre()
            if sperre then hinweis = grundtext(sperre) end
            return
        end
        stellen(i, (name == "plus") and 1 or -1)
        return
    end
    hinweis = ""
    if n == i then
        wahl = nil
        radBank, stellt = n, stellbar(n)
        if not stellt then
            local sperre = schreibsperre()
            if sperre then hinweis = grundtext(sperre) end
        end
        return
    end
    radBank, stellt = nil, false
    wahl = (wahl ~= n) and n or nil
end

local function oeffnen()
    bank = nil
    neuVersuchAb = 0
    zustand, meldung, laeuft = "laedt", "", false
    wahl, radBank, stellt = nil, nil, false
    letzteBank = lage.bank
    erstlesungWiederholt = false
    soll, sollBank, hinweis = nil, nil, ""
    govGelesen, govVersuche = false, 0
    speicherStufe, arbeitSeit = nil, nil
    lesen()
end

local function verlassen()
    neuerVorgang()                             -- offene Rueckrufe laufen ins Leere, eine offene Frage geht aus der Schlange
    laeuft, erstlesungWiederholt = false, false
    letzterTakt = nil
    warVerbunden = false
    if kunde ~= nil and kette == nil then      -- der Platz beim MSP-Dienst der Suite wird frei; der naechste Schirm meldet sich neu an.
        if type(kunde.release) == "function" then pcall(kunde.release, kunde) end   -- Laeuft ein Schreibvorgang, gibt sein Ende ihn frei
        kunde = nil
    end
end

local deckelMarke, deckelMerk = nil, nil
local function deckelText()                    -- regelt der FC die Drehzahl, deckelt das Max-Gas seinen Ausgang: 99 gilt als voll
    if prozent() then return nil end
    local marke = 0
    for i = 1, 3 do
        local g = gesehen[i]
        marke = marke * 256 + ((g and g.maxgas) or 255)
    end
    if marke ~= deckelMarke then               -- der Text wird nur neu gesetzt, wenn sich ein Max-Gas aendert
        local text = nil
        for i = 1, 3 do
            local g = gesehen[i]
            if g ~= nil and g.maxgas ~= nil and g.maxgas < 99 then
                text = (text and (text .. ", ") or (T.maxgas .. " ")) .. "BANK " .. i .. " " .. floor(g.maxgas) .. " %"
            end
        end
        deckelMarke, deckelMerk = marke, text
    end
    return deckelMerk
end

-- der Takt: liest die Lage aus dem Zustand der Suite, treibt Lesen und Fristen und legt in anz ab, was der Schirm zeigt
local function takt(state)
    state = state or {}
    local d = state.derived or {}
    local jetzt = zeit()
    lage.verbunden = state.rfConnected == true
    lage.scharf = nil
    if lage.verbunden and state.armed ~= nil then lage.scharf = (state.armed == true) end
    local b = tonumber(d.pid_profile) or tonumber(state.profile)
    lage.bank = (lage.verbunden and b) and floor(b) or nil
    local rpm = tonumber(d.rpm) or tonumber(state.rpm)
    lage.rpm = (lage.verbunden and rpm and rpm > 0) and floor(rpm + 0.5) or nil
    if D == nil then return end
    -- eben entschaerft: der Satz fuer scharf gilt nicht mehr. Nur beim Wechsel - meldet der FC selbst scharf, waehrend die
    -- Telemetrie unscharf sagt, bleibt der Satz stehen
    if scharfVorher == true and lage.scharf ~= true and hinweis == T.grund.armiert then
        hinweis = ""
        if not laeuft and zustand == "bereit" and lage.bank ~= nil then lesen() end   -- was scharf stehen blieb, wird frisch gelesen
    end
    scharfVorher = lage.scharf

    if letzterTakt == nil or jetzt - letzterTakt > WEG_NACH then warVerbunden = false end
    if letzterTakt == nil or jetzt - letzterTakt > OFFEN_NACH then oeffnen() end
    letzterTakt = jetzt
    if lage.verbunden then warVerbunden, weg = true, false
    elseif warVerbunden then weg = true end     -- der Heli ist weg, waehrend der Schirm offen ist: der Schirm schliesst

    -- ein anderer FC (andere Kennung): was von den Baenken des vorigen gelesen war, gilt nicht mehr. Dieselbe Kennung behaelt es
    local id = rfsuite and type(rfsuite.session) == "table" and rfsuite.session.mcu_id or nil
    if id ~= nil and id ~= kennung then
        if kennung ~= nil then
            gesehen, simSatz = {}, nil
            govModus, govGelesen, govVersuche = nil, false, 0
            soll, sollBank, bank = nil, nil, nil
            if not laeuft and lage.bank ~= nil then lesen() end
        end
        kennung = id
    end
    if not govGelesen and not govLesen and not laeuft and zustand == "bereit" then   -- welcher Governor-Modus: Drehzahl oder Max-Gas
        govLesen = true
        local a = apiHolen("governor_config")
        local ok = fragen("governor_config", nil, function(buf)
            govLesen = false
            local gc = a.parse(buf)
            local vorher = govModus
            govModus = (type(gc) == "table" and type(gc.gov_mode) == "number") and gc.gov_mode or false
            if type(govModus) == "number" and vorher ~= nil and vorher ~= govModus then soll, sollBank = nil, nil end
            govGelesen = true
        end, function()
            govLesen, govVersuche = false, govVersuche + 1
            if govVersuche >= 3 then govGelesen = true end
        end, nil, true)
        if ok == false then govLesen = false end
    end
    -- scharf geworden, waehrend das erste Lesen lief oder ein Lesefehler dastand: sofort der Satz fuer scharf
    if lage.scharf == true and ((laeuft and zustand == "laedt") or (zustand == "fehler" and not meldungGelb)) then
        neuerVorgang()
        fehlerMelden("armiert")
    end
    if laeuft and jetzt - start > ZEITABLAUF then
        neuerVorgang()                         -- eine offene Lesefrage geht aus der Schlange; ein Schreibvorgang laeuft als kette weiter
        local schrieb = speicherStufe ~= nil or hinweis == T.k_warten
        laeuft, speicherStufe = false, nil
        if schrieb then hinweis = grundtext("zeitablauf")   -- die Anzeige gibt den Schreibvorgang auf, die Kette liest am Ende neu
        else fehlerMelden("zeitablauf") end                  -- ein Lesen ohne Antwort ist ein Fehler: der Takt liest alle 3 s neu
    end
    if zustand == "fehler" and not laeuft and jetzt > neuVersuchAb then   -- nach einem Fehler alle 3 s nochmal
        neuVersuchAb = jetzt + NEUVERSUCH
        lesen()
    end
    if soll ~= nil and lage.bank ~= nil and lage.bank ~= sollBank then   -- der Schalter liegt um: die gestellte Zahl gehoerte der alten Bank
        soll, sollBank, hinweis = nil, nil, ""
        radBank, stellt = nil, false
    end
    if lage.bank ~= letzteBank and not laeuft then   -- waehrend einer Anfrage bleibt der Wechsel offen und wird danach gelesen
        letzteBank = lage.bank
        if lage.bank ~= nil then lesen() end
    end
    if stellt and not stellbar(radBank) then stellt = false end
    if speicherStufe == 4 and jetzt >= speicherBis then speicherStufe = nil end

    for i = 1, 3 do
        local k = anz[i]
        local aktiv, gewaehlt = (lage.bank == i), (wahl == i)
        local amStellen = aktiv and stellt and radBank == i
        local g = gesehen[i]
        local dz = g and wertVon(g)
        local gestellt = (dz ~= nil and sollBank == i and soll ~= nil and soll ~= dz)
        if gestellt then dz = soll end
        local laufend = aktiv and lage.rpm ~= nil and (lage.scharf == true or not gestellt)
        if laufend then dz, gestellt = lage.rpm, false end
        k.bild = S.bild[i][(amStellen and "stellt") or (aktiv and "aktiv") or (gewaehlt and "gewaehlt") or (dz and "mit") or "ohne"]
        k.farbe = gestellt and "y" or (aktiv and "c" or "w")
        if dz ~= k.dz then
            k.dz = dz
            k.text = dz and string.format("%d", floor(dz)) or nil
            k.n = k.text and #k.text or 0
            k.links = S.karte[i].mitte - floor(k.n * D.zahl.adv / 2)
        end
        k.mitte = dz and "zahl" or ((g == nil) and "ungelesen" or "strich")
        k.einheit = dz and (((laufend or not prozent()) and "umin") or "proz") or nil
    end
    anz.stellBank = stellt and radBank or nil
    anz.speichernGruen = (zustand == "bereit" and geaendert())

    local text, farbe = nil, nil
    if zustand == "fehler" then text, farbe = meldung, meldungGelb and D.farben.GELB or D.farben.ROT
    elseif not lage.verbunden then text, farbe = T.f_kein_heli, D.farben.ROT
    elseif hinweis ~= "" then text, farbe = hinweis, D.farben.GELB
    elseif zustand ~= "bereit" then text, farbe = T.laeuft, D.farben.NEON
    else
        text = deckelText()
        farbe = D.farben.ROT
    end
    local arbeit = (text == T.laeuft or text == T.k_warten or (text ~= nil and text == T.grund.msp_nicht_bereit))
    if arbeit then text = nil end               -- ein Arbeitswort steht nicht da: dafuer laeuft der Balken
    anz.balken, anz.stufe = nil, 0
    if speicherStufe ~= nil then
        anz.balken, anz.stufe = "speichern", speicherStufe
        arbeitSeit = nil
    elseif arbeit then
        if arbeitSeit == nil then arbeitSeit = jetzt end
        anz.balken, anz.stufe = "arbeit", math.max(0, math.min(#D.felder - 1, floor((jetzt - arbeitSeit) / 100)))
    else
        arbeitSeit = nil
    end
    anz.text, anz.textFarbe = text or "", farbe or 0
    anz.klein = text ~= nil and #text > 60
    anz.band = (text ~= nil) or (anz.balken ~= nil)
end

local function rgb(t) return RGB(t[1], t[2], t[3]) end

-- jede Stelle einer Karte ist ein fester Baustein, der Bild, Ort und Sichtbarkeit selbst nachfragt: gebaut wird einmal
local function ziffer(i, stelle)
    local lc, lf, datei = nil, nil, ORDNER .. "b/zw/48.png"
    return function()
        local k = anz[i]
        local c = k.text and byte(k.text, stelle)
        if c ~= nil and (c ~= lc or k.farbe ~= lf) then
            lc, lf, datei = c, k.farbe, ORDNER .. "b/z" .. k.farbe .. "/" .. c .. ".png"
        end
        return datei
    end
end

-- EdgeTX zeichnet um den Knopf, auf dem Rad und ENTER stehen, einen blauen Rahmen ausserhalb seiner Flaeche. Der Knopf sitzt
-- darum in einem Kasten, der genau so gross ist wie er: der Kasten schneidet ab, was ueber ihn hinausragt
local function knopf(n, l, kinder, druck, sichtbar)
    n[#n + 1] = {type = "box", x = l[1], y = l[2], w = l[3], h = l[4], borderPad = 0, visible = sichtbar, children = {
        {type = "button", x = 0, y = 0, w = l[3], h = l[4], cornerRadius = 0, color = D.bandRgb, children = kinder, press = druck}}}
end

local function datenLaden()
    local d = laden("bank_daten.lua")
    if d == nil then return false end
    sprache = "en"
    local ok, e = pcall(getGeneralSettings)
    local s = ok and type(e) == "table" and type(e.language) == "string" and string.lower(e.language) or nil
    if s and d.sprache[s] then sprache = s end
    S = d.sprache[sprache]
    T = S.T
    d.bandRgb = rgb(d.bandFarbe)
    for k, v in pairs(d.farben) do d.farben[k] = rgb(v) end
    local o = ORDNER .. "b/" .. sprache .. "/k"
    S.bild = {}
    for i = 1, 3 do
        S.bild[i] = {aktiv = o .. i .. "_aktiv.png", stellt = o .. i .. "_stellt.png", gewaehlt = o .. i .. "_gewaehlt.png",
                     mit = o .. i .. "_mit.png", ohne = o .. i .. "_ohne.png"}
    end
    D = d
    return true
end

-- Laden und Bauen in einem Aufruf: die Suite haelt den Schluessel einer Ansicht gleich nach dem Bau fest, ein zweiter
-- Schritt kaeme erst dran, wenn sich sonst etwas aendert
local function bauen(zone, state, ctx)
    ctxJetzt = ctx
    local n = {}
    n[#n + 1] = {type = "image", x = 0, y = 0, w = 800, h = 480, file = ORDNER .. "b/grund.png"}
    if D == nil and not datenLaden() then return n end
    zu = false
    takt(state)
    if weg and ctx then               -- darunter steht dann, was die Suite ohne Heli zeigt
        weg, zu = false, true
        verlassen()
        ctx.action("closeView")
        return n
    end

    local o = ORDNER .. "b/" .. sprache .. "/"
    local kx, ky = D.knopf[1], D.knopf[2]     -- Kinder eines Knopfs sitzen in seinem Inneren: um Rand und Abstand versetzt
    local ti = S.titel
    n[#n + 1] = {type = "image", x = ti[1], y = ti[2], w = ti[3], h = ti[4], file = o .. "titel.png"}

    local Z = D.zahl
    for i = 1, 3 do
        local K = S.karte[i]
        local dx, dy = K.x + kx, K.y + ky
        local kinder = {}
        kinder[#kinder + 1] = {type = "image", x = -kx, y = -ky, w = K.w, h = K.h, file = function() return anz[i].bild end}
        local function teil(l, datei, art, wert)
            kinder[#kinder + 1] = {type = "image", x = l[1] - dx, y = l[2] - dy, w = l[3], h = l[4], file = o .. "k" .. i .. datei,
                                   visible = function() return anz[i][art] == wert end}
        end
        teil(K.ungelesen, "_ungelesen.png", "mitte", "ungelesen")
        teil(K.strich, "_strich.png", "mitte", "strich")
        teil(K.umin, "_umin.png", "einheit", "umin")
        teil(K.proz, "_proz.png", "einheit", "proz")
        local oben = K.zahlY - floor(Z.h / 2) + Z.zy - dy
        for s = 1, STELLEN do
            local versatz = (s - 1) * Z.adv + Z.zx - dx
            kinder[#kinder + 1] = {type = "image", w = Z.zw, h = Z.zh, file = ziffer(i, s),
                                   pos = function() return (anz[i].links or 0) + versatz, oben end,
                                   visible = function() return anz[i].mitte == "zahl" and s <= (anz[i].n or 0) end}
        end
        knopf(n, {K.x, K.y, K.w, K.h}, kinder, function() ausloesen("bank", i) end)
    end
    for i = 1, 3 do
        local K = S.karte[i]
        local function stell(l, datei, name)
            knopf(n, l, {{type = "image", x = -kx, y = -ky, w = l[3], h = l[4], file = o .. "k" .. i .. datei}},
                  function() ausloesen(name) end, function() return anz.stellBank == i end)
        end
        stell(K.minus, "_minus.png", "minus")
        stell(K.plus, "_plus.png", "plus")
    end

    local zl, sp = S.zurueck, S.speichern
    knopf(n, zl, {{type = "image", x = -kx, y = -ky, w = zl[3], h = zl[4], file = o .. "zurueck.png"}}, function()
        verlassen()
        if ctxJetzt then ctxJetzt.action("closeView") end
    end)
    local gruen, leise = o .. "speichern_gruen.png", o .. "speichern_leise.png"
    knopf(n, sp, {{type = "image", x = -kx, y = -ky, w = sp[3], h = sp[4],
                   file = function() return anz.speichernGruen and gruen or leise end}}, function() ausloesen("speichern") end)

    -- die Meldezeile wie in NovaFly: ein dunkles Band, links der Text in der Schrift der Firmware, rechts die vier Felder
    local bd = D.band
    n[#n + 1] = {type = "rectangle", x = bd[1], y = bd[2], w = bd[3], h = bd[4], filled = true, color = D.bandRgb,
                 visible = function() return anz.band end}
    n[#n + 1] = {type = "label", x = D.text[1], y = D.text[2], w = 780, font = function() return anz.klein and SYS_KLEIN or 0 end,
                 text = function() return anz.text end, color = function() return anz.textFarbe end}
    local cGruen, cCyan, cLinie = D.farben.GRUEN, D.farben.CYAN, D.farben.LINIE
    for i = 1, #D.felder do
        local f = D.felder[i]
        n[#n + 1] = {type = "rectangle", x = f[1], y = f[2], w = f[3], h = f[4], thickness = 1,
                     filled = function() return i <= anz.stufe end,
                     color = function()
                         if i > anz.stufe then return cLinie end
                         return anz.balken == "speichern" and cGruen or cCyan
                     end,
                     visible = function() return anz.balken ~= nil end}
    end
    return n
end

local M = {}

function M.sources() return {"pid_profile", "rpm"} end

function M.renderKey(zone, state)
    if D == nil then return "bank|leer|" .. floor(zeit() / 300) end   -- die Daten fehlen: alle 3 s ein neuer Versuch
    if zu then return "bank|zu" end
    local ok, grund = pcall(takt, state)
    if not ok then merken("bank takt: " .. tostring(grund)) end
    return weg and "bank|weg" or "bank"
end

function M.build(children, zone, state, ctx)
    local ok, n = pcall(bauen, zone, state, ctx)
    if not ok then
        merken("bank build: " .. tostring(n))
        -- der Fehler als Text; RTN schliesst den Schirm (M.back)
        n = {{type = "label", x = 10, y = 10, w = 780, text = tostring(n), color = RGB(255, 80, 80)}}
    end
    for i = 1, #n do children[#children + 1] = n[i] end
end

function M.back(ctx)
    verlassen()
    ctx.action("closeView")
end

MERK.M, MERK.suite, MERK.msp = M, rfsuite, rfsuite and rfsuite.msp
return M
