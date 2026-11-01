-- What the Flight Log page says when a registry edit is refused.
--
-- Run from the repository root:
--     lua5.3 bin/flight_log/verify_page_refusal_message.lua
--
-- Drives the real src/rfsuite/app/pages/tools/flight_log/page.lua, lib/flight_log.lua,
-- lib/atomic_file.lua and ui/controls.lua against an in-memory card. The page is opened, the
-- Batteries tab pressed, and a new pack saved or an existing one deleted through the buttons the
-- page builds. A registry that is refused before anything is written -- the file stands but does
-- not open, or the read does not match its size -- must not be reported as a write the card did
-- not take; a write that the card really refused still is.

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
-- luacheck: globals io fstat mkdir del rename loadScript SMLSIZE CENTER RIGHT LEFT
local files = {}
local unopenable = {}
local failRename = false
local short, shortAt = {}, nil

io.open = function(path, mode)
  mode = mode or "r"
  local kind = string.sub(mode, 1, 1)
  if unopenable[path] then return nil end
  if kind == "r" and files[path] == nil then return nil end
  if kind == "w" then files[path] = "" end
  if kind == "a" and files[path] == nil then files[path] = "" end
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
io.close = function() return true end
function fstat(path)
  if files[path] == nil then return nil end
  return { size = #files[path] }
end
function mkdir() return 8 end
function del(path) files[path] = nil; return 0 end
function rename(from, to)
  if failRename then return 1 end
  if files[from] == nil or files[to] ~= nil then return 8 end
  files[to], files[from] = files[from], nil
  return 0
end

SMLSIZE, CENTER, RIGHT, LEFT = 0, 1, 2, 3

-- The modules the page loads from the package. Anything not listed answers as missing, which
-- the page already handles (no translations: every text is its English fallback).
local REAL = {
  ["lib/flight_log.lua"] = true,
  ["lib/atomic_file.lua"] = true,
  ["ui/controls.lua"] = true
}
local STUB = {
  ["ui/loading_overlay.lua"] = { append = function() end }
}
function loadScript(path)
  local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
  if relative ~= nil and REAL[relative] then return assert(loadfile("src/rfsuite/" .. relative)) end
  if relative ~= nil and STUB[relative] then
    local module = STUB[relative]
    return function() return module end
  end
  return nil
end
_G.rfsuite = { palette = {} }

local FlightLog = assert(loadfile("src/rfsuite/lib/flight_log.lua"))()
local REG = FlightLog.registryPath()
local REGISTRY = "# my packs\n"
  .. "id=1;name=Red 6S;cap=5000;cells=6;cycles=12\n"
  .. "id=2;name=Blue 6S;cap=4500;cells=6;cycles=3\n"

local WRITE_TEXT = "The card did not take the write"

-- ---------------------------------------------------------------------------
-- The page, driven through what it builds
-- ---------------------------------------------------------------------------

local function freshCard()
  for k in pairs(files) do files[k] = nil end
  for k in pairs(unopenable) do unopenable[k] = nil end
  for k in pairs(short) do short[k] = nil end
  failRename, shortAt = false, nil
  files[REG] = REGISTRY
end

local function open()
  local page = assert(loadfile("src/rfsuite/app/pages/tools/flight_log/page.lua"))()
  local state = { children = {} }
  local ctx = {
    x = 0, y = 0, w = 480, h = 272,
    preferences = {},
    requestRebuild = function() end
  }
  function state.build()
    state.children = {}
    ctx.children = state.children
    page.build(ctx)
    return state.children
  end
  function state.find(kind, text)
    for _, child in ipairs(state.children) do
      if child.type == kind and child.text == text then return child end
    end
    return nil
  end
  function state.labels()
    local out = {}
    for _, child in ipairs(state.children) do
      if child.type == "label" and type(child.text) == "string" then out[#out + 1] = child.text end
    end
    return out
  end
  function state.press(text)
    local button = state.find("button", text)
    assert(button ~= nil, "no button " .. text)
    button.press()
    state.build()
  end
  state.build()
  page.wakeup(ctx)
  state.build()
  return state
end

local function hasLabel(state, text)
  for _, label in ipairs(state.labels()) do
    if label == text then return true end
  end
  return false
end

local function shown(state)
  local out = {}
  for _, label in ipairs(state.labels()) do
    if label == WRITE_TEXT or string.find(label, "registry", 1, true) then out[#out + 1] = label end
  end
  return table.concat(out, " | ")
end

-- Saves a new pack from the Batteries tab with `stage` applied to the card just before Save.
local function saveNew(stage)
  freshCard()
  local state = open()
  state.press("Batteries")
  state.press("New battery")
  check("the editor is open", state.find("button", "Save") ~= nil)
  stage()
  state.press("Save")
  return state
end

-- Deletes pack 1 through its detail view with `stage` applied before Delete.
local function deleteFirst(stage)
  freshCard()
  local state = open()
  state.press("Batteries")
  local more = nil
  for _, child in ipairs(state.children) do
    if child.type == "button" and child.text == ">" then more = child; break end
  end
  assert(more ~= nil, "no pack row")
  more.press()
  state.build()
  stage()
  state.press("Delete")
  return state
end

-- ---------------------------------------------------------------------------
print("1. a registry read refused before anything is written")
-- ---------------------------------------------------------------------------
do
  local state = saveNew(function()
    short[REG] = true
    shortAt = 10
  end)
  check("a read cut short: the page does not say the card refused a write",
    not hasLabel(state, WRITE_TEXT), shown(state))
  check("a read cut short: the page says the registry was not read whole and nothing changed",
    hasLabel(state, "The registry was not read whole; nothing was changed"), shown(state))
  check("a read cut short: the registry on the card is unchanged", files[REG] == REGISTRY, files[REG])
  check("a read cut short: the editor stays open with what was typed",
    state.find("button", "Save") ~= nil)

  state = saveNew(function() unopenable[REG] = true end)
  check("a registry that stands but does not open: not reported as a refused write",
    not hasLabel(state, WRITE_TEXT), shown(state))
  check("a registry that stands but does not open: the not-read-whole message",
    hasLabel(state, "The registry was not read whole; nothing was changed"), shown(state))
  check("a registry that stands but does not open: unchanged", files[REG] == REGISTRY, files[REG])

  state = deleteFirst(function()
    short[REG] = true
    shortAt = 10
  end)
  check("Delete on a read cut short: the not-read-whole message on the pack's view",
    hasLabel(state, "The registry was not read whole; nothing was changed"), shown(state))
  check("Delete on a read cut short: the registry on the card is unchanged", files[REG] == REGISTRY, files[REG])
end

-- ---------------------------------------------------------------------------
print("2. a write the card refused keeps its message")
-- ---------------------------------------------------------------------------
do
  local state = saveNew(function() failRename = true end)
  check("a rename the card refuses: the page says the card did not take the write",
    hasLabel(state, WRITE_TEXT), shown(state))
  check("a rename the card refuses: the not-read-whole message is not shown",
    not hasLabel(state, "The registry was not read whole; nothing was changed"), shown(state))
  check("a rename the card refuses: the registry under its name is unchanged",
    files[REG] == REGISTRY, files[REG])

  state = deleteFirst(function() failRename = true end)
  check("Delete with a rename the card refuses: the write message", hasLabel(state, WRITE_TEXT), shown(state))
end

-- ---------------------------------------------------------------------------
print("3. a save that goes through shows neither")
-- ---------------------------------------------------------------------------
do
  local state = saveNew(function() end)
  check("a normal save: no refusal message",
    not hasLabel(state, WRITE_TEXT)
      and not hasLabel(state, "The registry was not read whole; nothing was changed"), shown(state))
  check("a normal save: the new pack is in the registry", string.find(files[REG] or "", "id=3;", 1, true) ~= nil,
    files[REG])
end

print(string.format("Flight Log page refusal messages: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
