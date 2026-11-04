local _, ns = ...

-- Display widgets: text, key/value rows, stat blocks, badges, status chips, progress bar, banner, empty state.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme, Util, Icons = Kit.Theme, Kit.Util, Kit.Icons

local function setColor(region, color, alpha)
  if type(color) == "table" then
    region:SetTextColor(color[1], color[2], color[3], alpha or color[4] or 1)
  else
    region:SetTextColor(Theme.Color(color or "text", alpha))
  end
end
Kit.SetTextColor = setColor

-- Glow text (plan 5.5): four copies of a font string, one unit away on each side, in the accent at a low alpha,
-- drawn behind it. They are made on the first call, anchored to `fs` so they follow its width, and kept with the
-- widget: `owner.glowCopies[fs]`. Everything is set on every call, because widgets are pooled; with `enabled` false
-- the copies are hidden. `wrap` is the word wrap of `fs`. Pass the text through Kit.SyncGlow after `fs` changes.
local GLOW_OFFSETS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

function Kit.SetGlow(owner, fs, enabled, wrap)
  owner.glowCopies = owner.glowCopies or {}
  local copies = owner.glowCopies[fs]
  if not enabled then
    for _, copy in ipairs(copies or {}) do
      copy:Hide()
    end
    return
  end
  if not copies then
    copies = {}
    owner.glowCopies[fs] = copies
    for index, offset in ipairs(GLOW_OFFSETS) do
      local copy = owner.frame:CreateFontString(nil, "BACKGROUND")
      copy:SetPoint("TOPLEFT", fs, "TOPLEFT", offset[1], offset[2])
      copy:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", offset[1], offset[2])
      copies[index] = copy
    end
  end
  for _, copy in ipairs(copies) do
    -- Setting a font object is what gives a font string its font; a copy with none would not draw.
    local font = fs.GetFontObject and fs:GetFontObject()
    if font then
      copy:SetFontObject(font)
    end
    copy:SetJustifyH(fs.GetJustifyH and fs:GetJustifyH() or "LEFT")
    copy:SetJustifyV("TOP")
    copy:SetWordWrap(wrap == true)
    setColor(copy, "accent", Theme.metrics.glowTextAlpha)
    copy:SetText(fs:GetText() or "")
    copy:Show()
  end
end

-- Copies the current text of `fs` onto its glow copies, if it has any shown.
function Kit.SyncGlow(owner, fs)
  local copies = owner.glowCopies and owner.glowCopies[fs]
  if not copies then
    return
  end
  for _, copy in ipairs(copies) do
    copy:SetText(fs:GetText() or "")
  end
end

-- Text. opts: text, style ("body"...), color (token or { r, g, b, a }), align ("LEFT" | "CENTER" | "RIGHT"),
-- wrap (wrap onto several lines), upper (capitals), glow (a soft accent halo, for page titles and heroes only).
Kit.Define("Label", {
  create = function(obj)
    obj.fs = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.fs:SetPoint("TOPLEFT")
    -- The glow copies follow every later SetText, not only the one in apply.
    function obj:SetText(text)
      Kit.Widget.SetText(self, text)
      Kit.SyncGlow(self, self.fs)
    end
  end,
  apply = function(obj, opts)
    obj.style = opts.style or "body"
    obj.fs:SetFontObject(Theme.StyleFont(obj.style))
    setColor(obj.fs, opts.color or "text")
    obj.fs:SetJustifyH(opts.align or "LEFT")
    obj.fs:SetJustifyV("TOP")
    obj.fs:SetWordWrap(opts.wrap == true)
    obj:SetText(opts.text or "")
    Kit.SetGlow(obj, obj.fs, opts.glow == true, opts.wrap)
  end,
  layout = function(obj, width)
    obj.fs:SetWidth(width)
    local line = Theme.LineHeight(obj.style)
    if obj.opts.wrap then
      local measured = obj.fs:GetStringHeight()
      return math.max(line, math.ceil(measured or line))
    end
    return line
  end,
  natural = function(obj)
    return math.ceil(obj.fs:GetStringWidth() or 0)
  end,
})

local Widget = Kit.Widget

function Widget:SetColor(color)
  local target = self.fs or self.label
  if target then
    setColor(target, color)
  end
end

-- The small muted capital label that opens a block ("YOUR READINESS").
Kit.Define("SectionLabel", {
  create = function(obj)
    obj.fs = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.fs:SetPoint("TOPLEFT")
  end,
  apply = function(obj, opts)
    obj.fs:SetFontObject(Theme.StyleFont("label"))
    setColor(obj.fs, opts.color or "muted")
    obj.fs:SetJustifyH("LEFT")
    obj.fs:SetWordWrap(false)
    obj.opts.upper = true
    obj:SetText(opts.text or "")
  end,
  layout = function(obj, width)
    obj.fs:SetWidth(width)
    return Theme.LineHeight("label") + 2
  end,
})

-- A 1px line.
Kit.Define("Divider", {
  create = function(obj)
    obj.line = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.line:SetAllPoints(obj.frame)
  end,
  apply = function(obj, opts)
    obj.line:SetColorTexture(Theme.Color(opts.color or "border"))
  end,
  layout = function()
    return 1
  end,
})

-- A tinted icon. opts: icon, color, size.
Kit.Define("Icon", {
  create = function(obj)
    obj.texture = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.texture:SetAllPoints(obj.frame)
  end,
  apply = function(obj, opts)
    obj.size = opts.size or 16
    Icons.Apply(obj.texture, opts.icon, opts.color or "dim")
    obj.texture:SetRotation(opts.rotation or 0)
  end,
  layout = function(obj)
    return obj.size
  end,
  natural = function(obj)
    return obj.size
  end,
})

-- label on the left in dim, value on the right. opts: label, value, valueColor, dot (a status token: a colored dot
-- before the value).
Kit.Define("KeyValue", {
  create = function(obj)
    obj.left = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.right = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.dot = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.left:SetPoint("LEFT")
    obj.right:SetPoint("RIGHT")
    obj.left:SetJustifyH("LEFT")
    obj.right:SetJustifyH("RIGHT")
  end,
  apply = function(obj, opts)
    obj.left:SetFontObject(Theme.StyleFont("body"))
    obj.right:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.left, "dim")
    setColor(obj.right, opts.valueColor or "text")
    obj.left:SetText(opts.label or "")
    obj.right:SetText(opts.value or "")
    obj.dot:ClearAllPoints()
    if opts.dot then
      Icons.Apply(obj.dot, "disc", opts.dot)
      obj.dot:SetSize(8, 8)
      obj.dot:SetPoint("RIGHT", obj.right, "LEFT", -6, 0)
    else
      obj.dot:Hide()
    end
  end,
  layout = function(obj, width)
    obj.right:SetWidth(math.max(0, math.min(width * 0.65, obj.right:GetStringWidth() or 0)))
    obj.left:SetWidth(math.max(0, width * 0.5))
    return 24
  end,
})

-- A plain texture (a game icon, such as a profession's), cropped a little to hide the border baked into the art. An
-- unknown texture draws nothing but keeps its room, so rows stay aligned. opts: texture (fileID or path), size.
Kit.Define("Picture", {
  create = function(obj)
    obj.texture = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.texture:SetAllPoints(obj.frame)
    obj.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end,
  apply = function(obj, opts)
    obj.size = opts.size or 16
    obj.texture:SetTexture(opts.texture)
    obj.texture:SetShown(opts.texture ~= nil)
  end,
  layout = function(obj)
    return obj.size
  end,
  natural = function(obj)
    return obj.size
  end,
})

local STAT_ICON, STAT_ICON_GAP = 16, 6

-- A muted caption over a 14-15px value. opts: caption, value, color (token of the value), classToken, icon (a
-- texture shown before the caption). Caption and value wrap onto more lines when they do not fit the width, so a
-- long translation is never cut; the block grows taller instead.
Kit.Define("StatBlock", {
  create = function(obj)
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(STAT_ICON, STAT_ICON)
    obj.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    obj.caption = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.value = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.caption:SetJustifyH("LEFT")
    obj.caption:SetJustifyV("TOP")
    obj.value:SetJustifyH("LEFT")
    obj.value:SetJustifyV("TOP")
  end,
  apply = function(obj, opts)
    obj.caption:SetFontObject(Theme.StyleFont("small"))
    obj.value:SetFontObject(Theme.StyleFont("value"))
    setColor(obj.caption, "muted")
    setColor(obj.value, opts.color or "text")
    obj.caption:SetText(opts.caption or "")
    obj.value:SetText(opts.value or "")
    obj.caption:SetWordWrap(true)
    obj.value:SetWordWrap(true)
    obj.hasIcon = opts.icon ~= nil
    obj.indent = obj.hasIcon and (STAT_ICON + STAT_ICON_GAP) or 0
    obj.icon:ClearAllPoints()
    if obj.hasIcon then
      obj.icon:SetTexture(opts.icon)
      obj.icon:SetPoint("TOPLEFT", 0, -math.floor((Theme.LineHeight("small") - STAT_ICON) / 2))
      obj.icon:Show()
    else
      obj.icon:Hide()
    end
    obj.caption:ClearAllPoints()
    obj.caption:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", obj.indent, 0)
    obj.value:ClearAllPoints()
    obj.value:SetPoint("TOPLEFT", obj.caption, "BOTTOMLEFT", 0, -3)
  end,
  layout = function(obj, width)
    local textWidth = math.max(1, width - obj.indent)
    obj.caption:SetWidth(textWidth)
    obj.value:SetWidth(textWidth)
    local captionHeight = math.max(Theme.LineHeight("small"), math.ceil(obj.caption:GetStringHeight() or 0))
    if obj.hasIcon then
      captionHeight = math.max(captionHeight, STAT_ICON)
    end
    local valueHeight = math.max(Theme.LineHeight("value"), math.ceil(obj.value:GetStringHeight() or 0))
    obj.caption:SetHeight(captionHeight)
    obj.value:SetHeight(valueHeight)
    return captionHeight + valueHeight + 3
  end,
})

-- Stat blocks in a grid. opts: columns, stats = { { caption, value, color, icon } ... }.
Kit.Define("StatGrid", {
  apply = function(obj, opts)
    obj.columns = math.max(1, opts.columns or #(opts.stats or {}))
    obj.gap, obj.rowGap = 16, 14
    for _, stat in ipairs(opts.stats or {}) do
      Kit.StatBlock(obj, { caption = stat.caption, value = stat.value, color = stat.color, icon = stat.icon })
    end
  end,
  layout = function(obj, width)
    return Kit.LayoutGrid(obj, width)
  end,
})

-- A small tinted tag. opts: text, color (status token), fixed (the text is a fixed word, not a name or free text). The
-- width follows the text.
Kit.Define("Badge", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("CENTER")
  end,
  apply = function(obj, opts)
    local token = opts.color or "muted"
    -- `fixed` marks a fixed word, drawn in capitals; a name or free text keeps its own case.
    obj.label:SetFontObject(Theme.StyleFont(opts.fixed and "label" or "smallMedium"))
    setColor(obj.label, token)
    obj.bg:SetColorTexture(Theme.Color(token, 0.14))
    obj:SetText(opts.text or "")
  end,
  layout = function(obj, width)
    obj.frame:SetWidth(math.min(width, obj:NaturalWidth()))
    return 20
  end,
  natural = function(obj)
    return math.ceil(obj.label:GetStringWidth() or 0) + 16
  end,
})

-- A hexagonal chip in the status color with a stroke icon. opts: status, size (22 or 40), icon (overrides the status
-- icon).
Kit.Define("StatusChip", {
  create = function(obj)
    obj.disc = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.disc:SetAllPoints(obj.frame)
    obj.glyph = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.glyph:SetPoint("CENTER")
  end,
  apply = function(obj, opts)
    obj.size = opts.size or Theme.metrics.chip
    local token = Theme.StatusToken(opts.status)
    Icons.Apply(obj.disc, "hex", token, 0.14)
    Icons.Apply(obj.glyph, opts.icon or Icons.ForStatus(opts.status), token)
    obj.glyph:SetSize(math.floor(obj.size * 0.55), math.floor(obj.size * 0.55))
  end,
  layout = function(obj)
    return obj.size
  end,
  natural = function(obj)
    return obj.size
  end,
})

-- The bar's own colors (plan 5.4): the track and its border.
local TRACK_COLOR, TRACK_BORDER = Theme.Hex("140204"), Theme.Hex("3A0610")
local XP_TICKS = 19
local TIP_GLOW_MIN_HEIGHT, TIP_GLOW_SIZE = 8, 6
local GLOW_FILE = "Interface\\AddOns\\NrageAssistant\\Media\\Shapes\\glow"

-- A flat color on a texture that may keep an old gradient.
local function flat(texture, color)
  texture:SetColorTexture(color[1], color[2], color[3], color[4])
  Theme.Gradient(texture, "HORIZONTAL", color, color)
end

-- A bar. opts: value (0..1), color (token), height, xp (the red three-stop bar of plan 5.4: a gradient fill that
-- brightens toward the tip, 19 ticks and a glow at the tip when it is 8 or more high), label and valueText (xp only,
-- in the `label` style over the bar). A `color` other than the accent stays flat even with xp, so a complete bar is
-- green.
Kit.Define("ProgressBar", {
  create = function(obj)
    obj.track = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.track:SetAllPoints(obj.frame)
    obj.border = Kit.Pixel.Border(obj.frame, TRACK_BORDER)
    obj.fill = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.fill:SetPoint("TOPLEFT")
    obj.fill:SetPoint("BOTTOMLEFT")
    -- The second half of an xp fill, hanging from the end of the first.
    obj.fill2 = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.fill2:SetPoint("TOPLEFT", obj.fill, "TOPRIGHT")
    obj.fill2:SetPoint("BOTTOMLEFT", obj.fill, "BOTTOMRIGHT")
    obj.ticks = {}
    for index = 1, XP_TICKS do
      obj.ticks[index] = obj.frame:CreateTexture(nil, "ARTWORK", 2)
    end
    obj.glow = obj.frame:CreateTexture(nil, "ARTWORK", 1)
    obj.glow:SetTexture(GLOW_FILE)
    -- A normally blended halo would be a smudge, so a client that refuses ADD gets no glow.
    obj.glowOk = pcall(obj.glow.SetBlendMode, obj.glow, "ADD")
    obj.leftText = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.leftText:SetPoint("LEFT", 6, 0)
    obj.leftText:SetJustifyH("LEFT")
    obj.leftText:SetWordWrap(false)
    obj.rightText = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.rightText:SetPoint("RIGHT", -6, 0)
    obj.rightText:SetJustifyH("RIGHT")
    obj.rightText:SetWordWrap(false)
  end,
  apply = function(obj, opts)
    obj.value = Util.Clamp(opts.value or 0, 0, 1)
    obj.barHeight = opts.height or 6
    local color = opts.color or "accent"
    obj.xp = opts.xp == true and color == "accent"
    obj.track:SetColorTexture(TRACK_COLOR[1], TRACK_COLOR[2], TRACK_COLOR[3], TRACK_COLOR[4])
    -- A thin flat bar (the 2 unit countdown) has no room for a border.
    obj.border:SetColor(TRACK_BORDER)
    obj.border:SetShown(obj.xp or obj.barHeight >= 6)
    if obj.xp then
      local stops = Theme.gradients.bar
      obj.fill:SetColorTexture(1, 1, 1, 1)
      obj.fill2:SetColorTexture(1, 1, 1, 1)
      Theme.Gradient(obj.fill, "HORIZONTAL", stops[1], stops[2])
      Theme.Gradient(obj.fill2, "HORIZONTAL", stops[2], stops[3])
    else
      local flatColor = { Theme.Color(color) }
      flat(obj.fill, flatColor)
      flat(obj.fill2, flatColor)
    end
    obj.glow:SetVertexColor(Theme.Color("accent", 0.6))
    for _, text in ipairs({ obj.leftText, obj.rightText }) do
      text:SetFontObject(Theme.StyleFont("label"))
      setColor(text, "text")
    end
    obj.leftText:SetText(obj.xp and opts.label or "")
    obj.rightText:SetText(obj.xp and opts.valueText or "")
    obj.leftText:SetShown(obj.xp and obj.leftText:GetText() ~= "")
    obj.rightText:SetShown(obj.xp and obj.rightText:GetText() ~= "")
  end,
  layout = function(obj, width)
    local filled = math.floor(width * obj.value)
    local drawn = filled > 0
    local height = obj.barHeight
    if obj.xp then
      -- Two halves, so the brightest color of the gradient is always at the tip.
      local first = math.ceil(filled / 2)
      obj.fill:SetWidth(math.max(first, 0.001))
      obj.fill2:SetWidth(math.max(filled - first, 0.001))
    else
      obj.fill:SetWidth(math.max(filled, 0.001))
    end
    obj.fill:SetShown(drawn)
    obj.fill2:SetShown(obj.xp and drawn)
    local px = Kit.Pixel.Size(obj.frame)
    for index, tick in ipairs(obj.ticks) do
      tick:ClearAllPoints()
      if obj.xp and drawn then
        local x = Kit.Pixel.Snap(width * index / (XP_TICKS + 1), px)
        tick:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", x, 0)
        tick:SetPoint("BOTTOMLEFT", obj.frame, "BOTTOMLEFT", x, 0)
        tick:SetWidth(px)
        tick:SetColorTexture(0, 0, 0, 1)
        tick:Show()
      else
        tick:Hide()
      end
    end
    obj.glow:ClearAllPoints()
    if obj.xp and drawn and obj.glowOk and height >= TIP_GLOW_MIN_HEIGHT then
      local size = height + TIP_GLOW_SIZE * 2
      obj.glow:SetSize(size, size)
      obj.glow:SetPoint("CENTER", obj.fill2, "RIGHT", 0, 0)
      obj.glow:Show()
    else
      obj.glow:Hide()
    end
    return height
  end,
})

-- The inline message at the top of the content: tinted with the status color, an icon, the text and a dismiss
-- button. opts: kind ("success" | "warning" | "danger" | "info"), text, onDismiss.
Kit.Define("Banner", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.bar = obj.frame:CreateTexture(nil, "BORDER")
    obj.bar:SetPoint("TOPLEFT")
    obj.bar:SetPoint("BOTTOMLEFT")
    obj.bar:SetWidth(3)
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(16, 16)
    obj.icon:SetPoint("TOPLEFT", 14, -12)
    obj.fs = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.fs:SetPoint("TOPLEFT", 40, -11)
    obj.fs:SetJustifyH("LEFT")
    obj.fs:SetJustifyV("TOP")
    obj.fs:SetWordWrap(true)
    obj.close = CreateFrame("Button", nil, obj.frame)
    obj.close:SetSize(24, 24)
    obj.close:SetPoint("TOPRIGHT", -8, -6)
    obj.closeIcon = obj.close:CreateTexture(nil, "ARTWORK")
    obj.closeIcon:SetSize(12, 12)
    obj.closeIcon:SetPoint("CENTER")
    obj.close:SetScript("OnClick", function()
      if obj.opts and obj.opts.onDismiss then
        obj.opts.onDismiss()
      end
    end)
  end,
  apply = function(obj, opts)
    local kind = opts.kind or "info"
    local token = kind
    obj.bg:SetColorTexture(Theme.Color(token, 0.12))
    obj.bar:SetColorTexture(Theme.Color(token))
    Icons.Apply(obj.icon, kind == "info" and "alert" or Icons.ForStatus(kind), token)
    obj.fs:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.fs, "text")
    obj.fs:SetText(opts.text or "")
    Icons.Apply(obj.closeIcon, "close", "dim")
    if opts.onDismiss then
      obj.close:Show()
    else
      obj.close:Hide()
    end
  end,
  layout = function(obj, width)
    obj.fs:SetWidth(math.max(0, width - 40 - 40))
    local textHeight = math.ceil(obj.fs:GetStringHeight() or 16)
    return math.max(40, textHeight + 22)
  end,
  reset = function(obj)
    obj.close:SetScript("OnClick", nil)
  end,
})

-- A centered icon, a title and a hint inside a card. opts: icon, title, hint.
Kit.Define("EmptyState", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Kit.Pixel.Border(obj.frame, "border")
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(28, 28)
    obj.icon:SetPoint("TOP", 0, -22)
    obj.title = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.title:SetPoint("TOP", obj.icon, "BOTTOM", 0, -10)
    obj.hint = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.hint:SetPoint("TOP", obj.title, "BOTTOM", 0, -6)
    obj.title:SetJustifyH("CENTER")
    obj.hint:SetJustifyH("CENTER")
    obj.hint:SetWordWrap(true)
  end,
  apply = function(obj, opts)
    obj.bg:SetColorTexture(Theme.Color("panel"))
    Icons.Apply(obj.icon, opts.icon or "list", "muted")
    obj.title:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.title, "text")
    obj.title:SetText(opts.title or "")
    obj.hint:SetFontObject(Theme.StyleFont("small"))
    setColor(obj.hint, "muted")
    obj.hint:SetText(opts.hint or "")
  end,
  layout = function(obj, width)
    obj.title:SetWidth(math.max(0, width - 40))
    obj.hint:SetWidth(math.max(0, width - 80))
    local hint = (obj.opts.hint and obj.opts.hint ~= "") and math.ceil(obj.hint:GetStringHeight() or 14) + 6 or 0
    return 22 + 28 + 10 + Theme.LineHeight("body") + hint + 24
  end,
})

-- The page title and its one-line description; an optional badge sits beside the title. opts: title, description,
-- badge = { text, color }.
Kit.Define("PageHeader", {
  create = function(obj)
    obj.title = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.title:SetPoint("TOPLEFT")
    obj.title:SetJustifyH("LEFT")
    obj.desc = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.desc:SetJustifyH("LEFT")
    obj.desc:SetJustifyV("TOP")
    obj.desc:SetWordWrap(true)
  end,
  apply = function(obj, opts)
    obj.title:SetFontObject(Theme.StyleFont("title"))
    setColor(obj.title, "text")
    obj.title:SetText(opts.title or "")
    Kit.SetGlow(obj, obj.title, true, false)
    obj.desc:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.desc, "dim")
    obj.desc:SetText(opts.description or "")
    obj.desc:ClearAllPoints()
    obj.desc:SetPoint("TOPLEFT", 0, -(Theme.LineHeight("title") + 4))
    if opts.badge then
      obj.badge =
        Kit.Badge(obj, { text = opts.badge.text, color = opts.badge.color, fixed = opts.badge.fixed, layout = {} })
      -- The badge is placed by hand, beside the title; Layout below does not stack the children.
    else
      obj.badge = nil
    end
  end,
  layout = function(obj, width)
    obj.title:SetWidth(math.max(0, width - 160))
    obj.desc:SetWidth(width)
    if obj.badge then
      local w = obj.badge:NaturalWidth()
      obj.badge:Layout(w)
      obj.badge.frame:ClearAllPoints()
      obj.badge.frame:SetPoint("TOPRIGHT", obj.frame, "TOPRIGHT", 0, -6)
    end
    local desc = (obj.opts.description and obj.opts.description ~= "") and math.ceil(obj.desc:GetStringHeight() or 16)
      or 0
    return Theme.LineHeight("title") + 4 + desc
  end,
})
