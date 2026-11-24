-- SEITEN: die Bausteine der zwei Displays neben dem Cockpit (VORFLUG links, BAENKE rechts) wie die Ethos-Fassung: Chips aus
-- den Linien des Cockpits mit Ecken r 4, die erste oder letzte Kante offen zum Schirmrand; Zeilen aus Stuecken (Zahl gross,
-- Einheit klein), unten buendig; fuenf Empfangsbalken. Lagen im Bezugsmass 480 x 320 (R.sx, R.sy, R.kx, R.ky). Text, Farbe und
-- Ort eines Stuecks nennen Funktionen, die nur lesen, was stand() rechnet; eine Zeile liest ihre Texte einmal je Takt (G.takt) und
-- rechnet den Ort nur neu, wenn sich ein Text aendert. Eine Zeile aus lauter festen Texten steht fest und braucht keine Funktion.
return function(T)
    local R, FARBE, G = T.R, T.FARBE, T.G
    local floor = math.floor
    local P = {}
    local AUS = 40                                   -- so weit liegt eine offene Kante ausserhalb des Schirms
    P.LEISE = lcd.RGB(158, 170, 184)                 -- leere Felder und Balken wie die Ethos-Fassung (stil.FELD_LEISE)

    function P.chip(n, L, x, y, w, h, offen)         -- der Kern der Vorlage in Spalte x und x + w, Zeile y und y + h; offen = "links" oder "rechts"
        local l, r = R.kx(x), R.kx(x + w) + 1
        local o, u = R.ky(y), R.ky(y + h) + 1
        if offen == "links" then l = -AUS end
        if offen == "rechts" then r = R.W - 1 + AUS end
        R.feld(n, L, l, o, r - l + 1, u - o + 1, R.RUND)
    end

    function P.flaeche(n, x, y, w, h, farbe, sichtbar)   -- eine Flaeche in Bildpunkten des Schirms; farbe und sichtbar duerfen Funktionen sein
        n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, filled = true, color = farbe, visible = sichtbar}
    end

    function P.zeile(n, cx, cy, segs, lage, dx, dy)   -- segs = {{text, farbe, font}, ...}; cx, cy in Bildpunkten, cy die Mitte der Zeile; lage "links", "rechts" oder mittig
        dx, dy = dx or 0, dy or 0
        local k = #segs
        local z = {texte = {}, x = {}, y = {}, b = {}, h = {}, fertig = false, takt = false}   -- b, h: Breite und Hoehe je Stueck
        local fest, hoehe = true, 0
        for i = 1, k do
            if type(segs[i][1]) == "function" then fest = false end
            z.h[i] = T.hoehe(segs[i][3])                -- die Schrift eines Stuecks bleibt: seine Hoehe auch
            if z.h[i] > hoehe then hoehe = z.h[i] end
        end
        local oben = cy - floor(hoehe / 2)
        local function rechnen()
            if z.takt == G.takt then return end
            z.takt = G.takt
            local neu = not z.fertig
            for i = 1, k do
                local tx = segs[i][1]
                if type(tx) == "function" then tx = tx() end
                tx = tx ~= nil and tostring(tx) or ""
                if z.texte[i] ~= tx or not z.fertig then   -- gemessen wird nur ein Stueck, dessen Text sich aendert
                    z.texte[i], z.b[i], neu = tx, tx ~= "" and T.breite(tx, segs[i][3]) or 0, true
                end
            end
            if not neu then return end
            z.fertig = true
            local breite = -T.LUECKE
            for i = 1, k do breite = breite + z.b[i] + T.LUECKE end
            local x = cx - floor(breite / 2)
            if lage == "links" then x = cx elseif lage == "rechts" then x = cx - breite end
            for i = 1, k do
                z.x[i], z.y[i] = x - dx, oben + hoehe - z.h[i] - ((i > 1) and 1 or 0) - dy
                x = x + z.b[i] + T.LUECKE
            end
        end
        if fest then
            rechnen()
            for i = 1, #segs do
                local s = segs[i]
                n[#n + 1] = {type = "label", x = z.x[i], y = z.y[i], w = 0, font = s[3], color = s[2], text = z.texte[i]}
            end
            return
        end
        for i = 1, #segs do
            local s = segs[i]
            n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = s[3], color = s[2],
                         text = function() rechnen() return z.texte[i] end,
                         pos = function() rechnen() return z.x[i], z.y[i] end}
        end
    end

    function P.wort(n, x, cy, text, farbe, font, lage, dx, dy)   -- ein festes Wort: mittig um x, ab x (links) oder bis x (rechts)
        dx, dy = dx or 0, dy or 0
        local b, h = T.breite(text, font), T.hoehe(font)
        local links = x - floor(b / 2)
        if lage == "links" then links = x elseif lage == "rechts" then links = x - b end
        n[#n + 1] = {type = "label", x = links - dx, y = cy - floor(h / 2) - dy, w = 0, font = font, text = text, color = farbe}
    end

    function P.empfang(n, x, unten, voll, farbe, dx, dy)   -- fuenf Balken wie am Sender, steigend 6 bis 18 (Bezugsmass); voll und farbe Funktionen
        dx, dy = dx or 0, dy or 0
        for i = 0, 4 do
            local hb = 6 + i * 3
            local x0, y0 = R.sx(x + i * 6), R.sy(unten - hb)
            local nr = i
            P.flaeche(n, x0 - dx, y0 - dy, R.sx(x + i * 6 + 4) - x0, R.sy(unten) - y0, function() return nr < voll() and farbe() or P.LEISE end)
        end
    end

    local api = {}
    local function apiHolen(name)                    -- der Satz der Suite (tasks/msp/api/<name>.lua): command, parse, Antwort im Simulator
        if api[name] == nil then
            local m = nil
            if rfsuite and type(rfsuite.require) == "function" then
                local ok, r = pcall(rfsuite.require, "tasks/msp/api/" .. name .. ".lua")
                if ok and type(r) == "table" and type(r.parse) == "function" then m = r end
            end
            api[name] = m or false
        end
        return api[name] or nil
    end

    function P.kunde()                               -- ein Platz beim MSP-Dienst der Suite (rfsuite.msp), einmal fuer das Theme, gemerkt ueber jedes Neuladen
        local G = T.G
        if G.mspKunde == nil and rfsuite and type(rfsuite.msp) == "table" and type(rfsuite.msp.register) == "function" then
            local ok, k = pcall(rfsuite.msp.register, "novafly-theme")
            if ok and type(k) == "table" then G.mspKunde = k end
        end
        return G.mspKunde
    end

    function P.lesen(name, fertig)                   -- liest einen Satz; fertig(werte) oder fertig(nil, grund) genau einmal; false, wenn nichts abging
        local a, k = apiHolen(name), P.kunde()
        if a == nil or k == nil or type(k.request) ~= "function" then return false end
        local einmal = false
        local ok, id = pcall(k.request, k, {
            command = a.command,
            simulatorResponse = a.simulatorResponse,
            onReply = function(buf)
                if einmal then return end
                einmal = true
                local ok2, w = pcall(a.parse, buf)
                if ok2 and type(w) == "table" then fertig(w) else fertig(nil, "unvollstaendig") end
            end,
            onError = function(g)
                if einmal then return end
                einmal = true
                fertig(nil, g)
            end,
        })
        if not ok or id == nil then einmal = true return false end
        return true
    end

    function P.apiAlt()                              -- vor API 12.09 heissen die Modi des Governors anders (OFF, PASSTHROUGH, STANDARD, MODE1, MODE2)
        local v = nil
        if rfsuite and type(rfsuite.msp) == "table" and type(rfsuite.msp.status) == "function" then
            local ok, st = pcall(rfsuite.msp.status)
            if ok and type(st) == "table" then v = tonumber(st.apiVersion) end
        end
        if v == nil and rfsuite and type(rfsuite.session) == "table" then v = tonumber(rfsuite.session.apiVersion) end
        return v ~= nil and v < 12.09
    end

    return P
end
