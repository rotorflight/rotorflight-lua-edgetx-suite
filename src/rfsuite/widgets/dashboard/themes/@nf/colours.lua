-- Per colour (keys as in the suite's settings) the mid tone of a line, its bright core and the glow outside;
-- frame.lua draws all lines, arcs and bars with them, and the images notch_<colour>.png and fade_<colour>_*.png
-- carry the same colours.
return {
    blue = {mid = {2, 117, 194}, core = {141, 255, 255}, glow = {1, 35, 58}},
    turquoise = {mid = {2, 194, 191}, core = {141, 255, 255}, glow = {1, 58, 57}},
    green = {mid = {2, 194, 24}, core = {141, 255, 151}, glow = {1, 58, 7}},
    yellow = {mid = {194, 168, 2}, core = {255, 255, 141}, glow = {58, 50, 1}},
    gold = {mid = {194, 141, 17}, core = {255, 255, 148}, glow = {58, 42, 5}},
    orange = {mid = {194, 82, 2}, core = {255, 177, 141}, glow = {58, 25, 1}},
    red = {mid = {255, 3, 7}, core = {255, 142, 143}, glow = {76, 1, 2}},
    magenta = {mid = {236, 2, 178}, core = {255, 141, 255}, glow = {71, 1, 53}},
    violet = {mid = {141, 3, 255}, core = {255, 142, 255}, glow = {42, 1, 76}},
    silver = {mid = {194, 194, 194}, core = {255, 255, 255}, glow = {58, 58, 58}},
}
