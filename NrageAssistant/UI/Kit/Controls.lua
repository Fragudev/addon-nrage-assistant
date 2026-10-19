local _, ns = ...

-- Controls: buttons, switch, checkbox, chips, segmented control, tab strip, edit boxes, dropdown, form field.
-- A control calls the function it was given (onClick, onChange, onCommit...) and never decides anything itself.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme, Util, Icons, Pixel = Kit.Theme, Kit.Util, Kit.Icons, Kit.Pixel
local setColor = Kit.SetTextColor
local Widget = Kit.Widget

local function callback(obj, name, ...)
  local fn = obj.opts and obj.opts[name]
  if fn then
    return fn(...)
  end
end

-- A tooltip with one line of text, for icon buttons.
local function tooltipOn(obj)
  obj.frame:SetScript("OnEnter", function()
    obj.hovered = true
    if obj.refresh then
      obj:refresh()
    end
    local tip = obj.opts and obj.opts.tooltip
    if tip and GameTooltip then
      GameTooltip:SetOwner(obj.frame, "ANCHOR_BOTTOM")
      GameTooltip:SetText(tip)
      GameTooltip:Show()
    end
  end)
  obj.frame:SetScript("OnLeave", function()
    obj.hovered = false
    obj.pressed = false
    if obj.refresh then
      obj:refresh()
    end
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  obj.frame:SetScript("OnMouseDown", function()
    obj.pressed = true
    if obj.refresh then
      obj:refresh()
    end
  end)
  obj.frame:SetScript("OnMouseUp", function()
    obj.pressed = false
    if obj.refresh then
      obj:refresh()
    end
  end)
end

local BUTTON_FILL = {
  secondary = "control",
  primary = "accent",
  ghost = "transparent",
  danger = "control",
  dangerSolid = "danger",
}
local BUTTON_TEXT = {
  secondary = "text",
  primary = "onAccent",
  ghost = "accent",
  danger = "danger",
  dangerSolid = "onAccent",
}
local BUTTON_HEIGHT = {
  secondary = Theme.metrics.button,
  primary = Theme.metrics.buttonPrimary,
  ghost = Theme.metrics.buttonGhost,
  danger = Theme.metrics.button,
  dangerSolid = Theme.metrics.button,
}

-- A text button. opts: text, variant ("secondary" | "primary" | "ghost" | "danger" | "dangerSolid"), icon, onClick,
-- disabled, tooltip, height.
Kit.Define("Button", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.wash = obj.frame:CreateTexture(nil, "BORDER")
    obj.wash:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "border")
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(14, 14)
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetJustifyH("CENTER")
    tooltipOn(obj)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled then
        callback(obj, "onClick", obj)
      end
    end)
    function obj:refresh()
      local variant = self.opts.variant or "secondary"
      self.wash:SetColorTexture(1, 1, 1, (self.pressed and 0.1) or (self.hovered and 0.06) or 0)
      self.frame:SetAlpha(self.opts.disabled and 0.4 or 1)
      if variant == "ghost" then
        setColor(self.label, self.hovered and "text" or "accent")
      end
    end
  end,
  apply = function(obj, opts)
    local variant = opts.variant or "secondary"
    obj.hovered, obj.pressed = false, false
    obj.bg:SetColorTexture(Theme.Color(BUTTON_FILL[variant] or "control"))
    obj.border:SetColor(variant == "secondary" and "border" or (variant == "danger" and "danger" or "transparent"))
    obj.label:SetFontObject(Theme.StyleFont(variant == "ghost" and "small" or "smallMedium"))
    setColor(obj.label, BUTTON_TEXT[variant] or "text")
    obj.label:ClearAllPoints()
    obj.icon:ClearAllPoints()
    if opts.icon and Icons.Exists(opts.icon) then
      Icons.Apply(obj.icon, opts.icon, BUTTON_TEXT[variant] or "text")
      obj.icon:SetPoint("LEFT", 12, 0)
      obj.label:SetPoint("LEFT", 32, 0)
      obj.label:SetPoint("RIGHT", -10, 0)
    else
      obj.icon:Hide()
      obj.label:SetPoint("LEFT", 8, 0)
      obj.label:SetPoint("RIGHT", -8, 0)
    end
    obj:SetText(opts.text or "")
    obj:refresh()
  end,
  layout = function(obj)
    return obj.opts.height or BUTTON_HEIGHT[obj.opts.variant or "secondary"] or Theme.metrics.button
  end,
  natural = function(obj)
    local extra = (obj.opts.icon and Icons.Exists(obj.opts.icon)) and 22 or 0
    return math.ceil(obj.label:GetStringWidth() or 0) + 28 + extra
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

-- Enables or disables a control after it was made.
function Widget:SetDisabled(disabled)
  if self.opts then
    self.opts.disabled = disabled and true or false
  end
  if self.refresh then
    self:refresh()
  end
end

-- A square button with an icon only. opts: icon, tooltip, onClick, variant ("ghost" | "secondary" | "danger"), size.
Kit.Define("IconButton", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.glyph = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.glyph:SetPoint("CENTER")
    tooltipOn(obj)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled then
        callback(obj, "onClick", obj)
      end
    end)
    function obj:refresh()
      local variant = self.opts.variant or "ghost"
      local base = variant == "secondary" and 1 or 0
      self.bg:SetColorTexture(1, 1, 1, (self.pressed and 0.12) or (self.hovered and 0.08) or (base * 0.05))
      local token = self.opts.color or (variant == "danger" and "danger" or (self.hovered and "text" or "dim"))
      Icons.Apply(self.glyph, self.opts.icon, token)
      self.frame:SetAlpha(self.opts.disabled and 0.4 or 1)
    end
  end,
  apply = function(obj, opts)
    obj.size = opts.size or 28
    obj.hovered, obj.pressed = false, false
    obj.glyph:SetSize(math.floor(obj.size * 0.55), math.floor(obj.size * 0.55))
    obj.glyph:SetRotation(opts.rotation or 0)
    obj:refresh()
  end,
  layout = function(obj)
    return obj.size
  end,
  natural = function(obj)
    return obj.size
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

-- A switch: a 34x18 track and a 14px knob; with `label` it is a settings row (label left, switch right).
-- opts: label, description, checked, onChange(checked), disabled.
Kit.Define("Switch", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    local m = Theme.metrics.switch
    obj.track = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.track:SetSize(m.width, m.height)
    obj.track:SetPoint("RIGHT")
    obj.knob = obj.frame:CreateTexture(nil, "OVERLAY")
    obj.knob:SetSize(m.knob, m.knob)
    obj.text = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.text:SetPoint("LEFT")
    obj.text:SetJustifyH("LEFT")
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled then
        obj:SetChecked(not obj.checked)
        callback(obj, "onChange", obj.checked)
      end
    end)
  end,
  apply = function(obj, opts)
    obj.text:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.text, "text")
    obj.text:SetText(opts.label or "")
    obj.frame:SetAlpha(opts.disabled and 0.4 or 1)
    obj:SetChecked(opts.checked)
  end,
  layout = function()
    return 36
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

function Widget:SetChecked(checked)
  self.checked = checked and true or false
  if self.knob then
    local m = Theme.metrics.switch
    self.track:SetColorTexture(Theme.Color(self.checked and "accent" or "text", self.checked and 1 or 0.16))
    self.knob:SetColorTexture(Theme.Color(self.checked and "onAccent" or "text", self.checked and 1 or 0.8))
    self.knob:ClearAllPoints()
    local inset = (m.height - m.knob) / 2
    self.knob:SetPoint("RIGHT", self.frame, "RIGHT", self.checked and -inset or -(m.width - m.knob - inset), 0)
  end
  if self.box then
    self.fill:SetShown(self.checked)
    self.tick:SetShown(self.checked)
  end
end

function Widget:GetChecked()
  return self.checked == true
end

-- A checkbox with a label. opts: label, checked, onChange(checked), disabled.
Kit.Define("Checkbox", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.box = CreateFrame("Frame", nil, obj.frame)
    obj.box:SetSize(16, 16)
    obj.box:SetPoint("LEFT")
    obj.boxBg = obj.box:CreateTexture(nil, "BACKGROUND")
    obj.boxBg:SetAllPoints(obj.box)
    obj.boxBorder = Pixel.Border(obj.box, "border")
    obj.fill = obj.box:CreateTexture(nil, "BORDER")
    obj.fill:SetAllPoints(obj.box)
    obj.tick = obj.box:CreateTexture(nil, "ARTWORK")
    obj.tick:SetSize(12, 12)
    obj.tick:SetPoint("CENTER")
    obj.text = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.text:SetPoint("LEFT", 26, 0)
    obj.text:SetJustifyH("LEFT")
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled then
        obj:SetChecked(not obj.checked)
        callback(obj, "onChange", obj.checked)
      end
    end)
  end,
  apply = function(obj, opts)
    obj.boxBg:SetColorTexture(Theme.Color("input"))
    obj.fill:SetColorTexture(Theme.Color("accent"))
    Icons.Apply(obj.tick, "check", "onAccent")
    obj.text:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.text, "text")
    obj.text:SetText(opts.label or "")
    obj.frame:SetAlpha(opts.disabled and 0.4 or 1)
    obj:SetChecked(opts.checked)
  end,
  layout = function(obj, width)
    obj.text:SetWidth(math.max(0, width - 26))
    return 24
  end,
  natural = function(obj)
    return 26 + math.ceil(obj.text:GetStringWidth() or 0)
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

-- A toggle pill (filters, enchant slots). opts: text, active, onToggle(active), color (token), disabled.
Kit.Define("Chip", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "border")
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("CENTER")
    tooltipOn(obj)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled then
        obj.opts.active = not obj.opts.active
        obj:refresh()
        callback(obj, "onToggle", obj.opts.active)
      end
    end)
    function obj:refresh()
      local token = self.opts.color or "accent"
      if self.opts.active then
        self.bg:SetColorTexture(Theme.Color(token, 0.18))
        self.border:SetColor(token)
        setColor(self.label, token)
      else
        self.bg:SetColorTexture(1, 1, 1, self.hovered and 0.08 or 0.03)
        self.border:SetColor("border")
        setColor(self.label, "dim")
      end
      self.frame:SetAlpha(self.opts.disabled and 0.4 or 1)
    end
  end,
  apply = function(obj, opts)
    obj.hovered = false
    obj.label:SetFontObject(Theme.StyleFont("small"))
    obj.label:SetText(opts.text or "")
    obj:refresh()
  end,
  layout = function()
    return 26
  end,
  natural = function(obj)
    return math.ceil(obj.label:GetStringWidth() or 0) + 22
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

-- Exclusive choices side by side. opts: items = { { value, text } ... }, value, onChange(value).
Kit.Define("Segmented", {
  apply = function(obj, opts)
    obj.value = opts.value
    obj.segments = {}
    for _, item in ipairs(opts.items or {}) do
      local segment = Kit.Chip(obj, {
        text = item.text,
        active = item.value == opts.value,
        layout = {},
        onToggle = function()
          obj.value = item.value
          for _, other in ipairs(obj.segments) do
            other.opts.active = other.item.value == item.value
            other:refresh()
          end
          callback(obj, "onChange", item.value)
        end,
      })
      segment.item = item
      obj.segments[#obj.segments + 1] = segment
    end
  end,
  layout = function(obj, width)
    local x = 0
    for _, segment in ipairs(obj.segments) do
      local w = math.min(segment:NaturalWidth(), math.max(0, width - x))
      segment:Layout(w)
      Kit.Place(segment, obj.frame, x, 0)
      x = x + w + 4
    end
    return 26
  end,
  natural = function(obj)
    local total = 0
    for _, segment in ipairs(obj.segments) do
      total = total + segment:NaturalWidth() + 4
    end
    return total
  end,
})

-- The sub-navigation strip: tabs with a 2px accent underline under the selected one.
-- opts: tabs = { { value, text } ... }, value, onSelect(value).
Kit.Define("TabStrip", {
  create = function(obj)
    obj.line = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.line:SetPoint("BOTTOMLEFT")
    obj.line:SetPoint("BOTTOMRIGHT")
    obj.line:SetHeight(1)
    obj.underline = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.underline:SetHeight(2)
  end,
  apply = function(obj, opts)
    obj.line:SetColorTexture(Theme.Color("border"))
    obj.underline:SetColorTexture(Theme.Color("accent"))
    obj.value = opts.value
    obj.tabs = {}
    for _, tab in ipairs(opts.tabs or {}) do
      local button = Kit.Button(obj, {
        text = tab.text,
        variant = "ghost",
        height = 32,
        layout = {},
        onClick = function()
          obj.value = tab.value
          callback(obj, "onSelect", tab.value)
        end,
      })
      button.tab = tab
      obj.tabs[#obj.tabs + 1] = button
    end
  end,
  layout = function(obj, width)
    local x = 0
    obj.underline:Hide()
    for _, button in ipairs(obj.tabs) do
      local w = math.min(button:NaturalWidth() + 8, math.max(0, width - x))
      button:Layout(w)
      Kit.Place(button, obj.frame, x, 0)
      local selected = button.tab.value == obj.value
      setColor(button.label, selected and "text" or "dim")
      if selected then
        obj.underline:ClearAllPoints()
        obj.underline:SetPoint("BOTTOMLEFT", obj.frame, "BOTTOMLEFT", x, 0)
        obj.underline:SetWidth(w)
        obj.underline:Show()
      end
      x = x + w + 6
    end
    return 34
  end,
})

-- A single-line text box. opts: text, placeholder, maxLetters, numeric, disabled, error (boolean), onChange(text,
-- userInput), onEnter(text), onCommit(text): Enter or losing the focus with a changed text (Escape restores the text
-- that was there). The kit never saves anything: the callbacks do.
Kit.Define("EditBox", {
  frameType = "EditBox",
  create = function(obj)
    local frame = obj.frame
    frame:SetAutoFocus(false)
    frame:SetTextInsets(10, 10, 0, 0)
    frame:SetJustifyH("LEFT")
    obj.bg = frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(frame)
    obj.border = Pixel.Border(frame, "border")
    obj.hint = frame:CreateFontString(nil, "OVERLAY")
    obj.hint:SetPoint("LEFT", 10, 0)
    obj.hint:SetJustifyH("LEFT")

    local function commit()
      local text = frame:GetText()
      if text ~= obj.stored then
        obj.stored = text
        callback(obj, "onCommit", text)
      end
    end
    frame:SetScript("OnEnterPressed", function()
      callback(obj, "onEnter", frame:GetText())
      obj.escaped = false
      frame:ClearFocus()
    end)
    frame:SetScript("OnEscapePressed", function()
      obj.escaped = true
      frame:SetText(obj.stored or "")
      frame:ClearFocus()
    end)
    frame:SetScript("OnEditFocusGained", function()
      obj.focused = true
      obj.escaped = false
      obj:refresh()
    end)
    frame:SetScript("OnEditFocusLost", function()
      obj.focused = false
      obj:refresh()
      if not obj.escaped and obj.opts then
        commit()
      end
      obj.escaped = false
    end)
    frame:SetScript("OnTextChanged", function(_, userInput)
      obj:refresh()
      callback(obj, "onChange", frame:GetText(), userInput == true)
    end)
    function obj:refresh()
      local border = (self.opts.error and "danger") or (self.focused and "accent") or "border"
      self.border:SetColor(border)
      local empty = frame:GetText() == ""
      if empty and not self.focused and self.opts.placeholder then
        self.hint:Show()
      else
        self.hint:Hide()
      end
    end
  end,
  apply = function(obj, opts)
    local frame = obj.frame
    obj.focused, obj.escaped = false, false
    frame:SetFontObject(Theme.StyleFont("body"))
    setColor(frame, "text")
    frame:SetMaxLetters(opts.maxLetters or 0)
    frame:SetNumeric(opts.numeric == true)
    frame:SetText(opts.text or "")
    obj.stored = opts.text or ""
    frame:EnableMouse(not opts.disabled)
    frame:SetAlpha(opts.disabled and 0.5 or 1)
    obj.bg:SetColorTexture(Theme.Color("input"))
    obj.hint:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.hint, "muted")
    obj.hint:SetText(opts.placeholder or "")
    obj:refresh()
  end,
  layout = function()
    return Theme.metrics.input
  end,
  reset = function(obj)
    obj.frame:ClearFocus()
    obj.frame:SetAlpha(1)
  end,
})

function Widget:GetText()
  if self.frame and self.kind == "EditBox" then
    return self.frame:GetText() or ""
  end
  return self.text or ""
end

function Widget:SetText(text)
  text = tostring(text or "")
  if self.kind == "EditBox" then
    self.frame:SetText(text)
    self.stored = text
    return
  end
  if self.opts and self.opts.upper then
    text = Util.Upper(text)
  end
  self.text = text
  local target = self.fs or self.label
  if target then
    target:SetText(text)
  end
end

function Widget:Focus()
  if self.frame.SetFocus then
    self.frame:SetFocus()
  end
end

function Widget:SetError(flag)
  if self.opts then
    self.opts.error = flag and true or false
  end
  if self.refresh then
    self:refresh()
  end
end

-- A multi-line text area inside a scroll frame (the export and import boxes). opts: text, readOnly, onChange(text),
-- height. The box takes the keyboard focus on demand (Widget:Focus) and can select all its text.
Kit.Define("TextArea", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "border")
    obj.scroll = CreateFrame("ScrollFrame", nil, obj.frame)
    obj.scroll:SetPoint("TOPLEFT", 8, -8)
    obj.scroll:EnableMouseWheel(true)
    obj.edit = CreateFrame("EditBox", nil, obj.scroll)
    obj.edit:SetMultiLine(true)
    obj.edit:SetAutoFocus(false)
    obj.edit:SetFontObject(Theme.StyleFont("small"))
    obj.scroll:SetScrollChild(obj.edit)
    obj.edit:SetScript("OnEscapePressed", function()
      obj.edit:ClearFocus()
    end)
    obj.edit:SetScript("OnTextChanged", function(_, userInput)
      if userInput then
        callback(obj, "onChange", obj.edit:GetText())
      end
    end)
    obj.edit:SetScript("OnEditFocusGained", function()
      if obj.opts and obj.opts.readOnly then
        obj.edit:HighlightText()
      end
    end)
    obj.scroll:SetScript("OnMouseWheel", function(_, delta)
      local current = obj.scroll:GetVerticalScroll()
      obj.scroll:SetVerticalScroll(math.max(0, current - delta * 30))
    end)
  end,
  apply = function(obj, opts)
    obj.bg:SetColorTexture(Theme.Color("input"))
    setColor(obj.edit, "text")
    obj.edit:SetText(opts.text or "")
    obj.edit:SetCursorPosition(0)
    obj.readOnly = opts.readOnly == true
    obj.edit:EnableMouse(true)
  end,
  layout = function(obj, width)
    local height = obj.opts.height or 200
    obj.scroll:SetSize(width - 16, height - 16)
    obj.edit:SetWidth(width - 16)
    obj.edit:SetHeight(height - 16)
    return height
  end,
  reset = function(obj)
    obj.edit:ClearFocus()
  end,
})

function Widget:HighlightAll()
  if self.edit then
    self.edit:SetFocus()
    self.edit:HighlightText()
  end
end

function Widget:GetValueText()
  return self.edit and self.edit:GetText() or ""
end

-- A button that opens a menu of choices. opts: items = { { value, text, color, disabled } ... }, value, placeholder,
-- onChange(value), disabled.
Kit.Define("Dropdown", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.wash = obj.frame:CreateTexture(nil, "BORDER")
    obj.wash:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "border")
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("LEFT", 10, 0)
    obj.label:SetPoint("RIGHT", -28, 0)
    obj.label:SetJustifyH("LEFT")
    obj.label:SetWordWrap(false)
    obj.chevron = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.chevron:SetSize(12, 12)
    obj.chevron:SetPoint("RIGHT", -10, 0)
    tooltipOn(obj)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and not obj.opts.disabled and Kit.Menu then
        Kit.Menu.Open(obj.frame, obj.choices, function(value)
          obj:SetValue(value)
          callback(obj, "onChange", value)
        end, { selected = obj.value, width = obj.width })
      end
    end)
    function obj:refresh()
      self.wash:SetColorTexture(1, 1, 1, self.hovered and 0.06 or 0)
      self.frame:SetAlpha(self.opts.disabled and 0.4 or 1)
    end
  end,
  apply = function(obj, opts)
    obj.hovered = false
    obj.bg:SetColorTexture(Theme.Color("control"))
    obj.label:SetFontObject(Theme.StyleFont("body"))
    Icons.Apply(obj.chevron, "chevron", "dim")
    obj.chevron:SetRotation(-math.pi / 2)
    obj.choices = opts.items or {}
    obj:SetValue(opts.value)
    obj:refresh()
  end,
  layout = function()
    return Theme.metrics.input
  end,
  reset = function(obj)
    obj.frame:SetAlpha(1)
  end,
})

function Widget:SetItems(items)
  self.choices = items or {}
  self:SetValue(self.value)
end

function Widget:SetValue(value)
  if self.kind ~= "Dropdown" then
    self.value = value
    return
  end
  self.value = value
  local text
  for _, item in ipairs(self.choices or {}) do
    if item.value == value then
      text = item.text
    end
  end
  if text then
    setColor(self.label, "text")
    self.label:SetText(text)
  else
    setColor(self.label, "muted")
    self.label:SetText((self.opts and self.opts.placeholder) or "")
  end
end

function Widget:GetValue()
  return self.value
end

-- A caption above a control: add the control to the field after making it. opts: label, hint, error (text).
Kit.Define("Field", {
  create = function(obj)
    obj.errorText = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.errorText:SetJustifyH("LEFT")
  end,
  apply = function(obj, opts)
    obj.gap = 6
    if opts.label then
      Kit.Label(obj, { text = opts.label, style = "small", color = "dim" })
    end
    obj.errorText:SetFontObject(Theme.StyleFont("small"))
    setColor(obj.errorText, "danger")
    obj.errorText:SetText(opts.error or "")
    obj.errorText:SetShown(opts.error ~= nil)
  end,
  layout = function(obj, width)
    local height = Kit.LayoutStack(obj, width, obj.gap, nil)
    if obj.opts.error then
      obj.errorText:ClearAllPoints()
      obj.errorText:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", 0, -(height + 4))
      obj.errorText:SetWidth(width)
      height = height + 4 + Theme.LineHeight("small")
    end
    return height
  end,
})
