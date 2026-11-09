local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Common = nil
local Controls = nil
local LoadingOverlay = nil
local Graph = nil
local Env = nil
local t = nil

-- The engine walks a log in small units, and it is what reads a log for BOTH views: the
-- flight statistics are accumulated by the same pass that indexes the file for the plot.
-- So it is loaded once a log has been chosen -- not once the plot has been -- and dropped
-- again when the page closes. The file list costs nothing for it.
local GRAPH_TICKS_PER_WAKEUP = 6

-- The tool opened from the dashboard runs inside the widget's call, and EdgeTX stops a widget
-- call at 20 000 Lua instructions. A summary unit (STATS_LINES_TICK in graph.lua) costs about
-- half of that, so there a wakeup spends one unit in all: with more, every call was stopped in
-- the middle of the second, and the row being read at that moment was counted without all of
-- its values. The tool script runs without that limit and keeps the figure above.
local GRAPH_TICKS_PER_WIDGET_WAKEUP = 1

-- Hosted, the scan is bounded by a number of units rather than by the clock: the limit counts
-- instructions, and an entry costs instructions whatever time it takes. Three units of
-- SCAN_UNIT_ENTRIES cost about 3 700 where the names carry their date.
local SCAN_UNITS_PER_WIDGET_WAKEUP = 3

-- Breaking a row's model and file name into the lines its column holds is most of what the list
-- costs: about 1 100 instructions a row at 480x320, so some 28 000 for a window of twenty-five,
-- against the 2 100 the rest of the page build takes. Built that way inside the widget's call, the
-- build was stopped every time, built again on the next pass, and the list never appeared on a
-- card holding more than about fifteen logs. Hosted, the page's wakeup breaks this many rows per
-- call instead, keeps the lines on each log's record, and asks for the build once the window is
-- done (see layOutWindow); five rows cost about 5 500. The tool script runs without that limit,
-- and its build breaks the window itself as before.
local LAYOUT_ROWS_PER_WIDGET_WAKEUP = 5

-- True while the page is called from inside the dashboard widget (see lib/env.lua).
local function inWidgetCall()
  return Env ~= nil and Env ~= false and Env.isWidget() == true
end

local state = {
  selectedFile = nil,
  selectedFilePath = nil,
  selectedModel = nil,
  logsList = {},
  -- The window of the list on screen: the index of its first log, less one; see LIST_WINDOW. A
  -- log's summary and plot are views on top of the list, so coming back from them finds the
  -- list on the window it was left on.
  listTop = 0,
  summary = nil,
  loading = false,
  -- `loading` says a log is being read; `reading` says the engine has been given it and is
  -- walking it, which is what tells the wakeup to spend units rather than to start again.
  reading = false,
  -- The directory walk in progress (see newScan), or nil. It is started by M.build and
  -- advanced by M.wakeup, never run inside a build; `scanned` says it has finished.
  scan = nil,
  -- What the scan notice drew last, so a wakeup repaints it only when that changes.
  scanShown = nil,
  scanned = false,
  requestRebuild = nil,
  -- The file list and the statistics of a selected log are told apart by
  -- selectedFile, as before. "graph" is the third view on top of those, and
  -- pickCurves puts it into its column chooser.
  view = nil,
  pickCurves = false,
  -- The plot was opened from the list's Graph button rather than from a summary, so Back from
  -- it returns to the list and the engine holds no summary.
  direct = false,
  slots = {},
  -- Set when the engine refused the chosen columns, so the view says so instead of drawing
  -- the chooser again.
  graphRefused = false
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if Env == nil then Env = loadModule("lib/env.lua") or false end
  if not t then t = Common and Common.pageT("logs") or nil end
end

-- `lcd.sizeText(text, flags)` answers for the font the label is drawn in and carries no
-- drawing-context guard, so it may be called while the child list is being built. The fallback
-- is only there for a build that does not offer the call.
local function textSize(text, font)
  local fn = lcd and lcd.sizeText
  if type(fn) == "function" then
    local ok, tw, th = pcall(fn, tostring(text or ""), font)
    tw, th = tonumber(tw), tonumber(th)
    if ok and tw and th and th > 0 then
      return tw, th
    end
  end
  return #tostring(text or "") * 7, 16
end

local ELLIPSIS = "..."

-- The ellipsis is the one string every cut and every overlong label measures, and it is the
-- same three characters every time. Ask each font about it once instead of once per row.
local ellipsisW = {}
local function ellipsisWidth(font)
  local key = font or 0
  local width = ellipsisW[key]
  if not width then
    width = textSize(ELLIPSIS, font)
    ellipsisW[key] = width
  end
  return width
end

-- The largest cut length at or below `n` that does not fall inside a multi-byte character, so
-- that shortening a file name can never leave half a sequence behind.
local function charBoundary(text, n)
  while n > 0 do
    local b = string.byte(text, n + 1)
    if not b or b < 0x80 or b >= 0xC0 then return n end
    n = n - 1
  end
  return 0
end

-- The longest prefix of `text`, in bytes, that fits `maxW` px in `font`: never longer than
-- `text` less one character, never shorter than `minN`, and always on a character boundary.
--
-- A prefix does not get narrower as it grows, so the prefixes that fit are exactly the short
-- ones and the break point is the single edge between the two runs. Bisecting for that edge
-- asks the font about six substrings where walking the string backwards asked about one per
-- character -- and on a list of three hundred logs that difference is the page build.
local function fittingPrefix(text, font, maxW, minN)
  local best = minN
  local lo, hi = minN, #text - 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local n = charBoundary(text, mid)
    if textSize(string.sub(text, 1, n), font) <= maxW then
      if n > best then
        best = n
      end
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

-- Cut `text` so that it, plus a trailing ellipsis, fits `maxW` px in `font`. A text that
-- already fits is returned untouched.
local function fitToWidth(text, font, maxW)
  text = tostring(text or "")
  if maxW <= 0 or textSize(text, font) <= maxW then
    return text
  end

  local room = maxW - ellipsisWidth(font)
  if room <= 0 then
    return ELLIPSIS
  end

  -- A cut of nothing at all always fits, `room` being positive here, so the search cannot
  -- come back empty-handed and the ellipsis on its own is what a zero-length cut produces.
  local cut = string.sub(text, 1, fittingPrefix(text, font, room, 0))
  -- Trailing dots and spaces would read as part of the ellipsis, so drop them first.
  return (string.gsub(cut, "[%.%s]+$", "")) .. ELLIPSIS
end

-- The characters the engine is willing to break a line after, as a Lua set: space, and the
-- punctuation that lets `Model-2026-08-10-100706.csv` be split at all. Breaking at the same
-- places is what keeps a label reading as it did before it was broken here.
local BREAK_SET = "[ ,%.;:%-_%)%]}]"

-- One line of `s` that fits `maxW` px in `font`, and what is left over.
--
-- The break is taken after the last break character that still fits, so a word is not split
-- when it need not be; a word too long for a line on its own is broken inside it, at a
-- character boundary, because there is nowhere else to break it. A break at a space drops the
-- space, which is not drawn at the end of a line either way; every other break keeps its
-- character on the line it ends.
--
-- `sw` is the width of `s` where the caller has already had it measured; leaving it out costs
-- one more measurement of a string the font has just been asked about.
local function takeLine(s, font, maxW, sw)
  if (sw or textSize(s, font)) <= maxW then
    return s, ""
  end

  -- One character is kept whatever it measures: a line that took nothing would leave the
  -- caller with the same string to break again, and the loop would not end.
  local n = fittingPrefix(s, font, maxW, 1)

  local head = string.sub(s, 1, n)
  local _, brk = string.find(head, "^.*" .. BREAK_SET)
  if brk then
    if string.byte(head, brk) == 32 then
      if brk > 1 then
        return string.sub(s, 1, brk - 1), (string.gsub(string.sub(s, brk + 1), "^ +", ""))
      end
    else
      return string.sub(s, 1, brk), string.sub(s, brk + 1)
    end
  end
  return head, string.sub(s, n + 1)
end

-- `text` broken into at most `maxLines` lines of `maxW` px in `font`.
--
-- What does not fit is cut on the last line rather than carried past it, so a text laid out
-- this way can never be taller than the room it was given.
local function wrapToWidth(text, font, maxW, maxLines)
  local lines = {}
  local rest = tostring(text or "")

  while rest ~= "" do
    -- One measurement of `rest` serves both the test below and the break after it. Measuring
    -- it here rather than inside the test costs nothing: takeLine needs the same number for
    -- the same string either way.
    local restW = textSize(rest, font)

    if #lines + 1 >= maxLines and restW > maxW then
      local room = maxW - ellipsisWidth(font)
      if room <= 0 then
        room = maxW
      end
      lines[#lines + 1] = takeLine(rest, font, room, restW) .. ELLIPSIS
      break
    end

    local line
    line, rest = takeLine(rest, font, maxW, restW)
    if line == "" then
      break
    end
    lines[#lines + 1] = line
  end

  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

-- The heading of the flight summary, in the width the heading actually has.
--
-- Controls.appendStaticSectionHeader gives its label no `w`, so LVGL sizes the label to its own
-- text: a heading wider than the header neither wraps nor is clipped, it runs past the right
-- edge of the page and leaves the page body scrolling sideways.
--
-- Two steps, in this order. extractFileInfo takes the model out of the file name itself when
-- the name carries one ("^(.-)%-%d%d%d%d"), and for those -- which is every log the tool
-- writes -- "<model> - <file>" prints the model twice and spends the width on the half that is
-- already there. So drop the prefix, but only when the name really does begin with it: a model
-- that came from the parent folder instead is not in the name, and is the only place that says
-- which helicopter this was.
--
-- What is left is then measured in the font the header draws in and cut to fit. Dropping the
-- duplicate is enough on its own at 480 px and wider; the cut is what a narrow screen needs.
local function summaryTitle(model, file, maxW)
  model = tostring(model or "")
  local title = tostring(file or "")
  if model ~= "" and string.sub(title, 1, #model) ~= model then
    title = model .. " - " .. title
  end
  return fitToWidth(title, MIDSIZE, maxW)
end

local function closeGraph()
  if Graph then
    Graph.close()
    Graph = nil
  end
  state.view = nil
  state.pickCurves = false
  state.direct = false
  state.slots = {}
  collectgarbage("collect")
end

-- The loading notices take these functions rather than a number: the overlay reads a function
-- again on every refresh, while a number is drawn once, and nothing rebuilds the notice before
-- the walk has finished. Defined once, so no build creates a closure for them.
local function readingProgress()
  return (Graph and state.reading) and Graph.getProgress() or 0
end

local function graphProgress()
  return Graph and Graph.getProgress() or 0
end

local function pageText(i18n, key)
  if t then
    local translated = t(i18n, key)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return key
end

-- A summary figure, or "--" where the log carries no column for it: the summary returns nil
-- for those, and a number there would be a guess.
local function statText(fmt, ...)
  for i = 1, select("#", ...) do
    if select(i, ...) == nil then return "--" end
  end
  return string.format(fmt, ...)
end

-- A directory listing that can be read a few names at a time.
--
-- EdgeTX's dir() returns a C closure whose only upvalue is the open directory, and that
-- userdata closes itself when it is collected (radio/src/lua/api_filesystem.cpp: dir_iter,
-- dir_gc). So the iterator can be kept between two wakeups and read on where it stopped, and
-- a listing that is dropped half-read closes its directory with the next collection. A
-- listing without an `iter` is complete: the system.listFiles fallback answers in one table,
-- and a directory that cannot be opened answers with no names at all.
local function openListing(listBasePath)
  local listing = { names = {} }
  if type(dir) == "function" then
    local iterator = dir(listBasePath)
    if type(iterator) == "function" then
      listing.iter = iterator
      return listing
    end
  end

  if system and system.listFiles then
    local ok, res = pcall(system.listFiles, listBasePath)
    if ok and type(res) == "table" then
      for i = 1, #res do
        local name = res[i]
        if name and name ~= "." and name ~= ".." and name ~= "" then
          listing.names[#listing.names + 1] = name
        end
      end
    end
  end

  return listing
end

-- The next name of a listing, or false once it has none left. A name read is held on the
-- listing until the caller has dealt with it and dropped it (`listing.held = nil`), so a call
-- stopped in between deals with it on the next one rather than losing it. The read that ends
-- the directory is what drops the iterator. A call stopped between the read and `held` can
-- lose the name; scanStep reads such a directory again.
local function nextName(listing)
  local name = listing.held
  if name ~= nil then return name end
  if listing.iter then
    -- Set around the read: a call stopped inside this window may have lost the name, and
    -- scanStep then reads the directory again.
    listing.reading = true
    name = listing.iter() or false
    listing.held = name
    listing.reading = nil
    if name == false then listing.iter = nil end
  else
    local j = (listing.j or 0) + 1
    name = listing.names[j] or false
    listing.held = name
    listing.j = j
  end
  return name
end

local function formatDateText(date, time, isNarrow, unknownText)
  if not date or date == "" then
    return unknownText
  end
  local d = date
  if isNarrow then
    local md = string.match(date, "^%d%d%d%d%-(%d%d%-%d%d)$")
    if md then
      d = md
    end
  end
  if not time or time == "" then
    return d
  end
  local t = time
  if isNarrow then
    local hm = string.match(time, "^(%d%d:%d%d)")
    if hm then t = hm end
  end
  return d .. "  " .. t
end

local function extractFileInfo(filename, fullPath, parentFolder)
  local date = string.match(filename, "(%d%d%d%d%-%d%d%-%d%d)")
  local time = nil

  -- Pattern: YYYY-MM-DD-HHMMSS or YYYY-MM-DD_HHMMSS
  local h1, m1, s1 = string.match(filename, "%d%d%d%d%-%d%d%-%d%d[_-]?(%d%d)(%d%d)(%d%d)")
  if h1 and m1 and s1 then
    time = h1 .. ":" .. m1 .. ":" .. s1
  else
    -- Pattern: YYYY-MM-DD_HH-MM-SS or YYYY-MM-DD-HH-MM-SS
    local h2, m2, s2 = string.match(filename, "%d%d%d%d%-%d%d%-%d%d[_-](%d%d)%-(%d%d)%-(%d%d)")
    if h2 and m2 and s2 then
      time = h2 .. ":" .. m2 .. ":" .. s2
    end
  end

  local model = string.match(filename, "^(.-)%-%d%d%d%d")
  if not model or model == "" then
    model = (parentFolder and parentFolder ~= "" and parentFolder ~= "telemetry" and parentFolder ~= "rfsuite" and parentFolder ~= "LOGS") and parentFolder or nil
  end

  -- Fallback: peek first lines if date/time not in filename.
  --
  -- This peek is also where a CSV that is not a telemetry log is told apart, and such a file is
  -- not listed. EdgeTX's logger names a log <model>-<date>-<time>, or <model>-<date> with one
  -- log per day, and starts it with a Date,Time header (radio/src/logs.cpp). A name that carries
  -- a date and a time is therefore taken as one of its logs without being opened, which keeps
  -- the walk as cheap as it was; every other file is opened here anyway, and has to start with
  -- that header to be listed.
  --
  -- logs.cpp writes that name and that header only on a build with RTCLOCK. Without it the file
  -- is named <model>.csv, the header starts with Time instead and each row carries a tick count
  -- where the time goes, so the graph could not plot such a log either: it needs the Date and
  -- Time columns and a clock time (graph.lua refuses it as not_telemetry). Accepting a Time
  -- header here would list files the graph then refuses. EdgeTX defines RTCLOCK for every colour
  -- radio it builds, and the suite runs on colour radios only.
  if not date or not time then
    local f = io.open(fullPath, "r")
    if f then
      local firstChunk = io.read(f, 512)
      io.close(f)
      if not firstChunk or string.sub(firstChunk, 1, 10) ~= "Date,Time," then
        return nil
      end
      if firstChunk then
        local l1, l2 = string.match(firstChunk, "([^\r\n]+)[\r\n]+([^\r\n]+)")
        if l2 then
          local d, tm = string.match(l2, "^(.-),(.-),")
          if d and string.match(d, "^%d%d%d%d%-%d%d%-%d%d$") then
            date = d
          end
          if tm then
            local tClean = string.match(tm, "^(%d%d:%d%d:%d%d)")
            if tClean then time = tClean end
          end
        end
      end
    end
  end

  local sortDate = date or "0000-00-00"
  local sortTime = (time and time ~= "") and string.gsub(time, ":", "") or "000000"
  local sortKey = sortDate .. "_" .. sortTime .. "_" .. filename

  return {
    file = filename,
    path = fullPath,
    model = model,
    date = date,
    time = time or "",
    sortKey = sortKey
  }
end

-- The search paths NEST, and each one is walked both at its top level and one directory down.
-- A file lying directly in /LOGS/rfsuite/telemetry is therefore reached twice: once as a
-- top-level .csv of the first path, and once as a .csv inside the `telemetry` subdirectory of
-- the second. Nothing downstream removes it -- `extractFileInfo` builds a fresh record each
-- time and the sort has no uniqueness step -- so that file appears twice in the list, as two
-- adjacent identical rows (the sort key is the same). A file inside a model folder, or one
-- directly in /LOGS, is reached once.
--
-- The full path is what identifies a log, so that is what the scan remembers.
local SEARCH_PATHS = {
  "/LOGS/rfsuite/telemetry",
  "/LOGS/rfsuite",
  "/LOGS"
}

-- The scan is a small state machine that M.wakeup advances a few entries at a time: a name
-- read from a directory, or a name already read being looked at -- for a .csv that is
-- extractFileInfo, which opens the file only where its name carries no date and time.
--
-- Each search path is listed in the order the paths are given, and a log among its names is
-- collected as soon as its name has been read: one unit per name, where reading every name
-- first and walking the names afterwards paid two. A folder among the names is kept aside and
-- listed, one at a time, once the path's own listing has ended, so only one directory is open
-- at any time. A file is reached by one route within a path, and the paths still come one
-- after the other, so the first path a file is reached by, which decides the folder its model
-- may be named after, is the one it was reached by before. The sort is a phase of its own, so
-- it never shares a wakeup with a last batch of entries.
--
-- The sort runs table.sort without a comparator, over one string per log, so every comparison
-- is made in C. A Lua comparator runs once per comparison, and over a few hundred logs that alone
-- is more than one widget call may spend, so in the tool opened from the dashboard the call was
-- stopped in the middle of the sort, the next one started it again, and the list never appeared.
-- Building those strings before the sort and putting the records back in order after it are
-- linear, and are taken SORT_ENTRIES_PER_UNIT logs per unit of the budget.
local SCAN_UNIT_ENTRIES = 10
local SORT_ENTRIES_PER_UNIT = 10

-- How long one wakeup may spend on the scan, in getTime() ticks of 10 ms. A colour radio runs
-- a tool's run() as one plain call that nothing can interrupt, so until it returns the screen is
-- not repainted and no key or touch is read. The host calls a page's wakeup about every 50 ms,
-- so 40 ms of scanning per call keeps the radio answering while spending most of the time on the
-- walk; with a budget of a fixed number of entries instead, the passes that only match names
-- cost almost nothing and each still took a frame. getTime() moves in whole ticks, so a wakeup
-- spends between 30 and 40 ms here plus the one unit that crosses the line, and always at least
-- one unit.
local SCAN_BUDGET_TICKS = 4

local function newScan()
  return {
    phase = "list",
    s = 1,
    listing = nil,
    dirs = {},
    di = 0,
    sub = nil,
    read = 0,
    found = {},
    seen = {}
  }
end

-- An entry is marked as seen, and its listing's held name dropped (scanStep), only once it is
-- done: the tool opened from the dashboard can be stopped in the middle of one, and the next
-- wakeup then reads it again rather than leaving the log out of the list.
local function scanCollect(scan, fileName, fullPath, parentFolder)
  if scan.seen[fullPath] then return end
  -- Added already by a call stopped before it could mark it.
  local last = scan.found[#scan.found]
  if not (last and last.path == fullPath) then
    local info = extractFileInfo(fileName, fullPath, parentFolder)
    if info then scan.found[#scan.found + 1] = info end
  end
  scan.seen[fullPath] = true
end

-- One name of `listing`, of a folder `base` whose model is `parent` ("" for a search path):
-- a log is collected, and a folder of a search path is kept aside for the walk. Answers false
-- once the listing has no name left.
local function scanName(scan, listing, base, parent)
  local name = nextName(listing)
  if name == false then return false end
  if name ~= "." and name ~= ".." and name ~= "" then
    if string.match(name, "%.csv$") then
      scanCollect(scan, name, base .. "/" .. name, parent)
    elseif parent == "" and not string.match(name, "%.%w+$") then
      -- Subdirectory (e.g. Model name). `dirs` is the list and, by name, the set of the folders
      -- kept aside, so a listing read again adds none twice; added before it is marked, so a
      -- call stopped in between adds it twice at worst, never not at all.
      local dirs = scan.dirs
      if not dirs[name] then
        dirs[#dirs + 1] = name
        dirs[name] = true
      end
    end
    scan.read = scan.read + 1
  end
  listing.held = nil
  return true
end

-- Advances the scan by at most `budget` entries and answers true once it is complete, with
-- `scan.found` sorted newest first. Steps that only move from one directory to the next cost
-- nothing and are taken in the same call; the sort is one call on its own. Every step leaves
-- the scan where its phase can go on from, at any point: a call stopped in the middle of one
-- (see scanCollect) repeats part of it rather than leaving the scan in a phase it cannot finish.
local function scanUnits(scan, budget)
  while budget > 0 do
    if scan.phase == "list" then
      if not scan.listing then
        scan.listing = openListing(SEARCH_PATHS[scan.s])
      end
      if not scanName(scan, scan.listing, SEARCH_PATHS[scan.s], "") then
        scan.listing = nil
        scan.di = 0
        scan.phase = "walk"
      end
      budget = budget - 1
    elseif scan.phase == "walk" then
      -- The folders the path's listing held, each listed and its logs collected as read.
      local sub = scan.sub
      if sub then
        if not scanName(scan, sub.listing, sub.path, sub.parent) then
          -- Dropped before the position moves on: a call stopped in between lists this folder
          -- again, and scanCollect takes none of its logs twice.
          scan.sub = nil
          scan.di = scan.di + 1
        end
        budget = budget - 1
      elseif scan.di < #scan.dirs then
        local entry = scan.dirs[scan.di + 1]
        local path = SEARCH_PATHS[scan.s] .. "/" .. entry
        scan.sub = { listing = openListing(path), path = path, parent = entry }
        budget = budget - 1
      else
        local s = scan.s + 1
        if s > #SEARCH_PATHS then
          -- The walk is over. The sort is left to the next call, so it never runs in the same
          -- call as the walk's last entries.
          scan.phase = "keys"
          scan.dirs = nil
          return false
        end
        -- In this order, so a call stopped between two of them lists a path again rather than
        -- skipping one; scanCollect takes no log twice.
        scan.phase = "list"
        scan.dirs = {}
        scan.s = s
      end
    elseif scan.phase == "keys" then
      -- Each record's sort key, then its position in `found` in eight digits (no card holds that
      -- many logs): unique, and "\1" sorts below every
      -- character a sort key holds, so the order of the sort keys is kept. The table is made here
      -- rather than where the walk ends, so a call stopped at that change of phase finds it made;
      -- writing a key again after a stopped call writes the same string.
      local found = scan.found
      local keys = scan.keys
      if keys == nil then
        keys = {}
        scan.keys = keys
      end
      local k = scan.k or 0
      local last = math.min(#found, k + budget * SORT_ENTRIES_PER_UNIT)
      while k < last do
        k = k + 1
        keys[k] = found[k].sortKey .. "\1" .. string.format("%08d", k)
        scan.k = k
      end
      if k < #found then return false end
      scan.phase = "sort"
      return false
    elseif scan.phase == "sort" then
      table.sort(scan.keys)
      scan.k = 0
      scan.phase = "order"
      return false
    elseif scan.phase == "order" then
      -- Newest first: the keys ascend, so the last one names the first record. The records go into
      -- a new array, and `found` is replaced by it in one assignment once it is complete, so a call
      -- stopped anywhere in here leaves either the old array whole or the new one.
      local found, keys = scan.found, scan.keys
      local sorted = scan.sorted
      if sorted == nil then
        sorted = {}
        scan.sorted = sorted
      end
      local n = #keys
      local k = scan.k or 0
      local last = math.min(n, k + budget * SORT_ENTRIES_PER_UNIT)
      while k < last do
        k = k + 1
        sorted[k] = found[tonumber(string.sub(keys[n - k + 1], -8))]
        scan.k = k
      end
      if k < n then return false end
      scan.found = sorted
      scan.phase = "done"
      scan.keys, scan.sorted, scan.k = nil, nil, nil
      return true
    else
      return true
    end
  end
  return false
end

-- A call stopped at the instruction limit can lose a name: EdgeTX's directory iterator has moved
-- past it before the name reaches `listing.held` (see nextName). A listing left in that window
-- is therefore read again from the start; scanCollect takes no log twice and `dirs` keeps no
-- folder twice. Each restart is one assignment, and a stop anywhere else restarts nothing, so
-- calls that are all stopped still move on.
local function scanStep(scan, budget)
  local listing, sub = scan.listing, scan.sub
  if listing and listing.reading then
    scan.listing = nil
  elseif sub and sub.listing.reading then
    scan.sub = { listing = openListing(sub.path), path = sub.path, parent = sub.parent }
  end
  return scanUnits(scan, budget)
end

-- The scan for as long as one wakeup may spend on it; see SCAN_BUDGET_TICKS. Without a clock it
-- takes one unit per call. Given `units`, it takes that many units at most and no clock.
local function scanForAWhile(scan, units)
  local clock = (units == nil) and type(getTime) == "function" and getTime or nil
  local start = clock and clock() or 0
  local taken = 0
  while true do
    if scanStep(scan, SCAN_UNIT_ENTRIES) then return true end
    -- The sort gets a wakeup of its own rather than what is left of this one.
    if scan.phase == "sort" then return false end
    taken = taken + 1
    if units ~= nil then
      if taken >= units then return false end
    elseif not clock or clock() - start >= SCAN_BUDGET_TICKS then
      return false
    end
  end
end

-- The scan to its end in one call. Only for a build that has no overlay to report it with.
local function scanLogFiles()
  local scan = newScan()
  while not scanStep(scan, SCAN_UNIT_ENTRIES) do end
  state.logsList = scan.found
  return scan.found
end


-- The list's layout, defined with the list's constants further down (see layOutWindow).
local listColumns, listWindow, layOutWindow

-- One line to the suite's log; nothing is built when the log does not want this level.
local function pageLog(level, fmt, ...)
  local Log = _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.logs", level, fmt, ...)
  end
end

function M.getHeaderActions()
  return {
    reload = true,
    save = false,
    help = true
  }
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/logs/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = pageText(ctx and ctx.i18n, "title"), message = "" }
end

function M.wakeup(ctx)
  ensureDeps()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    state.requestRebuild = ctx.requestRebuild
  end
  local widgetCall = inWidgetCall()
  -- The units of log walk this wakeup may still spend, in the reading block and the busy block
  -- below together where the call is a widget's.
  local graphTicks = widgetCall and GRAPH_TICKS_PER_WIDGET_WAKEUP or GRAPH_TICKS_PER_WAKEUP

  -- The scan walks three directory trees and opens every candidate whose name carries no date
  -- and time. Done in one call -- in M.build or in one wakeup -- the tool stands still until the
  -- walk is over, however many logs the card holds. So the build that asks for it draws the
  -- notice and each wakeup spends SCAN_BUDGET_TICKS on it -- the same shape this page already
  -- uses for reading a selected log -- and the notice is drawn again whenever what it counts
  -- has moved. Hosted, the wakeup spends a number of units on it instead (see
  -- SCAN_UNITS_PER_WIDGET_WAKEUP).
  local scanning = state.scan ~= nil
  if scanning then
    if scanForAWhile(state.scan, widgetCall and SCAN_UNITS_PER_WIDGET_WAKEUP or nil) then
      state.logsList = state.scan.found
      state.scan = nil
      state.scanShown = nil
      state.scanned = true
      state.loading = false
      -- Frees what the steps left behind (about 300 KB at 587 logs) before the build allocates;
      -- measured on the EdgeTX simulator, under 1 ms and no more than the same collect after it.
      collectgarbage("collect")
      pageLog("info", "logs list: %d logs found", #state.logsList)
      -- Hosted, the window's rows are broken first (below), and that asks for the build once it is
      -- done; the notice stays up meanwhile.
      if widgetCall and state.listW and #state.logsList > 0 then
        state.layoutPending = true
      elseif state.requestRebuild then
        state.requestRebuild()
      end
    else
      local shown = state.scan.read .. "/" .. #state.scan.found
      if shown ~= state.scanShown then
        state.scanShown = shown
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    end
  end

  -- Hosted, the rows of the window on screen are broken here rather than in the build, a few per
  -- call (see LAYOUT_ROWS_PER_WIDGET_WAKEUP), and the build is asked for once all of them are.
  -- Never in the call that ran the scan: its last step and the collect after it are already there.
  if state.layoutPending and not scanning then
    if state.selectedFile or state.view == "graph" or not state.listW or #state.logsList == 0 then
      state.layoutPending = false
    else
      local _, _, _, labelW = listColumns(state.listW)
      local modelDefault = pageText(ctx and ctx.i18n, "model_default")
      local rows = widgetCall and LAYOUT_ROWS_PER_WIDGET_WAKEUP or nil
      if layOutWindow(labelW, modelDefault, rows) then
        -- Asked for before the flag is cleared: a call stopped in between asks again, never not.
        if state.requestRebuild then state.requestRebuild() end
        state.layoutPending = false
        pageLog("debug", "logs list: window laid out, %d px label column", labelW)
      else
        pageLog("trace", "logs list: %d rows broken this call", rows or 0)
      end
    end
  end

  -- Reading the selected log. The whole file has to be walked to answer the flight summary,
  -- and a long one is megabytes: done in a single call it stands the tool still for as long
  -- as the walk takes, because a script gets no time slice it can be interrupted in. So the
  -- engine walks it a fixed number of lines at a time and this is where those units are
  -- spent -- with the notice the build drew already on the screen, and its bar following the
  -- position in the file rather than a constant.
  --
  -- The pass that answers the summary is the same one that indexes the file for the plot, so
  -- opening the plot afterwards reads nothing again.
  if state.loading and state.selectedFilePath then
    if not Graph then Graph = loadModule("app/pages/logs/graph.lua") end
    if not Graph then
      state.loading = false
      state.summary = nil
      if state.requestRebuild then state.requestRebuild() end
    else
      if not state.reading then
        state.reading = true
        Graph.open(state.selectedFilePath, { stats = true })
      end

      for _ = 1, graphTicks do
        if Graph.tick() then break end
        if not Graph.isBusy() then break end
      end
      if widgetCall then graphTicks = 0 end

      if not Graph.isBusy() then
        state.summary = Graph.getSummary()
        state.loading = false
        state.reading = false
        collectgarbage("collect")
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    end
  end

  -- The graph's file work happens here rather than in its build, so the notice
  -- the build drew is on the screen while the log is being walked. A few units
  -- per wakeup rather than one: the unit is sized so that it cannot stall a
  -- frame, and a long log would otherwise take longer to index than to read.
  if Graph and Graph.isBusy() and graphTicks > 0 then
    local redraw = false
    for _ = 1, graphTicks do
      if Graph.tick() then
        redraw = true
        break
      end
      if not Graph.isBusy() then break end
    end
    if redraw then
      -- Asked for before the flag is cleared: a call stopped in between asks again, never not.
      if state.requestRebuild then state.requestRebuild() end
      state.drawnBusy = false
    end
  end

  -- A view drawn while the engine was busy is drawn again once it is idle, also where the tick
  -- that finished was stopped before its answer reached the loop above: the loading notice
  -- would otherwise stay up over a finished index.
  if state.view == "graph" and state.drawnBusy and Graph and not Graph.isBusy() then
    if state.requestRebuild then state.requestRebuild() end
    state.drawnBusy = false
  end
end

function M.onReload(ctx)
  state.scanned = false
  state.listTop = 0
  state.scan = nil
  state.scanShown = nil
  state.layoutPending = nil
  closeGraph()
  state.selectedFile = nil
  state.selectedFilePath = nil
  state.summary = nil
  state.loading = false
  state.reading = false
  collectgarbage("collect")
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ctx.requestRebuild()
  end
  return true
end

function M.onBack(ctx)
  -- Back walks the views it came through: chooser to plot, plot to statistics,
  -- statistics to the file list, and only then out of the page.
  if state.view == "graph" then
    if state.pickCurves and Graph and #Graph.getCurves() > 0 then
      state.pickCurves = false
      return true
    end
    -- Back to the summary of the same file: the plot's data goes, the engine and its index
    -- stay until the page leaves the file (the branch below, onReload, onClose), so Graph
    -- opens again without reading the log. A plot opened from the list has no summary to go
    -- back to, and leaves the file.
    if not state.direct and Graph and Graph.releasePlot() then
      state.view = nil
      state.pickCurves = false
      state.slots = {}
      collectgarbage("collect")
    elseif not state.direct then
      closeGraph()
    end
    if not state.direct then return true end
  end

  if state.selectedFile ~= nil then
    state.selectedFile = nil
    state.selectedFilePath = nil
    state.selectedModel = nil
    state.summary = nil
    state.loading = false
    state.reading = false
    closeGraph()
    collectgarbage("collect")
    return true
  end
  return false
end

-- `direct` opens the plot from the list: the engine then indexes the log without the summary,
-- which is the larger part of a summary walk's cost.
local function openGraph(direct)
  if not Graph then Graph = loadModule("app/pages/logs/graph.lua") end
  if not Graph then return false end
  state.view = "graph"
  state.pickCurves = false
  state.direct = direct == true
  state.slots = {}
  state.graphRefused = false
  -- The statistics view has had this file walked, and the walk built the index the plot needs;
  -- Back from the plot keeps it. Opening it again here is what the engine recognises and
  -- answers without reading.
  Graph.open(state.selectedFilePath, { stats = not state.direct })
  return true
end

-- i18n is resolved when the package is built, and the card carries no locale table at all, so
-- a lookup whose key is a variable cannot be resolved on the radio -- it reaches the screen as
-- the key itself. Every text this file picks by name is therefore looked up through a literal
-- here and chosen out of the resulting table.
local function graphErrorText(i18n, err)
  local texts = {
    open = pageText(i18n, "graph_err_open"),
    empty = pageText(i18n, "graph_err_empty"),
    not_telemetry = pageText(i18n, "graph_err_not_telemetry"),
    no_data = pageText(i18n, "graph_err_no_data"),
    no_time = pageText(i18n, "graph_err_no_time")
  }
  return texts[err] or texts.open
end

local function templateText(i18n, key)
  local texts = {
    tpl_power = pageText(i18n, "tpl_power"),
    tpl_battery = pageText(i18n, "tpl_battery"),
    tpl_link = pageText(i18n, "tpl_link"),
    tpl_governor = pageText(i18n, "tpl_governor")
  }
  return texts[key] or key
end

local GRAPH_INFO_H  = 20
local GRAPH_AXIS_H  = 18
local GRAPH_READ_H  = 24
local GRAPH_CTRL_H  = 34
local GRAPH_GAP     = 6
local GRAPH_MIN_CHART_H = 60

--- How much room a page really has, from its content origin down.
--
-- `h` in the build context is the height of the page BODY, not of the screen: `ui/home.lua`
-- hands a page module `pageBodyHeight()`, which is `LCD_H` less the header EdgeTX builds for
-- every Lua page. `LvglWidgetPage` parents the children to `page->getBody()`, a window at
-- {0, MENU_HEADER_HEIGHT, LCD_W, LCD_H - MENU_HEADER_HEIGHT} (lua_lvgl_widget.cpp), so `h` is
-- already the bottom edge these children may reach.
--
-- Taking the header off a second time here would only shorten the plot, and nothing would
-- complain, because the page scrolls either way.
--
-- The 8 px is the bottom margin. `chartRect` spends the rest on the fixed rows, so the last
-- control row ends `GRAPH_GAP` above the budget and stops 14 px clear of the body.
local function contentBudget(y, bodyH)
  local usable = bodyH - y - 8
  if usable < 160 then usable = 160 end
  return usable
end

local function rebuild()
  if state.requestRebuild then state.requestRebuild() end
end

-- The list is built a window of logs at a time, into the page body, which scrolls on its own:
-- a touch drags it, and the rotary encoder moves the focus from one row's View button to the
-- next, which scrolls the focused row into view. A page of this tool is handed no key or rotary
-- event of its own -- ui/home.lua reads them for its back handling only -- so this focus
-- movement is how the encoder reaches the list, and every row has a control that can hold it.
--
-- LIST_WINDOW bounds what a build creates and measures: five LVGL objects and a wrapped label
-- per row, however many logs the card holds. Twenty-five rows are about a hundred objects, the
-- list a card of twenty-five logs always built, and at 480x320, with rows of at least 44 px,
-- some four screens to scroll or turn through. Previous above the window and Next below it
-- build the neighbouring window, which starts again at its top.
local LIST_WINDOW = 25

local LIST_NAV_H = 44

local LIST_ROW_MIN_H = 44
local LIST_ROW_MAX_LINES = 3

-- The list's columns for a page `w` px wide; the label column is the room between the date column
-- and the two buttons. One function for the build and the wakeup, so the lines the wakeup keeps
-- were broken for the column the build draws them into.
listColumns = function(w)
  local isNarrow = w < 380
  local dateColW = isNarrow and math.floor(w * 0.34) or math.min(180, math.floor(w * 0.28))
  local btnW = isNarrow and 56 or (w < 600 and 76 or 100)
  local labelW = math.max(40, (w - btnW - 10 - GRAPH_GAP - btnW) - (dateColW + 15) - 10)
  return isNarrow, dateColW, btnW, labelW
end

-- The logs of the window on screen: the index of the first and the last, and the window's top.
-- It is clamped because the list can be shorter after a refresh than when the window was chosen.
listWindow = function()
  local logCount = #state.logsList
  local maxTop = math.floor((logCount - 1) / LIST_WINDOW) * LIST_WINDOW
  local top = math.max(0, math.min(state.listTop or 0, maxTop))
  return top, top + 1, math.min(logCount, top + LIST_WINDOW)
end

-- Breaks the names of the window's logs that are not broken for this column yet, `rows` of them at
-- most (all where `rows` is nil), and answers true once every row of the window is. The lines are
-- kept on the log's record with the width and the default model name they were made for: the
-- records outlive the page (see M.onClose), and a log without a model is labelled in the language
-- of the moment. One record is complete or untouched, so a call stopped in the middle of a row
-- breaks that row again on the next.
layOutWindow = function(labelW, modelDefault, rows)
  local logs = state.logsList
  local _, first, last = listWindow()
  for i = first, last do
    local item = logs[i]
    if item.labelW ~= labelW or item.labelModel ~= modelDefault then
      if rows ~= nil then
        if rows <= 0 then return false end
        rows = rows - 1
      end
      local lines = wrapToWidth(string.format("[%s] %s", item.model or modelDefault, item.file),
                                SMLSIZE, labelW, LIST_ROW_MAX_LINES)
      item.labelText = table.concat(lines, "\n")
      item.labelLines = #lines
      item.labelModel = modelDefault
      -- Last: it is what marks the record as broken for this column.
      item.labelW = labelW
    end
  end
  return true
end

-- A row of the window's own: a button, where there is somewhere to go, and which logs the
-- window holds out of how many.
local function appendWindowNav(children, x, y, w, buttonText, onPress, buttonRight, rangeText)
  local navW = math.min(120, math.floor(w * 0.28))
  local labelX = x + 10
  if onPress then
    local btnX = buttonRight and (x + w - navW - 10) or (x + 10)
    children[#children + 1] = {
      type = "button",
      x = btnX,
      y = y + 7,
      w = navW,
      h = 30,
      text = buttonText,
      press = onPress
    }
    if not buttonRight then
      labelX = x + navW + 20
    end
  end

  children[#children + 1] = {
    type = "label",
    x = labelX,
    y = y + 13,
    w = w - navW - 30,
    text = rangeText,
    color = Palette.text,
    font = SMLSIZE
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y + LIST_NAV_H - 1,
    w = w,
    h = 1,
    color = Palette.border,
    filled = true
  }

  return LIST_NAV_H
end

-- The column chooser: the presets this log can serve, the flight to look at when
-- the file holds more than one, and one slot per curve. Slots rather than a list
-- of every column, because a telemetry log has well over a hundred of them and a
-- row each would be a page nobody can scroll.
local function buildCurvePicker(children, x, y, w, i18n)
  local cursorY = y

  -- The chooser is built out of the shared controls and has no fallback shape:
  -- without them there is no way to offer a hundred columns on one screen.
  if not (Controls and type(Controls.appendComboSelect) == "function") then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = y + 20, w = w - 20,
      text = pageText(i18n, "graph_no_columns"),
      color = Palette.warning,
      align = CENTER
    }
    return
  end

  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "graph_select"))
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local templates = Graph.getTemplates()
  if #templates > 0 then
    local n = #templates
    local btnW = math.floor((w - (n - 1) * GRAPH_GAP) / n)
    for i = 1, n do
      local tpl = templates[i]
      children[#children + 1] = {
        type = "button",
        x = x + (i - 1) * (btnW + GRAPH_GAP),
        y = cursorY,
        w = btnW,
        h = GRAPH_CTRL_H,
        text = templateText(i18n, tpl.key),
        press = function()
          state.slots = {}
          for j = 1, #tpl.cols do state.slots[j] = tpl.cols[j] end
          state.graphRefused = not Graph.applyColumns(tpl.cols)
          if not state.graphRefused then state.pickCurves = false end
          rebuild()
        end
      }
    end
    cursorY = cursorY + GRAPH_CTRL_H + GRAPH_GAP * 2
  end

  local sessions = Graph.getSessions()
  if #sessions > 1 then
    local options = {}
    for i = 1, #sessions do
      local s = sessions[i]
      options[i] = {
        value = i,
        label = string.format("%d  (%s)", i, Graph.formatOffset(s.t1 - s.t0))
      }
    end
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w, pageText(i18n, "graph_flight"),
      options, Graph.getSessionIndex(),
      function(v)
        Graph.selectSession(v)
        rebuild()
      end)
  end

  local columns = Graph.getColumns()
  if #columns == 0 then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = cursorY + 20, w = w - 20,
      text = pageText(i18n, "graph_no_columns"),
      color = Palette.warning,
      align = CENTER
    }
    return
  end

  local options = { { value = 0, label = pageText(i18n, "graph_none") } }
  for i = 1, #columns do
    local c = columns[i]
    local label = c.name
    if c.unit ~= nil and c.unit ~= "" then label = label .. " (" .. c.unit .. ")" end
    options[#options + 1] = { value = c.col, label = label }
  end

  local curveLabel = pageText(i18n, "graph_curve")
  for k = 1, Graph.MAX_CURVES do
    local slot = k
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w, curveLabel .. " " .. slot,
      options, state.slots[slot] or 0,
      function(v)
        if v == 0 then state.slots[slot] = nil else state.slots[slot] = v end
        rebuild()
      end)
  end

  local chosen = {}
  for k = 1, Graph.MAX_CURVES do
    if state.slots[k] then chosen[#chosen + 1] = state.slots[k] end
  end

  local btnW = 200
  if btnW > w then btnW = w end
  children[#children + 1] = {
    type = "button",
    x = x + math.floor((w - btnW) / 2),
    y = cursorY + GRAPH_GAP,
    w = btnW,
    h = GRAPH_CTRL_H,
    text = pageText(i18n, "graph_show"),
    active = function() return #chosen > 0 end,
    press = function()
      if #chosen == 0 then return end
      state.graphRefused = not Graph.applyColumns(chosen)
      if not state.graphRefused then state.pickCurves = false end
      rebuild()
    end
  }
end

-- The plot area, in absolute page pixels. It is computed for every view of the graph and not
-- only for the chart: how wide the chart will be decides how many buckets a column is reduced
-- to, so the engine has to know it BEFORE a column can be chosen. Deriving it inside the chart
-- branch meant the chooser could never leave itself -- the branch it had to reach first was the
-- one that would have supplied the number.
local function chartRect(x, y, w, availH)
  local chartH = availH - (GRAPH_INFO_H + GRAPH_AXIS_H + GRAPH_READ_H + GRAPH_CTRL_H + GRAPH_GAP * 4)
  if chartH < GRAPH_MIN_CHART_H then chartH = GRAPH_MIN_CHART_H end
  return x + 2, y + GRAPH_INFO_H + GRAPH_GAP, w - 4, chartH
end

-- What the cursor and the readout row show. The step buttons move the cursor without a build:
-- the cursor and the readout labels read this table through function properties, which the
-- firmware calls again on every refresh of the scene, and a step fills it once. It is filled
-- from the engine at every build of the plot and at every step, never inside those functions,
-- so a refresh allocates nothing and does not reach for an engine that Back has already closed.
-- Every curve slot has its text, an empty one where the plot has no such curve or no reading yet:
-- a plot built before its cursor was set has no readings, and the first step gives it some.
local cursorView = { x = 0, y = 0, left = 0, right = 0, shown = false, time = "-", values = {} }

local function readCursor()
  local v = cursorView
  local x = Graph.getCursorX()
  v.x = x
  v.shown = x >= v.left and x <= v.right
  v.time = Graph.getCursorTimeText() or "-"
  local readout = Graph.getReadout()
  for k = 1, Graph.MAX_CURVES do
    local r = readout[k]
    local text = ""
    if r ~= nil then
      text = r.name .. " -"
      if r.value ~= nil then
        text = string.format("%s %g%s", r.name, r.value, r.unit or "")
      end
    end
    v.values[k] = text
  end
end

local function stepCursor(buckets)
  if Graph and Graph.moveCursor(buckets) then readCursor() end
end

local function buildChart(children, x, y, w, availH, i18n)
  local chartX, chartY, chartW, chartH = chartRect(x, y, w, availH)

  local winT0, winT1, sessT0 = Graph.getWindow()
  local windowText = Graph.formatOffset(winT0 - sessT0) .. " - " .. Graph.formatOffset(winT1 - sessT0)

  children[#children + 1] = {
    type = "label",
    x = x, y = y, w = math.floor(w * 0.55),
    text = tostring(state.selectedFile or ""),
    color = Palette.text,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label",
    x = x + math.floor(w * 0.55), y = y, w = w - math.floor(w * 0.55),
    text = windowText,
    color = Palette.text,
    font = SMLSIZE,
    align = RIGHT
  }

  -- The time axis, and the only edge the plot needs: a full frame drawn unfilled is not
  -- distinguishable from the page behind it at this theme's contrast.
  children[#children + 1] = {
    type = "rectangle",
    x = chartX, y = chartY + chartH, w = chartW, h = 1,
    color = Palette.grid,
    filled = true
  }

  -- Vertical grid lines are rectangles rather than line objects: a one-pixel
  -- column needs no point list, and the axis label belongs to the same step.
  local grid = Graph.getGrid()
  for i = 1, #grid do
    local g = grid[i]
    children[#children + 1] = {
      type = "rectangle",
      x = g.x, y = chartY + 1, w = 1, h = chartH - 2,
      color = Palette.grid,
      filled = true
    }
    children[#children + 1] = {
      type = "label",
      x = math.max(x, g.x - 18), y = chartY + chartH + 2, w = 40,
      text = g.label,
      color = Palette.muted,
      font = SMLSIZE
    }
  end

  local curves = Graph.getCurves()
  for k = 1, #curves do
    if not Graph.isCurveEmpty(k) then
      children[#children + 1] = {
        type = "line",
        x = 0, y = 0, w = 0, h = 0,
        pts = Graph.getPoints(k),
        color = Graph.getCurveColor(k),
        thickness = 1
      }
    end
  end

  local view = cursorView
  view.left, view.right, view.y = chartX, chartX + chartW, chartY + 1
  readCursor()
  -- Always in the scene, because where it stands, and whether it is inside the plot, is the
  -- firmware's to update.
  children[#children + 1] = {
    type = "rectangle",
    x = view.x, y = view.y, w = 1, h = chartH - 2,
    color = Palette.cursor,
    filled = true,
    pos = function() return view.x, view.y end,
    visible = function() return view.shown end
  }

  -- Readout row: the cursor keys, the time it stands at, and what each curve
  -- reaches there.
  local readY = chartY + chartH + GRAPH_AXIS_H + GRAPH_GAP
  local stepW = 30
  children[#children + 1] = {
    type = "button",
    x = x, y = readY, w = stepW, h = GRAPH_READ_H,
    text = "<",
    press = function() stepCursor(-1) end
  }
  children[#children + 1] = {
    type = "button",
    x = x + stepW + 4, y = readY, w = stepW, h = GRAPH_READ_H,
    text = ">",
    press = function() stepCursor(1) end
  }

  local readX = x + 2 * (stepW + 4) + GRAPH_GAP
  local timeW = 52
  children[#children + 1] = {
    type = "label",
    x = readX, y = readY + 3, w = timeW,
    text = function() return view.time end,
    color = Palette.text,
    font = SMLSIZE
  }

  local valuesX = readX + timeW + GRAPH_GAP
  local valuesW = math.max(40, (x + w) - valuesX)
  local slotW = math.floor(valuesW / Graph.MAX_CURVES)
  local values = view.values
  for k = 1, Graph.MAX_CURVES do
    children[#children + 1] = {
      type = "label",
      x = valuesX + (k - 1) * slotW, y = readY + 3, w = slotW,
      text = function() return values[k] end,
      color = Graph.getCurveColor(k),
      font = SMLSIZE
    }
  end

  -- Window controls. A drag would be the obvious gesture and is not available:
  -- the page these children live in scrolls, and it takes the gesture first.
  local ctrlY = readY + GRAPH_READ_H + GRAPH_GAP
  local labels = {
    { text = "-", press = function() Graph.zoom(-1) rebuild() end },
    { text = "+", press = function() Graph.zoom(1) rebuild() end },
    { text = pageText(i18n, "graph_full"), press = function() Graph.zoomFull() rebuild() end },
    { text = "<<", press = function() Graph.pan(-1) rebuild() end },
    { text = ">>", press = function() Graph.pan(1) rebuild() end },
    { text = pageText(i18n, "graph_curves"), press = function()
        state.pickCurves = true
        rebuild()
      end }
  }
  local n = #labels
  local btnW = math.floor((w - (n - 1) * GRAPH_GAP) / n)
  for i = 1, n do
    children[#children + 1] = {
      type = "button",
      x = x + (i - 1) * (btnW + GRAPH_GAP),
      y = ctrlY,
      w = btnW,
      h = GRAPH_CTRL_H,
      text = labels[i].text,
      press = labels[i].press
    }
  end
end

local function buildGraphView(children, x, y, w, availH, i18n)
  -- Told once per build, before anything is asked of the engine. A change drops its cached
  -- windows and starts the current one again, under the loading notice below.
  Graph.setGeometry(chartRect(x, y, w, availH))
  -- What this build drew, so the wakeup can draw again once the engine is idle (see M.wakeup).
  state.drawnBusy = Graph.isBusy()

  -- The engine walks a file to the end for the summary whether or not the plot can use it, so
  -- a file the plot cannot draw is only known once the walk is done: one without Date and Time
  -- columns, one without data rows, or one with rows of which none carries a time the plot can
  -- read. The summary reads its times more leniently than the plot (parseTimeSec against
  -- parseTimeCs), so the last case still has a summary, and is told apart from the second by it.
  -- These files used to reach the chooser, where every choice was refused without a word. Once
  -- they are caught here no choice is refused; a refusal would still say so, with no_data.
  local err = Graph.getError()
  if err == nil and not Graph.isBusy() then
    if not Graph.isTelemetry() then
      err = "not_telemetry"
    elseif not state.direct and not Graph.hasSummary() then
      -- Opened from the list the engine reads no summary; a file with no row it can use is
      -- then refused by the engine itself (getError).
      err = "no_data"
    elseif #Graph.getSessions() == 0 then
      err = "no_time"
    elseif state.graphRefused then
      err = "no_data"
    end
  end
  if err ~= nil then
    local headH = 0
    if Controls and type(Controls.appendStaticSectionHeader) == "function" then
      Controls.appendStaticSectionHeader(children, x, y, w, pageText(i18n, "graph_title"))
      headH = Controls.STATIC_SECTION_H or 50
    end
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = y + headH + 20, w = w - 20,
      text = graphErrorText(i18n, err),
      color = Palette.warning,
      align = CENTER
    }
    return
  end

  -- A read of the card is reported with the overlay the rest of the tool uses: the index pass,
  -- before anything can be chosen, and every window the cache does not hold -- a new curve
  -- choice, a zoom, a page step, another flight. The bar is the engine's position in what it
  -- reads. A window served from the cache reads nothing and leaves the plot up meanwhile.
  local reading = Graph.getReading()
  if reading ~= nil then
    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x, y = y, w = w, h = availH,
        title = pageText(i18n, "loading_title"),
        message = (reading == "index") and pageText(i18n, "graph_scanning") or pageText(i18n, "graph_reading"),
        progress = graphProgress
      })
    end
    return
  end

  if state.pickCurves or #Graph.getCurves() == 0 then
    buildCurvePicker(children, x, y, w, i18n)
    return
  end

  buildChart(children, x, y, w, availH, i18n)
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h or 200
  local i18n = ctx.i18n

  local cursorY = y

  -- If loading overlay is active. The bar is the engine's position in the file, so it stands
  -- for how much of the log has been read rather than for the fact that something is going on.
  if state.loading and LoadingOverlay then
    LoadingOverlay.append(children, {
      x = x,
      y = y,
      w = w,
      h = h,
      title = pageText(i18n, "loading_title"),
      message = pageText(i18n, "loading_message"),
      progress = readingProgress
    })
    return
  end

  -- The plot of the selected log, on top of its statistics.
  if state.view == "graph" and Graph then
    buildGraphView(children, x, cursorY, w, contentBudget(cursorY, h), i18n)
    return
  end

  -- If a log file is selected, show summary dashboard.
  --
  -- The file is never read from here. A build cannot be interrupted, so reading a log in one
  -- would be the stall the notice above exists to avoid; the wakeup does the walk and this
  -- draws whatever it has finished. A summary that is still nil at this point is a log the
  -- walk could not make sense of, which is the case the message below is for.
  if state.selectedFile and state.selectedFilePath then
    local summary = state.summary

    local titleText = summaryTitle(state.selectedModel or pageText(i18n, "model_default"), state.selectedFile, w)
    if Controls and type(Controls.appendStaticSectionHeader) == "function" then
      Controls.appendStaticSectionHeader(children, x, cursorY, w, titleText)
      cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
    end

    if not summary then
      children[#children + 1] = {
        type = "label",
        x = x + 10,
        y = cursorY + 20,
        w = w - 20,
        text = pageText(i18n, "parse_failed"),
        color = Palette.warning,
        align = CENTER
      }
      return
    end

    local rowH = 40
    local labelColW = math.max(90, math.min(180, math.floor(w * 0.28)))
    local valColX = x + labelColW + 15
    local valColW = math.max(60, w - labelColW - 27)

    -- 1) Flight Duration Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "flight_duration"),
      color = Palette.text,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s   (%d %s)", summary.durationStr, summary.sampleCount, pageText(i18n, "samples")),
      -- The default label colour these values were always drawn in (COLOR_WHITE is undefined); white is unreadable on the light page.
      color = Palette.accent,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    -- 2) Voltage Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "voltage_title"),
      color = Palette.text,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %s   |   %s: %s   |   %s: %s",
        pageText(i18n, "start"), statText("%.2fV", summary.vStart),
        pageText(i18n, "min"), statText("%.2fV (-%.2fV)", summary.vMin, summary.vSag),
        pageText(i18n, "end_val"), statText("%.2fV", summary.vEnd)),
      color = Palette.accent,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    -- 3) Current Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "current_title"),
      color = Palette.text,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %s   |   %s: %s   |   %s: %s",
        pageText(i18n, "peak"), statText("%.1f A", summary.cPeak),
        pageText(i18n, "avg"), statText("%.1f A", summary.cAvg),
        pageText(i18n, "consumption_title"), statText("~%d mAh", summary.mah and math.floor(summary.mah))),
      color = Palette.accent,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    -- 4) Headspeed RPM Row
    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "rpm_title"),
      color = Palette.text,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %s   |   %s: %s (%s)",
        pageText(i18n, "max"), statText("%d rpm", summary.rMax and math.floor(summary.rMax)),
        pageText(i18n, "min"), statText("%d rpm", summary.rMin and math.floor(summary.rMin)),
        pageText(i18n, "in_flight")),
      color = Palette.accent,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    -- 5) ESC Temp Row
    local prefs = (ctx and ctx.preferences) or (type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences)
    local useFahrenheit = tonumber(prefs and prefs.localizations and prefs.localizations.temperature_unit) == 1
    local tMaxVal = summary.tMax
    local tStartVal = summary.tStart
    local tempUnit = "°C"
    if useFahrenheit then
      tMaxVal = tMaxVal and ((tMaxVal * 9 / 5) + 32)
      tStartVal = tStartVal and ((tStartVal * 9 / 5) + 32)
      tempUnit = "°F"
    end

    children[#children + 1] = {
      type = "label",
      x = x + 12,
      y = cursorY + 10,
      w = labelColW,
      text = pageText(i18n, "temp_title"),
      color = Palette.text,
      font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label",
      x = valColX,
      y = cursorY + 10,
      w = valColW,
      text = string.format("%s: %s   |   %s: %s   |   %s %s: %s",
        pageText(i18n, "max"), statText("%d %s", tMaxVal and math.floor(tMaxVal), tempUnit),
        pageText(i18n, "start"), statText("%d %s", tStartVal and math.floor(tStartVal), tempUnit),
        pageText(i18n, "max"), pageText(i18n, "throttle_title"),
        statText("%d %%", summary.thrMax and math.floor(summary.thrMax))),
      color = Palette.accent,
      font = SMLSIZE
    }
    cursorY = cursorY + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = cursorY - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    -- The statistics answer what the flight came to; the plot answers when. Opened from here
    -- it reuses the index the summary walk built; the list's own Graph button reads only that
    -- index.
    local graphBtnW = 200
    if graphBtnW > w then graphBtnW = w end
    children[#children + 1] = {
      type = "button",
      x = x + math.floor((w - graphBtnW) / 2),
      y = cursorY + 12,
      w = graphBtnW,
      h = 36,
      text = pageText(i18n, "graph_open"),
      press = function()
        openGraph()
        if state.requestRebuild then state.requestRebuild() end
      end
    }

    return
  end

  -- List Mode: show available telemetry logs
  --
  -- The page width is kept for the wakeup, which breaks the rows of the list for it where the tool
  -- runs inside the dashboard widget (see layOutWindow).
  state.listW = w
  if not state.scanned then
    -- `state.loading` belongs to the CSV parse and drives a branch above this one with its own
    -- message, so the scan has a state of its own. Starting it reads nothing; the wakeup does
    -- the walk. The notice is drawn on every build until the walk has finished, with how many
    -- directory entries have been read and how many logs found so far.
    --
    -- It carries no bar. How many entries the walk will read is not known before it has read
    -- them -- EdgeTX's dir() answers one name at a time, and nothing says how many a directory
    -- holds -- and the reading is most of the time the walk takes, so any fraction drawn here
    -- would be one this page made up. The two counts are what is known, and they move on every
    -- wakeup of the walk.
    if LoadingOverlay then
      if not state.scan then
        state.scan = newScan()
        state.scanShown = nil
      end
      local countText = string.format(pageText(i18n, "scan_counts"), state.scan.read, #state.scan.found)
      LoadingOverlay.append(children, {
        x = x,
        y = y,
        w = w,
        h = h,
        title = pageText(i18n, "loading_title"),
        message = pageText(i18n, "scanning_message") .. "\n" .. countText,
        bar = false
      })
      return
    end

    -- No overlay module: nothing can be said, so do what this page did before rather than
    -- leave the list empty.
    state.scan = nil
    scanLogFiles()
    state.scanned = true
  end

  -- The rows' names are broken for the label column before a row is drawn. The tool script breaks
  -- the window here; hosted, the wakeup does it a few rows per call (see
  -- LAYOUT_ROWS_PER_WIDGET_WAKEUP), and until it is done the notice is drawn with the window it is
  -- preparing.
  if #state.logsList > 0 then
    local _, _, _, layoutW = listColumns(w)
    local deferred = LoadingOverlay ~= nil and inWidgetCall()
    if not layOutWindow(layoutW, pageText(i18n, "model_default"), deferred and 0 or nil) then
      state.layoutPending = true
      local _, first, last = listWindow()
      pageLog("debug", "logs list: rows %d-%d not broken yet for %d px, drawn once they are", first, last, layoutW)
      LoadingOverlay.append(children, {
        x = x,
        y = y,
        w = w,
        h = h,
        title = pageText(i18n, "loading_title"),
        message = pageText(i18n, "select_log") .. "\n"
          .. string.format(pageText(i18n, "list_range"), first, last, #state.logsList),
        bar = false
      })
      return
    end
  end

  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "select_log"))
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if #state.logsList == 0 then
    children[#children + 1] = {
      type = "label",
      x = x + 10,
      y = cursorY + 25,
      w = w - 20,
      text = pageText(i18n, "no_logs_found"),
      color = Palette.muted,
      align = CENTER
    }
    cursorY = cursorY + 60

    local btnW = 200
    local btnH = 36
    local btnX = x + math.floor((w - btnW) / 2)
    children[#children + 1] = {
      type = "button",
      x = btnX,
      y = cursorY,
      w = btnW,
      h = btnH,
      text = pageText(i18n, "refresh"),
      press = function()
        state.scanned = false
        state.listTop = 0
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    }
    return
  end

  -- Render log files list.
  --
  -- Proportional layout based on available width `w`:
  -- - Date/Time column: ~28-34% of `w` (compacts to `MM-DD HH:MM` on narrow screens < 380px)
  -- - Action buttons, View and Graph side by side: 56px on narrow screens, 76px on medium (<600px),
  --   100px on wide screens. Narrower than one button had, so the model and file name keep the room
  --   their wrapping needs; on 480 px two 100px buttons left half of it and doubled the build.
  -- - Model & filename: space between date column and action button with safe margins
  -- - Row height: follows measured broken lines so wrapped titles cannot overflow into adjacent rows
  local isNarrow, dateColW, btnW, labelW = listColumns(w)
  local btnH = 30
  local graphX = x + w - btnW - 10
  local btnX = graphX - GRAPH_GAP - btnW
  local labelX = x + dateColW + 15
  local _, labelLineH = textSize("Ag", SMLSIZE)

  -- The window on screen (see listWindow).
  local logCount = #state.logsList
  local top, first, last = listWindow()
  state.listTop = top
  local windowed = logCount > LIST_WINDOW
  local rangeText = string.format(pageText(i18n, "list_range"), first, last, logCount)

  if windowed then
    local onPrev = nil
    if top > 0 then
      onPrev = function()
        state.listTop = top - LIST_WINDOW
        rebuild()
      end
    end
    cursorY = cursorY + appendWindowNav(children, x, cursorY, w, pageText(i18n, "page_prev"),
                                        onPrev, false, rangeText)
  end

  local dateUnknown = pageText(i18n, "date_unknown")

  for i = first, last do
    local item = state.logsList[i]
    local itemY = cursorY

    -- Broken for this column by layOutWindow above, or by the wakeup before this build.
    local labelText = item.labelText
    local rowH = math.max(LIST_ROW_MIN_H, 22 + item.labelLines * labelLineH)

    -- Date and Time
    children[#children + 1] = {
      type = "label",
      x = x + 10,
      y = itemY + 11,
      w = dateColW,
      text = formatDateText(item.date, item.time, isNarrow, dateUnknown),
      color = Palette.text,
      font = SMLSIZE
    }

    -- Model name and File name
    children[#children + 1] = {
      type = "label",
      x = labelX,
      y = itemY + 11,
      w = labelW,
      text = labelText,
      color = Palette.muted,
      font = SMLSIZE
    }

    -- View button
    children[#children + 1] = {
      type = "button",
      x = btnX,
      y = itemY + 7,
      w = btnW,
      h = btnH,
      text = pageText(i18n, "btn_view"),
      press = function()
        state.selectedFile = item.file
        state.selectedFilePath = item.path
        state.selectedModel = item.model
        state.summary = nil
        state.loading = true
        state.reading = false
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    }

    -- Graph button: straight to the plot, without the summary.
    children[#children + 1] = {
      type = "button",
      x = graphX,
      y = itemY + 7,
      w = btnW,
      h = btnH,
      text = pageText(i18n, "graph_open"),
      press = function()
        state.selectedFile = item.file
        state.selectedFilePath = item.path
        state.selectedModel = item.model
        state.summary = nil
        state.loading = false
        state.reading = false
        openGraph(true)
        if state.requestRebuild then
          state.requestRebuild()
        end
      end
    }

    children[#children + 1] = {
      type = "rectangle",
      x = x,
      y = itemY + rowH - 1,
      w = w,
      h = 1,
      color = Palette.border,
      filled = true
    }

    cursorY = cursorY + rowH
  end

  if windowed then
    local onNext = nil
    if last < logCount then
      onNext = function()
        state.listTop = top + LIST_WINDOW
        rebuild()
      end
    end
    appendWindowNav(children, x, cursorY, w, pageText(i18n, "page_next"), onNext, true, rangeText)
  end
end

-- The list of logs and the window of it on screen are kept when the page closes, so coming back
-- neither walks the card again nor builds more than one window of it. Each log is one table of up
-- to six short strings from extractFileInfo (date and model may be absent), about half a kilobyte
-- of Lua memory on the 64-bit EdgeTX simulator (a radio's 32-bit build has smaller table and
-- string headers; not measured there): 2.3 MB on the simulator for 5000 logs, which counts
-- against the limit EdgeTX sets for all Lua scripts and widgets together (6 MB on colour radios).
-- The LVGL tree is not kept; the host drops it with the page. The list is read again when the
-- pilot asks for it with Reload, or when the host drops this module from its page cache
-- (app/pages/init.lua) and loads it afresh. A log written since the list was read is not on it
-- until then.
--
-- A walk still in progress is dropped rather than kept, and with it any directory it held open;
-- the next visit starts it again.
function M.onClose()
  state.scan = nil
  state.scanShown = nil
  state.layoutPending = nil
  closeGraph()
  state.selectedFile = nil
  state.selectedFilePath = nil
  state.selectedModel = nil
  state.summary = nil
  state.loading = false
  state.reading = false
  LoadingOverlay = nil
  collectgarbage("collect")
end

return M
