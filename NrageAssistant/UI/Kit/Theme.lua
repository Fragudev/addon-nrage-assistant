local _, ns = ...

-- Design tokens of the UI kit (plan section 1): colors, fonts and metrics. Everything the widgets draw asks the
-- theme, so the look changes in one place.
-- Nothing here touches the client except Theme.Font (CreateFont), which only runs when a widget is built.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme = {}
Kit.Theme = Theme

-- "#RRGGBB" (or "RRGGBB") -> { r, g, b, a } with each channel in 0..1. Returns nil for text that is not a color.
function Theme.Hex(value, alpha)
  local r, g, b = tostring(value):match("^#?(%x%x)(%x%x)(%x%x)$")
  if not r then
    return nil
  end
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, alpha or 1 }
end

local hex = Theme.Hex

-- The NRAGE palette (plan 5.1): red and black, with sand for neutral information. Washes are the accent with a low
-- alpha, never white, because white looks grey on red-black.
local ACCENT = "FF0019"

Theme.colors = {
  bg = hex("030001", 0.96),
  panel = hex("0C0203"),
  panelTop = hex("140405"),
  side = hex("0C0203"),
  control = hex(ACCENT, 0.06),
  controlHover = hex(ACCENT, 0.16),
  input = hex("050102"),
  border = hex(ACCENT, 0.22),
  borderStrong = hex(ACCENT, 0.6),
  line = hex("3A0A10"),
  text = hex("F4EBE8"),
  dim = hex("A8918D"),
  muted = hex("A8918D", 0.85),
  accent = hex(ACCENT),
  onAccent = hex("FFFFFF"),
  info = hex("FFD9A8"),
  success = hex("6FE08A"),
  warning = hex("F0B85A"),
  danger = hex("FF6A6A"),
  hover = hex(ACCENT, 0.08),
  selected = hex(ACCENT, 0.12),
  stripe = { 0, 0, 0, 0.14 },
  overlay = { 0, 0, 0, 0.5 },
  gold = hex("F0B85A"),
  silver = hex("C0C6CF"),
  bronze = hex("C9A27E"),
  ice = hex("5CC8FF"),
  online = hex("45E07A"),
  blood = hex("2A0006"),
  -- Opaque grounds for the surfaces that must hide what is behind them (plan 5.7): the menus, the popups and the
  -- calendar. The gradient tokens above may become translucent over the window scene; these never do.
  panelSolid = hex("0C0203"),
  panelTopSolid = hex("140405"),
  controlSolid = hex("1A0508"),
  transparent = { 0, 0, 0, 0 },
}

-- Pairs of colors for the surfaces drawn as a gradient (plan 5.1). `bar` has three stops.
Theme.gradients = {
  panel = { hex("140405"), hex("0C0203") },
  panelSolid = { hex("140405"), hex("0C0203") },
  primary = { hex("FF2236"), hex("C3000F") },
  bar = { hex("7A000B"), hex("FF0019"), hex("FF7A5A") },
}

-- r, g, b, a of a token, optionally with another alpha ("danger" at 0.14 is the chip ground).
function Theme.Color(name, alpha)
  local color = Theme.colors[name] or Theme.colors.text
  return color[1], color[2], color[3], alpha or color[4]
end

-- The old and the new SetGradient disagree on the order of VERTICAL, and which end `minColor` takes there has not
-- been measured in the game (plan section 4, row 15). The assumption is this one line:
-- true means minColor is the bottom.
local VERTICAL_MIN_AT_BOTTOM = true

-- A gradient on `texture` from `from` (the left or the top) to `to`, both { r, g, b, a }. Tries the ColorMixin form
-- of patch 10.0, then the older r, g, b form, and falls back to the flat `from` color. Returns whether a gradient
-- was applied. The texture should hold a white color texture first, which the gradient tints.
function Theme.Gradient(texture, orientation, from, to)
  local min, max = from, to
  if orientation == "VERTICAL" and VERTICAL_MIN_AT_BOTTOM then
    min, max = to, from
  end
  local create = _G.CreateColor
  if type(create) == "function" then
    local ok = pcall(function()
      texture:SetGradient(
        orientation,
        create(min[1], min[2], min[3], min[4] or 1),
        create(max[1], max[2], max[3], max[4] or 1)
      )
    end)
    if ok then
      return true
    end
  end
  local ok = pcall(function()
    texture:SetGradient(orientation, min[1], min[2], min[3], max[1], max[2], max[3])
  end)
  if ok then
    return true
  end
  pcall(function()
    texture:SetColorTexture(from[1], from[2], from[3], from[4] or 1)
  end)
  return false
end

-- The token for a status word, so every widget colors "success", "met" or "failed" the same way.
local STATUS_TOKENS = {
  success = "success",
  met = "success",
  ok = "success",
  open = "success",
  main = "success",
  warning = "warning",
  pending = "warning",
  partial = "warning",
  off = "warning",
  manual = "warning",
  danger = "danger",
  missing = "danger",
  failed = "danger",
  cancelled = "danger",
  accent = "accent",
  info = "info",
  planned = "info",
  other = "info",
  automatic = "info",
  muted = "muted",
  closed = "muted",
  unknown = "muted",
  waived = "muted",
}

function Theme.StatusToken(status)
  return STATUS_TOKENS[status] or "muted"
end

-- Class colors by class file token (the game's own colors, written down here so no client table is needed).
local CLASS_COLORS = {
  DEATHKNIGHT = "C41E3A",
  DEMONHUNTER = "A330C9",
  DRUID = "FF7C0A",
  EVOKER = "33937F",
  HUNTER = "AAD372",
  MAGE = "3FC7EB",
  MONK = "00FF98",
  PALADIN = "F48CBA",
  PRIEST = "FFFFFF",
  ROGUE = "FFF468",
  SHAMAN = "0070DD",
  WARLOCK = "8788EE",
  WARRIOR = "C69B6D",
}

-- { r, g, b, a } of a class token, or nil when it is not a known class.
function Theme.ClassColor(token)
  local value = CLASS_COLORS[token]
  return value and hex(value) or nil
end

-- Item quality (0 poor .. 5 legendary) -> color, as the game shows it.
local QUALITY_COLORS = { [0] = "9D9D9D", "FFFFFF", "1EFF00", "0070DD", "A335EE", "FF8000" }

function Theme.QualityColor(quality)
  return hex(QUALITY_COLORS[quality] or QUALITY_COLORS[1])
end

-- The top three of a ranking: gold, silver and bronze (plan 3.6.3).
function Theme.PositionToken(position)
  if position == 1 then
    return "gold"
  elseif position == 2 then
    return "silver"
  elseif position == 3 then
    return "bronze"
  end
  return "dim"
end

-- Sizes in interface units (plan 1.3). One table so no widget hard-codes a number twice.
Theme.metrics = {
  window = { width = 1000, height = 640, minWidth = 760, minHeight = 480 },
  header = 52,
  logo = 30,
  closeButton = 32,
  sidebar = 200,
  sidebarPadY = 14,
  sidebarPadX = 8,
  navRow = 36,
  navIcon = 16,
  navGap = 10,
  navBar = 3,
  contentTop = 26,
  contentSide = 30,
  blockGap = 20,
  card = { padX = 20, padY = 18, gap = 14, alpha = 0.9, glow = 0.3 },
  button = 30,
  buttonPrimary = 34,
  buttonGhost = 22,
  input = 32,
  switch = { width = 34, height = 18, knob = 14 },
  listRowPadX = 20,
  listRowPadY = 13,
  tableHeader = 28,
  tableRow = 30,
  chip = 22,
  chipHero = 40,
  scrollbar = 6,
  -- The window scene (plan 5.7): its alpha over the solid ground, the alpha of the header and the sidebar over it,
  -- and the size of the original art, whose aspect the "cover" fit needs (the file is squeezed to 1024x512).
  sceneAlpha = 0.5,
  sceneSurfaceAlpha = 0.82,
  sceneSource = { 2560, 1429 },
  -- Alpha of the four copies behind a glowing text (plan 5.5, plan section 4, row 19).
  glowTextAlpha = 0.35,
}

-- Cinzel and Barlow Condensed (SIL OFL 1.1, Media/Fonts/OFL-*.txt). The label, button and display files are
-- derived copies with capitals and tracking baked in (tools/make_fonts.py), so no string has to change. When a file
-- cannot be loaded the game font is used instead.
local FONT_DIR = "Interface\\AddOns\\NrageAssistant\\Media\\Fonts\\"
Theme.FONT_FILES = {
  medium = FONT_DIR .. "BarlowCondensed-Medium.ttf",
  semibold = FONT_DIR .. "BarlowCondensed-SemiBold.ttf",
  bold = FONT_DIR .. "BarlowCondensed-Bold.ttf",
  label = FONT_DIR .. "NrageLabel-SemiBold.ttf",
  button = FONT_DIR .. "NrageButton-Bold.ttf",
  display = FONT_DIR .. "NrageDisplay-Bold.ttf",
  displayBlack = FONT_DIR .. "NrageDisplay-Black.ttf",
}

-- Text styles of the plan (5.2): name -> { weight, size }. Player names, item names and free text must never use
-- `label`, `button` or a display weight: those draw capitals.
Theme.styles = {
  title = { "displayBlack", 22 },
  hero = { "displayBlack", 18 },
  window = { "display", 15 },
  value = { "bold", 15 },
  body = { "medium", 13 },
  small = { "medium", 12 },
  smallMedium = { "semibold", 12 },
  label = { "label", 11 },
  tiny = { "medium", 11 },
  nav = { "button", 13 },
  button = { "button", 13 },
}

local fonts = {}

-- A font object for the weight and size, made on first use and kept. Falls back to the game's font when the file
-- is missing, so a broken install still draws readable text.
function Theme.Font(weight, size)
  local key = weight .. size
  if fonts[key] then
    return fonts[key]
  end
  local font = CreateFont("NrageAssistantFont" .. key)
  local file = Theme.FONT_FILES[weight] or Theme.FONT_FILES.medium
  local ok, loaded = pcall(font.SetFont, font, file, size, "")
  if not (ok and loaded) then
    pcall(font.SetFont, font, STANDARD_TEXT_FONT, size, "")
  end
  fonts[key] = font
  return font
end

-- The font object of a named style ("title", "body"...).
function Theme.StyleFont(style)
  local spec = Theme.styles[style] or Theme.styles.body
  return Theme.Font(spec[1], spec[2])
end

-- A line of this style takes about this many units of height.
function Theme.LineHeight(style)
  local spec = Theme.styles[style] or Theme.styles.body
  return math.ceil(spec[2] * 1.25)
end

Theme.LOGO = "Interface\\AddOns\\NrageAssistant\\Media\\nrage_logo"
