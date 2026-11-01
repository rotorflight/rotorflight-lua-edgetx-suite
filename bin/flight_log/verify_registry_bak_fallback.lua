-- The battery registry after a replace that was cut short between its two renames.
--
-- Run from the repository root:
--     lua5.3 bin/flight_log/verify_registry_bak_fallback.lua
--
-- Drives the real src/rfsuite/lib/flight_log.lua and lib/atomic_file.lua against an in-memory card
-- that answers io.open/io.read/io.write/io.close, fstat, mkdir, rename and del the way the radio's
-- filesystem library does. lib/atomic_file.lua parks batteries.cfg as batteries.cfg.bak and then
-- renames batteries.cfg.new into place; power lost between the two leaves only the `.bak`. The
-- registry is then read from the `.bak`, and the next edit writes it back under the name, so a new
-- pack added after the cut is appended to the pilot's registry instead of starting a file of one
-- line that the edit after it would park over the `.bak`.
--
-- An edit is also never built on a registry read short: where fstat answers a size, a read that
-- does not match it -- a file that does not open, a read ended early by a card error -- refuses
-- the edit instead of writing a short registry over the pilot's.

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail ~= nil then print("        " .. tostring(detail)) end
  end
end

-- ---------------------------------------------------------------------------
-- The card
-- ---------------------------------------------------------------------------
-- luacheck: globals io fstat mkdir del rename loadScript
local files = {}
-- A path in `unopenable` stands on the card (fstat answers) but does not open; `failRename`
-- refuses one rename; `shortAt` ends every read of a path in `short` after that many bytes, the
-- way a card error does (the same empty string as the end of the file). Every handle handed out
-- is counted, and so is every close.
local unopenable = {}
local failRename = nil
local short, shortAt = {}, nil
local opened, closed = 0, 0

io.open = function(path, mode)
  mode = mode or "r"
  local kind = string.sub(mode, 1, 1)
  if unopenable[path] then return nil end
  if kind == "r" and files[path] == nil then return nil end
  if kind == "w" then files[path] = "" end
  if kind == "a" and files[path] == nil then files[path] = "" end
  opened = opened + 1
  return { path = path, pos = 1 }
end
io.read = function(f, n)
  local data = files[f.path] or ""
  if short[f.path] then data = string.sub(data, 1, shortAt) end
  if f.pos > #data then return "" end
  local chunk = string.sub(data, f.pos, f.pos + n - 1)
  f.pos = f.pos + #chunk
  return chunk
end
io.write = function(f, ...)
  for i = 1, select("#", ...) do files[f.path] = files[f.path] .. tostring((select(i, ...))) end
  return f
end
io.close = function(f)
  if type(f) == "table" and not f.closed then
    f.closed = true
    closed = closed + 1
  end
  return true
end
function fstat(path)
  if files[path] == nil then return nil end
  return { size = #files[path] }
end
function mkdir() return 8 end
function del(path) files[path] = nil; return 0 end
-- FatFS refuses a rename onto an existing name
function rename(from, to)
  if failRename ~= nil and failRename(from, to) then return 1 end
  if files[from] == nil or files[to] ~= nil then return 8 end
  files[to], files[from] = files[from], nil
  return 0
end
function loadScript(path)
  local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
  assert(relative == "lib/atomic_file.lua", "unexpected module: " .. tostring(path))
  return assert(loadfile("src/rfsuite/" .. relative))
end
_G.rfsuite = nil

local FlightLog = assert(loadfile("src/rfsuite/lib/flight_log.lua"))()
local AtomicFile = assert(loadfile("src/rfsuite/lib/atomic_file.lua"))()

local REG = FlightLog.registryPath()
local BAK = REG .. ".bak"

-- The pilot's registry as kept by hand: a comment, three packs, an unknown field
local REGISTRY = "# my packs\n"
  .. "id=1;name=Red 6S;cap=5000;cells=6;models=*;cycles=12;last=2026-10-01\n"
  .. "id=2;name=Blue 6S;cap=4500;cells=6;models=goblin;cycles=3;note=new\n"
  .. "id=3;name=Spare;cap=3300;cells=6;cycles=40\n"

local function reset()
  for k in pairs(files) do files[k] = nil end
  for k in pairs(unopenable) do unopenable[k] = nil end
  for k in pairs(short) do short[k] = nil end
  failRename, shortAt = nil, nil
end

-- The state a cut-off replace leaves: no file under the name, the registry parked as `.bak`, and
-- the finished `.new` the second rename never moved.
local function cutOff()
  reset()
  files[BAK] = REGISTRY
  files[REG .. ".new"] = REGISTRY .. "id=9;name=Lost edit;cycles=0\n"
end

local function ids(registry)
  local out = {}
  for i = 1, #registry do out[#out + 1] = registry[i].id end
  return table.concat(out, ",")
end

local function call(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then return "error: " .. tostring(a) end
  return a, b
end

local DT = { year = 2026, mon = 11, day = 1, hour = 10, min = 0, sec = 0 }

-- ---------------------------------------------------------------------------
print("1. the shared helper")
-- ---------------------------------------------------------------------------
do
  local helper = AtomicFile.readablePath
  check("lib/atomic_file.lua offers readablePath", type(helper) == "function", type(helper))
  if type(helper) == "function" then
    reset()
    files["/x"], files["/x.bak"] = "file", "older"
    check("a file under the name is read from the name, a stale .bak beside it is not",
      helper("/x") == "/x", helper("/x"))
    reset()
    files["/x.bak"] = "only copy"
    check("only a .bak: it is read from the .bak", helper("/x") == "/x.bak", helper("/x"))
    reset()
    files["/x"], files["/x.bak"] = "file", "older"
    unopenable["/x"] = true
    check("a file under the name that does not open: still the name, never the older .bak",
      helper("/x") == "/x", helper("/x"))
    reset()
    files["/x.bak"] = "only copy"
    unopenable["/x.bak"] = true
    check("only a .bak, and it does not open: the .bak, so its read fails rather than reading as no file",
      helper("/x") == "/x.bak", helper("/x"))
    -- A card whose fstat does not answer: the opens alone decide
    local realFstat = fstat
    fstat = nil
    reset()
    files["/x.bak"] = "only copy"
    check("no fstat, only a .bak: still read from the .bak", helper("/x") == "/x.bak", helper("/x"))
    reset()
    files["/x"], files["/x.bak"] = "file", "older"
    check("no fstat, a file under the name: the name", helper("/x") == "/x", helper("/x"))
    cutOff()
    check("no fstat, only the registry's .bak: loadRegistry still shows the pilot's packs",
      ids(FlightLog.loadRegistry()) == "1,2,3", ids(FlightLog.loadRegistry()))
    fstat = realFstat
    reset()
    check("neither: the name, so a missing file still reads as missing", helper("/x") == "/x", helper("/x"))
  end
end

-- ---------------------------------------------------------------------------
print("2. the readers, with only the .bak left")
-- ---------------------------------------------------------------------------
do
  cutOff()
  local registry = call(FlightLog.loadRegistry)
  check("loadRegistry (the Batteries page, the pack prompt) shows the pilot's packs",
    type(registry) == "table" and ids(registry) == "1,2,3", type(registry) == "table" and ids(registry) or registry)

  cutOff()
  local data, err = call(FlightLog.readRegistry)
  check("readRegistry (the disarm task) answers the registry text whole",
    data == REGISTRY and err == nil, tostring(data) .. " / " .. tostring(err))
  check("and a pack in it is found", FlightLog.hasBattery(data, "2") == true)
  check("reading writes nothing: the card is as the cut left it",
    files[REG] == nil and files[BAK] == REGISTRY)
end

-- ---------------------------------------------------------------------------
print("3. a new pack added after the cut")
-- ---------------------------------------------------------------------------
do
  cutOff()
  local created = call(FlightLog.createBattery, { id = "4", name = "New 6S", cap = 5200, cells = 6 })
  check("createBattery succeeds", created == true, created)
  check("it is appended to the pilot's registry, which stands under the name again",
    files[REG] == REGISTRY .. "id=4;name=New 6S;cap=5200;cells=6;cycles=0\n", files[REG])
  check("the .bak is left as it was by that write", files[BAK] == REGISTRY, files[BAK])

  local marked = call(FlightLog.markUsed, "4", DT)
  check("the next edit (a counted flight) succeeds", marked == true, marked)
  check("every pack survives it", ids(FlightLog.loadRegistry()) == "1,2,3,4", ids(FlightLog.loadRegistry()))
  check("the comment and the unknown field survive it",
    files[REG] ~= nil and string.find(files[REG], "# my packs\n", 1, true) == 1
      and string.find(files[REG], "note=new", 1, true) ~= nil, files[REG])
  check("and the .bak it parked holds the whole registry, not the file of one line",
    files[BAK] == REGISTRY .. "id=4;name=New 6S;cap=5200;cells=6;cycles=0\n", files[BAK])
end

-- ---------------------------------------------------------------------------
print("4. the first edit after the cut writes the registry back under the name")
-- ---------------------------------------------------------------------------
do
  cutOff()
  local marked = call(FlightLog.markUsed, "2", DT)
  check("markUsed succeeds", marked == true, marked)
  check("the registry stands under the name, the pack stamped",
    files[REG] ~= nil and string.find(files[REG],
      "id=2;name=Blue 6S;cap=4500;cells=6;models=goblin;cycles=4;note=new;last=2026-11-01\n", 1, true) ~= nil
      and ids(FlightLog.loadRegistry()) == "1,2,3", files[REG])

  -- The disarm task reads with readRegistry and hands the text to markUsed
  cutOff()
  local data = FlightLog.readRegistry()
  marked = call(FlightLog.markUsed, "3", DT, data)
  check("markUsed with the text readRegistry answered succeeds", marked == true, marked)
  check("and writes it back under the name", files[REG] ~= nil
    and string.find(files[REG], "id=3;name=Spare;cap=3300;cells=6;cycles=41;last=2026-11-01", 1, true) ~= nil, files[REG])

  cutOff()
  local updated = call(FlightLog.updateBattery, "3", { name = "Spare 2" })
  check("updateBattery succeeds", updated == true, updated)
  check("and writes the registry back under the name", files[REG] ~= nil
    and string.find(files[REG], "id=3;name=Spare 2;cap=3300", 1, true) ~= nil
    and ids(FlightLog.loadRegistry()) == "1,2,3", files[REG])

  cutOff()
  local deleted = call(FlightLog.deleteBattery, "3")
  check("deleteBattery succeeds", deleted == true, deleted)
  check("and writes the rest of the registry back under the name",
    files[REG] ~= nil and ids(FlightLog.loadRegistry()) == "1,2", files[REG])

  cutOff()
  FlightLog.markUsed("1", DT)
  FlightLog.markUsed("2", DT)
  -- The parked file is the one the first stamp wrote: pack 1 counted, pack 2 not yet
  check("the edit after that replaces the .bak with the registry it parked",
    files[BAK] ~= nil
      and string.find(files[BAK], "id=1;name=Red 6S;cap=5000;cells=6;models=*;cycles=13;last=2026-11-01\n", 1, true) ~= nil
      and string.find(files[BAK], "id=2;name=Blue 6S;cap=4500;cells=6;models=goblin;cycles=3;note=new\n", 1, true) ~= nil
      and string.find(files[BAK], "id=3;", 1, true) ~= nil and ids(FlightLog.loadRegistry()) == "1,2,3", files[BAK])
end

-- ---------------------------------------------------------------------------
print("4b. the first edit after the cut fails at its final rename")
-- ---------------------------------------------------------------------------
do
  cutOff()
  failRename = function(from, to) return from == REG .. ".new" and to == REG end
  local marked = call(FlightLog.markUsed, "2", DT)
  failRename = nil
  check("markUsed reports the failure", marked == false, marked)
  check("the .bak, the only copy, is untouched", files[BAK] == REGISTRY and files[REG] == nil, files[BAK])
  check("the registry still reads whole from it", FlightLog.readRegistry() == REGISTRY)
  check("the next edit writes it back under the name", FlightLog.markUsed("2", DT) == true
    and ids(FlightLog.loadRegistry()) == "1,2,3" and files[BAK] == REGISTRY, files[REG])
end

-- ---------------------------------------------------------------------------
print("5. unchanged: neither file, and a file under the name")
-- ---------------------------------------------------------------------------
do
  reset()
  check("neither file: an empty registry", #FlightLog.loadRegistry() == 0)
  local data, err = FlightLog.readRegistry()
  check("neither file: readRegistry answers no text and no error", data == nil and err == nil,
    tostring(data) .. " / " .. tostring(err))
  local marked, reason = FlightLog.markUsed("1", DT)
  check("neither file: nothing to stamp", marked == false and reason == "noregistry", tostring(reason))
  check("neither file: an edit is refused as not found", FlightLog.updateBattery("1", { name = "x" }) == "notfound"
    and files[REG] == nil)
  check("neither file: a new pack starts the file", FlightLog.createBattery({ id = "1", name = "First" }) == true
    and files[REG] == "id=1;name=First;cycles=0\n", files[REG])

  reset()
  files[REG] = REGISTRY
  files[BAK] = "id=7;name=Old\n"
  check("a file under the name is read, not the .bak beside it", ids(FlightLog.loadRegistry()) == "1,2,3",
    ids(FlightLog.loadRegistry()))
  check("an edit of it parks it over the .bak as before", FlightLog.markUsed("1", DT) == true
    and files[BAK] == REGISTRY, files[BAK])

  reset()
  files[REG] = REGISTRY
  files[BAK] = "id=7;name=Old\n"
  unopenable[REG] = true
  check("a file under the name that does not open: the older .bak is not read in its place",
    ids(FlightLog.loadRegistry()) == "", ids(FlightLog.loadRegistry()))
end

-- ---------------------------------------------------------------------------
print("6. an edit is never written over a registry that was read short")
-- ---------------------------------------------------------------------------
do
  local FIRST = "# my packs\nid=1;name=Red 6S;cap=5000;cells=6;models=*;cycles=12;last=2026-10-01\n"

  reset()
  files[REG] = REGISTRY
  short[REG], shortAt = true, #FIRST
  local updated = call(FlightLog.updateBattery, "1", { name = "Red" })
  check("a read that ended before the size fstat answered: the edit is refused as unreadable",
    updated == "unreadable", updated)
  check("and the registry is left as it was", files[REG] == REGISTRY and files[BAK] == nil, files[REG])

  reset()
  files[BAK] = REGISTRY
  short[BAK], shortAt = true, #FIRST
  local marked = call(FlightLog.markUsed, "1", DT)
  check("the same for a registry read from the .bak", marked == false and files[REG] == nil
    and files[BAK] == REGISTRY, tostring(marked) .. " / " .. tostring(files[REG]))

  reset()
  files[REG] = REGISTRY
  unopenable[REG] = true
  local created = call(FlightLog.createBattery, { id = "4", name = "New 6S" })
  check("a file that stands but does not open: a new pack is refused, not started as a file of one line",
    created == "unreadable" and files[REG] == REGISTRY and files[BAK] == nil, created)

  cutOff()
  unopenable[BAK] = true
  created = call(FlightLog.createBattery, { id = "4", name = "New 6S" })
  check("only the .bak, and it does not open: a new pack is refused, the .bak left alone",
    created == "unreadable" and files[REG] == nil and files[BAK] == REGISTRY, created)

  -- The disarm task: readRegistry refuses, and markUsed is then called with no text and reads again
  reset()
  files[REG] = REGISTRY
  short[REG], shortAt = true, #FIRST
  local text, why = FlightLog.readRegistry()
  local stamped, reason = call(FlightLog.markUsed, "1", DT, text)
  check("the disarm's count after a short read: readRegistry refuses, and markUsed's own read refuses too",
    text == nil and why == "unreadable" and stamped == false and reason == "unreadable",
    tostring(why) .. " / " .. tostring(stamped) .. " / " .. tostring(reason))
  check("and the registry is left as it was", files[REG] == REGISTRY and files[BAK] == nil, files[REG])
end

check("every file opened was closed again", opened == closed, opened .. " opened, " .. closed .. " closed")

print(string.format("Flight log registry after a cut-off replace: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
