local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
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
  state.slots = {}
  collectgarbage("collect")
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

-- Reads at most `budget` entries into the listing and answers how many reads that took: the
-- reads spent, `.` and `..` and the one that ends the directory among them. That last read is
-- what drops the iterator. A name read is held on the listing until it has been taken, so a
-- call stopped in between (see scanCollect) takes it on the next one rather than losing it.
local function readListing(listing, budget)
  local spent = 0
  while listing.iter and spent < budget do
    if listing.held == nil then
      listing.held = listing.iter() or false
      spent = spent + 1
    end
    local name = listing.held
    if name == false then
      listing.iter = nil
    elseif name ~= "." and name ~= ".." and name ~= "" then
      listing.names[#listing.names + 1] = name
    end
    listing.held = nil
  end
  return spent
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
-- Each search path is listed and then walked, in the order the paths are given, and a folder
-- among its names is listed and walked when it is reached -- the order the walk always had, so
-- the first path a file is reached by, which decides the folder its model may be named after,
-- is the one it was reached by before. The sort is a phase of its own, so it never shares a
-- wakeup with a last batch of entries.
local SCAN_UNIT_ENTRIES = 10

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
    names = nil,
    i = 0,
    sub = nil,
    read = 0,
    found = {},
    seen = {}
  }
end

-- An entry is marked as seen, and the walk's position moved past it (scanStep), only once it is
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

-- Reads up to `budget` names of a listing and counts them as read: the names added, `.` and
-- `..` not counted, so `scan.read` is not the reads spent. Answers the reads spent.
local function scanRead(scan, listing, budget)
  local before = #listing.names
  local spent = readListing(listing, budget)
  scan.read = scan.read + #listing.names - before
  return spent
end

-- Advances the scan by at most `budget` entries and answers true once it is complete, with
-- `scan.found` sorted newest first. Steps that only move from one directory to the next cost
-- nothing and are taken in the same call; the sort is one call on its own. Every step leaves
-- the scan where its phase can go on from, at any point: a call stopped in the middle of one
-- (see scanCollect) repeats part of it rather than leaving the scan in a phase it cannot finish.
local function scanStep(scan, budget)
  while budget > 0 do
    if scan.phase == "list" then
      if not scan.listing then
        scan.listing = openListing(SEARCH_PATHS[scan.s])
      end
      budget = budget - scanRead(scan, scan.listing, budget)
      if not scan.listing.iter then
        local names = scan.listing.names
        scan.i = 0
        scan.names = names
        scan.listing = nil
        scan.phase = "walk"
      end
    elseif scan.phase == "walk" then
      local basePath = SEARCH_PATHS[scan.s]
      local sub = scan.sub
      if sub then
        -- Inside a subdirectory (e.g. a model folder) of a search path: list it, then collect
        -- its .csv files.
        if sub.listing.iter then
          budget = budget - scanRead(scan, sub.listing, budget)
        else
          local names = sub.listing.names
          while budget > 0 and sub.j < #names do
            local subFile = names[sub.j + 1]
            if string.match(subFile, "%.csv$") then
              scanCollect(scan, subFile, sub.path .. "/" .. subFile, sub.parent)
            end
            sub.j = sub.j + 1
            budget = budget - 1
          end
          if sub.j >= #names then
            -- The entry that opened this folder counts as walked, even where the call that
            -- opened it was stopped before it could move on.
            if scan.i < sub.at then scan.i = sub.at end
            scan.sub = nil
          end
        end
      elseif scan.i < #scan.names then
        local entry = scan.names[scan.i + 1]
        if string.match(entry, "%.csv$") then
          scanCollect(scan, entry, basePath .. "/" .. entry, "")
        elseif not string.match(entry, "%.%w+$") then
          -- Subdirectory (e.g. Model name)
          local modelDir = basePath .. "/" .. entry
          scan.sub = { listing = openListing(modelDir), path = modelDir, parent = entry, j = 0, at = scan.i + 1 }
        end
        scan.i = scan.i + 1
        budget = budget - 1
      else
        local s = scan.s + 1
        if s > #SEARCH_PATHS then
          -- The walk is over. The sort is left to the next call, so it never runs in the same
          -- call as the walk's last entries.
          scan.phase = "sort"
          scan.names = nil
          return false
        end
        scan.phase = "list"
        scan.s = s
        scan.names = nil
      end
    elseif scan.phase == "sort" then
      table.sort(scan.found, function(a, b) return a.sortKey > b.sortKey end)
      scan.phase = "done"
      return true
    else
      return true
    end
  end
  return false
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
  if state.scan then
    if scanForAWhile(state.scan, widgetCall and SCAN_UNITS_PER_WIDGET_WAKEUP or nil) then
      state.logsList = state.scan.found
      state.scan = nil
      state.scanShown = nil
      state.scanned = true
      state.loading = false
      -- Frees what the steps left behind (about 300 KB at 587 logs) before the build allocates;
      -- measured on the EdgeTX simulator, under 1 ms and no more than the same collect after it.
      collectgarbage("collect")
      if state.requestRebuild then
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
    if redraw and state.requestRebuild then
      state.requestRebuild()
    end
  end
end

function M.onReload(ctx)
  state.scanned = false
  state.listTop = 0
  state.scan = nil
  state.scanShown = nil
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
    closeGraph()
    return true
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

local function openGraph()
  if not Graph then Graph = loadModule("app/pages/logs/graph.lua") end
  if not Graph then return false end
  state.view = "graph"
  state.pickCurves = false
  state.slots = {}
  state.graphRefused = false
  -- The statistics view has just had this file walked, and the walk built the index the plot
  -- needs. Opening it again here is what the engine recognises and answers without reading.
  Graph.open(state.selectedFilePath, { stats = true })
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
-- LIST_WINDOW bounds what a build creates and measures: four LVGL objects and a wrapped label
-- per row, however many logs the card holds. Twenty-five rows are about a hundred objects, the
-- list a card of twenty-five logs always built, and at 480x320, with rows of at least 44 px,
-- some four screens to scroll or turn through. Previous above the window and Next below it
-- build the neighbouring window, which starts again at its top.
local LIST_WINDOW = 25

local LIST_NAV_H = 44

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

local function buildChart(children, x, y, w, availH, i18n)
  local chartX, chartY, chartW, chartH = chartRect(x, y, w, availH)

  local winT0, winT1, sessT0 = Graph.getWindow()
  local windowText = Graph.formatOffset(winT0 - sessT0) .. " - " .. Graph.formatOffset(winT1 - sessT0)
  if Graph.isBusy() then
    windowText = windowText .. "   " .. tostring(math.floor(Graph.getProgress() * 100)) .. " %"
  end

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

  local cursorX = Graph.getCursorX()
  if cursorX >= chartX and cursorX <= chartX + chartW then
    children[#children + 1] = {
      type = "rectangle",
      x = cursorX, y = chartY + 1, w = 1, h = chartH - 2,
      color = Palette.cursor,
      filled = true
    }
  end

  -- Readout row: the cursor keys, the time it stands at, and what each curve
  -- reaches there.
  local readY = chartY + chartH + GRAPH_AXIS_H + GRAPH_GAP
  local stepW = 30
  children[#children + 1] = {
    type = "button",
    x = x, y = readY, w = stepW, h = GRAPH_READ_H,
    text = "<",
    press = function()
      Graph.moveCursor(-1)
      rebuild()
    end
  }
  children[#children + 1] = {
    type = "button",
    x = x + stepW + 4, y = readY, w = stepW, h = GRAPH_READ_H,
    text = ">",
    press = function()
      Graph.moveCursor(1)
      rebuild()
    end
  }

  local readX = x + 2 * (stepW + 4) + GRAPH_GAP
  local timeW = 52
  children[#children + 1] = {
    type = "label",
    x = readX, y = readY + 3, w = timeW,
    text = Graph.getCursorTimeText() or "-",
    color = Palette.text,
    font = SMLSIZE
  }

  local readout = Graph.getReadout()
  local valuesX = readX + timeW + GRAPH_GAP
  local valuesW = math.max(40, (x + w) - valuesX)
  local slotW = math.floor(valuesW / Graph.MAX_CURVES)
  for k = 1, #readout do
    local r = readout[k]
    local text = r.name .. " -"
    if r.value ~= nil then
      text = string.format("%s %g%s", r.name, r.value, r.unit or "")
    end
    children[#children + 1] = {
      type = "label",
      x = valuesX + (k - 1) * slotW, y = readY + 3, w = slotW,
      text = text,
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
  -- windows and starts the current one again; the points it still holds are drawn meanwhile.
  Graph.setGeometry(chartRect(x, y, w, availH))

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
    elseif not Graph.hasSummary() then
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

  -- Nothing can be chosen before the index exists, so the scan is the one wait
  -- this view reports with the overlay the rest of the tool uses.
  if #Graph.getCurves() == 0 and Graph.isBusy() then
    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x, y = y, w = w, h = availH,
        title = pageText(i18n, "loading_title"),
        message = pageText(i18n, "graph_scanning"),
        progress = Graph.getProgress()
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
      progress = (Graph and state.reading) and Graph.getProgress() or 0
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

    -- The statistics answer what the flight came to; the plot answers when. It is
    -- opened from here rather than from the list, so the log is chosen once.
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
  -- - Action button: 60px on narrow screens, 80px on medium (<480px), 100px on wide screens
  -- - Model & filename: space between date column and action button with safe margins
  -- - Row height: follows measured broken lines so wrapped titles cannot overflow into adjacent rows
  local ROW_MIN_H = 44
  local ROW_MAX_LINES = 3
  local isNarrow = w < 380
  local dateColW = isNarrow and math.floor(w * 0.34) or math.min(180, math.floor(w * 0.28))
  local btnW = isNarrow and 60 or (w < 480 and 80 or 100)
  local btnH = 30
  local btnX = x + w - btnW - 10
  local labelX = x + dateColW + 15
  local labelW = math.max(40, btnX - labelX - 10)
  local _, labelLineH = textSize("Ag", SMLSIZE)

  -- The window on screen. It is clamped because the list can be shorter after a refresh than
  -- when the window was chosen.
  local logCount = #state.logsList
  local maxTop = math.floor((logCount - 1) / LIST_WINDOW) * LIST_WINDOW
  local top = math.max(0, math.min(state.listTop or 0, maxTop))
  state.listTop = top
  local first = top + 1
  local last = math.min(logCount, top + LIST_WINDOW)
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
  local modelDefault = pageText(i18n, "model_default")

  for i = first, last do
    local item = state.logsList[i]
    local itemY = cursorY

    local labelLines = wrapToWidth(string.format("[%s] %s", item.model or modelDefault, item.file),
                                   SMLSIZE, labelW, ROW_MAX_LINES)
    local labelText = table.concat(labelLines, "\n")
    local rowH = math.max(ROW_MIN_H, 22 + #labelLines * labelLineH)

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
