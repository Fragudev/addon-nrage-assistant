local _, ns = ...

-- Client-side harness for the style measurements (docs/NRAGE_STYLE_PLAN.md section 4, rows 13 to 20). Temporary:
-- removed in phase P5. Not unit tested: it only draws one standalone test frame on real client calls. Every call that
-- is new to this addon goes through pcall, so a missing or changed API prints a line instead of raising.
-- Usage: /nrage styleprobe   (opens or closes the frame; take a screenshot at UI scale 1.0 and another at 0.71)
local StyleProbe = {}

local PREFIX = "|cff33ff99Nrage Assistant|r"
local ROOT = "Interface\\AddOns\\NrageAssistant\\Media\\"
local FONT_DIR = ROOT .. "Fonts\\"
local SHAPES = ROOT .. "Shapes\\"
local WHITE_FILE = "Interface\\Buttons\\WHITE8X8"
local NAME = "NrageStyleProbeFrame"

-- Lowercase on purpose: the capital fonts must show capitals, with accents and the enye, from lowercase input.
local SAMPLE = "reserva de guerra, ñandú, camión, pingüino ¿qué? ¡sí! · … – — 0123"
local FONTS = {
  { file = "NrageDisplay-Bold.ttf", size = 18 },
  { file = "NrageDisplay-Black.ttf", size = 18 },
  { file = "NrageLabel-SemiBold.ttf", size = 12, base = "BarlowCondensed-SemiBold.ttf", tracking = 0.30 },
  { file = "NrageButton-Bold.ttf", size = 13, base = "BarlowCondensed-Bold.ttf", tracking = 0.16 },
  { file = "BarlowCondensed-Medium.ttf", size = 13 },
  { file = "BarlowCondensed-SemiBold.ttf", size = 13 },
  { file = "BarlowCondensed-Bold.ttf", size = 13 },
}
local CUTS = { 4, 6, 8 }
local RED = { 1, 0.3, 0.25 }
local frame

local function say(text)
  print(PREFIX .. " " .. text)
end

-- Runs a client call guarded by pcall; says what failed. Returns ok and the first result.
local function Try(label, fn, ...)
  local ok, a = pcall(fn, ...)
  if not ok then
    say(label .. " failed: " .. tostring(a))
  end
  return ok, a
end

local function Color(r, g, b, a)
  local create = _G.CreateColor
  if type(create) ~= "function" then
    error("CreateColor is missing")
  end
  return create(r, g, b, a or 1)
end

local function Rect(x, y, w, h, color, layer, sub)
  local t = frame:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
  t:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
  t:SetSize(w, h)
  t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
  return t
end

local function Text(x, y, str, size, color, file, layer)
  local fs = frame:CreateFontString(nil, layer or "OVERLAY")
  local ok, set = pcall(fs.SetFont, fs, file or STANDARD_TEXT_FONT, size, "")
  if not ok or set == false then
    pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, "")
    str = "[SetFont failed] " .. str
  end
  fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
  fs:SetJustifyH("LEFT")
  fs:SetTextColor(color and color[1] or 1, color and color[2] or 1, color and color[3] or 1, color and color[4] or 1)
  fs:SetText(str)
  return fs
end

local function Heading(x, y, str)
  Text(x, y, str, 11, { 1, 0.85, 0.5 })
end

local function Note(x, y, str)
  return Text(x, y, str, 10, { 0.8, 0.8, 0.8 })
end

local function Width(fs)
  local ok, width = pcall(fs.GetStringWidth, fs)
  return ok and width or nil
end

local function Chars(str)
  return select(2, str:gsub("[^\128-\191]", ""))
end

-- Rows 13 and 14: do the fonts load, show capitals from lowercase, and measure with their tracking.
local function FontRows(x, y)
  Heading(x, y, "13/14 fonts: lowercase input, accents, enye, width from GetStringWidth")
  y = y + 16
  local chars = Chars(SAMPLE)
  for _, spec in ipairs(FONTS) do
    local fs = Text(x, y, SAMPLE, spec.size, nil, FONT_DIR .. spec.file)
    local width = Width(fs)
    local line = ("%s %dpt: width=%s"):format(spec.file, spec.size, width and ("%.1f"):format(width) or "?")
    if spec.base and width then
      local ref = Text(x, y, SAMPLE, spec.size, { 0, 0, 0, 0 }, FONT_DIR .. spec.base)
      local base = Width(ref)
      if base then
        line = line
          .. (" base=%.1f gain=%.1f expected=%.1f"):format(base, width - base, chars * spec.tracking * spec.size)
      end
    end
    Note(x, y + spec.size + 6, line)
    say(line)
    y = y + spec.size + 22
  end
  return y
end

-- Row 20: Barlow Condensed at 12 and 13.
local function SizeRows(x, y)
  Heading(x, y, "20 Barlow Condensed at 12 and 13")
  y = y + 16
  local text = "Reserva para la próxima banda: 25 de 30 jugadores listos · 14:35"
  for _, file in ipairs({ "BarlowCondensed-Medium.ttf", "BarlowCondensed-SemiBold.ttf" }) do
    for _, size in ipairs({ 12, 13 }) do
      Text(x, y, ("%s %d: %s"):format(file:match("Condensed%-(%a+)"), size, text), size, nil, FONT_DIR .. file)
      y = y + size + 5
    end
  end
  return y
end

-- Row 15: SetGradient with the ColorMixin form, in both orientations, on a color texture and on a white file.
local function GradientRows(x, y)
  Heading(x, y, "15 SetGradient(orientation, minColor=RED, maxColor=BLUE)")
  y = y + 16
  local column = 0
  for _, orientation in ipairs({ "HORIZONTAL", "VERTICAL" }) do
    for _, source in ipairs({ "SetColorTexture", "white file" }) do
      local px = x + column * 100
      local t = Rect(px, y, 90, 30, { 1, 1, 1, 1 })
      if source == "white file" then
        t:SetTexture(WHITE_FILE)
      end
      local ok, err = pcall(function()
        t:SetGradient(orientation, Color(1, 0, 0, 1), Color(0, 0, 1, 1))
      end)
      local result = ("%s on %s: %s"):format(orientation, source, ok and "worked" or "failed: " .. tostring(err))
      if not ok then
        -- The form before patch 10.0.0, for the record.
        local oldOk = pcall(t.SetGradient, t, orientation, 1, 0, 0, 0, 0, 1)
        result = result .. (" (old r,g,b form: %s)"):format(oldOk and "worked" or "failed")
      end
      Note(px, y + 33, orientation:sub(1, 4) .. " " .. (source == "white file" and "file" or "flat"))
      say("15 " .. result)
      column = column + 1
    end
  end
  Note(x, y + 46, "Red is minColor: on HORIZONTAL is red left or right? On VERTICAL is red top or bottom?")
  return y + 62
end

-- Row 16: SetBlendMode("ADD") on a tinted texture, against BLEND, over a grey stripe.
local function BlendRows(x, y)
  Heading(x, y, "16 SetBlendMode: glow art tinted red, BLEND (left) vs ADD (right)")
  y = y + 16
  Rect(x, y, 230, 70, { 0.35, 0.35, 0.38, 1 })
  Rect(x, y + 28, 230, 14, { 0.7, 0.7, 0.7, 1 }, "ARTWORK", 1)
  for i, mode in ipairs({ "BLEND", "ADD" }) do
    local t = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    t:SetTexture(SHAPES .. "glow")
    t:SetVertexColor(RED[1], RED[2], RED[3], 0.8)
    t:SetSize(70, 70)
    t:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 5 + (i - 1) * 115, -y)
    local ok, err = pcall(t.SetBlendMode, t, mode)
    say(("16 SetBlendMode(%s): %s"):format(mode, ok and "worked" or "failed: " .. tostring(err)))
  end
  return y + 80
end

-- Rows 17 and 18: a sliced cut-corner panel per cut size (four flipped corner tiles, three body rectangles, four
-- diagonal edges and four 1px straight edges), so the diagonal can be compared with the straight edge.
local function CutPanel(x, y, w, h, cut)
  local fill, edge = { 0.32, 0.04, 0.05, 1 }, { RED[1], RED[2], RED[3], 1 }
  Rect(x + cut, y, w - 2 * cut, h, fill)
  Rect(x, y + cut, cut, h - 2 * cut, fill)
  Rect(x + w - cut, y + cut, cut, h - 2 * cut, fill)
  Rect(x + cut, y, w - 2 * cut, 1, edge, "ARTWORK", 1)
  Rect(x + cut, y + h - 1, w - 2 * cut, 1, edge, "ARTWORK", 1)
  Rect(x, y + cut, 1, h - 2 * cut, edge, "ARTWORK", 1)
  Rect(x + w - 1, y + cut, 1, h - 2 * cut, edge, "ARTWORK", 1)
  local corners = {
    { 0, 0, 0, 1, 0, 1 },
    { w - cut, 0, 1, 0, 0, 1 },
    { 0, h - cut, 0, 1, 1, 0 },
    { w - cut, h - cut, 1, 0, 1, 0 },
  }
  for _, kind in ipairs({ "fill", "edge" }) do
    for _, c in ipairs(corners) do
      local t = frame:CreateTexture(nil, "ARTWORK", nil, kind == "fill" and 0 or 1)
      t:SetTexture(SHAPES .. ("cut%d_%s"):format(cut, kind))
      t:SetSize(cut, cut)
      t:SetPoint("TOPLEFT", frame, "TOPLEFT", x + c[1], -(y + c[2]))
      local color = kind == "fill" and fill or edge
      t:SetVertexColor(color[1], color[2], color[3], 1)
      Try("SetTexCoord", t.SetTexCoord, t, c[3], c[4], c[5], c[6])
    end
  end
end

local function CutRows(x, y)
  Heading(x, y, "17/18 sliced cut corners (4, 6, 8): look for seams, and compare diagonal and straight edge weight")
  y = y + 16
  for i, cut in ipairs(CUTS) do
    CutPanel(x + (i - 1) * 130, y, 118, 44, cut)
    Note(x + (i - 1) * 130, y + 48, "cut " .. cut)
  end
  return y + 64
end

-- Row 19: text halo by offset copies at three alphas, next to a zero offset shadow.
local function HaloRows(x, y)
  Heading(x, y, "19 halo: copies at 0.25, 0.35, 0.5 and SetShadowOffset(0, 0)")
  y = y + 16
  Rect(x, y, 392, 34, { 0.1, 0.02, 0.03, 1 })
  local file = FONT_DIR .. "NrageDisplay-Bold.ttf"
  for i, alpha in ipairs({ 0.25, 0.35, 0.5 }) do
    local px = x + 6 + (i - 1) * 98
    for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      Text(px + offset[1], y + 7 + offset[2], "Reserva", 18, { RED[1], 0.2, 0.15, alpha }, file, "ARTWORK")
    end
    Text(px, y + 7, "Reserva", 18, { 1, 0.92, 0.88 }, file)
    Note(px, y + 36, "copies " .. alpha)
  end
  local shadowed = Text(x + 6 + 3 * 98, y + 7, "Reserva", 18, { 1, 0.92, 0.88 }, file)
  Try("SetShadowOffset", shadowed.SetShadowOffset, shadowed, 0, 0)
  Try("SetShadowColor", shadowed.SetShadowColor, shadowed, RED[1], 0.2, 0.15, 0.5)
  Note(x + 6 + 3 * 98, y + 36, "shadow 0, 0")
  return y + 54
end

local function Section(label, fn, x, y)
  local ok, result = pcall(fn, x, y)
  if not ok then
    say(label .. " failed: " .. tostring(result))
    return y
  end
  return result
end

local function Build()
  frame = CreateFrame("Frame", NAME, UIParent)
  frame:SetSize(860, 600)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  Rect(0, 0, 860, 600, { 0.04, 0.02, 0.02, 0.97 }, "BACKGROUND")
  Text(16, 10, "Nrage style probe (drag to move, Esc to close)", 14, { 1, 0.85, 0.5 })

  local left = Section("rows 13/14", FontRows, 16, 36)
  Section("row 20", SizeRows, 16, left + 8)
  local right = Section("row 15", GradientRows, 440, 36)
  right = Section("row 16", BlendRows, 440, right + 8)
  right = Section("row 19", HaloRows, 440, right + 8)
  Section("rows 17/18", CutRows, 440, right + 8)

  local close = CreateFrame("Button", nil, frame)
  close:SetSize(60, 20)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  local label = close:CreateFontString(nil, "OVERLAY")
  label:SetFont(STANDARD_TEXT_FONT, 12, "")
  label:SetAllPoints(close)
  label:SetText("[ close ]")
  close:SetScript("OnClick", function()
    frame:Hide()
  end)
  if UISpecialFrames then
    table.insert(UISpecialFrames, NAME)
  end
end

function StyleProbe.Toggle()
  if not ns.active then
    say("probe unavailable: the addon is disabled for this character.")
    return
  end
  if frame then
    frame:SetShown(not frame:IsShown())
    return
  end
  local ok, err = pcall(Build)
  if not ok then
    say("style probe failed: " .. tostring(err))
    return
  end
  say("style probe open. Screenshot at UI scale 1.0 and 0.71, and read the lines above.")
end

function StyleProbe.Handle()
  StyleProbe.Toggle()
end

ns.StyleProbe = StyleProbe
