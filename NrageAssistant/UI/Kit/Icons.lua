local _, ns = ...

-- The stroke icons of the kit (Media/Icons, drawn by tools/make_icons.py): small white textures that the widgets
-- tint at runtime. An icon is asked for by name; an unknown name gives nil and the widget draws without it.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Icons = {}
Kit.Icons = Icons

local DIR = "Interface\\AddOns\\NrageAssistant\\Media\\Icons\\"

Icons.NAMES = {
  "alert",
  "ban",
  "book",
  "calendar",
  "check",
  "check-circle",
  "chevron",
  "circle",
  "close",
  "cross",
  "dash",
  "disc",
  "dot",
  "dots",
  "gear",
  "gem",
  "home",
  "list",
  "pencil",
  "plus",
  "search",
  "send",
  "swords",
  "trash",
  "user",
  "users",
}

local known = {}
for _, name in ipairs(Icons.NAMES) do
  known[name] = true
end

function Icons.Exists(name)
  return known[name] == true
end

-- The texture path of an icon (without the extension, as the game expects), or nil for an unknown name.
function Icons.Path(name)
  if not known[name] then
    return nil
  end
  return DIR .. name
end

-- Sets `texture` to icon `name`, tinted with a theme token (default text). Returns false for an unknown name.
function Icons.Apply(texture, name, token, alpha)
  local path = Icons.Path(name)
  if not path then
    texture:Hide()
    return false
  end
  texture:SetTexture(path)
  texture:SetVertexColor(Kit.Theme.Color(token or "text", alpha))
  texture:Show()
  return true
end

-- The icon that goes with a status: the circle chips and the banners use these.
local STATUS_ICONS = {
  success = "check",
  met = "check",
  ok = "check",
  danger = "cross",
  missing = "cross",
  failed = "cross",
  warning = "alert",
  pending = "alert",
  partial = "dash",
  waived = "dash",
  unknown = "dash",
  muted = "dash",
}

function Icons.ForStatus(status)
  return STATUS_ICONS[status] or "dash"
end
