-- The link detail view (init.lua registers it as `deck_link`, in full screen and in the widget
-- zone): the ELRS link in detail, both directions of it.
--
-- Opened in full screen by a tap on the header's link cluster, and -- in full screen and in the
-- zone alike -- by the switch the pilot names on the settings page (`link_switch`), held: it shows
-- while the switch is in that position. In the zone it is display only: the host builds it
-- without a `ctx`, and it then binds nothing, not even its close box.
--
-- What it reads:
--
--   the header       `ELRS`, the air rate (`link_packet_rate`) and its modulation, which
--                    lib/link_rates.lua knows per rate (LinkRates.modulationOf): "500Hz (LORA)".
--   RQ, TQ           the receiver's link quality (`state.lq`) and the transmitter's (`TQly`).
--   1RSS, 2RSS       the signal at each receiver antenna in dBm, the bar the headroom over the
--                    air rate's sensitivity floor (`link_floor`, layout.lua L.rssiPercent); the
--                    second antenna only once the host has seen one (`link_diversity`).
--   TRSS             the signal at the transmitter module, the downlink, against the same floor:
--                    both directions run at the one air rate.
--   SNR              the signal-to-noise ratio at the receiver and at the transmitter
--                    (`RSNR` / `TSNR`, "9 / 8dB"), the bar the receiver's figure as a position
--                    between the air rate's two dynamic-power thresholds (LinkRates.snrPercent):
--                    empty at the one where ExpressLRS asks for more power, full at the one where
--                    it asks for less. `-` on an FLRC or FSK rate, which reports no
--                    signal-to-noise ratio, so a 0 there is not drawn as a bad link; an empty bar
--                    on a rate whose thresholds are not known.
--   TPWR             the transmitter power in mW, the bar its share of the TX power maximum the
--                    announcements use (`state.alerts.tpwr.max`). High is the bad end here:
--                    dynamic power raises the power as the link weakens, so the bar warns as it
--                    grows.
--   the foot line    the least link quality of the flight record (`minLq`): the flight in
--                    progress where it has one, the last flight otherwise -- the rule the host's
--                    own boxes read the record by. `-` until the model has been armed once.
--
-- Every bar's warning and critical steps are the levels of the matching announcement
-- (`state.alerts`, layout.lua L.alertSteps): link quality's for RQ and TQ, the RSSI alert's for the
-- receiver antennas, the Downlink alert's for TRSS, the SNR alert's for SNR, the TX power alert's for
-- TPWR. A bar with no levels published draws without steps. `TRSS`, `RSNR`, `TSNR` and
-- the air rate are this view's own `sources`: a widget with view sources reads them while the view
-- is on top in full screen and at no other time, so the flight pays nothing for them. In the zone
-- and on a widget without view sources the host resolves none of them, and those figures read `-`.

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local K = requireModule("widgets/dashboard/themes/deck/viewkit.lua") or {}
local L = requireModule("widgets/dashboard/themes/deck/layout.lua") or {}
local Rates = requireModule("lib/link_rates.lua") or {}

local M = {}

-- What a memo holds before its first reading: no reading equals it.
local UNSET = {}

-- The readings only this view draws, handed to the host by M.sources.
local SOURCES = { "link_packet_rate", "TRSS", "RSNR", "TSNR" }

-- The widest figure a row can show, the SNR pair, which the figure column is sized against.
local VALUE_SAMPLE = "-10 / -10dB"

-- Readers of one number, nil for anything else, with the test written out: the sweep calls them
-- every frame.
local function stateField(state, name)
  return function()
    local v = state[name]
    if type(v) ~= "number" then return nil end
    return v
  end
end

local function derivedField(state, name)
  return function()
    local d = state.derived
    local v = d and d[name]
    if type(v) ~= "number" then return nil end
    return v
  end
end

-- One extreme of the flight record: the flight in progress where it has a value for the key, the
-- flight that ended otherwise.
local function recordField(state, key)
  return function()
    local flight = state.flight
    if type(flight) ~= "table" then return nil end
    local rec = flight.current
    local v = type(rec) == "table" and rec[key] or nil
    if v == nil then
      rec = flight.last
      v = type(rec) == "table" and rec[key] or nil
    end
    if type(v) ~= "number" then return nil end
    return v
  end
end

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" or type(L.setting) ~= "function" then return children end
  state = state or {}
  local g = K.begin(zone, state)
  if g == nil then return children end
  local UD, C, T = K.UD, K.C, K.T

  -- The air rate's modulation, looked up when the rate changes -- once per link at most. The
  -- header and the SNR row each keep the rate they last saw and ask only then.
  local function modulation(rate)
    if type(rate) ~= "string" or type(Rates.modulationOf) ~= "function" then return nil end
    return Rates.modulationOf(rate)
  end
  local function snrReported(rate)
    local mod = modulation(rate)
    return mod == nil or mod == "LoRa"
  end

  -- The close box only where there is a ctx, i.e. in full screen: the zone binds no press.
  local closePress = nil
  if type(ctx) == "table" and type(ctx.action) == "function" then
    closePress = function() ctx.action("closeView") end
  end
  local asideRate, aside = UNSET, "-"
  local top = K.header(children, g, T.view_link, closePress, function()
    local d = state.derived
    local rate = d and d.link_packet_rate
    if rate == asideRate then return aside end
    asideRate = rate
    local mod = modulation(rate)
    if type(rate) ~= "string" or rate == "" then
      aside = "-"
    elseif mod ~= nil then
      aside = rate .. " (" .. string.upper(mod) .. ")"
    else
      aside = rate
    end
    return aside
  end)

  local steps = L.alertSteps
  local lqWarn, lqCrit = steps(state, "lq")
  local rsWarn, rsCrit = steps(state, "rssi")
  local trWarn, trCrit = steps(state, "trss")
  local snWarn, snCrit = steps(state, "rsnr")
  local pwWarn, pwCrit = steps(state, "tpwr")
  -- Kept per pair of raw readings: the bar's colour and its length both ask every frame.
  -- rssiPercent tests both for a number itself.
  local function rss(read)
    local lastDbm, lastFloor, lastP = UNSET, UNSET, nil
    return function()
      -- The host replaces the snapshot rather than filling it, so it is read per call.
      local snap = state.derived
      local dbm, floor = read(), snap and snap.link_floor
      if dbm == lastDbm and floor == lastFloor then return lastP end
      lastDbm, lastFloor = dbm, floor
      lastP = L.rssiPercent(dbm, floor)
      return lastP
    end
  end
  local function dbm(read)
    return UD.getter(read, function(v)
      if v == nil or v == 0 then return "-" end
      return string.format("%ddBm", math.floor(v))
    end)
  end
  local function percent(read)
    return UD.getter(read, function(v)
      if v == nil then return "-" end
      return string.format("%d%%", math.floor(v))
    end)
  end

  -- SNR: `-` and an empty bar on a rate that reports none, rather than a 0 dB link drawn in the
  -- warning colour. Each closure reads the snapshot once and keeps the rate beside the figures,
  -- so a standing link costs it two or three comparisons. The bar is the scale the SNR alert
  -- speaks on: the reading's position between the rate's two dynamic-power thresholds, out of the
  -- rate's row, looked up from the air-rate byte and the module generation the host resolved
  -- `link_packet_rate` from, which it keeps on the state. Keyed on the byte and the generation, not
  -- on the rate's name: several bytes share a name ("50Hz" on 2.4 GHz and on 900 MHz) with
  -- different thresholds.
  local lastS, lastSRate, lastSMode, lastSGen, lastSRow, lastSP = UNSET, UNSET, UNSET, UNSET, nil, nil
  local function snrPercent()
    local d = state.derived
    local s, rate = d and d.RSNR, d and d.link_packet_rate
    local mode, gen = state.linkRfMode, state.linkGeneration
    if s == lastS and rate == lastSRate and mode == lastSMode and gen == lastSGen then return lastSP end
    lastS = s
    if rate ~= lastSRate or mode ~= lastSMode or gen ~= lastSGen then
      lastSRate, lastSMode, lastSGen = rate, mode, gen
      lastSRow = nil
      if type(rate) == "string" and type(Rates.forMode) == "function" then
        lastSRow = Rates.forMode(mode, gen)
      end
    end
    if lastSRow == nil or type(Rates.snrPercent) ~= "function" then
      lastSP = nil
    else
      lastSP = Rates.snrPercent(s, lastSRow)
    end
    return lastSP
  end
  local lastR, lastT, lastTRate, lastTOk, snrText = UNSET, UNSET, UNSET, true, "-"
  local function snrValue()
    local d = state.derived
    local r, t, rate = d and d.RSNR, d and d.TSNR, d and d.link_packet_rate
    if r == lastR and t == lastT and rate == lastTRate then return snrText end
    lastR, lastT = r, t
    if rate ~= lastTRate then
      lastTRate = rate
      lastTOk = snrReported(rate)
    end
    if type(r) ~= "number" or not lastTOk then
      snrText = "-"
    elseif type(t) == "number" then
      snrText = string.format("%d / %ddB", math.floor(r), math.floor(t))
    else
      snrText = string.format("%ddB", math.floor(r))
    end
    return snrText
  end

  local readTpwr = derivedField(state, "TPWR")
  local tpwrLevels = type(state.alerts) == "table" and state.alerts.tpwr or nil
  local tpwrMax = type(tpwrLevels) == "table" and tonumber(tpwrLevels.max) or nil
  if tpwrMax ~= nil and tpwrMax <= 0 then tpwrMax = nil end
  local lastPw, lastPwP = UNSET, nil
  local function tpwrPercent()
    local v = readTpwr()
    if v == lastPw then return lastPwP end
    lastPw = v
    if v == nil or v <= 0 or tpwrMax == nil then lastPwP = nil else lastPwP = math.min(100, math.floor(100 * v / tpwrMax + 0.5)) end
    return lastPwP
  end

  local readTrss = derivedField(state, "TRSS")
  local rows = {
    { label = T.link_rq, value = percent(stateField(state, "lq")),
      bar = stateField(state, "lq"), warn = lqWarn, crit = lqCrit },
    { label = T.link_tq, value = percent(derivedField(state, "TQly")),
      bar = derivedField(state, "TQly"), warn = lqWarn, crit = lqCrit },
    { label = T.link_rss1, value = dbm(stateField(state, "rss1")), bar = rss(stateField(state, "rss1")),
      warn = rsWarn, crit = rsCrit },
  }
  if type(L.diversity) == "function" and L.diversity(state) then
    rows[#rows + 1] = { label = T.link_rss2, value = dbm(stateField(state, "rss2")),
      bar = rss(stateField(state, "rss2")), warn = rsWarn, crit = rsCrit }
  end
  rows[#rows + 1] = { label = T.link_trss, value = dbm(readTrss), bar = rss(readTrss), warn = trWarn, crit = trCrit }
  rows[#rows + 1] = { label = T.link_snr, value = snrValue, bar = snrPercent, warn = snWarn, crit = snCrit }
  rows[#rows + 1] = { label = T.tpwr, value = UD.getter(readTpwr, function(v)
    if v == nil or v <= 0 then return "-" end
    return string.format("%dmW", math.floor(v))
  end), bar = tpwrPercent, warn = pwWarn, crit = pwCrit, high = true }

  -- The foot line: the least link quality of the flight, in the row names' face.
  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local footY = g.y + g.h - g.pad - g.fontH
  UD.label(children, x, footY, w, g.fontH, UD.getter(recordField(state, "minLq"), function(v)
    if v == nil then return T.link_rq_min .. " -" end
    return string.format("%s %d%%", T.link_rq_min, math.floor(v))
  end), g.font, C.label, LEFT)
  UD.hline(children, x, footY - g.gap, w)

  -- The rows, each a name, a bar and the figure in one line: the name in the flight view's face
  -- and the label colour, the figure as large as the row takes, its face picked against the row
  -- height less 2 px. The name column
  -- is as wide as the widest name drawn, the figure column as wide as the widest figure.
  local rowsH = footY - g.gap - top - g.gap
  local rowH = math.floor(rowsH / #rows)
  local font = UD.selectFont(math.max(8, rowH - 2), math.floor(w / 2), VALUE_SAMPLE)
  local fontH = UD.measure(font, VALUE_SAMPLE)
  local labelW = 0
  for i = 1, #rows do labelW = math.max(labelW, UD.textWidth(g.font, rows[i].label)) end
  labelW = labelW + g.pad
  local valueW = UD.textWidth(font, VALUE_SAMPLE) + g.pad
  local barX = x + labelW
  local barW = math.max(20, w - labelW - valueW - g.pad)
  local barH = math.max(4, math.min(rowH - 6, fontH))
  for i = 1, #rows do
    local row = rows[i]
    local ry = top + (i - 1) * rowH
    local ty = ry + math.floor((rowH - fontH) / 2)
    UD.label(children, x, ry + math.floor((rowH - g.fontH) / 2), labelW, g.fontH, row.label, g.font, C.label, LEFT)
    -- `high` turns the steps round: the bar warns as it grows (TPWR) rather than as it shrinks.
    local read, warn, crit, high = row.bar, row.warn, row.crit, row.high
    local by = ry + math.floor((rowH - barH) / 2)
    local lastSV, lastW = UNSET, 0
    local lastV, lastColor = UNSET, nil
    UD.rect(children, barX, by, barW, barH, C.track, true, 2)
    children[#children + 1] = {
      type = "rectangle", x = barX, y = by, w = 1, h = barH, filled = true, rounded = 2,
      color = function()
        local v = read()
        if v == lastV then return lastColor end
        lastV = v
        if v == nil then lastColor = C.track
        elseif crit == nil then lastColor = C.ok
        elseif high then
          if v >= crit then lastColor = C.crit
          elseif v >= warn then lastColor = C.warn
          else lastColor = C.ok end
        elseif v <= crit then lastColor = C.crit
        elseif v <= warn then lastColor = C.warn
        else lastColor = C.ok end
        return lastColor
      end,
      size = function()
        local v = read()
        if v ~= lastSV then
          lastSV = v
          local p = v or 0
          if p < 0 then p = 0 elseif p > 100 then p = 100 end
          lastW = math.floor(barW * p / 100)
        end
        return lastW, barH
      end
    }
    if crit ~= nil then
      UD.rect(children, barX + math.floor(barW * crit / 100), by, 2, barH, C.tick, true, 0)
      UD.rect(children, barX + math.floor(barW * warn / 100), by, 2, barH, C.tick, true, 0)
    end
    UD.rect(children, barX, by, barW, barH, C.frame, false, 2, 1)
    UD.label(children, x + w - valueW, ty, valueW, fontH, row.value, font, C.text, RIGHT)
  end
  return children
end

-- The readings only this view draws. A host with view sources resolves them while the view is on
-- top in full screen and at no other time.
function M.sources()
  return SOURCES
end

-- The second antenna adds a row, once the host has seen it.
function M.renderKey(_, state)
  if type(L.diversity) == "function" and L.diversity(state) then return "div" end
  return ""
end

return M
