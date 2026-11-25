-- PAGE: the nodes of the two pages next to the cockpit (preflight on the left, banks on the right) as in the Ethos theme: chips from
-- the cockpit's lines with corners r 4, the first or last edge open to the screen edge; rows of pieces (number large,
-- unit small), bottom-aligned; five signal bars. Positions in the 480 x 320 reference (R.sx, R.sy, R.kx, R.ky). Text, colour and
-- place of a piece are functions that only read what refresh() computes; a row reads its texts once per tick (G.tick) and
-- computes the place again only when a text changes. A row made of fixed texts only stays fixed and needs no function.
return function(T)
    local R, COLOUR, G = T.R, T.COLOUR, T.G
    local floor = math.floor
    local P = {}
    local OUT = 40                                   -- this far an open edge lies outside the screen
    P.MUTED = lcd.RGB(158, 170, 184)                 -- empty fields and bars as in the Ethos theme (its muted field colour)

    function P.chip(n, L, x, y, w, h, open)         -- the reference core in column x and x + w, row y and y + h; open = "left" or "right"
        local l, r = R.kx(x), R.kx(x + w) + 1
        local o, u = R.ky(y), R.ky(y + h) + 1
        if open == "left" then l = -OUT end
        if open == "right" then r = R.W - 1 + OUT end
        R.field(n, L, l, o, r - l + 1, u - o + 1, R.ROUND)
    end

    function P.area(n, x, y, w, h, colour, shown)   -- an area in screen pixels; colour and shown may be functions
        n[#n + 1] = {type = "rectangle", x = x, y = y, w = w, h = h, filled = true, color = colour, visible = shown}
    end

    function P.row(n, cx, cy, segs, place, dx, dy)   -- segs = {{text, colour, font}, ...}; cx, cy in pixels, cy the middle of the row; place "left", "right" or centred
        dx, dy = dx or 0, dy or 0
        local k = #segs
        local z = {texts = {}, x = {}, y = {}, b = {}, h = {}, done = false, tick = false}   -- b, h: width and height per piece
        local fixed, height = true, 0
        for i = 1, k do
            if type(segs[i][1]) == "function" then fixed = false end
            z.h[i] = T.height(segs[i][3])                -- the font of a piece stays: so does its height
            if z.h[i] > height then height = z.h[i] end
        end
        local top = cy - floor(height / 2)
        local function compute()
            if z.tick == G.tick then return end
            z.tick = G.tick
            local fresh = not z.done
            for i = 1, k do
                local tx = segs[i][1]
                if type(tx) == "function" then tx = tx() end
                tx = tx ~= nil and tostring(tx) or ""
                if z.texts[i] ~= tx or not z.done then   -- only a piece whose text changes is measured
                    z.texts[i], z.b[i], fresh = tx, tx ~= "" and T.textWidth(tx, segs[i][3]) or 0, true
                end
            end
            if not fresh then return end
            z.done = true
            local textWidth = -T.GAP
            for i = 1, k do textWidth = textWidth + z.b[i] + T.GAP end
            local x = cx - floor(textWidth / 2)
            if place == "left" then x = cx elseif place == "right" then x = cx - textWidth end
            for i = 1, k do
                z.x[i], z.y[i] = x - dx, top + height - z.h[i] - ((i > 1) and 1 or 0) - dy
                x = x + z.b[i] + T.GAP
            end
        end
        if fixed then
            compute()
            for i = 1, #segs do
                local s = segs[i]
                n[#n + 1] = {type = "label", x = z.x[i], y = z.y[i], w = 0, font = s[3], color = s[2], text = z.texts[i]}
            end
            return
        end
        for i = 1, #segs do
            local s = segs[i]
            n[#n + 1] = {type = "label", x = 0, y = 0, w = 0, font = s[3], color = s[2],
                         text = function() compute() return z.texts[i] end,
                         pos = function() compute() return z.x[i], z.y[i] end}
        end
    end

    function P.word(n, x, cy, text, colour, font, place, dx, dy)   -- a fixed word: centred on x, from x (left) or up to x (right)
        dx, dy = dx or 0, dy or 0
        local b, h = T.textWidth(text, font), T.height(font)
        local left = x - floor(b / 2)
        if place == "left" then left = x elseif place == "right" then left = x - b end
        n[#n + 1] = {type = "label", x = left - dx, y = cy - floor(h / 2) - dy, w = 0, font = font, text = text, color = colour}
    end

    function P.signal(n, x, bottom, full, colour, dx, dy)   -- five bars as on the radio, rising 6 to 18 (reference); full and colour are functions
        dx, dy = dx or 0, dy or 0
        for i = 0, 4 do
            local hb = 6 + i * 3
            local x0, y0 = R.sx(x + i * 6), R.sy(bottom - hb)
            local nr = i
            P.area(n, x0 - dx, y0 - dy, R.sx(x + i * 6 + 4) - x0, R.sy(bottom) - y0, function() return nr < full() and colour() or P.MUTED end)
        end
    end

    local api = {}
    local function apiLoad(name)                    -- the suite's record (tasks/msp/api/<name>.lua): command, parse, reply in the simulator
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

    function P.client()                               -- one place at the suite's MSP service (rfsuite.msp), once for the theme, kept across every reload
        local G = T.G
        if G.mspClient == nil and rfsuite and type(rfsuite.msp) == "table" and type(rfsuite.msp.register) == "function" then
            local ok, k = pcall(rfsuite.msp.register, "nf-theme")
            if ok and type(k) == "table" then G.mspClient = k end
        end
        return G.mspClient
    end

    function P.read(name, done)                   -- reads a record; done(values) or done(nil, reason) exactly once; false when nothing was sent
        local a, k = apiLoad(name), P.client()
        if a == nil or k == nil or type(k.request) ~= "function" then return false end
        local once = false
        local ok, id = pcall(k.request, k, {
            command = a.command,
            simulatorResponse = a.simulatorResponse,
            onReply = function(buf)
                if once then return end
                once = true
                local ok2, w = pcall(a.parse, buf)
                if ok2 and type(w) == "table" then done(w) else done(nil, "incomplete") end
            end,
            onError = function(g)
                if once then return end
                once = true
                done(nil, g)
            end,
        })
        if not ok or id == nil then once = true return false end
        return true
    end

    function P.apiOld()                              -- before API 12.09 the governor modes have other names (OFF, PASSTHROUGH, STANDARD, MODE1, MODE2)
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
