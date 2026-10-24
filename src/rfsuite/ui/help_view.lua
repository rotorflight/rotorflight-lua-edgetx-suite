local HelpView = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or loadModule("ui/palette.lua")

function HelpView.open(ctx)
  return false
end

-- The help text is a page of its own, built the way the menu pages in ui/home.lua build theirs.
-- A `page` node is always a full-screen EdgeTX page with its own header: it takes no x/y/w/h,
-- paints over anything built before it, and anything built after it sits on top of its body.
-- So the header is the page's own (title, subtitle, icon), and the text is its body. The sheet
-- is closed by EXIT, or by the header's close icon (`backButton`) on a touch radio; both reach
-- `onBack`, which closes the help while it is open.
--
-- EdgeTX builds a page body that takes no focus, and the rotary encoder and the keys scroll a
-- body only by moving the focus: LVGL scrolls the focused object into view, no further than
-- needed. So a thin marker that can take the focus stands above every line of the text (the
-- help texts give one setting per line) and one more below the last. Turning the encoder
-- moves the focus from marker to marker, one line per step in either direction: forward, the
-- marker comes to rest at the bottom edge with the line above it complete; back, at the top
-- edge with the line below it complete. The focused marker is drawn in the focus colour and
-- shows where the reader is. The first marker takes the focus when the sheet opens, which
-- leaves the text at its start. A marker does nothing when pressed. Touch scrolls the body by
-- dragging, as before.
local function splitLines(text)
  local lines = {}
  local pos = 1
  while true do
    local nextPos = string.find(text, "\n", pos, true)
    if not nextPos then
      lines[#lines + 1] = string.sub(text, pos)
      return lines
    end
    lines[#lines + 1] = string.sub(text, pos, nextPos - 1)
    pos = nextPos + 1
  end
end

function HelpView.build(ctx)
  local i18n = ctx.i18n
  -- The caller names the page the help belongs to; fall back to the generic caption only when
  -- it supplies nothing. Written in the form the package-time resolver recognises.
  local headerTitle = ctx.title or ""
  if headerTitle == "" then
    headerTitle = i18n and i18n.t and i18n.t("app.help.title") or "Help"
  end
  local textW = math.max(40, (ctx.contentW or LCD_W) - 16)

  local children = {}
  local function marker()
    children[#children + 1] = { type = "button", w = textW, h = 2, text = "" }
  end
  local lines = splitLines(tostring(ctx.message or ""))
  for i = 1, #lines do
    local line = lines[i]
    -- A blank line keeps its row and takes no marker: there is nothing on it to read.
    if line ~= "" then marker() end
    -- A label given a width and no height wraps and grows with its text.
    children[#children + 1] = {
      type = "label",
      w = textW,
      text = line ~= "" and line or " ",
      color = Palette.text,
      font = SMLSIZE
    }
  end
  marker()

  return {
    {
      type = "page",
      title = headerTitle,
      subtitle = ctx.subtitle,
      icon = ctx.icon,
      back = ctx.onBack,
      backButton = true,
      flexFlow = lvgl.FLOW_COLUMN,
      children = children
    }
  }
end

return HelpView
