-- Von einem Skript erzeugt - nicht von Hand aendern. Je Farbe (Schluessel wie in den
-- Einstellungen der Suite) der Mittelton einer Linie, ihr heller Kern und der Schein aussen; rahmen.lua malt damit alle
-- Linien, Bogen und Balken, die Bilder absatz_<farbe>.png und auslauf_<farbe>_*.png tragen dieselben Farben.
return {
    blue = {mitte = {2, 117, 194}, kern = {141, 255, 255}, schein = {1, 35, 58}},
    turquoise = {mitte = {2, 194, 191}, kern = {141, 255, 255}, schein = {1, 58, 57}},
    green = {mitte = {2, 194, 24}, kern = {141, 255, 151}, schein = {1, 58, 7}},
    yellow = {mitte = {194, 168, 2}, kern = {255, 255, 141}, schein = {58, 50, 1}},
    gold = {mitte = {194, 141, 17}, kern = {255, 255, 148}, schein = {58, 42, 5}},
    orange = {mitte = {194, 82, 2}, kern = {255, 177, 141}, schein = {58, 25, 1}},
    red = {mitte = {255, 3, 7}, kern = {255, 142, 143}, schein = {76, 1, 2}},
    magenta = {mitte = {236, 2, 178}, kern = {255, 141, 255}, schein = {71, 1, 53}},
    violet = {mitte = {141, 3, 255}, kern = {255, 142, 255}, schein = {42, 1, 76}},
    silver = {mitte = {194, 194, 194}, kern = {255, 255, 255}, schein = {58, 58, 58}},
}
