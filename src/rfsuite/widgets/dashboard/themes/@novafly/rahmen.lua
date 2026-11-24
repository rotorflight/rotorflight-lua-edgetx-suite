-- RAHMEN des Themes fuer EdgeTX: die Linien des Cockpits als Bausteine der Suite (lvgl) auf dem einen Grund, in der gewaehlten
-- Farbe; die Masse der Ethos-Fassung (480 x 320) auf die Schirmgroesse des Senders umgerechnet (800 x 480, 480 x 320, 480 x 272). Eine Linie ist vier Punkte Mittelton mit zwei Punkten
-- hellem Kern und aussen je einem Punkt Schein. Ein Feld mit Rundungen ist ein hohler Baustein je Lage, eine offene Seite liegt
-- ausserhalb des Schirms; das Mittelfeld hat oben keine Kante, dort liegt der Absatz als Maske (gfx/absatz_<farbe>.png), seine
-- unteren Ecken sind Boegen. KX(c), KY(r) rechnen eine Linie der Vorlage in die erste Spalte und Zeile ihres Kerns um.
local R = {}
local floor, sin, cos, rad, min, max = math.floor, math.sin, math.cos, math.rad, math.min, math.max

local W, H = tonumber(LCD_W) or 800, tonumber(LCD_H) or 480   -- die Schirmgroesse des Senders, gewoehnlich gelesen: die Suite laedt das Theme in einer eigenen Umgebung
local GROSS800 = W >= 700
R.W, R.H, R.GROSS800 = W, H, GROSS800
R.GFX = GROSS800 and "gfx/" or ("gfx_" .. W .. "x" .. H .. "/")   -- der Ordner der Bilder fuer diese Schirmgroesse

function R.sx(v) return floor(v * W / 480 + 0.5) end   -- sx, sy, kx, ky: Lagen im Bezugsmass 480 x 320 auf diesen Schirm; px, py: Bildpunkte der Fassung fuer 800 x 480
function R.sy(v) return floor(v * H / 320 + 0.5) end
function R.kx(c) return floor(c * W / 480 + 1 / 3) end   -- erste Spalte des Kerns einer senkrechten Linie der Vorlage in Spalte c
function R.ky(r) return floor(r * H / 320 + 0.25) end    -- erste Zeile des Kerns einer waagrechten Linie der Vorlage in Zeile r
function R.px(v) return floor(v * W / 800 + 0.5) end     -- Bildpunkte der Fassung fuer 800 x 480 in der Breite
function R.py(v) return floor(v * H / 480 + 0.5) end     -- und in der Hoehe; Radien rechnen mit py, damit ein Kreis rund bleibt
local kx, ky, px, py = R.kx, R.ky, R.px, R.py

R.KERN, R.MITTE, R.SCHEIN = GROSS800 and 2 or 1, GROSS800 and 4 or 3, GROSS800 and 6 or 5   -- 480er Schirme wie die Ethos-Fassung in 480 x 320: Kern 1, Mittelton 3, Schein 5
R.RUND = GROSS800 and 7 or 5                  -- aeusserer Radius des Kerns an einer Ecke der Vorlage mit r 4 (6 Punkte, der Kern 1,5 aussen davon; bei 480: r 4 und der halbe Kern)
R.GRUEN, R.GELB, R.ROT = {12, 228, 16}, {245, 224, 26}, {240, 35, 12}
R.NADEL, R.GRAU = {255, 80, 80}, {134, 138, 145}
R.GROSS = {r = py(152), anfang = -104.4, ende = 104.4, fuss = py(90), spitze = py(132), striche = "striche_gross.png", strichKante = 2 * (py(152) + py(4)) + 2}   -- die zwei Tachos: Bogen und Pfeil (GROSS) oder Balken (KLEIN); Winkel wie Ethos (0 = oben), gruen bis 78 %, gelb bis 90 %, dann rot
R.KLEIN = {r = py(70), anfang = -135, ende = 100, balkenInnen = py(48), balkenAussen = py(54), striche = "striche_klein.png", strichKante = 2 * (py(70) + py(4)) + 2}
R.AUSLAUF_LINKS = {{5, 394}, {55, 200}, {250, 225}, {255, 215}}   -- je Linie einer Seite: Zeile der Vorlage und wie weit sie vom Cockpit her ins Bild reicht (Ethos rahmen.lua AUSLAUF_*); die unterste (314) fehlt auf VORFLUG: sie lag dicht unter dem letzten Fusschip und machte seinen Rand doppelt
R.AUSLAUF_RECHTS = {{5, 394}, {55, 330}, {250, 225}, {255, 215}, {314, 120}}
R.AUSLAUF_WEICH = px(200)                     -- Laenge des Verlaufs am Ende einer Linie (Ethos 120)
R.ABSATZ = {x = px(190), y = py(51), w = px(420), h = py(48)}
R.KNOPF_DX, R.KNOPF_DY = GROSS800 and 10 or 8, GROSS800 and 5 or 4   -- Kinder eines Knopfs sitzen in seinem Inneren (800: Rand 2, Abstand 8 und 3; 480: 8 und 4, im Simulator gemessen): so weit zurueck

function R.rgb(t) return lcd.RGB(t[1], t[2], t[3]) end

function R.farben(e)                          -- {mitte, kern, schein} aus farben.lua als Farben des Senders
    return {mitte = R.rgb(e.mitte), kern = R.rgb(e.kern), schein = R.rgb(e.schein)}
end

local function rect(n, x, y, w, h, farbe)
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, filled = true, color = farbe}
end

function R.waagrecht(n, F, k, x0, x1)        -- Kern in den Zeilen k und k+1, von Spalte x0 bis x1 (einschliesslich)
    rect(n, x0, k - 2, x1 - x0 + 1, R.SCHEIN, F.schein)
    rect(n, x0, k - 1, x1 - x0 + 1, R.MITTE, F.mitte)
    rect(n, x0, k, x1 - x0 + 1, R.KERN, F.kern)
end

function R.senkrecht(n, F, k, y0, y1)
    rect(n, k - 2, y0, R.SCHEIN, y1 - y0 + 1, F.schein)
    rect(n, k - 1, y0, R.MITTE, y1 - y0 + 1, F.mitte)
    rect(n, k, y0, R.KERN, y1 - y0 + 1, F.kern)
end

function R.feld(n, F, x, y, w, h, r)   -- ein Feld mit runden Ecken: x, y, w, h ist der Kern (zwei Punkte, innen am Rand), Mittelton und Schein je einen Punkt weiter aussen; r = aeusserer Kern-Radius
    n[#n + 1] = {type = "rectangle", x = x - 2, y = y - 2, w = w + 4, h = h + 4, thickness = R.SCHEIN, rounded = r + 2, color = F.schein}
    n[#n + 1] = {type = "rectangle", x = x - 1, y = y - 1, w = w + 2, h = h + 2, thickness = R.MITTE, rounded = r + 1, color = F.mitte}
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, thickness = R.KERN, rounded = r, color = F.kern}
end

function R.ecke(n, F, cx, cy, r, a0, a1)   -- eine runde Ecke allein: drei Boegen um cx, cy, a0 bis a1 nach lvgl (0 rechts, im Uhrzeigersinn); ein arc mit radius r deckt sich mit der Ecke eines runden Rechtecks
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r + 2, thickness = R.SCHEIN, startAngle = a0, endAngle = a1, color = F.schein}
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r + 1, thickness = R.MITTE, startAngle = a0, endAngle = a1, color = F.mitte}
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r, thickness = R.KERN, startAngle = a0, endAngle = a1, color = F.kern}
end

function R.rahmen(n, F, x, y, w, h)          -- ein duenner Rahmen nur im Kern (die Batterie)
    n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, thickness = R.KERN, color = F.kern}
end

function R.batterie(n, F, dx, dy)            -- die Batterie: Rahmen und Kappe (ihre Balken malt das Cockpit); dx, dy, wenn sie als Kind eines Knopfs liegt - im Vollbild verdeckt das Gesicht des Akku-Knopfs den Rahmen darunter
    R.rahmen(n, F, kx(136) - dx, ky(267) - dy, kx(155) + 1 - kx(136) + 1, ky(301) + 1 - ky(267) + 1)
    rect(n, kx(142) - dx, ky(263) - 1 - dy, R.sx(8), ky(267) - (ky(263) - 1), F.kern)
end

function R.cockpit(n, F)   -- der ganze Rahmen, links und rechts offen, ohne obere Linie neben dem Mittelfeld; ein hohles Feld nimmt im Vollbild jeden Druck: die Knoepfe kommen nach dem Rahmen, die Maske des Absatzes nach den Knoepfen
    local AUS = 40                            -- so weit liegt eine offene Seite ausserhalb des Schirms
    R.waagrecht(n, F, ky(5), 0, W - 1)                                            -- die Linie oben
    R.feld(n, F, -AUS, ky(55), kx(116) + 1 + AUS, ky(250) + 1 - ky(55) + 1, R.RUND)   -- das linke Feld, links offen
    R.feld(n, F, kx(363), ky(55), W + AUS - kx(363), ky(250) + 1 - ky(55) + 1, R.RUND)  -- das rechte Feld, rechts offen
    local l, r, u = kx(121), kx(358) + 1, ky(252)   -- das Mittelfeld: Seiten bei 121 und 358 von unter dem Absatz bis zu den Ecken, Boden bei 252, Ecken r 4 als Boegen; erste Kern-Spalte links, letzte rechts, erste Kern-Zeile unten
    local ab, bis = R.ABSATZ.y + R.ABSATZ.h, u + 1 - R.RUND     -- die Seiten: erste Zeile unter der Maske bis ueber die Ecke
    R.senkrecht(n, F, l, ab, bis)
    R.senkrecht(n, F, r - 1, ab, bis)
    R.waagrecht(n, F, u, l + R.RUND, r - R.RUND)
    R.ecke(n, F, l + R.RUND, u + 2 - R.RUND, R.RUND, 90, 180)
    R.ecke(n, F, r + 1 - R.RUND, u + 2 - R.RUND, R.RUND, 0, 90)
    local oben, hoehe = ky(255), ky(314) + 1 - ky(255) + 1   -- die Fussreihe (255 bis 314): drei Felder, links und rechts offen, Ecken r 4
    R.feld(n, F, -AUS, oben, kx(117) + 1 + AUS, hoehe, R.RUND)
    R.feld(n, F, kx(121), oben, kx(358) + 1 - kx(121) + 1, hoehe, R.RUND)
    R.feld(n, F, kx(362), oben, W + AUS - kx(362), hoehe, R.RUND)
    R.batterie(n, F, 0, 0)                    -- die Batterie unten links im Mittelfeld der Fussreihe; der Kasten um die Tankanzeige ist weg
end

function R.absatz(n, ordner, farbe)          -- der Absatz oben am Mittelfeld: die Maske in der Farbe (nur die Linien, sonst durchsichtig)
    n[#n + 1] = {type = "image", x = R.ABSATZ.x, y = R.ABSATZ.y, w = R.ABSATZ.w, h = R.ABSATZ.h,
                 file = ordner .. R.GFX .. "absatz_" .. farbe .. ".png"}
end

function R.seite(n, F, links, ordner, farbe)   -- die Linien einer Seite (VORFLUG vier, BAENKE fuenf): vom Cockpit her ins Bild, dann auslaufend (Bild gfx/auslauf_<farbe>_l/_r.png in zwei Laengen)
    for _, l in ipairs(links and R.AUSLAUF_LINKS or R.AUSLAUF_RECHTS) do
        local k, weit = ky(l[1]), R.sx(l[2])
        local weich = min(R.AUSLAUF_WEICH, floor(weit * 0.8))
        if links then
            R.waagrecht(n, F, k, W - weit + weich, W - 1)
            n[#n + 1] = {type = "image", x = W - weit, y = k - 2, w = weich, h = R.SCHEIN,
                         file = ordner .. R.GFX .. "auslauf_" .. farbe .. "_l" .. weich .. ".png"}
        else
            R.waagrecht(n, F, k, 0, weit - weich - 1)
            n[#n + 1] = {type = "image", x = weit - weich, y = k - 2, w = weich, h = R.SCHEIN,
                         file = ordner .. R.GFX .. "auslauf_" .. farbe .. "_r" .. weich .. ".png"}
        end
    end
end

function R.winkel(a) return a - 90 + ((a - 90 < 0) and 360 or 0) end   -- Ethos-Winkel (0 oben) in lvgl (0 rechts), 0..360

local function arc(n, cx, cy, r, dicke, a0, a1, farbe)
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = r, thickness = dicke, startAngle = a0, endAngle = a1, color = farbe}
end

function R.bogen(n, art, cx, cy, ordner)   -- der Bogen eines Tachos: gruen, gelb, rot (Ethos: Ring r-1 bis r+1, hier drei Punkte) und die Teilstriche als Bild
    local w = R.winkel
    local g, y = art.anfang + (art.ende - art.anfang) * 0.78, art.anfang + (art.ende - art.anfang) * 0.90
    local a0, ag, ay, a1 = w(art.anfang), w(g), w(y), w(art.ende)
    if ag < a0 then ag = ag + 360 end         -- ueber die 0 (rechts) hinweg zaehlt lvgl weiter (135 bis 405 in gauge.lua der Suite)
    if ay < ag then ay = ay + 360 end
    if a1 < ay then a1 = a1 + 360 end
    local r = art.r + 2
    arc(n, cx, cy, r, 3, floor(a0 + 0.5), floor(ag + 0.5), R.rgb(R.GRUEN))
    arc(n, cx, cy, r, 3, floor(ag + 0.5), floor(ay + 0.5), R.rgb(R.GELB))
    arc(n, cx, cy, r, 3, floor(ay + 0.5), floor(a1 + 0.5), R.rgb(R.ROT))
    local halb = floor(art.strichKante / 2)
    n[#n + 1] = {type = "image", x = cx - halb, y = cy - halb, w = art.strichKante, h = art.strichKante, file = ordner .. R.GFX .. art.striche}
end

function R.pfeilPunkte(art, cx, cy, anteil)   -- die drei Ecken des Pfeils (GROSS) fuer einen Anteil 0..1 des Bogens, in Bildpunkten des Schirms
    if anteil < 0 then anteil = 0 elseif anteil > 1 then anteil = 1 end
    local a = art.anfang + (art.ende - art.anfang) * anteil
    local w, w1, w2 = rad(a), rad(a - 7), rad(a + 7)
    return {{floor(cx + art.fuss * sin(w1) + 0.5), floor(cy - art.fuss * cos(w1) + 0.5)},
            {floor(cx + art.fuss * sin(w2) + 0.5), floor(cy - art.fuss * cos(w2) + 0.5)},
            {floor(cx + art.spitze * sin(w) + 0.5), floor(cy - art.spitze * cos(w) + 0.5)}}
end

function R.pfeil(n, punkte, sichtbar)        -- der Pfeil des Cockpits: ein Dreieck, dessen Ecken eine Funktion nennt
    n[#n + 1] = {type = "triangle", x = 0, y = 0, w = 0, h = 0, pts = punkte, color = R.rgb(R.NADEL), visible = sichtbar}
end

function R.balken(n, F, art, cx, cy, ende, sichtbar)   -- der Balken der Bankseite: ein Ring innen am Bogen vom Anfang bis zum Wert (lvgl-Winkel, den eine Funktion nennt)
    n[#n + 1] = {type = "arc", x = cx, y = cy, radius = art.balkenAussen, thickness = art.balkenAussen - art.balkenInnen,
                 startAngle = floor(R.winkel(art.anfang) + 0.5), endAngle = ende, color = F.mitte, visible = sichtbar}
end

function R.balkenWinkel(art, anteil)         -- der lvgl-Winkel des Balkenendes fuer einen Anteil 0..1
    if anteil < 0 then anteil = 0 elseif anteil > 1 then anteil = 1 end
    local a = R.winkel(art.anfang) + (art.ende - art.anfang) * anteil
    return floor(a + 0.5)
end

R.STACHELN = {links = {{66, 24}, {240, 60}, {262, 45}}, rechts = {{66, 24}, {124, 60}, {136, 45}, {240, 24}}}   -- wie die Ethos-Fassung: je Zeile, wie weit eine Linie der Displays vom Schirmrand her ins Cockpit reicht

function R.stacheln(n, ordner, farbe)        -- die Stacheln: links die Linien von VORFLUG (Akku-Kasten, letzter Fusschip), rechts die von BAENKE (Chips); voll am Rand, auslaufend ueber ihre ganze Laenge
    for _, s in ipairs(R.STACHELN.links) do
        local w = R.sx(s[2])
        n[#n + 1] = {type = "image", x = 0, y = ky(s[1]) - 2, w = w, h = R.SCHEIN, file = ordner .. R.GFX .. "auslauf_" .. farbe .. "_r" .. w .. ".png"}
    end
    for _, s in ipairs(R.STACHELN.rechts) do
        local w = R.sx(s[2])
        n[#n + 1] = {type = "image", x = W - w, y = ky(s[1]) - 2, w = w, h = R.SCHEIN, file = ordner .. R.GFX .. "auslauf_" .. farbe .. "_l" .. w .. ".png"}
    end
end

return R
