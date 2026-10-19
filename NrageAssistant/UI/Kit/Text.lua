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

-- Text. opts: text, style ("body"...), color (token or { r, g, b, a }), align ("LEFT" | "CENTER" | "RIGHT"),
-- wrap (wrap onto several lines), upper (capitals).
Kit.Define("Label", {
  create = function(obj)
    obj.fs = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.fs:SetPoint("TOPLEFT")
  end,
  apply = function(obj, opts)
    obj.style = opts.style or "body"
    obj.fs:SetFontObject(Theme.StyleFont(obj.style))
    setColor(obj.fs, opts.color or "text")
    obj.fs:SetJustifyH(opts.align or "LEFT")
    obj.fs:SetJustifyV("TOP")
    obj.fs:SetWordWrap(opts.wrap == true)
    obj:SetText(opts.text or "")
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

-- A muted caption over a 14-15px value. opts: caption, value, color (token of the value), classToken.
Kit.Define("StatBlock", {
  create = function(obj)
    obj.caption = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.value = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.caption:SetPoint("TOPLEFT")
    obj.value:SetPoint("TOPLEFT", obj.caption, "BOTTOMLEFT", 0, -3)
    obj.caption:SetJustifyH("LEFT")
    obj.value:SetJustifyH("LEFT")
  end,
  apply = function(obj, opts)
    obj.caption:SetFontObject(Theme.StyleFont("small"))
    obj.value:SetFontObject(Theme.StyleFont("value"))
    setColor(obj.caption, "muted")
    setColor(obj.value, opts.color or "text")
    obj.caption:SetText(opts.caption or "")
    obj.value:SetText(opts.value or "")
    obj.caption:SetWordWrap(false)
    obj.value:SetWordWrap(false)
  end,
  layout = function(obj, width)
    obj.caption:SetWidth(width)
    obj.value:SetWidth(width)
    return Theme.LineHeight("small") + Theme.LineHeight("value") + 3
  end,
})

-- Stat blocks in a grid. opts: columns, stats = { { caption, value, color } ... }.
Kit.Define("StatGrid", {
  apply = function(obj, opts)
    obj.columns = math.max(1, opts.columns or #(opts.stats or {}))
    obj.gap, obj.rowGap = 16, 14
    for _, stat in ipairs(opts.stats or {}) do
      Kit.StatBlock(obj, { caption = stat.caption, value = stat.value, color = stat.color })
    end
  end,
  layout = function(obj, width)
    return Kit.LayoutGrid(obj, width)
  end,
})

-- A small tinted tag. opts: text, color (status token). The width follows the text.
Kit.Define("Badge", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("CENTER")
  end,
  apply = function(obj, opts)
    local token = opts.color or "muted"
    obj.label:SetFontObject(Theme.StyleFont("smallMedium"))
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

-- A round chip in the status color with a stroke icon. opts: status, size (22 or 40), icon (overrides the status icon).
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
    Icons.Apply(obj.disc, "disc", token, 0.14)
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

-- A thin bar. opts: value (0..1), color (token), height.
Kit.Define("ProgressBar", {
  create = function(obj)
    obj.track = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.track:SetAllPoints(obj.frame)
    obj.fill = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.fill:SetPoint("TOPLEFT")
    obj.fill:SetPoint("BOTTOMLEFT")
  end,
  apply = function(obj, opts)
    obj.value = Util.Clamp(opts.value or 0, 0, 1)
    obj.barHeight = opts.height or 6
    obj.track:SetColorTexture(Theme.Color("text", 0.08))
    obj.fill:SetColorTexture(Theme.Color(opts.color or "accent"))
  end,
  layout = function(obj, width)
    local filled = math.floor(width * obj.value)
    obj.fill:SetWidth(math.max(filled, 0.001))
    if filled <= 0 then
      obj.fill:Hide()
    else
      obj.fill:Show()
    end
    return obj.barHeight
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
    local token = kind == "info" and "accent" or kind
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
    obj.desc:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.desc, "dim")
    obj.desc:SetText(opts.description or "")
    obj.desc:ClearAllPoints()
    obj.desc:SetPoint("TOPLEFT", 0, -(Theme.LineHeight("title") + 4))
    if opts.badge then
      obj.badge = Kit.Badge(obj, { text = opts.badge.text, color = opts.badge.color, layout = {} })
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
