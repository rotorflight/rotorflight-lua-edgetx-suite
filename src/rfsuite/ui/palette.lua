-- Tool UI colours, named for their meaning on screen. Each is a role of the suite's colour scheme
-- (lib/color_schemes.lua), which holds every value: this file only says which scheme role each tool
-- role takes, and palette.apply rewrites the roles IN PLACE, so every module that holds this table
-- sees a scheme change without a reload. The radio's own controls and the page header follow the
-- scheme through the theme slots instead (lib/theme_slots.lua).
--
-- lcd is absent on the desktop runners that load this file; there every role is nil, which is what an
-- unset colour property already means to the code reading it.

-- { tool role, scheme role }. Two tool roles may share a scheme role and stay two roles.
local ROLES = {
  { "background", "page" },      -- behind a page's body
  { "card", "card" },      -- a value box on a settings row
  { "border", "rule" },      -- dividers, frames
  { "text", "text" },
  { "muted", "muted" },
  { "accent", "accent" },
  { "accentText", "onAccent" },  -- text on an accent fill
  { "warning", "warning" },
  { "error", "error" },
  { "ok", "ok" },
  { "caution", "warning" },   -- a check that passed with a remark
  { "panel", "page" },      -- a full-screen notice, the closing screen, a log surface
  { "panelText", "text" },
  { "headingText", "text" },      -- a group title on a page
  { "settingsText", "text" },
  { "logWarning", "warning" },    -- a warn row in Session Logs; an error row draws in error
  { "strongBorder", "text" },      -- a frame that has to stand out
  { "wizardBorder", "accent" },
  { "grid", "rule" },      -- the log graph's grid lines
  { "cursor", "accent" },    -- the log graph's cursor
  { "progressTrack", "rule" },
  { "testProgressTrack", "raised" },
  { "tile", "tileOff" },   -- a disabled tile's face
  { "tileMuted", "tileOffText" }, -- a disabled tile's text
  -- The Alignment page's 3D model: outlines and blades, three face shades, the boom ring, the rotor
  -- discs. Each reads on the page in both schemes; the darkest face stays quiet and is outlined.
  { "modelLine", "text" },
  { "modelFaceLight", "muted" },
  { "modelFaceMid", "disabled" },
  { "modelFaceDark", "rule" },
  { "modelAccent", "accent" },
  { "modelDisc", "disabled" },
}

local palette = {}

-- file -> the file drawn for it in the current scheme. A menu asks for the same pictures on every build,
-- so each is worked out once per scheme; apply() empties it.
local iconCache = {}

-- The scheme name the roles carry.
palette.scheme = nil

-- How far a disabled tile's icon fades into its face, 0-255; 0 draws no fade.
palette.iconFade = 0

local function loadSchemes()
  local root = _G.rfsuite
  if root and type(root.require) == "function" then return root.require("lib/color_schemes.lua") end
  local core = root and root.paths and root.paths.core
  local chunk = core and loadScript and loadScript(core .. "/lib/color_schemes.lua", "t")
  return chunk and chunk() or nil
end

--- Rewrite every role for scheme `name` (anything else is the default scheme). Returns the name.
function palette.apply(name)
  if not (lcd and lcd.RGB) then return nil end
  local Schemes = loadSchemes()
  if not Schemes then return nil end
  local scheme = Schemes.name(name)
  local colors = Schemes.colors(scheme)
  for i = 1, #ROLES do
    palette[ROLES[i][1]] = colors[ROLES[i][2]]
  end
  palette.scheme = scheme
  palette.iconFade = Schemes.iconFade(scheme) or 0
  iconCache = {}
  return scheme
end

-- The suite's own pictures exist once per scheme, named by their path below their source folder with
-- the slashes joined: app/pages/setup/mixer/icon.png is app/icons/<scheme>/setup_mixer_icon.png, and a
-- shipped dashboard theme's widgets/dashboard/themes/grid/icons/look.png is
-- widgets/dashboard/theme_icons/<scheme>/grid_icons_look.png, each made from the source picture in the
-- scheme's picture colour (docs/developer/color-schemes.md).
local ICON_SETS = {
  { "/app/pages/", "/app/icons/" },
  { "/widgets/dashboard/themes/", "/widgets/dashboard/theme_icons/" },
}

--- The tile icon to draw for `file` in the current scheme. A picture from anywhere else -- a pilot's
--- own dashboard theme -- is drawn as it is, and so is one whose scheme picture is missing (a page
--- added without running bin/icons/make_scheme_icons.py): its own picture rather than a blank tile.
--- The check is one fstat per picture and scheme; the answer is kept until the scheme changes.
function palette.iconPath(file)
  local hit = iconCache[file]
  if hit then return hit end
  local root = _G.rfsuite
  local core = root and root.paths and root.paths.core
  if type(file) ~= "string" or type(core) ~= "string" or palette.scheme == nil then return file end
  local result = file
  for i = 1, #ICON_SETS do
    local from = core .. ICON_SETS[i][1]
    if string.sub(file, 1, #from) == from then
      local joined = string.gsub(string.sub(file, #from + 1), "/", "_")
      result = core .. ICON_SETS[i][2] .. palette.scheme .. "/" .. joined
      if type(fstat) == "function" and fstat(result) == nil then
        local Log = root.Log
        if Log and type(Log.emit) == "function" then
          Log.emit("rfsuite.ui", "no " .. tostring(palette.scheme) .. " picture for " .. file .. ", drawn as it is", "warn")
        end
        result = file
      end
      break
    end
  end
  iconCache[file] = result
  return result
end

-- `floating` keeps an object in place while its parent scrolls, and out of a flex layout. EdgeTX
-- reads the property from 2.11.8 on; before that an unknown property raises "Invalid property" and
-- stops the build, so it is only set where the firmware is known to take it.
local floatingSupported = nil
function palette.canFloat()
  if floatingSupported == nil then
    floatingSupported = false
    if type(getVersion) == "function" then
      local _, _, maj, minor, rev = getVersion()
      maj, minor, rev = tonumber(maj) or 0, tonumber(minor) or 0, tonumber(rev) or 0
      floatingSupported = maj > 2 or (maj == 2 and (minor > 11 or (minor == 11 and rev >= 8)))
    end
  end
  return floatingSupported
end

-- A page body is transparent and shows the radio theme's background through it. A filled rectangle the
-- size of the body, appended FIRST so everything else draws over it, puts the scheme's page colour
-- there instead. Floating, it stays behind the visible part of a page that scrolls; before EdgeTX
-- 2.11.8 it scrolls away with the content.
function palette.appendBackground(children, w, h)
  children[#children + 1] = {
    type = "rectangle",
    x = 0, y = 0, w = w, h = h,
    color = palette.background,
    filled = true,
    floating = palette.canFloat() or nil
  }
end

-- The scheme as stored, or the default until the tool has read the preferences (ui/home.lua applies it
-- again once it has).
local root = _G.rfsuite
local prefs = root and root.preferences
palette.apply(prefs and prefs.general and prefs.general.color_scheme)

if root then root.palette = palette end
return palette
