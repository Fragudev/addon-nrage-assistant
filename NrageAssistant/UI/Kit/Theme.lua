local _, ns = ...

-- Design tokens of the UI kit (plan section 1): colors, fonts and metrics. Everything the widgets draw asks the
-- theme, so the look changes in one place, and the accent is a single token that can become a setting.
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

-- The base palette "ember" (plan 1.1). White washes are white with a low alpha.
Theme.colors = {
  bg = hex("121010"),
  panel = hex("191614"),
  side = hex("0D0C0B"),
  control = hex("231F1C"),
  input = hex("0B0A09"),
  border = { 1, 1, 1, 0.08 },
  text = hex("F3EFEA"),
  dim = hex("F3EFEA", 0.68),
  muted = hex("F3EFEA", 0.5),
  accent = hex("3FA7FF"),
  onAccent = hex("0A0C10"),
  success = hex("5BD69A"),
  warning = hex("F5B84C"),
  danger = hex("F07272"),
  hover = { 1, 1, 1, 0.06 },
  selected = { 1, 1, 1, 0.07 },
  stripe = { 0, 0, 0, 0.14 },
  overlay = { 0, 0, 0, 0.5 },
  gold = hex("E6BA66"),
  silver = hex("C0C6CF"),
  bronze = hex("C9A27E"),
  transparent = { 0, 0, 0, 0 },
}

-- The accents the settings can offer later (the mockup shows these four).
Theme.accents = {
  blue = "3FA7FF",
  gold = "E6BA66",
  teal = "0CD29D",
  bronze = "C9A27E",
}

function Theme.SetAccent(name)
  local value = Theme.accents[name]
  if not value then
    return false
  end
  Theme.colors.accent = hex(value)
  return true
end

-- r, g, b, a of a token, optionally with another alpha ("danger" at 0.14 is the chip ground).
function Theme.Color(name, alpha)
  local color = Theme.colors[name] or Theme.colors.text
  return color[1], color[2], color[3], alpha or color[4]
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
  planned = "accent",
  other = "accent",
  automatic = "accent",
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
  card = { padX = 20, padY = 18, gap = 14 },
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
}

-- Fira Sans (SIL OFL 1.1, Media/Fonts/OFL.txt). When a file cannot be loaded the game font is used instead.
local FONT_DIR = "Interface\\AddOns\\NrageAssistant\\Media\\Fonts\\"
Theme.FONT_FILES = {
  regular = FONT_DIR .. "FiraSans-Regular.ttf",
  medium = FONT_DIR .. "FiraSans-Medium.ttf",
  semibold = FONT_DIR .. "FiraSans-SemiBold.ttf",
}

-- Text styles of the plan (1.2): name -> { weight, size }.
Theme.styles = {
  title = { "semibold", 22 },
  hero = { "semibold", 18 },
  window = { "semibold", 15 },
  value = { "medium", 14 },
  body = { "regular", 13 },
  small = { "regular", 12 },
  smallMedium = { "medium", 12 },
  label = { "semibold", 11 },
  tiny = { "regular", 10 },
  nav = { "medium", 13 },
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
  local file = Theme.FONT_FILES[weight] or Theme.FONT_FILES.regular
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
