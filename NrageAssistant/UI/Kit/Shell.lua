local _, ns = ...

-- Floating and chrome widgets: popups and menus, the modal, the date picker, the window with its header, the
-- sidebar with its navigation rows and the user card.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme, Util, Icons, Pixel, Calendar = Kit.Theme, Kit.Util, Kit.Icons, Kit.Pixel, Kit.Calendar
local setColor = Kit.SetTextColor

-- ---------------------------------------------------------------------------------------------------------------
-- Popups. A popup is a floating card under an anchor with a click-away catcher behind it. There are two layers, so a
-- menu can open from inside a popover (the hour list of the date picker, a dropdown in the settings).

local Popup = {}
Popup.__index = Popup
Kit.Popup = Popup

local popups = {}

local function newPopup(layer)
  local popup = setmetatable({ layer = layer }, Popup)
  popup.catcher = CreateFrame("Button", nil, UIParent)
  popup.catcher:SetAllPoints(UIParent)
  popup.catcher:SetFrameStrata("FULLSCREEN_DIALOG")
  popup.catcher:SetFrameLevel(layer * 10)
  popup.catcher:RegisterForClicks("AnyUp")
  popup.catcher:SetScript("OnClick", function()
    popup:Close()
  end)
  popup.catcher:Hide()

  popup.frame = CreateFrame("Frame", nil, UIParent)
  popup.frame:SetFrameStrata("FULLSCREEN_DIALOG")
  popup.frame:SetFrameLevel(layer * 10 + 5)
  popup.frame:SetClampedToScreen(true)
  popup.frame:EnableMouse(true)
  popup.bg = popup.frame:CreateTexture(nil, "BACKGROUND")
  popup.bg:SetAllPoints(popup.frame)
  popup.bg:SetColorTexture(Theme.Color("panel"))
  popup.border = Pixel.Border(popup.frame, "border")
  popup.frame:Hide()
  popup.holder = { frame = popup.frame }
  return popup
end

-- The popup of a layer (1 = popover, 2 = menu), made on first use.
function Popup.Get(layer)
  if not popups[layer] then
    popups[layer] = newPopup(layer)
  end
  return popups[layer]
end

function Popup:IsOpen()
  return self.frame:IsShown() == true
end

-- Opens the popup under `anchor` (a frame) with `width`; `build(stack)` adds the content. opts: pad, onClose,
-- point ("BOTTOMLEFT" under the anchor by default; "BOTTOMRIGHT" aligns the right edges).
function Popup:Open(anchor, width, build, opts)
  opts = opts or {}
  self.build, self.width, self.anchor, self.opts = build, width, anchor, opts
  if self.stack then
    self.stack:Release()
  end
  self.stack = Kit.Stack(self.frame, { gap = opts.gap or 10, pad = opts.pad or { 12, 12, 12, 12 } })
  build(self.stack)
  self:Relayout()
  self.frame:ClearAllPoints()
  if opts.point == "BOTTOMRIGHT" then
    self.frame:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
  else
    self.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  end
  self.catcher:Show()
  self.frame:Show()
end

function Popup:Relayout()
  if not self.stack then
    return
  end
  local height = self.stack:Layout(self.width)
  Kit.Place(self.stack, self.frame, 0, 0)
  self.frame:SetSize(self.width, height)
end

-- Builds the content again (after a choice inside it changed what it shows).
function Popup:Rebuild()
  if self:IsOpen() then
    self.stack:Release()
    self.stack = Kit.Stack(self.frame, { gap = self.opts.gap or 10, pad = self.opts.pad or { 12, 12, 12, 12 } })
    self.build(self.stack)
    self:Relayout()
  end
end

function Popup:Close()
  if not self.frame:IsShown() then
    return
  end
  self.frame:Hide()
  self.catcher:Hide()
  if self.stack then
    self.stack:Release()
    self.stack = nil
  end
  local onClose = self.opts and self.opts.onClose
  if onClose then
    onClose()
  end
end

function Kit.CloseAllPopups()
  for _, popup in pairs(popups) do
    popup:Close()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Menu: a list of choices in the second layer. Used by the dropdown, the overflow button and the minimap menu.

Kit.Define("MenuItem", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.wash = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.wash:SetAllPoints(obj.frame)
    obj.check = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.check:SetSize(12, 12)
    obj.check:SetPoint("LEFT", 8, 0)
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(14, 14)
    obj.icon:SetPoint("LEFT", 26, 0)
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetJustifyH("LEFT")
    obj.label:SetWordWrap(false)
    obj.line = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.line:SetPoint("LEFT")
    obj.line:SetPoint("RIGHT")
    obj.line:SetHeight(1)
    obj.frame:SetScript("OnEnter", function()
      if obj.opts and not obj.opts.disabled and not obj.opts.separator then
        obj.wash:SetColorTexture(Theme.Color("hover"))
      end
    end)
    obj.frame:SetScript("OnLeave", function()
      obj.wash:SetColorTexture(0, 0, 0, 0)
    end)
    obj.frame:SetScript("OnClick", function()
      local opts = obj.opts
      if opts and not opts.disabled and not opts.separator and opts.onClick then
        opts.onClick(opts.value)
      end
    end)
  end,
  apply = function(obj, opts)
    obj.wash:SetColorTexture(0, 0, 0, 0)
    obj.line:SetShown(opts.separator == true)
    obj.line:SetColorTexture(Theme.Color("border"))
    obj.label:SetShown(not opts.separator)
    obj.check:SetShown(opts.selected == true)
    if opts.selected then
      Icons.Apply(obj.check, "check", "accent")
    end
    obj.icon:ClearAllPoints()
    obj.label:ClearAllPoints()
    local left = 26
    if opts.icon and Icons.Exists(opts.icon) then
      obj.icon:SetPoint("LEFT", 26, 0)
      Icons.Apply(obj.icon, opts.icon, "dim")
      left = 46
    else
      obj.icon:Hide()
    end
    obj.label:SetPoint("LEFT", left, 0)
    obj.label:SetPoint("RIGHT", -10, 0)
    obj.label:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.label, opts.disabled and "muted" or (opts.color or "text"))
    obj.label:SetText(opts.text or "")
  end,
  layout = function(obj)
    return obj.opts.separator and 9 or 28
  end,
})

local Menu = {}
Kit.Menu = Menu
local MENU_ROWS_MAX = 12

-- Opens a menu under `anchor`. items = { { value, text, icon, color, disabled, separator } ... }; `onSelect(value)`
-- runs on a click, after the menu closed. opts: selected (a value, shown with a check), width.
function Menu.Open(anchor, items, onSelect, opts)
  opts = opts or {}
  local popup = Popup.Get(2)
  local width = math.max(opts.width or 0, 170)
  popup:Open(anchor, width, function(stack)
    local host = stack
    if #items > MENU_ROWS_MAX then
      host = Kit.ScrollArea(stack, { gap = 0, height = MENU_ROWS_MAX * 28 })
    end
    for _, item in ipairs(items) do
      Kit.MenuItem(host, {
        value = item.value,
        text = item.text,
        icon = item.icon,
        color = item.color,
        disabled = item.disabled,
        separator = item.separator,
        selected = opts.selected ~= nil and item.value == opts.selected,
        onClick = function(value)
          popup:Close()
          onSelect(value)
        end,
      })
    end
  end, { pad = { 4, 4, 4, 4 }, gap = 0, point = opts.point })
end

function Menu.Close()
  Popup.Get(2):Close()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Modal: the main window dimmed behind, a centered card with a title and a close button. Escape closes it.

local Modal = {}
Kit.Modal = Modal
local modalFrame

local function buildModal()
  local overlay = CreateFrame("Frame", "NrageAssistantModal", UIParent)
  overlay:SetAllPoints(UIParent)
  overlay:SetFrameStrata("FULLSCREEN_DIALOG")
  overlay:SetFrameLevel(100)
  overlay:EnableMouse(true)
  overlay.dim = overlay:CreateTexture(nil, "BACKGROUND")
  overlay.dim:SetAllPoints(overlay)
  overlay.dim:SetColorTexture(Theme.Color("overlay"))
  overlay.card = CreateFrame("Frame", nil, overlay)
  overlay.card:SetPoint("CENTER")
  overlay.card:EnableMouse(true)
  overlay.cardBg = overlay.card:CreateTexture(nil, "BACKGROUND")
  overlay.cardBg:SetAllPoints(overlay.card)
  overlay.cardBg:SetColorTexture(Theme.Color("panel"))
  overlay.cardBorder = Pixel.Border(overlay.card, "border")
  overlay.title = overlay.card:CreateFontString(nil, "OVERLAY")
  overlay.title:SetPoint("TOPLEFT", 20, -16)
  overlay.title:SetFontObject(Theme.StyleFont("window"))
  setColor(overlay.title, "text")
  overlay:Hide()
  overlay:SetScript("OnHide", function()
    if modalFrame and modalFrame.stack then
      modalFrame.stack:Release()
      modalFrame.stack = nil
    end
  end)
  table.insert(UISpecialFrames, "NrageAssistantModal")
  return overlay
end

-- Opens the modal. opts: title, width, build(stack), onClose. The stack's width is the card width minus 40.
function Modal.Open(opts)
  modalFrame = modalFrame or buildModal()
  local frame = modalFrame
  Kit.CloseAllPopups()
  if frame.stack then
    frame.stack:Release()
  end
  frame.onClose = opts.onClose
  frame.title:SetText(opts.title or "")
  frame.stack = Kit.Stack(frame.card, { gap = 14 })
  opts.build(frame.stack)
  local width = opts.width or 520
  local inner = width - 40
  local height = frame.stack:Layout(inner)
  Kit.Place(frame.stack, frame.card, 20, 52)
  frame.card:SetSize(width, height + 52 + 20)
  if not frame.closeButton then
    frame.closeButton = Kit.IconButton(frame.card, {
      icon = "close",
      tooltip = ns.L("Close"),
      onClick = function()
        Modal.Close()
      end,
    })
    frame.closeButton:Layout(28)
    frame.closeButton.frame:ClearAllPoints()
    frame.closeButton.frame:SetPoint("TOPRIGHT", frame.card, "TOPRIGHT", -10, -10)
  end
  frame:Show()
end

function Modal.Close()
  if modalFrame and modalFrame:IsShown() then
    modalFrame:Hide()
    local onClose = modalFrame.onClose
    modalFrame.onClose = nil
    if onClose then
      onClose()
    end
  end
end

function Modal.IsOpen()
  return modalFrame ~= nil and modalFrame:IsShown() == true
end

-- ---------------------------------------------------------------------------------------------------------------
-- DatePicker: a field that shows the chosen date and time and opens a month calendar with hour and minute lists.

Kit.Define("DayCell", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "transparent")
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("CENTER")
    obj.frame:SetScript("OnClick", function()
      if obj.opts and obj.opts.onClick then
        obj.opts.onClick()
      end
    end)
  end,
  apply = function(obj, opts)
    obj.label:SetFontObject(Theme.StyleFont("small"))
    obj.label:SetText(opts.text or "")
    if opts.selected then
      obj.bg:SetColorTexture(Theme.Color("accent"))
      setColor(obj.label, "onAccent")
    else
      obj.bg:SetColorTexture(1, 1, 1, 0.03)
      setColor(obj.label, opts.muted and "muted" or "text")
    end
    obj.border:SetColor(opts.today and "accent" or "transparent")
  end,
  layout = function()
    return 28
  end,
})

local DEFAULT_MONTHS = { "January", "February", "March", "April", "May", "June", "July" }
DEFAULT_MONTHS[8], DEFAULT_MONTHS[9], DEFAULT_MONTHS[10] = "August", "September", "October"
DEFAULT_MONTHS[11], DEFAULT_MONTHS[12] = "November", "December"
local DEFAULT_WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

-- opts: value (timestamp or nil), format(timestamp) -> text, placeholder, onChange(timestamp), onError(reason),
-- monthName(month), weekdayName(index 1..7, Monday first), now() -> timestamp, clock (for tests).
Kit.Define("DateField", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Pixel.Border(obj.frame, "border")
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("LEFT", 10, 0)
    obj.label:SetPoint("RIGHT", -34, 0)
    obj.label:SetJustifyH("LEFT")
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetSize(14, 14)
    obj.icon:SetPoint("RIGHT", -10, 0)
    obj.frame:SetScript("OnClick", function()
      if obj.opts then
        obj:OpenCalendar()
      end
    end)
  end,
  apply = function(obj, opts)
    obj.bg:SetColorTexture(Theme.Color("control"))
    obj.label:SetFontObject(Theme.StyleFont("body"))
    Icons.Apply(obj.icon, "calendar", "dim")
    obj.value = opts.value
    obj:ShowValue()
  end,
  layout = function()
    return Theme.metrics.input
  end,
})

local Widget = Kit.Widget

function Widget:ShowValue()
  local opts = self.opts
  if self.value and opts.format then
    setColor(self.label, "text")
    self.label:SetText(opts.format(self.value))
  else
    setColor(self.label, "muted")
    self.label:SetText(opts.placeholder or "")
  end
end

function Widget:OpenCalendar()
  local opts = self.opts
  local clock = opts.clock
  local now = opts.now and opts.now() or time()
  local year, month, day, hour, minute
  if self.value then
    year, month, day, hour, minute = Calendar.Parts(self.value, clock)
  else
    year, month, day = Calendar.Parts(now, clock)
    hour, minute = 20, 0
  end
  local state = {
    year = year,
    month = month,
    selected = self.value and { year = year, month = month, day = day } or nil,
    hour = hour,
    minute = Calendar.SnapMinute(minute),
  }
  local todayYear, todayMonth, todayDay = Calendar.Parts(now, clock)
  local popup = Popup.Get(1)
  local field = self

  local function commit()
    if not state.selected then
      return
    end
    local stamp, reason = Calendar.ToTimestamp(
      state.selected.year,
      state.selected.month,
      state.selected.day,
      state.hour,
      state.minute,
      clock
    )
    if not stamp then
      if opts.onError then
        opts.onError(reason)
      end
      return
    end
    field.value = stamp
    field:ShowValue()
    if opts.onChange then
      opts.onChange(stamp)
    end
  end

  local function build(stack)
    local monthNames = opts.monthName or function(index)
      return DEFAULT_MONTHS[index]
    end
    local head = Kit.Row(stack, { gap = 4, height = 28, align = "center" })
    Kit.IconButton(head, {
      icon = "chevron",
      rotation = math.pi,
      tooltip = opts.previousText,
      layout = { width = 28 },
      onClick = function()
        state.year, state.month = Calendar.AddMonths(state.year, state.month, -1)
        popup:Rebuild()
      end,
    })
    Kit.Label(head, {
      text = ("%s %d"):format(monthNames(state.month), state.year),
      style = "smallMedium",
      align = "CENTER",
      layout = { weight = 1 },
    })
    Kit.IconButton(head, {
      icon = "chevron",
      tooltip = opts.nextText,
      layout = { width = 28 },
      onClick = function()
        state.year, state.month = Calendar.AddMonths(state.year, state.month, 1)
        popup:Rebuild()
      end,
    })

    local names = Kit.Grid(stack, { columns = 7, gap = 2, rowGap = 2 })
    for index = 1, 7 do
      Kit.Label(names, {
        text = opts.weekdayName and opts.weekdayName(index) or DEFAULT_WEEKDAYS[index],
        style = "tiny",
        color = "muted",
        align = "CENTER",
      })
    end
    local grid = Kit.Grid(stack, { columns = 7, gap = 2, rowGap = 2 })
    for _, week in ipairs(Calendar.MonthGrid(state.year, state.month)) do
      for _, cell in ipairs(week) do
        local selected = state.selected
          and state.selected.year == cell.year
          and state.selected.month == cell.month
          and state.selected.day == cell.day
        Kit.DayCell(grid, {
          text = tostring(cell.day),
          selected = selected == true,
          today = cell.year == todayYear and cell.month == todayMonth and cell.day == todayDay,
          -- Past days are muted but still selectable.
          muted = not cell.inMonth
            or (cell.year * 10000 + cell.month * 100 + cell.day) < (todayYear * 10000 + todayMonth * 100 + todayDay),
          onClick = function()
            state.selected = { year = cell.year, month = cell.month, day = cell.day }
            state.year, state.month = cell.year, cell.month
            commit()
            popup:Rebuild()
          end,
        })
      end
    end

    local times = Kit.Row(stack, { gap = 8 })
    local hours, minutes = {}, {}
    for h = 0, 23 do
      hours[#hours + 1] = { value = h, text = ("%02d"):format(h) }
    end
    for _, m in ipairs(Calendar.MINUTE_CHOICES) do
      minutes[#minutes + 1] = { value = m, text = ("%02d"):format(m) }
    end
    Kit.Dropdown(times, {
      items = hours,
      value = state.hour,
      layout = { weight = 1 },
      onChange = function(value)
        state.hour = value
        commit()
      end,
    })
    Kit.Dropdown(times, {
      items = minutes,
      value = state.minute,
      layout = { weight = 1 },
      onChange = function(value)
        state.minute = value
        commit()
      end,
    })
    Kit.Button(stack, {
      text = opts.doneText or "OK",
      variant = "primary",
      onClick = function()
        popup:Close()
      end,
    })
  end
  popup:Open(self.frame, 280, build)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Sidebar: navigation rows grouped under small labels, with a user card pinned at the bottom.

Kit.Define("NavRow", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.wash = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.wash:SetAllPoints(obj.frame)
    obj.bar = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.bar:SetPoint("TOPLEFT", 0, -8)
    obj.bar:SetPoint("BOTTOMLEFT", 0, 8)
    obj.bar:SetWidth(Theme.metrics.navBar)
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    local size = Theme.metrics.navIcon
    obj.icon:SetSize(size, size)
    obj.icon:SetPoint("LEFT", 16, 0)
    obj.label = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.label:SetPoint("LEFT", 16 + size + Theme.metrics.navGap, 0)
    obj.label:SetPoint("RIGHT", -8, 0)
    obj.label:SetJustifyH("LEFT")
    obj.label:SetWordWrap(false)
    obj.frame:SetScript("OnEnter", function()
      obj.hovered = true
      obj:refresh()
    end)
    obj.frame:SetScript("OnLeave", function()
      obj.hovered = false
      obj:refresh()
    end)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and obj.opts.onClick then
        obj.opts.onClick(obj.opts.value)
      end
    end)
    function obj:refresh()
      local selected = self.opts.selected
      if selected then
        self.wash:SetColorTexture(Theme.Color("selected"))
        self.bar:SetColorTexture(Theme.Color("accent"))
        self.bar:Show()
      else
        self.wash:SetColorTexture(1, 1, 1, self.hovered and 0.05 or 0)
        self.bar:Hide()
      end
      local token = selected and "text" or "dim"
      setColor(self.label, token)
      Icons.Apply(self.icon, self.opts.icon, selected and "accent" or "dim")
    end
  end,
  apply = function(obj, opts)
    obj.hovered = false
    obj.label:SetFontObject(Theme.StyleFont("nav"))
    obj.label:SetText(opts.text or "")
    obj:refresh()
  end,
  layout = function()
    return Theme.metrics.navRow
  end,
})

-- The initial avatar, the character name and "rank · role". opts: name, detail.
Kit.Define("UserCard", {
  create = function(obj)
    obj.line = obj.frame:CreateTexture(nil, "BORDER")
    obj.line:SetPoint("TOPLEFT")
    obj.line:SetPoint("TOPRIGHT")
    obj.line:SetHeight(1)
    obj.avatar = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.avatar:SetSize(32, 32)
    obj.avatar:SetPoint("LEFT", 14, 0)
    obj.initial = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.initial:SetPoint("CENTER", obj.avatar, "CENTER")
    obj.name = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.name:SetPoint("TOPLEFT", obj.avatar, "TOPRIGHT", 10, -1)
    obj.name:SetJustifyH("LEFT")
    obj.name:SetWordWrap(false)
    obj.detail = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.detail:SetPoint("BOTTOMLEFT", obj.avatar, "BOTTOMRIGHT", 10, 1)
    obj.detail:SetJustifyH("LEFT")
    obj.detail:SetWordWrap(false)
  end,
  apply = function(obj, opts)
    obj.line:SetColorTexture(Theme.Color("border"))
    Icons.Apply(obj.avatar, "disc", "accent", 0.18)
    obj.initial:SetFontObject(Theme.StyleFont("value"))
    setColor(obj.initial, "accent")
    obj.initial:SetText((opts.name or "?"):sub(1, 1):upper())
    obj.name:SetFontObject(Theme.StyleFont("smallMedium"))
    setColor(obj.name, "text")
    obj.name:SetText(opts.name or "")
    obj.detail:SetFontObject(Theme.StyleFont("tiny"))
    setColor(obj.detail, "muted")
    obj.detail:SetText(opts.detail or "")
  end,
  layout = function(obj, width)
    obj.name:SetWidth(math.max(0, width - 70))
    obj.detail:SetWidth(math.max(0, width - 70))
    return 60
  end,
})

-- opts: groups = { { label, items = { { value, text, icon } } } }, value, onSelect(value), user = { name, detail }.
Kit.Define("Sidebar", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
  end,
  apply = function(obj, opts)
    obj.bg:SetColorTexture(Theme.Color("side"))
    obj.nav = Kit.Stack(
      obj,
      { gap = 2, pad = { Theme.metrics.sidebarPadX, Theme.metrics.sidebarPadY, Theme.metrics.sidebarPadX, 0 } }
    )
    for index, group in ipairs(opts.groups or {}) do
      if group.label then
        Kit.Label(obj.nav, {
          text = Util.Upper(group.label),
          style = "tiny",
          color = "muted",
          layout = { gap = index == 1 and 2 or 14 },
        })
      end
      for _, item in ipairs(group.items) do
        Kit.NavRow(obj.nav, {
          value = item.value,
          text = item.text,
          icon = item.icon,
          selected = item.value == opts.value,
          onClick = opts.onSelect,
        })
      end
    end
    if opts.user then
      obj.card = Kit.UserCard(obj, { name = opts.user.name, detail = opts.user.detail })
    end
  end,
  layout = function(obj, width, height)
    obj.nav:Layout(width)
    Kit.Place(obj.nav, obj.frame, 0, 0)
    if obj.card then
      local h = obj.card:Layout(width)
      obj.card.frame:ClearAllPoints()
      obj.card.frame:SetPoint("BOTTOMLEFT", obj.frame, "BOTTOMLEFT", 0, 0)
      return height or h
    end
    return height or 0
  end,
})

-- ---------------------------------------------------------------------------------------------------------------
-- Window: the frame with its header (logo, title, version, sync pill, buttons), the body below it, dragging and
-- resizing, and the saved position. It is made once and shown and hidden; the sidebar and the content are the
-- caller's.

local Window = {}
Window.__index = Window
Kit.Window = Window

-- opts: name (global frame name, for Escape), title, version, logo, width, height, minWidth, minHeight, buttons = {
-- { icon, tooltip, onClick } } (right to left, before the close button), onClose, onResize(bodyWidth, bodyHeight).
function Window.New(opts)
  local m = Theme.metrics
  local self = setmetatable({ opts = opts, buttons = {} }, Window)
  local frame = CreateFrame("Frame", opts.name, UIParent)
  self.frame = frame
  frame:SetSize(opts.width or m.window.width, opts.height or m.window.height)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  frame:EnableMouse(true)
  local minW, minH = opts.minWidth or m.window.minWidth, opts.minHeight or m.window.minHeight
  if frame.SetResizeBounds then
    frame:SetResizeBounds(minW, minH)
  elseif frame.SetMinResize then
    frame:SetMinResize(minW, minH)
  end
  self.bg = frame:CreateTexture(nil, "BACKGROUND")
  self.bg:SetAllPoints(frame)
  self.bg:SetColorTexture(Theme.Color("bg"))
  self.border = Pixel.Border(frame, "border")

  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(m.header)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  self.header = header
  self.headerBg = header:CreateTexture(nil, "BACKGROUND")
  self.headerBg:SetAllPoints(header)
  self.headerBg:SetColorTexture(Theme.Color("side"))
  self.headerLine = header:CreateTexture(nil, "BORDER")
  self.headerLine:SetPoint("BOTTOMLEFT")
  self.headerLine:SetPoint("BOTTOMRIGHT")
  self.headerLine:SetHeight(1)
  self.headerLine:SetColorTexture(Theme.Color("border"))

  self.logo = header:CreateTexture(nil, "ARTWORK")
  self.logo:SetSize(m.logo, m.logo)
  self.logo:SetPoint("LEFT", 14, 0)
  self.logo:SetTexture(opts.logo or Theme.LOGO)
  self.title = header:CreateFontString(nil, "OVERLAY")
  self.title:SetPoint("LEFT", self.logo, "RIGHT", 10, 0)
  self.title:SetFontObject(Theme.StyleFont("window"))
  setColor(self.title, "text")
  self.title:SetText(opts.title or "")
  self.versionText = nil

  header:SetScript("OnDragStart", function()
    frame:StartMoving()
  end)
  header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    self:SaveStatus()
  end)

  self.body = CreateFrame("Frame", nil, frame)
  self.body:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
  self.body:SetPoint("BOTTOMRIGHT")

  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetFrameLevel(frame:GetFrameLevel() + 20)
  grip.texture = grip:CreateTexture(nil, "OVERLAY")
  grip.texture:SetAllPoints(grip)
  Icons.Apply(grip.texture, "chevron", "muted")
  grip.texture:SetRotation(-math.pi / 4)
  grip:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    self:SaveStatus()
    self:NotifyResize()
  end)
  self.grip = grip

  frame:SetScript("OnSizeChanged", function()
    self:NotifyResize()
  end)
  frame:SetScript("OnHide", function()
    Kit.CloseAllPopups()
    if opts.onClose then
      opts.onClose()
    end
  end)
  if opts.name then
    table.insert(UISpecialFrames, opts.name)
  end
  frame:Hide()

  -- The buttons of the header, right to left: close first, then the ones asked for.
  local all = {}
  for _, button in ipairs(opts.buttons or {}) do
    all[#all + 1] = button
  end
  local right = 10
  local closeButton = Kit.IconButton(header, {
    icon = "close",
    size = m.closeButton,
    tooltip = ns.L("Close"),
    onClick = function()
      frame:Hide()
    end,
  })
  closeButton:Layout(m.closeButton)
  closeButton.frame:SetPoint("RIGHT", header, "RIGHT", -right, 0)
  self.buttons.close = closeButton
  right = right + m.closeButton + 6
  for _, button in ipairs(all) do
    local widget = Kit.IconButton(header, {
      icon = button.icon,
      size = m.closeButton,
      tooltip = button.tooltip,
      onClick = button.onClick,
    })
    widget:Layout(m.closeButton)
    widget.frame:SetPoint("RIGHT", header, "RIGHT", -right, 0)
    self.buttons[button.name or button.icon] = widget
    right = right + m.closeButton + 6
  end
  self.rightEdge = right

  -- The sync pill: a dot and a short text, left of the buttons.
  self.pill = CreateFrame("Frame", nil, header)
  self.pill:SetHeight(24)
  self.pill:SetPoint("RIGHT", header, "RIGHT", -right - 4, 0)
  self.pillBg = self.pill:CreateTexture(nil, "BACKGROUND")
  self.pillBg:SetAllPoints(self.pill)
  self.pillDot = self.pill:CreateTexture(nil, "ARTWORK")
  self.pillDot:SetSize(8, 8)
  self.pillDot:SetPoint("LEFT", 10, 0)
  self.pillText = self.pill:CreateFontString(nil, "OVERLAY")
  self.pillText:SetPoint("LEFT", 24, 0)
  self.pillText:SetFontObject(Theme.StyleFont("small"))
  self.pill:Hide()

  if opts.version then
    self:SetVersion(opts.version)
  end
  return self
end

-- The small badge with the version, right of the title.
function Window:SetVersion(text)
  if not self.versionBadge then
    self.versionBadge = CreateFrame("Frame", nil, self.header)
    self.versionBadge:SetHeight(20)
    self.versionBg = self.versionBadge:CreateTexture(nil, "BACKGROUND")
    self.versionBg:SetAllPoints(self.versionBadge)
    self.versionBg:SetColorTexture(1, 1, 1, 0.07)
    self.versionLabel = self.versionBadge:CreateFontString(nil, "OVERLAY")
    self.versionLabel:SetPoint("CENTER")
    self.versionLabel:SetFontObject(Theme.StyleFont("small"))
    setColor(self.versionLabel, "dim")
  end
  self.versionLabel:SetText(text)
  self.versionBadge:SetWidth(math.ceil(self.versionLabel:GetStringWidth() or 30) + 14)
  self.versionBadge:ClearAllPoints()
  self.versionBadge:SetPoint("LEFT", self.title, "RIGHT", 10, 0)
end

function Window:SetTitle(text)
  self.title:SetText(text)
end

-- `text` in the pill, colored by a status token ("success" | "warning" | "danger" | "muted").
function Window:SetPill(text, status)
  local token = Theme.StatusToken(status)
  Icons.Apply(self.pillDot, "disc", token)
  self.pillBg:SetColorTexture(Theme.Color(token, 0.12))
  setColor(self.pillText, token)
  self.pillText:SetText(text or "")
  self.pill:SetWidth(math.ceil(self.pillText:GetStringWidth() or 40) + 36)
  self.pill:Show()
end

function Window:NotifyResize()
  local opts = self.opts
  if opts.onResize then
    local m = Theme.metrics
    opts.onResize(self.frame:GetWidth(), self.frame:GetHeight() - m.header)
  end
end

-- Remembers the size and position in `status` (a table saved with the addon's data), and applies what it holds.
function Window:SetStatusTable(status)
  self.status = status
  local m = Theme.metrics.window
  local width = type(status.width) == "number" and status.width or self.opts.width or m.width
  local height = type(status.height) == "number" and status.height or self.opts.height or m.height
  self.frame:SetSize(width, height)
  if type(status.left) == "number" and type(status.top) == "number" then
    self.frame:ClearAllPoints()
    self.frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", status.left, status.top)
  end
end

function Window:SaveStatus()
  local status = self.status
  if not status then
    return
  end
  status.width, status.height = self.frame:GetWidth(), self.frame:GetHeight()
  local left, top = self.frame:GetLeft(), self.frame:GetTop()
  if type(left) == "number" and type(top) == "number" then
    status.left, status.top = left, top
  end
end

function Window:Show()
  self.frame:Show()
  self:NotifyResize()
end

function Window:Hide()
  self.frame:Hide()
end

function Window:IsShown()
  return self.frame:IsShown() == true
end

function Window:Toggle()
  if self:IsShown() then
    self:Hide()
  else
    self:Show()
  end
end
