local _, ns = ...

-- The widget model of the kit. Every widget is a Lua object holding a frame; widgets are made with
-- Kit.<Kind>(parent, opts), add themselves to their parent, and are laid out top-down with explicit sizes:
--   widget:Layout(width) -> height     (sets the size of its frame, places its children)
-- A widget that is no longer needed is released (Widget:Release / container:Clear) and its frames are reused by
-- the next widget of the same kind, so redrawing a tab never leaks frames.
-- Containers: Stack (vertical), Row (horizontal), Grid (columns), Flow (wrapping), Card, ScrollArea.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme, Util = Kit.Theme, Kit.Util

local Widget = {}
Widget.__index = Widget
Kit.Widget = Widget

local kinds, pools = {}, {}

-- Registers a widget kind and makes Kit.<kind>(parent, opts). spec = {
--   create(obj)          builds the frame(s) once (obj.frame is made by the kit),
--   apply(obj, opts)     sets everything from opts (it runs again each time a pooled widget is reused),
--   layout(obj, width, height) -> height   (default: the fixed obj.height),
--   natural(obj) -> width   (optional: the width it wants in a Row with width = "auto"),
--   reset(obj)           (optional) drops what must not survive in the pool,
--   frameType            "Frame" by default, or "Button"...
-- }
function Kit.Define(kind, spec)
  kinds[kind] = spec
  Kit[kind] = function(parent, opts)
    return Kit.Create(kind, parent, opts)
  end
end

local function parentFrame(parent)
  if parent == nil then
    return UIParent
  end
  return parent.contentFrame or parent.frame or parent
end

function Kit.Create(kind, parent, opts)
  local spec = kinds[kind]
  assert(spec, "unknown widget kind " .. tostring(kind))
  local pool = pools[kind]
  local obj = pool and table.remove(pool)
  if not obj then
    obj = setmetatable({ kind = kind, spec = spec, items = {} }, Widget)
    obj.frame = CreateFrame(spec.frameType or "Frame", nil, parentFrame(parent))
    if spec.create then
      spec.create(obj)
    end
  end
  obj.released = false
  obj.hidden = false
  obj.items = {}
  obj.opts = opts or {}
  obj.parent = nil
  obj.frame:SetParent(parentFrame(parent))
  obj.frame:Show()
  if spec.apply then
    spec.apply(obj, obj.opts)
  end
  if type(parent) == "table" and parent.Add then
    parent:Add(obj, obj.opts.layout)
  end
  return obj
end

-- Adds a child that was made with this widget as its parent frame.
function Widget:Add(child, layout)
  child.parent = self
  self.items[#self.items + 1] = { obj = child, layout = layout or {} }
  return child
end

function Widget:Layout(width, height)
  local h = self.spec.layout and self.spec.layout(self, width, height) or self.height or 0
  self.width, self.height = width, h
  self.frame:SetSize(width, h)
  return h
end

-- The width this widget wants in a Row, or nil.
function Widget:NaturalWidth()
  return self.spec.natural and self.spec.natural(self) or nil
end

function Widget:SetShown(shown)
  self.hidden = not shown
  if shown then
    self.frame:Show()
  else
    self.frame:Hide()
  end
end

-- Releases the children and keeps the widget.
function Widget:Clear()
  for _, item in ipairs(self.items) do
    item.obj:Release()
  end
  self.items = {}
end

-- Hides the shared tooltip when `frame` owns it (a released frame must not leave its tooltip on the screen).
function Kit.HideTooltipFor(frame)
  local tip = GameTooltip
  if tip and tip.GetOwner and tip:GetOwner() == frame and tip.Hide then
    tip:Hide()
  end
end

-- `released` is set first: the reset below can clear an edit box focus, whose handlers must see the widget as gone
-- (an unsaved text is dropped, never committed, so a release never re-enters a redraw) and must not pool it twice.
function Widget:Release()
  if self.released then
    return
  end
  self.released = true
  self:Clear()
  if self.spec.reset then
    self.spec.reset(self)
  end
  Kit.HideTooltipFor(self.frame)
  self.frame:Hide()
  self.frame:ClearAllPoints()
  self.frame:SetParent(nil)
  self.opts = nil
  self.parent = nil
  local pool = pools[self.kind]
  if not pool then
    pool = {}
    pools[self.kind] = pool
  end
  pool[#pool + 1] = self
end

-- Test helper: how many widgets of a kind wait in the pool.
function Kit.PoolSize(kind)
  return pools[kind] and #pools[kind] or 0
end

-- Places `child` with its top left at (x, y) below the top left of `frame`.
local function place(child, frame, x, y)
  child.frame:ClearAllPoints()
  child.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
end
Kit.Place = place

local function padOf(pad)
  if type(pad) == "number" then
    return pad, pad, pad, pad
  end
  pad = pad or {}
  return pad[1] or 0, pad[2] or 0, pad[3] or 0, pad[4] or 0
end
Kit.PadOf = padOf

-- Vertical flow shared by Stack, Card and ScrollArea: children one under the other, `gap` between them.
local function layoutStack(obj, width, gap, pad)
  local left, top, right, bottom = padOf(pad)
  local inner = math.max(0, width - left - right)
  local y, shown = top, 0
  for _, item in ipairs(obj.items) do
    local child = item.obj
    if not child.hidden then
      if shown > 0 then
        y = y + (item.layout.gap or gap)
      end
      local childWidth = inner
      if type(item.layout.width) == "number" then
        childWidth = math.min(inner, item.layout.width)
      end
      local h = child:Layout(childWidth)
      local x = left
      if item.layout.align == "right" then
        x = left + inner - childWidth
      elseif item.layout.align == "center" then
        x = left + math.floor((inner - childWidth) / 2)
      end
      place(child, obj.contentFrame or obj.frame, x, y)
      y = y + h
      shown = shown + 1
    end
  end
  return y + bottom
end
Kit.LayoutStack = layoutStack

Kit.Define("Stack", {
  apply = function(obj, opts)
    obj.gap = opts.gap or Theme.metrics.blockGap
    obj.pad = opts.pad
  end,
  layout = function(obj, width)
    return layoutStack(obj, width, obj.gap, obj.pad)
  end,
})

-- Children side by side. opts: gap, height (minimum), align ("top" | "center"). A child's layout is { width = n }
-- (fixed), { width = "auto" } (what the child asks for through NaturalWidth) or { weight = w } (default 1). A row of
-- children that all have a width asks for their sum, so it can be "auto" itself.
Kit.Define("Row", {
  apply = function(obj, opts)
    obj.gap = opts.gap or 12
    obj.minHeight = opts.height or 0
    obj.align = opts.align or "top"
  end,
  layout = function(obj, width)
    local specs, shown = {}, {}
    for _, item in ipairs(obj.items) do
      if not item.obj.hidden then
        local layout = item.layout
        local spec = { weight = layout.weight, min = layout.min }
        if layout.width == "auto" then
          spec.width = item.obj:NaturalWidth() or 80
        elseif type(layout.width) == "number" then
          spec.width = layout.width
        end
        specs[#specs + 1] = spec
        shown[#shown + 1] = item
      end
    end
    local widths = Util.Distribute(width, specs, obj.gap)
    local heights, tallest = {}, obj.minHeight
    for index, item in ipairs(shown) do
      heights[index] = item.obj:Layout(widths[index])
      tallest = math.max(tallest, heights[index])
    end
    local x = 0
    for index, item in ipairs(shown) do
      local y = 0
      if obj.align == "center" then
        y = math.floor((tallest - heights[index]) / 2)
      end
      place(item.obj, obj.frame, x, y)
      x = x + widths[index] + obj.gap
    end
    return tallest
  end,
  natural = function(obj)
    local total, shown = 0, 0
    for _, item in ipairs(obj.items) do
      if not item.obj.hidden then
        local width = item.layout.width
        if width == "auto" then
          width = item.obj:NaturalWidth()
        end
        total = total + (type(width) == "number" and width or 80)
        shown = shown + 1
      end
    end
    return total + math.max(0, shown - 1) * obj.gap
  end,
})

local function sumBefore(widths, column, gap)
  local x = 0
  for index = 1, column - 1 do
    x = x + widths[index] + gap
  end
  return x
end

-- Children in `columns` equal columns, row after row. opts: columns, gap, rowGap.
local function layoutGrid(obj, width)
  local specs = {}
  for index = 1, obj.columns do
    specs[index] = { weight = 1 }
  end
  local widths = Util.Distribute(width, specs, obj.gap)
  local shown = {}
  for _, item in ipairs(obj.items) do
    if not item.obj.hidden then
      shown[#shown + 1] = item
    end
  end
  local y = 0
  for first = 1, #shown, obj.columns do
    local rowHeight = 0
    for column = 1, obj.columns do
      local item = shown[first + column - 1]
      if not item then
        break
      end
      rowHeight = math.max(rowHeight, item.obj:Layout(widths[column]))
      place(item.obj, obj.frame, sumBefore(widths, column, obj.gap), y)
    end
    y = y + rowHeight + (first + obj.columns <= #shown and obj.rowGap or 0)
  end
  return y
end
Kit.LayoutGrid = layoutGrid

Kit.Define("Grid", {
  apply = function(obj, opts)
    obj.columns = math.max(1, opts.columns or 2)
    obj.gap = opts.gap or 16
    obj.rowGap = opts.rowGap or obj.gap
  end,
  layout = layoutGrid,
})

-- Children that wrap onto new lines (chips). Every child needs a natural width. opts: gap, rowGap, rowHeight.
Kit.Define("Flow", {
  apply = function(obj, opts)
    obj.gap = opts.gap or 8
    obj.rowGap = opts.rowGap or 8
  end,
  layout = function(obj, width)
    local shown, widths = {}, {}
    for _, item in ipairs(obj.items) do
      if not item.obj.hidden then
        shown[#shown + 1] = item
        widths[#widths + 1] = math.min(width, item.obj:NaturalWidth() or 80)
      end
    end
    local y = 0
    for _, line in ipairs(Util.WrapLines(width, widths, obj.gap)) do
      local x, tallest = 0, 0
      for _, index in ipairs(line) do
        local h = shown[index].obj:Layout(widths[index])
        place(shown[index].obj, obj.frame, x, y)
        x = x + widths[index] + obj.gap
        tallest = math.max(tallest, h)
      end
      y = y + tallest + obj.rowGap
    end
    return math.max(0, y - obj.rowGap)
  end,
})

-- The border token of a field (plan 5.3): `line` at rest, `borderStrong` with the focus, and `danger` for an error,
-- which wins over the focus so the two never rely on the same color.
function Kit.FieldBorder(error, focused)
  if error then
    return "danger"
  end
  return focused and "borderStrong" or "line"
end

-- A cut-corner panel with padding (plan 5.3). opts: title (a section label on top), gap, fill (a token, which
-- replaces the gradient), pad ({ left, top, right, bottom }), border (token), solid (the opaque gradient, for a
-- card inside a surface that must hide what is behind it; the default is translucent, plan 5.7), highlight
-- (`borderStrong` and a glow), special (`gold` border).
Kit.Define("Card", {
  create = function(obj)
    obj.shape = Kit.Shape.New(obj.frame, { cut = "md" })
  end,
  apply = function(obj, opts)
    local m = Theme.metrics.card
    obj.gap = opts.gap or m.gap
    obj.pad = opts.pad or { m.padX, m.padY, m.padX, m.padY }
    if opts.fill then
      obj.shape:SetFill(opts.fill)
    else
      if opts.solid then
        obj.shape:SetFill({ gradient = "panelSolid" })
      else
        obj.shape:SetFill({ gradient = "panel", alpha = m.alpha })
      end
    end
    obj.shape.border:SetColor(
      opts.border or (opts.special and "gold") or (opts.highlight and "borderStrong") or "border"
    )
    obj.shape:SetGlow(opts.highlight and { color = "accent", alpha = m.glow } or nil)
    if opts.title then
      Kit.SectionLabel(obj, { text = opts.title })
    end
  end,
  layout = function(obj, width)
    return layoutStack(obj, width, obj.gap, obj.pad)
  end,
})

-- A scrolling column. The children live in a scroll child; the viewport size comes from the parent
-- (Layout(width, height)) because the window knows how much room there is. The wheel scrolls 40 units a notch.
local WHEEL_STEP = 40
local THUMB_MIN = 24 -- the shortest thumb, so it can still be grabbed

Kit.Define("ScrollArea", {
  frameType = "Frame",
  create = function(obj)
    obj.frame:SetClipsChildren(true)
    obj.scroll = CreateFrame("ScrollFrame", nil, obj.frame)
    obj.scroll:SetPoint("TOPLEFT")
    obj.contentFrame = CreateFrame("Frame", nil, obj.scroll)
    obj.contentFrame:SetPoint("TOPLEFT")
    obj.scroll:SetScrollChild(obj.contentFrame)
    obj.scroll:EnableMouseWheel(true)
    obj.track = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.thumb = obj.frame:CreateTexture(nil, "OVERLAY")
    obj.offset = 0
    obj.range = 0
    obj.scroll:SetScript("OnMouseWheel", function(_, delta)
      obj:SetScroll(obj.offset - delta * WHEEL_STEP)
    end)
    -- The bar takes the mouse over the whole gutter (the thumb alone is too thin to aim at): pressing the thumb
    -- drags it, pressing the track jumps the thumb there and keeps dragging until the button is released.
    obj.bar = CreateFrame("Frame", nil, obj.frame)
    obj.bar:EnableMouse(true)
    obj.bar:EnableMouseWheel(true)
    obj.bar:SetScript("OnMouseWheel", function(_, delta)
      obj:SetScroll(obj.offset - delta * WHEEL_STEP)
    end)
    obj.bar:SetScript("OnEnter", function()
      obj.barHovered = true
      obj:PaintThumb()
    end)
    obj.bar:SetScript("OnLeave", function()
      obj.barHovered = false
      obj:PaintThumb()
    end)
    obj.bar:SetScript("OnMouseDown", function(_, button)
      if button ~= "LeftButton" or (obj.range or 0) <= 0 then
        return
      end
      local y = obj:CursorFromTop()
      local top, height = obj.thumbTop or 0, obj.thumbHeight or 0
      obj.grab = (y >= top and y <= top + height) and (y - top) or math.floor(height / 2)
      obj:DragThumb()
      obj.bar:SetScript("OnUpdate", function()
        obj:DragThumb()
      end)
      obj:PaintThumb()
    end)
    local function stopDrag()
      obj.grab = nil
      obj.bar:SetScript("OnUpdate", nil)
      obj:PaintThumb()
    end
    obj.bar:SetScript("OnMouseUp", stopDrag)
    obj.bar:SetScript("OnHide", stopDrag)
  end,
  apply = function(obj, opts)
    obj.gap = opts.gap or Theme.metrics.blockGap
    obj.pad = opts.pad
    obj.track:SetColorTexture(Theme.Color("border", 0.04))
    obj:PaintThumb()
  end,
  -- opts.autoGutter: the gutter of the bar is kept only while there is something to scroll, so the content takes the
  -- whole width when it fits (the sidebar). Without it the gutter is always kept.
  layout = function(obj, width, height)
    local gutter = Theme.metrics.scrollbar + 4
    height = height or obj.opts.height or 200
    local inner = math.max(0, width - gutter)
    local total
    if obj.opts.autoGutter then
      total = layoutStack(obj, width, obj.gap, obj.pad)
      if total > height then
        total = layoutStack(obj, inner, obj.gap, obj.pad)
      else
        inner = width
      end
    else
      total = layoutStack(obj, inner, obj.gap, obj.pad)
    end
    obj.scroll:SetSize(inner, height)
    obj.contentFrame:SetSize(inner, math.max(total, 1))
    obj.view, obj.content = height, total
    obj.range = math.max(0, total - height)
    obj.offset = Util.Clamp(obj.offset, 0, obj.range)
    obj.scroll:SetVerticalScroll(obj.offset)
    obj:UpdateThumb(width, height)
    return height
  end,
  reset = function(obj)
    obj.offset = 0
    obj.grab = nil
    obj.barHovered = false
    obj.bar:SetScript("OnUpdate", nil)
  end,
})

-- The thumb is brighter while the mouse is over the bar and while it is dragged.
function Widget:PaintThumb()
  if self.thumb then
    local alpha = self.grab and 0.45 or (self.barHovered and 0.32 or 0.2)
    self.thumb:SetColorTexture(Theme.Color("text", alpha))
  end
end

-- The cursor height, in units from the top of the widget.
function Widget:CursorFromTop()
  local _, y = GetCursorPosition()
  return (self.frame:GetTop() or 0) - y / self.frame:GetEffectiveScale()
end

-- Follows the cursor while the thumb is held: the thumb top is the cursor less where it was grabbed.
function Widget:DragThumb()
  if not self.grab then
    return
  end
  local top = self:CursorFromTop() - self.grab
  self:SetScroll(Util.ThumbOffset(top, self.view or 0, self.content or 0, self.view or 0, THUMB_MIN))
end

-- Moves the view to `offset` (clamped) and updates the thumb.
function Widget:SetScroll(offset)
  if not self.scroll then
    return
  end
  self.offset = Util.Clamp(offset, 0, self.range or 0)
  self.scroll:SetVerticalScroll(self.offset)
  self:UpdateThumb(self.width or 0, self.view or 0)
end

function Widget:GetScroll()
  return self.offset or 0
end

function Widget:UpdateThumb(width, height)
  if not self.thumb then
    return
  end
  local barWidth = Theme.metrics.scrollbar
  local needed = (self.range or 0) > 0
  self.track:ClearAllPoints()
  self.thumb:ClearAllPoints()
  if not needed then
    self.track:Hide()
    self.thumb:Hide()
    if self.bar then
      self.bar:Hide()
    end
    return
  end
  local top, thumbHeight = Util.Thumb(self.view, self.content, self.offset, height, THUMB_MIN)
  self.thumbTop, self.thumbHeight = top, thumbHeight
  self.track:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, 0)
  self.track:SetSize(barWidth, height)
  self.thumb:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, -top)
  self.thumb:SetSize(barWidth, thumbHeight)
  self.track:Show()
  self.thumb:Show()
  if self.bar then
    self.bar:ClearAllPoints()
    self.bar:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, 0)
    self.bar:SetSize(barWidth + 4, height)
    self.bar:Show()
  end
  self.width = width
end
