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

local Controls = nil
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local BoardAlignmentApi = nil
local SensorAlignmentApi = nil
local BoardAutoAlignApi = nil
local ApiVersion = nil
local Armed = nil
local AutoAlignLifecycle = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local sin = math.sin
local cos = math.cos
local rad = math.rad
local floor = math.floor
local sqrt = math.sqrt
local max = math.max
local min = math.min
local abs = math.abs
local t_sort = table.sort

local MSP_ATTITUDE = 108
local BASE_VIEW_PITCH_R = rad(-90)
local BASE_VIEW_YAW_R = rad(90)
local CAMERA_DIST = 7.0

-- Each entry is a key and fallback pair in the form the packager translates in place, so an
-- installed suite shows the choices in the pilot's language. The fallback is the English text
-- rather than the key, because it is what is shown wherever the lookup finds nothing.
local magAlignChoices = {
  { labelKey = "mag_default", labelFallback = "Default", value = 1 },
  { labelKey = "mag_cw_0", labelFallback = "CW 0 deg", value = 2 },
  { labelKey = "mag_cw_90", labelFallback = "CW 90 deg", value = 3 },
  { labelKey = "mag_cw_180", labelFallback = "CW 180 deg", value = 4 },
  { labelKey = "mag_cw_270", labelFallback = "CW 270 deg", value = 5 },
  { labelKey = "mag_cw_0_flip", labelFallback = "CW 0 deg flip", value = 6 },
  { labelKey = "mag_cw_90_flip", labelFallback = "CW 90 deg flip", value = 7 },
  { labelKey = "mag_cw_180_flip", labelFallback = "CW 180 deg flip", value = 8 },
  { labelKey = "mag_cw_270_flip", labelFallback = "CW 270 deg flip", value = 9 },
  { labelKey = "mag_custom", labelFallback = "Custom", value = 10 }
}

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    generation = 0,
    autoAlignSupported = nil,
    autoAlignPending = false,
    autoAlignAction = nil,
    autoAlignActive = false,
    autoAlignState = nil,
    autoAlignNeedsProbe = false,
    autoAlignNeedsReload = false,
    autoAlignPollAt = 0,
    autoAlignStartedAt = 0,
    autoAlignArmedChanges = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil,
  liveViewEnabled = false,
  liveViewStartedAt = 0,
  pollingEnabled = false,
  lastAttitudeAt = 0,
  attitudeSamplePeriod = 0.25, -- ~4Hz refresh to prevent link overload
  pendingAttitude = false,
  pendingAt = 0,
  pendingTimeout = 1.0,
  autoRecenterPending = false,
  simStartAt = 0,
  viewYawOffset = 0,
  display = {
    roll_degrees = 0,
    pitch_degrees = 0,
    yaw_degrees = 0,
    gyro_1_alignment = 0,
    gyro_2_alignment = 0,
    mag_alignment = 0
  },
  live = {
    roll = 0,
    pitch = 0,
    yaw = 0
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not BoardAlignmentApi then BoardAlignmentApi = loadModule("tasks/msp/api/board_alignment_config.lua") end
  if not SensorAlignmentApi then SensorAlignmentApi = loadModule("tasks/msp/api/sensor_alignment.lua") end
  if not BoardAutoAlignApi then BoardAutoAlignApi = loadModule("tasks/msp/api/board_auto_align.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  -- The shared copy: lib/armed.lua counts arm/disarm changes per Lua state, and only the copy
  -- the tool asks on every pass sees them.
  if not Armed then
    Armed = (_G.rfsuite and _G.rfsuite.require and _G.rfsuite.require("lib/armed.lua")) or loadModule("lib/armed.lua")
  end
  if not AutoAlignLifecycle then AutoAlignLifecycle = loadModule("app/pages/setup/alignment/auto_align_lifecycle.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_alignment") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
  end
end

local function currentSessionSignature()
  local session = getSession()
  return session and session.signature or nil
end

local function autoAlignCallbackIsCurrent(token)
  local session = getSession()
  if Armed and type(Armed.isArmed) == "function" then Armed.isArmed() end
  local armedChanges = Armed and type(Armed.changeCount) == "function" and Armed.changeCount() or nil
  return AutoAlignLifecycle and AutoAlignLifecycle.isCurrent(ui.runtime, ui.loaded,
    session, currentSessionSignature(), session and session.fblConnected == true, armedChanges, token)
end

local function resetAutoAlign(invalidate)
  if not ui.runtime then return end
  if invalidate and AutoAlignLifecycle then AutoAlignLifecycle.invalidate(ui.runtime) end
  ui.runtime.autoAlignPending = false
  ui.runtime.autoAlignAction = nil
  ui.runtime.autoAlignActive = false
  ui.runtime.autoAlignState = nil
  ui.runtime.autoAlignNeedsProbe = false
  ui.runtime.autoAlignPollAt = 0
  ui.runtime.autoAlignStartedAt = 0
  ui.runtime.autoAlignArmedChanges = nil
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function toSigned16(v)
  v = tonumber(v) or 0
  if v > 32767 then return v - 65536 end
  return v
end

local function toU16(v)
  v = floor(tonumber(v) or 0)
  if v < -32768 then v = -32768 end
  if v > 32767 then v = 32767 end
  if v < 0 then return v + 65536 end
  return v
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_alignment) ~= "table" then return end
  local saved = session.setup_alignment
  ui.display.roll_degrees = saved.roll_degrees or 0
  ui.display.pitch_degrees = saved.pitch_degrees or 0
  ui.display.yaw_degrees = saved.yaw_degrees or 0
  ui.loaded_roll_degrees = saved.loaded_roll_degrees or saved.roll_degrees or 0
  ui.loaded_pitch_degrees = saved.loaded_pitch_degrees or saved.pitch_degrees or 0
  ui.loaded_yaw_degrees = saved.loaded_yaw_degrees or saved.yaw_degrees or 0
  ui.display.gyro_1_alignment = saved.gyro_1_alignment or 0
  ui.display.gyro_2_alignment = saved.gyro_2_alignment or 0
  ui.display.mag_alignment = saved.mag_alignment or 0
end

local function saveToSession()
  local session = getSession()
  if not session then return end
  session.setup_alignment = {
    roll_degrees = ui.display.roll_degrees,
    pitch_degrees = ui.display.pitch_degrees,
    yaw_degrees = ui.display.yaw_degrees,
    loaded_roll_degrees = ui.loaded_roll_degrees,
    loaded_pitch_degrees = ui.loaded_pitch_degrees,
    loaded_yaw_degrees = ui.loaded_yaw_degrees,
    gyro_1_alignment = ui.display.gyro_1_alignment,
    gyro_2_alignment = ui.display.gyro_2_alignment,
    mag_alignment = ui.display.mag_alignment
  }
end

local function recenterYawView()
  local loadedYaw = ui.loaded_yaw_degrees or 0
  ui.viewYawOffset = (tonumber(ui.live.yaw) or 0) - loadedYaw + (tonumber(ui.display.yaw_degrees) or 0)
end

local function rotatePoint(x, y, z, cx, sx, cy, sy, cz, sz)
  local bx = -y
  local by = z
  local bz = -x

  local x1 = bx * cz - by * sz
  local y1 = bx * sz + by * cz
  local z1 = bz

  local x2 = x1
  local y2 = y1 * cx - z1 * sx
  local z2 = y1 * sx + z1 * cx

  local x3 = x2 * cy + z2 * sy
  local y3 = y2
  local z3 = -x2 * sy + z2 * cy

  return x3, y3, z3
end

-- The helicopter model, in model coordinates: x forward, y right, z up, the main shaft at the
-- origin. It never changes, so it is built once with the module rather than on every page build.
local nose = {2.25, 0.0, 0.03}
local lf = {1.05, -0.42, 0.08}
local rf = {1.05, 0.42, 0.08}
local lb = {-0.45, -0.36, 0.06}
local rb = {-0.45, 0.36, 0.06}
local top = {0.15, 0.0, 0.80}
local podAftTop = {-0.70, 0.0, 0.50}
local podAftBot = {-0.70, 0.0, -0.06}
local podAftL = {-0.70, -0.24, 0.17}
local podAftR = {-0.70, 0.24, 0.17}
local mastBase = {0.05, 0.0, 0.70}
local hub = {0.05, 0.0, 1.00}
-- The boom tapers from the pod to the tail.
local boomSL = {-0.85, -0.09, 0.19}
local boomSR = {-0.85, 0.09, 0.19}
local boomSU = {-0.85, 0.0, 0.28}
local boomSD = {-0.85, 0.0, 0.10}
local boomEL = {-2.40, -0.035, 0.17}
local boomER = {-2.40, 0.035, 0.17}
local boomEU = {-2.40, 0.0, 0.205}
local boomED = {-2.40, 0.0, 0.135}

-- A closed circle of n segments around the z axis (main rotor) or the y axis (tail rotor).
local function ring(cx, cy, cz, r, n, axis)
  local pts = {}
  for i = 0, n - 1 do
    local a = (2 * math.pi * i) / n
    local u, v = r * cos(a), r * sin(a)
    if axis == "z" then
      pts[#pts + 1] = {cx + u, cy + v, cz}
    else
      pts[#pts + 1] = {cx + u, cy, cz + v}
    end
  end
  pts[#pts + 1] = pts[1]
  return pts
end

-- Both tips of a two-bladed rotor through (cx, cy, cz).
local function blade(cx, cy, cz, r, angle, axis)
  local u, v = r * cos(angle), r * sin(angle)
  if axis == "z" then
    return {cx + u, cy + v, cz}, {cx - u, cy - v, cz}
  end
  return {cx + u, cy, cz + v}, {cx - u, cy, cz - v}
end

-- A polyline: the points in order, with a colour index `c` and a thickness `w`.
local function polyline(c, w, pts)
  pts.c = c
  pts.w = w
  return pts
end

local mainTipA, mainTipB = blade(hub[1], hub[2], hub[3], 1.9, rad(30), "z")
local tailHub = {-2.48, 0.13, 0.40}
local tailTipA, tailTipB = blade(tailHub[1], tailHub[2], tailHub[3], 0.30, rad(60), "y")

-- Shades and line colours are indexes into scene.colors, resolved from the theme at build.
local LIGHT, MID, DARK, MAIN, ACCENT, DISC = 1, 2, 3, 4, 5, 6

-- Fuselage and boom faces, drawn far to near.
local FUSELAGE = {
  {nose, lf, top, LIGHT},
  {nose, top, rf, LIGHT},
  {lf, lb, top, MID},
  {rf, top, rb, MID},
  {lb, podAftTop, top, DARK},
  {rb, top, podAftTop, DARK},
  {lf, lb, rb, DARK},
  {lf, rb, rf, DARK},
  {lb, podAftL, podAftTop, DARK},
  {rb, podAftTop, podAftR, DARK},
  {lb, podAftBot, podAftL, DARK},
  {rb, podAftR, podAftBot, DARK},
  {boomSU, boomSL, boomEU, MID},
  {boomSL, boomEL, boomEU, MID},
  {boomSU, boomEU, boomSR, MID},
  {boomSR, boomEU, boomER, MID},
  {boomSL, boomSD, boomEL, DARK},
  {boomSD, boomED, boomEL, DARK},
  {boomSD, boomSR, boomED, DARK},
  {boomSR, boomER, boomED, DARK}
}

-- Main rotor (disc rim, blades, shaft): above the fuselage, below the nose plate.
local DISC_LINES = {
  polyline(DISC, 1, ring(hub[1], hub[2], hub[3], 1.9, 24, "z")),
  polyline(MAIN, 2, {mainTipA, hub, mainTipB}),
  polyline(DISC, 2, {mastBase, hub})
}

local NOSE_PLATE = {nose, lf, rf}

-- Outline, boom, fins, tail rotor and landing gear: above everything else.
local OUTLINE_LINES = {
  polyline(MAIN, 1, {lb, lf, nose, rf, rb}),
  polyline(MAIN, 1, {nose, top, podAftTop}),
  polyline(MAIN, 1, {boomSU, boomEU}),
  polyline(MAIN, 1, {boomSL, boomEL}),
  polyline(MAIN, 1, {boomSR, boomER}),
  polyline(MAIN, 1, {boomSD, boomED}),
  polyline(ACCENT, 1, {boomSU, boomSL, boomSD, boomSR, boomSU}),
  -- Vertical fin above and below the boom end, horizontal stabiliser ahead of it.
  polyline(MID, 2, {{-2.18, 0.0, 0.20}, {-2.50, 0.0, 0.66}, {-2.62, 0.0, 0.62}, {-2.46, 0.0, 0.20}}),
  polyline(MID, 2, {{-2.26, 0.0, 0.14}, {-2.48, 0.0, -0.14}, {-2.58, 0.0, -0.10}, {-2.44, 0.0, 0.14}}),
  polyline(MAIN, 1, {{-1.70, -0.40, 0.18}, {-1.86, -0.40, 0.18}, {-1.86, 0.40, 0.18}, {-1.70, 0.40, 0.18},
    {-1.70, -0.40, 0.18}}),
  -- Tail rotor beside the fin.
  polyline(DISC, 1, ring(tailHub[1], tailHub[2], tailHub[3], 0.30, 12, "y")),
  polyline(MAIN, 2, {tailTipA, tailHub, tailTipB}),
  -- Skids with upturned front ends, and the two bent cross tubes.
  polyline(MAIN, 2, {{1.30, -0.48, -0.40}, {1.12, -0.48, -0.60}, {0.92, -0.48, -0.66}, {-1.15, -0.48, -0.66},
    {-1.30, -0.48, -0.62}}),
  polyline(MAIN, 2, {{1.30, 0.48, -0.40}, {1.12, 0.48, -0.60}, {0.92, 0.48, -0.66}, {-1.15, 0.48, -0.66},
    {-1.30, 0.48, -0.62}}),
  polyline(MAIN, 1, {{0.55, -0.48, -0.66}, {0.50, -0.40, -0.30}, {0.48, -0.24, -0.04}, {0.48, 0.24, -0.04},
    {0.50, 0.40, -0.30}, {0.55, 0.48, -0.66}}),
  polyline(MAIN, 1, {{-0.55, -0.48, -0.66}, {-0.50, -0.40, -0.30}, {-0.48, -0.24, 0.02}, {-0.48, 0.24, 0.02},
    {-0.50, 0.40, -0.30}, {-0.55, 0.48, -0.66}})
}

-- Every point the model uses, once.
local MODEL_POINTS = {}
do
  local seen = {}
  local function add(p)
    if not seen[p] then
      seen[p] = true
      MODEL_POINTS[#MODEL_POINTS + 1] = p
    end
  end
  for _, tri in ipairs(FUSELAGE) do add(tri[1]); add(tri[2]); add(tri[3]) end
  for _, line in ipairs(DISC_LINES) do for _, p in ipairs(line) do add(p) end end
  for _, line in ipairs(OUTLINE_LINES) do for _, p in ipairs(line) do add(p) end end
  add(NOSE_PLATE[1]); add(NOSE_PLATE[2]); add(NOSE_PLATE[3])
end

-- Live View moves the model in place. Each attitude sample is projected once, into the tables
-- below; the model's objects read them through function-valued `pts` and `color` properties,
-- which EdgeTX re-reads on every refresh and redraws only when the points change. Rebuilding the
-- whole page for every sample cleared and recreated every object on it four times a second.
local scene = {
  ready = false,
  originX = 0, originY = 0,
  mx = 0, my = 0, scale = 1,
  colors = {},
  alternate = false,
  liveText = "",
  viewYawText = "",
  nosePrimary = "",
  noseSecondary = "",
  noseCombined = "",
  noseTwoLine = false,
  liveButtonText = "",
  liveRemaining = -1
}

local projX, projY, projZ = {}, {}, {}
local triOrder, triDepth = {}, {}
local function nearerLater(a, b) return triDepth[a] < triDepth[b] end

local triSlotPts, triSlotModel, triSlotColor = {}, {}, {}
local triSlotPtsFn, triSlotColorFn = {}, {}
for k = 1, #FUSELAGE do
  triSlotPts[k] = {{0, 0}, {0, 0}, {0, 0}}
  triSlotModel[k] = {0, 0, 0, 0, 0, 0, 0}
  triSlotColor[k] = 0
  triSlotPtsFn[k] = function() return triSlotPts[k] end
  triSlotColorFn[k] = function() return triSlotColor[k] end
end

local nosePlatePts = {{0, 0}, {0, 0}, {0, 0}}
local function nosePlatePtsFn() return nosePlatePts end

local function newLineSlots(lines)
  local pts, fns = {}, {}
  for j = 1, #lines do
    local slot = {}
    for i = 1, #lines[j] do slot[i] = {0, 0} end
    pts[j] = slot
    fns[j] = function() return slot end
  end
  return pts, fns
end
local discPts, discPtsFn = newLineSlots(DISC_LINES)
local outlinePts, outlinePtsFn = newLineSlots(OUTLINE_LINES)

local function liveTextFn() return scene.liveText end
local function viewYawTextFn() return scene.viewYawText end
local function nosePrimaryFn() return scene.nosePrimary end
local function noseSecondaryFn() return scene.noseSecondary end
local function noseCombinedFn() return scene.noseCombined end
local function noseTwoLineFn() return scene.noseTwoLine end
local function noseOneLineFn() return not scene.noseTwoLine end
local function liveButtonTextFn() return scene.liveButtonText end

-- EdgeTX deletes and recreates a triangle's canvas whenever its points change, and the new canvas
-- goes on top of its siblings. Far-to-near order therefore survives only if every face is
-- recreated in the same refresh, in slot order. So whenever any face moves, every face is handed
-- its points in the other of two vertex orders that EdgeTX's rasteriser fills identically: its
-- fillTriangle sorts the vertices by y with three strict compare-and-swaps, so an order that
-- sorts to the same sequence draws the same pixels while still changing every point table.
local function writeTriangle(dst, x1, y1, x2, y2, x3, y3, alternate)
  local ax, ay, bx, by, cx, cy = x1, y1, x2, y2, x3, y3
  if alternate then
    local s1x, s1y, s2x, s2y, s3x, s3y = x1, y1, x2, y2, x3, y3
    if s1y > s2y then s1x, s1y, s2x, s2y = s2x, s2y, s1x, s1y end
    if s1y > s3y then s1x, s1y, s3x, s3y = s3x, s3y, s1x, s1y end
    if s2y > s3y then s2x, s2y, s3x, s3y = s3x, s3y, s2x, s2y end
    if s1x ~= x1 or s1y ~= y1 or s2x ~= x2 or s2y ~= y2 then
      ax, ay, bx, by, cx, cy = s1x, s1y, s2x, s2y, s3x, s3y
    elseif y1 < y2 and y2 < y3 then
      ax, ay, bx, by, cx, cy = x3, y3, x2, y2, x1, y1
    elseif y1 == y2 and y2 < y3 then
      ax, ay, bx, by, cx, cy = x3, y3, x1, y1, x2, y2
    elseif y1 < y2 and y2 == y3 then
      ax, ay, bx, by, cx, cy = x2, y2, x1, y1, x3, y3
    end
    -- All three on one row has no second order; that face keeps its place for this sample.
  end
  local p = dst[1]; p[1] = ax; p[2] = ay
  p = dst[2]; p[1] = bx; p[2] = by
  p = dst[3]; p[1] = cx; p[2] = cy
end

local function writeLine(dst, line)
  for i = 1, #line do
    local p, q = dst[i], line[i]
    p[1] = projX[q]; p[2] = projY[q]
  end
end

local function updateTexts()
  if ui.liveViewEnabled then
    scene.liveText = string.format(scene.liveFmt, ui.live.roll, ui.live.pitch, ui.live.yaw)
  else
    scene.liveText = "Live: --"
  end
  scene.viewYawText = string.format(scene.viewYawFmt, ui.viewYawOffset)

  local pitchVal = ui.live.pitch - (ui.loaded_pitch_degrees or 0) + ui.display.pitch_degrees
  local rollVal = ui.live.roll - (ui.loaded_roll_degrees or 0) + ui.display.roll_degrees

  local primary = scene.noseLevel
  if pitchVal > 3.5 then
    primary = scene.noseDown
  elseif pitchVal < -3.5 then
    primary = scene.noseUp
  end

  local secondary = ""
  if rollVal > 3.5 then
    secondary = scene.leaningRight
  elseif rollVal < -3.5 then
    secondary = scene.leaningLeft
  end

  scene.nosePrimary = primary
  scene.noseSecondary = secondary
  scene.noseTwoLine = secondary ~= ""
  if secondary ~= "" then
    scene.noseCombined = primary .. ", " .. secondary
  else
    scene.noseCombined = primary
  end
end

-- Projects the model for the current attitude into the slot tables. Called by the build and once
-- per attitude sample; allocates nothing.
local function updateScene()
  if not scene.ready then return end
  scene.drawnRoll, scene.drawnPitch, scene.drawnYaw = ui.live.roll, ui.live.pitch, ui.live.yaw
  scene.drawnViewYaw = ui.viewYawOffset

  local pitchVal = ui.live.pitch - (ui.loaded_pitch_degrees or 0) + ui.display.pitch_degrees
  local rollVal = ui.live.roll - (ui.loaded_roll_degrees or 0) + ui.display.roll_degrees
  local yawVal = ui.live.yaw - (ui.loaded_yaw_degrees or 0) + ui.display.yaw_degrees

  local pitchR = rad(-pitchVal)
  local yawR = rad(-(yawVal - ui.viewYawOffset))
  local rollR = rad(-rollVal)

  local cx = cos(pitchR)
  local sx = sin(pitchR)
  local cy = cos(yawR)
  local sy = sin(yawR)
  local cz = cos(rollR)
  local sz = sin(rollR)

  local mx, my, scale = scene.mx, scene.my, scene.scale
  local ox, oy = scene.originX, scene.originY
  -- rotatePoint is linear, so it is applied to the three unit vectors once and every point is then
  -- a weighted sum of them: nine multiplications a point instead of a call and twelve.
  local axx, axy, axz = rotatePoint(1, 0, 0, cx, sx, cy, sy, cz, sz)
  local ayx, ayy, ayz = rotatePoint(0, 1, 0, cx, sx, cy, sy, cz, sz)
  local azx, azy, azz = rotatePoint(0, 0, 1, cx, sx, cy, sy, cz, sz)
  for i = 1, #MODEL_POINTS do
    local p = MODEL_POINTS[i]
    local x, y, z = p[1], p[2], p[3]
    local rx = x * axx + y * ayx + z * azx
    local ry = x * axy + y * ayy + z * azy
    local rz = x * axz + y * ayz + z * azz
    -- Rotation keeps a point's distance from the origin, and no model point is farther than 2.7
    -- from it, so the divisor never comes near zero and no point needs culling.
    local f = CAMERA_DIST / (CAMERA_DIST - rz) * scale
    projX[p] = floor(mx + rx * f) - ox
    projY[p] = floor(my - ry * f) - oy
    projZ[p] = rz
  end

  local count = #FUSELAGE
  for i = 1, count do
    local tri = FUSELAGE[i]
    triOrder[i] = i
    triDepth[i] = (projZ[tri[1]] + projZ[tri[2]] + projZ[tri[3]]) / 3
  end
  t_sort(triOrder, nearerLater)

  local changed = false
  for k = 1, count do
    local i = triOrder[k]
    local tri = FUSELAGE[i]
    local a, b, c = tri[1], tri[2], tri[3]
    local m = triSlotModel[k]
    local x1, y1, x2, y2, x3, y3 = projX[a], projY[a], projX[b], projY[b], projX[c], projY[c]
    if m[7] ~= i or m[1] ~= x1 or m[2] ~= y1 or m[3] ~= x2 or m[4] ~= y2 or m[5] ~= x3 or m[6] ~= y3 then
      changed = true
      m[1], m[2], m[3], m[4], m[5], m[6], m[7] = x1, y1, x2, y2, x3, y3, i
    end
  end
  if changed then
    local alternate = not scene.alternate
    scene.alternate = alternate
    local colors = scene.colors
    for k = 1, count do
      local m = triSlotModel[k]
      writeTriangle(triSlotPts[k], m[1], m[2], m[3], m[4], m[5], m[6], alternate)
      triSlotColor[k] = colors[FUSELAGE[m[7]][4]]
    end
  end

  for j = 1, #DISC_LINES do
    writeLine(discPts[j], DISC_LINES[j])
  end
  writeTriangle(nosePlatePts, projX[nose], projY[nose], projX[lf], projY[lf], projX[rf], projY[rf], false)
  for j = 1, #OUTLINE_LINES do
    writeLine(outlinePts[j], OUTLINE_LINES[j])
  end

  updateTexts()
end

-- A board at rest still reports attitude noise of a few tenths of a degree. The model is moved only
-- when roll or pitch has changed by more than this since it was last drawn, or yaw (whole degrees
-- in MSP_ATTITUDE) has changed at all; the readouts follow every reply.
local ATTITUDE_DEADBAND = 0.3

local function onAttitudeSample()
  if not scene.ready then return end
  local live = ui.live
  if abs(live.roll - scene.drawnRoll) > ATTITUDE_DEADBAND or abs(live.pitch - scene.drawnPitch) > ATTITUDE_DEADBAND
      or live.yaw ~= scene.drawnYaw or ui.viewYawOffset ~= scene.drawnViewYaw then
    updateScene()
  else
    updateTexts()
  end
end

local function updateLiveButtonText()
  if not ui.liveViewEnabled or not scene.liveRemainingFmt then return end
  local remaining = math.ceil(60.0 - (nowSeconds() - ui.liveViewStartedAt))
  if remaining < 0 then remaining = 0 end
  if remaining ~= scene.liveRemaining then
    scene.liveRemaining = remaining
    scene.liveButtonText = string.format(scene.liveRemainingFmt, remaining)
  end
end

local function parseAttitude(buf)
  if type(buf) ~= "table" or #buf < 6 then return false end
  local function readS16(lo, hi)
    local v = (tonumber(hi) or 0) << 8 | (tonumber(lo) or 0)
    if v > 32767 then return v - 65536 end
    return v
  end

  local rollRaw = readS16(buf[1], buf[2])
  local pitchRaw = readS16(buf[3], buf[4])
  local yawRaw = readS16(buf[5], buf[6])

  ui.live.roll = rollRaw / 10.0
  ui.live.pitch = pitchRaw / 10.0
  ui.live.yaw = yawRaw
  if ui.autoRecenterPending then
    recenterYawView()
    ui.autoRecenterPending = false
  end
  return true
end

local function buildSimulatedAttitudeResponse(now)
  local t0 = ui.simStartAt or 0
  local clockT = max(0, now - t0)

  local rollDeg = 25.0 * sin(clockT * 1.25)
  local pitchDeg = 18.0 * sin((clockT * 0.90) + 0.9)
  local yawDeg = 90.0 * sin((clockT * 0.42) + 0.2)

  local rollRaw = floor((rollDeg * 10.0) + 0.5)
  local pitchRaw = floor((pitchDeg * 10.0) + 0.5)
  local yawRaw = floor(yawDeg + 0.5)

  local function packS16(v)
    if v < 0 then v = v + 65536 end
    return v & 0xFF, (v >> 8) & 0xFF
  end

  local rLo, rHi = packS16(rollRaw)
  local pLo, pHi = packS16(pitchRaw)
  local yLo, yHi = packS16(yawRaw)

  return { rLo, rHi, pLo, pHi, yLo, yHi }
end

local function requestAttitude(queue, now)
  if ui.pendingAttitude then return false end
  ui.pendingAttitude = true
  ui.pendingAt = now

  local sim = false
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, ver = pcall(system.getVersion)
    if ok and ver and ver.simulation then
      sim = true
    end
  end
  local simResponse = sim and buildSimulatedAttitudeResponse(now) or {}

  return queue:add({
    command = MSP_ATTITUDE,
    uuid = "alignment.attitude",
    processReply = function(self, buf)
      parseAttitude(buf)
      ui.pendingAttitude = false
      -- The sample is drawn in place (onAttitudeSample); the page is not rebuilt for it.
      onAttitudeSample()
    end,
    errorHandler = function()
      ui.pendingAttitude = false
    end,
    simulatorResponse = simResponse
  })
end

local queueAutoAlignProbe

local function queueAlignmentRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BoardAlignmentApi or not SensorAlignmentApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: Read BOARD_ALIGNMENT_CONFIG
  queue:add({
    command = BoardAlignmentApi.command,
    simulatorResponse = BoardAlignmentApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = BoardAlignmentApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        local roll = toSigned16(parsed.roll_degrees)
        local pitch = toSigned16(parsed.pitch_degrees)
        local yaw = toSigned16(parsed.yaw_degrees)
        ui.display.roll_degrees = roll
        ui.display.pitch_degrees = pitch
        ui.display.yaw_degrees = yaw
        ui.loaded_roll_degrees = roll
        ui.loaded_pitch_degrees = pitch
        ui.loaded_yaw_degrees = yaw
        saveToSession()
      end

      -- Step 2: Read SENSOR_ALIGNMENT
      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      queue:add({
        command = SensorAlignmentApi.command,
        simulatorResponse = SensorAlignmentApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed2 = SensorAlignmentApi.parse(buf2)
          if type(parsed2) ~= "table" then return Common.failPageRead(ui) end
          if parsed2 then
            ui.display.gyro_1_alignment = math.max(0, math.min(255, tonumber(parsed2.gyro_1_alignment) or 0))
            ui.display.gyro_2_alignment = math.max(0, math.min(255, tonumber(parsed2.gyro_2_alignment) or 0))
            ui.display.mag_alignment = math.max(0, math.min(9, tonumber(parsed2.mag_alignment) or 0))
            saveToSession()
          end

          if ui.runtime then ui.runtime.readPending = false end
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if readValid then
            ui.runtime.autoAlignNeedsReload = false
            ui.runtime.autoAlignNeedsProbe = true
          end
          if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          readValid = false
          if ui.runtime then ui.runtime.readPending = false end
          ui.loading = false
          if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      readValid = false
      if ui.runtime then ui.runtime.readPending = false end
      ui.loading = false
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function sessionSupportsAutoAlignApi()
  local session = getSession()
  return ApiVersion and type(ApiVersion.isAtLeast) == "function" and session
    and ApiVersion.isAtLeast(session.apiVersion, { 12, 0, 10 }) == true
end

local function showAutoAlignResult(result)
  if not ConfirmDialog or not result then return end
  local state = result.state
  local message
  if state == BoardAutoAlignApi.states.success then
    message = pageText(nil, "auto_align_success",
      "Alignment applied and loaded into the fields. Save stores it now; otherwise the flight controller stores it at the next disarm.")
  elseif state == BoardAutoAlignApi.states.rejectedArmed then
    message = pageText(nil, "auto_align_armed", "Disarm the model before starting auto-align.")
  elseif state == BoardAutoAlignApi.states.rejectedUncalibrated then
    message = pageText(nil, "auto_align_uncalibrated", "Calibrate the accelerometer before starting auto-align.")
  elseif state == BoardAutoAlignApi.states.timeout then
    message = pageText(nil, "auto_align_timeout", "No tail lift was detected in time. Hold the model level and try again.")
  elseif state == BoardAutoAlignApi.states.noMatch then
    message = pageText(nil, "auto_align_no_match", "The movement did not match a supported board orientation. Hold level and try again.")
  else
    return
  end
  ConfirmDialog.show({ title = pageText(nil, "auto_align", "Auto-align"), message = message })
end

local function queueAutoAlignRequest(action)
  if not ui.runtime or ui.runtime.autoAlignPending or not BoardAutoAlignApi then return false end
  local session = getSession()
  if not session or session.fblConnected ~= true then return false end
  if Armed and type(Armed.isArmed) == "function" and Armed.isArmed() == true then
    ui.runtime.autoAlignState = BoardAutoAlignApi.states.rejectedArmed
    return false
  end
  local mspState = MspRuntime and MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return false end
  -- Polls wait for an idle queue; the START the pilot confirmed is queued behind whatever is there.
  if action ~= BoardAutoAlignApi.actions.start and not queue:isProcessed() then return false end
  local signature = currentSessionSignature()
  local armedChanges = Armed and type(Armed.changeCount) == "function" and Armed.changeCount() or nil
  local token = AutoAlignLifecycle.capture(ui.runtime, session, signature, armedChanges)
  local isProbe = action == BoardAutoAlignApi.actions.poll and ui.runtime.autoAlignSupported == nil
  ui.runtime.autoAlignPending = true
  ui.runtime.autoAlignAction = action
  return queue:add({
    command = BoardAutoAlignApi.command,
    payload = BoardAutoAlignApi.buildPayload(action),
    isWrite = action == BoardAutoAlignApi.actions.start,
    maxRetries = action == BoardAutoAlignApi.actions.start and 0 or nil,
    completeOnErrorReplyAttempt = 1,
    processReply = function(_, buf)
      if not autoAlignCallbackIsCurrent(token) then return end
      ui.runtime.autoAlignPending = false
      ui.runtime.autoAlignAction = nil
      local result = BoardAutoAlignApi.parse(buf)
      if not result then
        local wasProbe = ui.runtime.autoAlignSupported == nil
        if wasProbe then ui.runtime.autoAlignSupported = false end
        ui.runtime.autoAlignActive = false
        if not wasProbe then
          ui.runtime.autoAlignNeedsReload = true
          ui.runtime.readComplete = false
        end
      elseif isProbe and result.state ~= BoardAutoAlignApi.states.waitingForTailLift then
        -- The capability poll only learns that the command is supported. A finished state is
        -- kept by the flight controller until the next START, so it belongs to an earlier run
        -- (another visit, another tool) and is not this page's result.
        ui.runtime.autoAlignSupported = true
      else
        ui.runtime.autoAlignSupported = true
        ui.runtime.autoAlignState = result.state
        local outcome, active = BoardAutoAlignApi.classify(result.state)
        ui.runtime.autoAlignActive = active
        if active then
          if ui.runtime.autoAlignStartedAt <= 0 then ui.runtime.autoAlignStartedAt = nowSeconds() end
          if ui.runtime.autoAlignArmedChanges == nil then ui.runtime.autoAlignArmedChanges = armedChanges end
          ui.runtime.autoAlignPollAt = nowSeconds() + 0.25
        else
          if outcome == "success" then
            ui.display.roll_degrees = result.roll_degrees
            ui.display.pitch_degrees = result.pitch_degrees
            ui.display.yaw_degrees = result.yaw_degrees
            ui.loaded_roll_degrees = result.roll_degrees
            ui.loaded_pitch_degrees = result.pitch_degrees
            ui.loaded_yaw_degrees = result.yaw_degrees
            ui.dirty = true
            saveToSession()
          elseif outcome == "unknown" or (outcome == "idle" and ui.runtime.autoAlignStartedAt > 0) then
            ui.runtime.autoAlignNeedsReload = true
            ui.runtime.readComplete = false
          end
          showAutoAlignResult(result)
        end
      end
      if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
    end,
    errorHandler = function()
      if not autoAlignCallbackIsCurrent(token) then return end
      ui.runtime.autoAlignPending = false
      ui.runtime.autoAlignAction = nil
      if action == BoardAutoAlignApi.actions.start then
        -- A lost START reply is ambiguous: the controller may already be sampling. Polling is
        -- safe; repeating START would replace the level reference with the lifted attitude.
        ui.runtime.autoAlignActive = true
        ui.runtime.autoAlignPollAt = nowSeconds() + 0.25
      else
        local wasProbe = ui.runtime.autoAlignSupported == nil
        ui.runtime.autoAlignActive = false
        if wasProbe then
          ui.runtime.autoAlignSupported = false
        else
          ui.runtime.autoAlignNeedsReload = true
          ui.runtime.readComplete = false
        end
      end
      if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
    end
  })
end

queueAutoAlignProbe = function()
  if not ui.runtime or ui.runtime.autoAlignSupported ~= nil then return false end
  if not sessionSupportsAutoAlignApi() then
    ui.runtime.autoAlignSupported = false
    return false
  end
  return queueAutoAlignRequest(BoardAutoAlignApi.actions.poll)
end

local function queueAlignmentWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not BoardAlignmentApi or not SensorAlignmentApi then
    return false, "msp_runtime_unavailable"
  end

  -- The four nested queue:add calls that stood here ended with an empty processReply on the
  -- reboot and an empty errorHandler on every step, so a failed alignment write was silent and
  -- nothing waited for the board. The pipeline owns the process and reports its outcome.
  return SavePipeline.start({
    pageId = "setup_alignment",
    steps = {
      {
        label = "MSP_SET_BOARD_ALIGNMENT_CONFIG",
        command = BoardAlignmentApi.writeCommand,
        payload = BoardAlignmentApi.buildWritePayload({
          roll_degrees = toU16(ui.display.roll_degrees),
          pitch_degrees = toU16(ui.display.pitch_degrees),
          yaw_degrees = toU16(ui.display.yaw_degrees)
        })
      },
      {
        label = "MSP_SET_SENSOR_ALIGNMENT",
        command = SensorAlignmentApi.writeCommand,
        payload = SensorAlignmentApi.buildWritePayload({
          gyro_1_alignment = ui.display.gyro_1_alignment,
          gyro_2_alignment = ui.display.gyro_2_alignment,
          mag_alignment = ui.display.mag_alignment
        })
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_alignment" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function buildSessionSignature()
  return tostring(currentSessionSignature() or "")
end

local function getBaseTitle()
  return pageText(nil, "title", "Alignment")
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_alignment")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.liveViewEnabled = false
  ui.liveViewStartedAt = 0
  ui.pollingEnabled = false
  ui.autoRecenterPending = true
  ui.simStartAt = nowSeconds()
  ui.viewYawOffset = 0
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueAlignmentRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    resetAutoAlign(true)
    ui.runtime.autoAlignSupported = nil
    ui.runtime.lastSessionSignature = signature
    queueAlignmentRead(false)
  end

  if ui.runtime.autoAlignActive or ui.runtime.autoAlignPending then
    local session = getSession()
    local now = nowSeconds()
    if Armed and type(Armed.isArmed) == "function" then Armed.isArmed() end
    local armedChanges = Armed and type(Armed.changeCount) == "function" and Armed.changeCount() or nil
    if not session or session.fblConnected ~= true
      or (ui.runtime.autoAlignArmedChanges ~= nil and armedChanges ~= ui.runtime.autoAlignArmedChanges)
      or (Armed and type(Armed.isArmed) == "function" and Armed.isArmed() == true) then
      resetAutoAlign(true)
      ui.runtime.autoAlignNeedsReload = true
      ui.runtime.readComplete = false
      if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
    elseif ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending and now >= ui.runtime.autoAlignPollAt then
      if (now - ui.runtime.autoAlignStartedAt) > 16 then
        ui.runtime.autoAlignActive = false
        ui.runtime.autoAlignState = BoardAutoAlignApi.states.timeout
        ui.runtime.autoAlignNeedsReload = true
        ui.runtime.readComplete = false
        if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
      else
        queueAutoAlignRequest(BoardAutoAlignApi.actions.poll)
      end
    end
  end

  local session = getSession()
  if ui.runtime.autoAlignNeedsReload and not ui.runtime.readPending
    and session and session.fblConnected == true then
    if queueAlignmentRead(false) then ui.runtime.autoAlignNeedsReload = false end
  elseif ui.runtime.autoAlignNeedsProbe and not ui.runtime.autoAlignPending then
    if queueAutoAlignProbe() or ui.runtime.autoAlignSupported ~= nil then
      ui.runtime.autoAlignNeedsProbe = false
    end
  end

  if ui.liveViewEnabled then
    local now = nowSeconds()
    if (now - ui.liveViewStartedAt) >= 60.0 then
      ui.liveViewEnabled = false
      ui.pollingEnabled = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
      return
    end

    updateLiveButtonText()

    if ui.pendingAttitude and (now - ui.pendingAt) > ui.pendingTimeout then
      ui.pendingAttitude = false
    end

    if (now - ui.lastAttitudeAt) >= ui.attitudeSamplePeriod then
      ui.lastAttitudeAt = now
      local mspState = MspRuntime and MspRuntime.getState()
      local queue = mspState and mspState.queue
      if queue and type(queue.add) == "function" and queue:isProcessed() then
        requestAttitude(queue, now)
      end
    end
  end
end

function M.getHeaderActions()
  local trialBusy = ui.runtime and (ui.runtime.autoAlignActive or ui.runtime.autoAlignPending)
  return {
    save = not trialBusy and ui.runtime and ui.runtime.autoAlignNeedsReload ~= true,
    reload = not trialBusy,
    star = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  -- Where this page's own children start: the model's layers are put in front of them.
  local firstChild = #children + 1
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading", "Reading sensor configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local leftPad = 4
  local rightPad = 8
  local gap = 6
  local fieldW = w - leftPad - rightPad
  local rowH = (Controls and Controls.ROW_H) or 64
  local labelY1 = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local cellTop1 = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))

  -- Row 1: Roll, Nick, Yaw
  local editW = 68 -- 68px wide text fields so -180° never wraps
  local labelW = 40 -- 40px wide labels for Roll, Nick, Gier so they never wrap

  local slotX1 = x + leftPad
  local controlW = labelW + editW

  local slotX2 = slotX1 + controlW + gap
  local slotX3 = slotX2 + controlW + gap

  -- Slot 1: Roll
  children[#children + 1] = {
    type = "label",
    x = slotX1, y = labelY1,
    w = labelW,
    text = pageText(i18n, "roll", "Roll"),
    color = Palette.text,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX1 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    get = function() return ui.display.roll_degrees end,
    set = function(v)
      ui.display.roll_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Slot 2: Pitch (Nick)
  children[#children + 1] = {
    type = "label",
    x = slotX2, y = labelY1,
    w = labelW,
    text = pageText(i18n, "pitch", "Pitch"),
    color = Palette.text,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX2 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    get = function() return ui.display.pitch_degrees end,
    set = function(v)
      ui.display.pitch_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Slot 3: Yaw (Gier)
  children[#children + 1] = {
    type = "label",
    x = slotX3, y = labelY1,
    w = labelW,
    text = pageText(i18n, "yaw", "Yaw"),
    color = Palette.text,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "numberEdit",
    x = slotX3 + labelW, y = cellTop1,
    w = editW,
    min = -180, max = 360,
    active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    get = function() return ui.display.yaw_degrees end,
    set = function(v)
      ui.display.yaw_degrees = floor(v or 0)
      ui.dirty = true
      saveToSession()
    end,
    display = function(v) return tostring(v or 0) .. "°" end
  }

  -- Divider line below first row of fields
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color = Palette.border,
    filled = true
  }

  -- Row 2: Mag and Buttons (aligned on controlY)
  local controlY = (Controls and Controls.controlY and Controls.controlY(y + rowH, rowH)) or (y + rowH + math.floor((rowH - 32) / 2))
  local labelY2 = (Controls and Controls.labelY and Controls.labelY(y + rowH, rowH)) or (y + rowH + math.floor((rowH - 21) / 2))

  -- Slot 4: Mag
  local magLabelW = 38
  local magEditW = 160

  children[#children + 1] = {
    type = "label",
    x = x + leftPad, y = labelY2,
    w = magLabelW,
    text = pageText(i18n, "mag", "Mag"),
    color = Palette.text,
    font = SMLSIZE
  }

  local magAlignChoicesValues = {}
  for i, val in ipairs(magAlignChoices) do
    magAlignChoicesValues[i] = pageText(i18n, val.labelKey, val.labelFallback)
  end

  children[#children + 1] = {
    type = "choice",
    x = x + leftPad + magLabelW, y = controlY,
    w = magEditW,
    title = pageText(i18n, "mag", "Mag"),
    values = magAlignChoicesValues,
    active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    get = function()
      return ui.display.mag_alignment + 1
    end,
    set = function(v)
      ui.display.mag_alignment = max(0, min(9, (tonumber(v) or 1) - 1))
      ui.dirty = true
      saveToSession()
    end
  }

  -- Buttons
  local btnStart = x + leftPad + magLabelW + magEditW + gap * 2
  local remainingW = w - btnStart - rightPad
  local btnW = floor((remainingW - gap) / 2)

  scene.liveRemainingFmt = pageText(i18n, "live_remaining_fmt", "Live (%ds)")
  local liveBtnText = pageText(i18n, "live_view", "Live View")
  if ui.liveViewEnabled then
    scene.liveRemaining = -1
    updateLiveButtonText()
    liveBtnText = liveButtonTextFn
  end

  children[#children + 1] = {
    type = "button",
    x = btnStart, y = controlY,
    w = btnW,
    text = liveBtnText,
    active = function() return not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    press = function()
      if ui.liveViewEnabled then
        ui.liveViewEnabled = false
        ui.pollingEnabled = false
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      else
        ui.liveViewEnabled = true
        ui.liveViewStartedAt = nowSeconds()
        ui.pollingEnabled = true
        ui.lastAttitudeAt = 0
        ui.pendingAttitude = false
        ui.autoRecenterPending = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  }

  children[#children + 1] = {
    type = "button",
    x = btnStart + btnW + gap, y = controlY,
    w = btnW,
    text = pageText(i18n, "refresh_visual", "Refresh"),
    active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
    press = function()
      local mspState = MspRuntime and MspRuntime.getState()
      local queue = mspState and mspState.queue
      if queue and type(queue.add) == "function" then
        requestAttitude(queue, nowSeconds())
      end
    end
  }

  -- Divider line below second row of fields
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + 2 * rowH,
    w = w, h = 1,
    color = Palette.border,
    filled = true
  }

  local fieldsH = 2 * rowH
  if ui.runtime.autoAlignSupported == true then
    -- Row 3: Auto-align spans the row so translated labels have room.
    local autoAlignY = (Controls and Controls.controlY and Controls.controlY(y + fieldsH, rowH))
      or (y + fieldsH + math.floor((rowH - 32) / 2))
    children[#children + 1] = {
      type = "button", x = x + leftPad, y = autoAlignY, w = fieldW,
      text = ui.runtime.autoAlignActive and pageText(i18n, "auto_align_lift_tail", "Lift Tail")
        or pageText(i18n, "auto_align", "Auto-align"),
      active = function() return not ui.liveViewEnabled and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending end,
      press = function()
        local signature = currentSessionSignature()
        local session = getSession()
        local armedChanges = Armed and type(Armed.changeCount) == "function" and Armed.changeCount() or nil
        local token = AutoAlignLifecycle.capture(ui.runtime, session, signature, armedChanges)
        ConfirmDialog.show({
          title = pageText(i18n, "auto_align", "Auto-align"),
          message = pageText(i18n, "auto_align_start", "Hold the model level. Continue, then lift the tail at least 20 degrees."),
          onConfirm = function()
            if not autoAlignCallbackIsCurrent(token) then return end
            if not Armed or type(Armed.isArmed) ~= "function" or Armed.isArmed() == true
              or (type(Armed.isUncertain) == "function" and Armed.isUncertain() == true) then return end
            ui.runtime.autoAlignStartedAt = nowSeconds()
            ui.runtime.autoAlignArmedChanges = armedChanges
            ui.runtime.autoAlignState = BoardAutoAlignApi.states.idle
            if not queueAutoAlignRequest(BoardAutoAlignApi.actions.start) then
              ui.runtime.autoAlignStartedAt = 0
              ui.runtime.autoAlignArmedChanges = nil
            end
            if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
          end
        })
      end
    }
    fieldsH = fieldsH + rowH
    children[#children + 1] = {
      type = "rectangle",
      x = x, y = y + fieldsH,
      w = w, h = 1,
      color = Palette.border,
      filled = true
    }
  end

  -- Split layout start
  local splitY = y + fieldsH + 4
  -- Use actual screen height remaining to strictly prevent scrollbars
  local pageBodyH = (lvgl and lvgl.PAGE_BODY_HEIGHT)
  local headerH = 48
  if LCD_H and LCD_H > 300 then
    headerH = 64
  end
  local availH = (h and h > 0) and h or (pageBodyH and (pageBodyH - y)) or ((LCD_H - headerH) - y)
  local splitH = max(50, availH - fieldsH - 8)
  local leftW = floor(w * 0.40)
  local rightW = w - leftW - 4
  local rightX = x + leftW + 4

  -- The texts below and the model on the right follow each attitude sample in place (see
  -- updateScene), so their content is set up here and read through functions.
  scene.liveFmt = pageText(i18n, "live_fmt", "Live  R:%0.1f  P:%0.1f  Y:%0.1f")
  scene.viewYawFmt = pageText(i18n, "view_yaw_fmt", "View Yaw:%0.1f")
  scene.noseLevel = pageText(i18n, "nose_level", "Nose Level")
  scene.noseDown = pageText(i18n, "nose_down", "Nose Down")
  scene.noseUp = pageText(i18n, "nose_up", "Nose Up")
  scene.leaningRight = pageText(i18n, "leaning_right", "Leaning Right")
  scene.leaningLeft = pageText(i18n, "leaning_left", "Leaning Left")

  local colors = scene.colors
  colors[LIGHT] = COLOR_THEME_PRIMARY2
  colors[MID] = COLOR_THEME_SECONDARY2
  colors[DARK] = COLOR_THEME_PRIMARY3 or BLACK
  colors[MAIN] = WHITE
  colors[ACCENT] = COLOR_THEME_SECONDARY1 or YELLOW
  colors[DISC] = COLOR_THEME_SECONDARY2

  -- The model's layers are boxes the size of the page body, placed before everything else so
  -- that every control stays on top of them and keeps its touches. A box keeps a recreated
  -- triangle among its own siblings, so the layers stay in the order the model is drawn in.
  local originX, originY = x, y
  local layerH = splitY + splitH - y
  scene.originX = originX
  scene.originY = originY
  scene.mx = rightX + floor(rightW * 0.5)
  scene.my = splitY + floor(splitH * 0.5)
  scene.scale = max(6, min(rightW, splitH) * 0.22)
  scene.alternate = false
  for k = 1, #FUSELAGE do triSlotModel[k][7] = 0 end
  scene.ready = true
  updateScene()

  local faces = {
    -- Right Panel: 3D Visualization Area
    {
      type = "rectangle",
      x = rightX - originX, y = splitY - originY,
      w = rightW, h = splitH,
      color = Palette.panel,
      filled = true
    }
  }
  for k = 1, #FUSELAGE do
    faces[#faces + 1] = { type = "triangle", x = 0, y = 0, w = 0, h = 0, pts = triSlotPtsFn[k], color = triSlotColorFn[k] }
  end
  local disc = {}
  for j = 1, #DISC_LINES do
    local line = DISC_LINES[j]
    disc[j] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = discPtsFn[j], color = colors[line.c], thickness = line.w }
  end
  local plate = {
    { type = "triangle", x = 0, y = 0, w = 0, h = 0, pts = nosePlatePtsFn, color = colors[ACCENT] }
  }
  local outline = {}
  for j = 1, #OUTLINE_LINES do
    local line = OUTLINE_LINES[j]
    outline[j] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = outlinePtsFn[j], color = colors[line.c], thickness = line.w }
  end
  local layers = { faces, disc, plate, outline }
  for i = 1, #layers do
    table.insert(children, firstChild + i - 1, {
      type = "box",
      x = originX, y = originY,
      w = w, h = layerH,
      scrollDir = 0,
      scrollBar = false,
      children = layers[i]
    })
  end

  -- Vertical divider
  children[#children + 1] = {
    type = "rectangle",
    x = x + leftW, y = splitY,
    w = 1, h = splitH,
    color = Palette.border,
    filled = true
  }

  -- Left Panel: Readouts. One line per row of the small font, measured on this radio: a fixed
  -- 16 px pitch put each line half over the one before it where the font is taller.
  local lineH = (Controls and Controls.estimateWrappedTextHeight and Controls.estimateWrappedTextHeight("Ag", 0, SMLSIZE)) or 16
  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 2,
    w = leftW - 10,
    text = liveTextFn,
    color = Palette.text,
    font = SMLSIZE
  }

  local offsetText = string.format(pageText(i18n, "offset_fmt", "Offset R:%d  P:%d  Y:%d  Mag:%d"), ui.display.roll_degrees, ui.display.pitch_degrees, ui.display.yaw_degrees, ui.display.mag_alignment)
  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 2 + lineH,
    w = leftW - 10,
    text = offsetText,
    color = Palette.text,
    font = SMLSIZE
  }

  children[#children + 1] = {
    type = "label",
    x = x + 6, y = splitY + 2 + 2 * lineH,
    w = leftW - 10,
    text = viewYawTextFn,
    color = Palette.text,
    font = SMLSIZE
  }

  -- Nose Direction Box
  local boxY = splitY + 4 + 3 * lineH
  local boxH = splitH - (boxY - splitY) - 2
  -- Room for the title and one line; two lines need a third.
  local twoLineRoom = boxH >= 4 + 3 * lineH
  if boxH > 4 + 2 * lineH then
    children[#children + 1] = {
      type = "rectangle",
      x = x + 6, y = boxY,
      w = leftW - 12, h = boxH,
      color = Palette.border,
      filled = false
    }

    children[#children + 1] = {
      type = "label",
      x = x + 10, y = boxY + 2,
      w = leftW - 20,
      text = pageText(i18n, "nose_direction", "Nose Direction"),
      color = Palette.text,
      font = SMLSIZE
    }

    -- Two lines while the board also leans and there is room for them, one line otherwise.
    if twoLineRoom then
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = boxY + 2 + lineH,
        w = leftW - 20,
        text = nosePrimaryFn,
        visible = noseTwoLineFn,
        color = Palette.accent,
        font = SMLSIZE
      }
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = boxY + 2 + 2 * lineH,
        w = leftW - 20,
        text = noseSecondaryFn,
        visible = noseTwoLineFn,
        color = Palette.text,
        font = SMLSIZE
      }
    end
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = boxY + 2 + lineH,
      w = leftW - 20,
      text = noseCombinedFn,
      visible = twoLineRoom and noseOneLineFn or nil,
      color = Palette.accent,
      font = SMLSIZE
    }
  end
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
    and not ui.runtime.autoAlignActive and not ui.runtime.autoAlignPending and not ui.runtime.autoAlignNeedsReload
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueAlignmentWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  ui.loaded_roll_degrees = ui.display.roll_degrees
  ui.loaded_pitch_degrees = ui.display.pitch_degrees
  ui.loaded_yaw_degrees = ui.display.yaw_degrees
  saveToSession()
  -- Nothing is announced here. This function has only QUEUED the save: the writes, the commit
  -- and -- on this page -- the restart are all still ahead of it, and a dialog saying the
  -- settings are saved would be a claim it cannot make. It was also drawn on TOP of the
  -- overlay that reports the save, from a place where that overlay could not be repainted away
  -- first, and while a native dialog stands the tool's run() does not run at all. The pipeline
  -- reports the outcome in the overlay, once, when it knows it.
  return true
end

function M.onReload(ctx)
  if ui.runtime and (ui.runtime.autoAlignActive or ui.runtime.autoAlignPending) then return false end
  local session = getSession()
  if session then
    resetAutoAlign(true)
    ui.runtime.autoAlignSupported = nil
    loadFromSession()
    ui.dirty = false
    ui.liveViewEnabled = false
    ui.liveViewStartedAt = 0
    ui.pollingEnabled = false
    queueAlignmentRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/alignment/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end
  local i18n = ctx and ctx.i18n
  local title = pageText(i18n, "title", "Alignment")
  local message = pageText(i18n, "msg_reset_tail_view", "Reset view yaw so the tail faces you?")
  
  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      recenterYawView()
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  return true
end


function M.onClose()
  resetAutoAlign(true)
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  ui.liveViewEnabled = false
  ui.liveViewStartedAt = 0
  ui.pollingEnabled = false
  scene.ready = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  BoardAlignmentApi = nil
  SensorAlignmentApi = nil
  BoardAutoAlignApi = nil
  ApiVersion = nil
  Armed = nil
  AutoAlignLifecycle = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
