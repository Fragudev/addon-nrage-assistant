local _, ns = ...

-- The compact window of Intel and its warning (docs/PVP_INTEL_PLAN.md section 3.4). The window lists who is nearby (or
-- the last hour, the Ignore list, the Kill on Sight lists); a click on a row targets the player, Shift toggles his
-- Kill on Sight mark, Ctrl toggles Ignore and the right button opens a menu.
--
-- Targeting needs a secure button, and a secure button can only be changed outside combat. So the window keeps a fixed
-- set of invisible SecureActionButtonTemplate overlays, one per row, made once outside combat and always shown; the
-- rows you see are plain frames under them. In combat the overlays are left alone and the order of the rows is frozen
-- (IntelWindow.FreezeOrder): a player keeps his slot, one who left stays in it greyed, and a newcomer takes a free slot
-- but cannot be targeted until combat ends. A secure button never targets a name other than the one drawn over it.
-- If the window is first opened in combat, its overlays are made when combat ends (PLAYER_REGEN_ENABLED).
-- Nothing protected changes in combat: no attribute, size, position or creation of an overlay, and the row count and
-- the size (width and height) of the window are refused then. The height is owned by the row count: dragging the grip
-- only suggests a height, and on release it is turned into rows (IntelWindow.RowsForHeight) and snapped to them.
--
-- The decisions (FreezeOrder, Attributes, Binder) are pure and tested; the frame code only draws what they say.
local IntelWindow = {}

local L = ns.L

-- The most rows the window can have: the overlays are made for all of them once.
IntelWindow.ROWS_MAX = 20

local ROW_HEIGHT = 22
local HEADER, TABS, PAD, FOOTER = 30, 30, 8, 20
local WIDTH, WIDTH_MIN, WIDTH_MAX = 340, 260, 700
local WARNING_SECONDS = 6
local WARNING_WIDTH, WARNING_HEIGHT = 380, 44

-- ---------------------------------------------------------------------------------------------------------------
-- Pure decisions

-- Who is drawn in each slot while the secure buttons cannot change. `bound` = the name each slot's button targets
-- (nil or false for a free slot), `rows` = the players to show, in order (each has a `name`), `size` = the number of
-- slots (default #bound). Returns `slots` (slot -> { name, row, state }) and the number of players that found no
-- slot. The states: "bound" (the player the button targets), "left" (the button still targets a player who is not in
-- `rows` any more: he stays, greyed, and has no `row`) and "new" (a player in a free slot: nothing targets him).
function IntelWindow.FreezeOrder(bound, rows, size)
  size = size or #bound
  local slots, taken, indexOf = {}, {}, {}
  for index, row in ipairs(rows) do
    indexOf[row.name] = index
  end
  for slot = 1, size do
    local name = bound[slot]
    if name then
      local index = indexOf[name]
      if index and not taken[index] then
        taken[index] = true
        slots[slot] = { name = name, row = rows[index], state = "bound" }
      else
        slots[slot] = { name = name, state = "left" }
      end
    end
  end
  local slot, overflow = 1, 0
  for index, row in ipairs(rows) do
    if not taken[index] then
      while slot <= size and slots[slot] do
        slot = slot + 1
      end
      if slot <= size then
        slots[slot] = { name = row.name, row = row, state = "new" }
        slot = slot + 1
      else
        overflow = overflow + 1
      end
    end
  end
  return slots, overflow
end

local MODIFIERS = { "shift-", "ctrl-", "alt-", "shift-ctrl-", "shift-alt-", "ctrl-alt-", "shift-ctrl-alt-" }

-- The attributes of the secure button of a row, as a list of { attribute, value }: a left click runs
-- `/targetexact <name>`, and every modified left click is set to an empty type, so the button does nothing for them
-- (the window handles Shift, Ctrl and the right button in PostClick). A nil name, or one that is not a clean name,
-- clears them all: the button then does nothing.
function IntelWindow.Attributes(name)
  local list = {}
  local clean = type(name) == "string" and ns.IntelModel.CleanName(name) == name
  list[1] = { "type1", clean and "macro" or nil }
  list[2] = { "macrotext1", clean and ("/targetexact " .. name) or nil }
  for _, prefix in ipairs(MODIFIERS) do
    list[#list + 1] = { prefix .. "type1", clean and "" or nil }
  end
  return list
end

-- Binds the secure buttons to the rows. deps = { size, canBind = function() -> true outside combat with the buttons
-- made, apply = function(slot, name) (sets or clears the attributes of one button) }. While the buttons can be
-- bound, slot n targets row n and what is drawn is exactly that; otherwise nothing is touched and the order is frozen.
local Binder = {}
Binder.__index = Binder
IntelWindow.Binder = Binder

function Binder.New(deps)
  return setmetatable({ deps = deps, bound = {}, size = deps.size or 0 }, Binder)
end

-- The slots to draw for `rows` (see FreezeOrder), plus the number of players with no slot.
function Binder:Update(rows)
  if not self.deps.canBind() then
    return IntelWindow.FreezeOrder(self.bound, rows, self.size)
  end
  local slots = {}
  for slot = 1, self.size do
    local row = rows[slot]
    local name = row and row.name or nil
    if self.bound[slot] ~= name then
      self.deps.apply(slot, name)
      self.bound[slot] = name
    end
    if row then
      slots[slot] = { name = name, row = row, state = "bound" }
    end
  end
  return slots, math.max(0, #rows - self.size)
end

-- Changes the number of slots; the buttons of the slots that go are cleared. Refused when they cannot be bound.
-- Returns true, or false plus "combat".
function Binder:Resize(size)
  if size == self.size then
    return true
  end
  if not self.deps.canBind() then
    return false, "combat"
  end
  for slot = size + 1, self.size do
    if self.bound[slot] then
      self.deps.apply(slot, nil)
      self.bound[slot] = nil
    end
  end
  self.size = size
  return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window

local frame, binder, eventFrame
local rowFrames, overlays = {}, {}
local drawn = {}
local overlaysBuilt = false
local pendingLayout = false
local applied = 0
local mode = "nearby"
local muteButton

local function settings()
  return ns.Settings.Intel(ns.db)
end

local function inCombat()
  return ns.Platform.IsInCombat()
end

-- Tells the player what an action answered, in the chat (the window has no banner).
local function say(lines)
  local text = ns.Validate.IsFailure(lines) and ns.L("Not done: ") .. tostring(lines[1]) or lines[1]
  if text then
    print("Nrage Assistant: " .. text)
  end
  for index = 2, #lines do
    if lines[index] and not ns.Validate.IsFailure(lines) then
      print("Nrage Assistant: " .. lines[index])
    end
  end
end

local function actionDeps()
  return {
    commands = ns.intelCommands,
    service = ns.intel,
    directory = ns.intelDirectory,
    alerts = ns.intelAlerts,
  }
end

local function rowCount()
  return applied > 0 and applied or settings().window.rows
end

local function windowHeight(rows)
  return HEADER + TABS + rows * ROW_HEIGHT + FOOTER + PAD
end

-- The rows that fit a window of `height`: the nearest whole row, kept between 1 and ROWS_MAX. A value that is not a
-- number (or is NaN) gives 1, the smallest window.
function IntelWindow.RowsForHeight(height)
  if type(height) ~= "number" or height ~= height then
    return 1
  end
  local rows = math.floor((height - windowHeight(0)) / ROW_HEIGHT + 0.5)
  return math.min(IntelWindow.ROWS_MAX, math.max(1, rows))
end

-- Does an open bounty (an active mission of the season that names this player) exist? Read when a row is drawn.
local function hasBounty(key)
  local season = ns.pvpSeason
  if not (key and season) then
    return false
  end
  local active = season:ActiveSeason()
  if not active then
    return false
  end
  return ns.ViewModel.PvPBountyKeys(season:Missions(active.id))[key] == true
end

-- The text of a row (its name, level, guild and age), in the colours of the kit.
local function drawRow(index, slot)
  local Kit = ns.Kit
  local row = rowFrames[index]
  if not row then
    return
  end
  if not slot then
    drawn[index] = nil
    row:Hide()
    return
  end
  local data = slot.row or drawn[index]
  if slot.row then
    drawn[index] = slot.row
  end
  if not data then
    row:Hide()
    return
  end
  row:Show()
  local class = Kit.Theme.ClassColor(data.class)
  Kit.SetTextColor(row.name, class or "dim")
  row.name:SetText(data.nameText)
  row.level:SetText(data.levelText or "")
  row.guild:SetText(data.guildText or "")
  row.age:SetText(data.ageText or "")
  if class then
    row.bar:SetColorTexture(class[1], class[2], class[3], 1)
  else
    row.bar:SetColorTexture(Kit.Theme.Color("border"))
  end
  local bounty = hasBounty(data.key)
  row.mark:SetText((data.kos or data.stealth or bounty) and "!" or "")
  Kit.SetTextColor(row.mark, data.kos and "danger" or "warning")
  local alpha = 1
  if slot.state == "left" then
    alpha = 0.35
  elseif slot.state == "new" then
    alpha = 0.75
  elseif data.faded then
    alpha = 0.5
  end
  row:SetAlpha(alpha)
end

local function showTooltip(index)
  local data = drawn[index]
  if not (data and GameTooltip) then
    return
  end
  local Kit = ns.Kit
  local kosEntry = ns.intel and select(2, ns.intel:IsKos(data.key)) or nil
  GameTooltip:SetOwner(rowFrames[index], "ANCHOR_RIGHT")
  for line, entry in ipairs(ns.ViewModel.IntelRowTooltip(data, kosEntry, hasBounty(data.key))) do
    local color = Kit.Theme.colors[entry.color]
    if line == 1 then
      color = Kit.Theme.ClassColor(data.class) or color
    end
    GameTooltip:AddLine(entry.text, color[1], color[2], color[3], true)
  end
  GameTooltip:Show()
end

local function hideTooltip()
  if GameTooltip then
    GameTooltip:Hide()
  end
end

local function openMenu(index, data)
  local ui = ns.UI
  local platform = ns.Platform
  local ctx = {
    role = ui.Role(),
    actor = platform.GetIdentityKey(),
    group = platform.GroupDistribution(),
    inGuild = platform.IsInGuild(),
    guildEntry = ns.intel and ns.intel.guildKos[data.key] or nil,
  }
  ns.Kit.Menu.Open(rowFrames[index], ns.ViewModel.IntelMenu(data, ctx), function(value)
    say(ns.ViewModel.IntelRun(value, data, actionDeps()))
    IntelWindow.Refresh()
  end)
end

-- A click that the secure button did not handle: Shift, Ctrl and the right button. The left click targets, and that is
-- the secure button's job (it ran before this).
local function onClick(index, button)
  local data = drawn[index]
  if not (data and ns.intel and ns.intelCommands) then
    return
  end
  local shift, ctrl = ns.Platform.ModifierKeys()
  local action = ns.ViewModel.IntelClick(button, shift, ctrl)
  if action == "menu" then
    openMenu(index, data)
  elseif action == "kos" or action == "ignore" then
    say(ns.ViewModel.IntelRun(action, data, actionDeps()))
    IntelWindow.Refresh()
  end
end

local function makeRow(index)
  local Kit = ns.Kit
  local row = CreateFrame("Frame", nil, frame)
  row:SetHeight(ROW_HEIGHT)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints(row)
  row.bg:SetColorTexture(0, 0, 0, index % 2 == 0 and Kit.Theme.colors.stripe[4] or 0)
  row.hover = row:CreateTexture(nil, "BACKGROUND")
  row.hover:SetAllPoints(row)
  row.hover:SetColorTexture(Kit.Theme.Color("hover"))
  row.hover:Hide()
  row.bar = row:CreateTexture(nil, "ARTWORK")
  row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
  row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 3)
  row.bar:SetWidth(3)
  local function text(justify)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(Kit.Theme.StyleFont("small"))
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    Kit.SetTextColor(fs, "text")
    return fs
  end
  row.mark = text("CENTER")
  row.mark:SetPoint("LEFT", row, "LEFT", 6, 0)
  row.mark:SetWidth(10)
  row.name = text("LEFT")
  row.name:SetPoint("LEFT", row, "LEFT", 18, 0)
  row.age = text("RIGHT")
  row.age:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.age:SetWidth(34)
  Kit.SetTextColor(row.age, "muted")
  row.level = text("RIGHT")
  row.level:SetPoint("RIGHT", row.age, "LEFT", -2, 0)
  row.level:SetWidth(28)
  Kit.SetTextColor(row.level, "dim")
  row.guild = text("LEFT")
  row.guild:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
  row.guild:SetPoint("RIGHT", row.level, "LEFT", -4, 0)
  Kit.SetTextColor(row.guild, "muted")
  row:Hide()
  rowFrames[index] = row
  return row
end

-- The width of the names follows the width of the window.
local function layoutTexts()
  local inner = (frame:GetWidth() or WIDTH) - 2 * PAD
  for _, row in ipairs(rowFrames) do
    row.name:SetWidth(math.max(60, math.floor(inner * 0.38)))
  end
end

local function placeRows()
  local count = rowCount()
  for index, row in ipairs(rowFrames) do
    row:ClearAllPoints()
    if index <= count then
      local top = -(HEADER + TABS + (index - 1) * ROW_HEIGHT)
      row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, top)
      row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, top)
    else
      row:Hide()
    end
  end
  for index, overlay in ipairs(overlays) do
    overlay:SetShown(index <= count)
  end
  frame:SetHeight(windowHeight(count))
  layoutTexts()
  frame.empty:ClearAllPoints()
  frame.empty:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 6, -(HEADER + TABS + 4))
  frame.empty:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD - 6, -(HEADER + TABS + 4))
  frame.more:ClearAllPoints()
  frame.more:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD + 6, PAD)
  frame.shape:Resize()
end

-- Sets the size and the places of the rows. The overlays are protected, so once they exist this waits for the end of
-- combat.
local function layout()
  if overlaysBuilt and inCombat() then
    pendingLayout = true
    return false
  end
  pendingLayout = false
  placeRows()
  return true
end

local function applyAttributes(slot, name)
  local overlay = overlays[slot]
  if not overlay then
    return
  end
  for _, pair in ipairs(IntelWindow.Attributes(name)) do
    overlay:SetAttribute(pair[1], pair[2])
  end
end

-- The invisible secure buttons over the rows. Outside combat only; once made they stay. Returns true when they exist.
local function buildOverlays()
  if overlaysBuilt then
    return true
  end
  if inCombat() or not frame then
    return false
  end
  for index = 1, IntelWindow.ROWS_MAX do
    local overlay = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
    overlay:RegisterForClicks("AnyUp")
    overlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    local row = rowFrames[index]
    -- Anchored to the window, at the fixed place of its row, and never to the row: a frame a protected frame depends
    -- on cannot be moved in combat, and the rows are plain frames that are drawn again then.
    local top = -(HEADER + TABS + (index - 1) * ROW_HEIGHT)
    overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, top)
    overlay:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, top)
    overlay:SetHeight(ROW_HEIGHT)
    overlay:SetScript("PostClick", function(_, button)
      onClick(index, button)
    end)
    overlay:SetScript("OnEnter", function()
      row.hover:Show()
      showTooltip(index)
    end)
    overlay:SetScript("OnLeave", function()
      row.hover:Hide()
      hideTooltip()
    end)
    overlays[index] = overlay
    applyAttributes(index, nil)
  end
  overlaysBuilt = true
  return true
end

local function savePlace()
  local status = frame.status
  if not status then
    return
  end
  status.width = frame:GetWidth()
  local left, top = frame:GetLeft(), frame:GetTop()
  if type(left) == "number" and type(top) == "number" then
    status.left, status.top = left, top
  end
end

local function setMode(value)
  mode = value
  IntelWindow.Refresh()
end

local function refreshButtons()
  if muteButton then
    local on = settings().sound
    muteButton.opts.tooltip = on and L("Mute the alert sounds") or L("Turn the alert sounds on")
    muteButton.opts.color = on and nil or "danger"
    muteButton:refresh()
  end
end

local function buildHeader()
  local Kit = ns.Kit
  local title = frame:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -9)
  title:SetFontObject(Kit.Theme.StyleFont("window"))
  Kit.SetTextColor(title, "text")
  title:SetText(L("Intel"))
  frame.title = title

  local right = 4
  local function button(opts)
    local widget = Kit.IconButton(frame, opts)
    widget:Layout(24)
    widget.frame:ClearAllPoints()
    widget.frame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -right, -3)
    right = right + 26
    return widget
  end
  button({
    icon = "close",
    size = 24,
    tooltip = L("Close"),
    onClick = function()
      IntelWindow.Hide()
    end,
  })
  button({
    icon = "list",
    size = 24,
    tooltip = L("Open the Intel tab"),
    onClick = function()
      if ns.UI.OpenIntelTab then
        ns.UI.OpenIntelTab("nearby")
      end
    end,
  })
  muteButton = button({
    icon = "alert",
    size = 24,
    tooltip = L("Mute the alert sounds"),
    onClick = function()
      local current = settings()
      current.sound = not current.sound
      refreshButtons()
    end,
  })
  button({
    icon = "trash",
    size = 24,
    tooltip = L("Clear who is nearby"),
    onClick = function()
      if ns.intelCommands then
        ns.intelCommands:Clear()
        ns.intelCommands:Changed()
      end
      IntelWindow.Refresh()
    end,
  })

  local bar = Kit.Row(frame, { gap = 4, align = "center" })
  Kit.Segmented(bar, {
    items = ns.ViewModel.IntelWindowModes(),
    value = mode,
    layout = { weight = 1 },
    onChange = setMode,
  })
  frame.bar = bar
end

local function placeBar()
  local width = (frame:GetWidth() or WIDTH) - 2 * PAD
  frame.bar:Layout(width)
  ns.Kit.Place(frame.bar, frame, PAD, HEADER)
end

local setRows -- defined below; the grip needs it

local function buildFrame()
  local Kit = ns.Kit
  frame = CreateFrame("Frame", "NrageAssistantIntelWindow", UIParent)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetPoint("LEFT", UIParent, "LEFT", 40, 0)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(WIDTH_MIN, windowHeight(1), WIDTH_MAX, windowHeight(IntelWindow.ROWS_MAX))
  elseif frame.SetMinResize then
    frame:SetMinResize(WIDTH_MIN, windowHeight(1))
    if frame.SetMaxResize then
      frame:SetMaxResize(WIDTH_MAX, windowHeight(IntelWindow.ROWS_MAX))
    end
  end
  frame.shape = Kit.Shape.New(frame, { cut = "md" })
  frame.shape:SetFill("bg")
  frame.shape.border:SetColor("border")
  frame:SetSize(WIDTH, windowHeight(8))

  for index = 1, IntelWindow.ROWS_MAX do
    makeRow(index)
  end
  frame.empty = frame:CreateFontString(nil, "OVERLAY")
  frame.empty:SetFontObject(Kit.Theme.StyleFont("small"))
  frame.empty:SetJustifyH("LEFT")
  Kit.SetTextColor(frame.empty, "muted")
  frame.more = frame:CreateFontString(nil, "OVERLAY")
  frame.more:SetFontObject(Kit.Theme.StyleFont("small"))
  frame.more:SetJustifyH("LEFT")
  Kit.SetTextColor(frame.more, "muted")
  buildHeader()

  -- Moving and sizing the window moves and resizes the overlays anchored to its rows: never in combat, and not when it
  -- is locked.
  frame:SetScript("OnDragStart", function(self)
    if settings().window.locked or inCombat() then
      return
    end
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePlace()
  end)
  frame:SetScript("OnSizeChanged", function()
    layoutTexts()
    placeBar()
  end)
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  grip.texture = grip:CreateTexture(nil, "OVERLAY")
  grip.texture:SetAllPoints(grip)
  Kit.Icons.Apply(grip.texture, "chevron", "muted")
  grip.texture:SetRotation(-math.pi / 4)
  -- The height follows the rows: on release the dragged height becomes a row count and the window snaps to it. Only
  -- when the drag really started (not locked, not in combat); setRows is refused if combat began meanwhile.
  local sizing = false
  grip:SetScript("OnMouseDown", function()
    if not (settings().window.locked or inCombat()) then
      sizing = true
      frame:StartSizing("BOTTOMRIGHT")
    end
  end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    if sizing then
      sizing = false
      local rows = IntelWindow.RowsForHeight(frame:GetHeight())
      if setRows(rows) then
        settings().window.rows = rows
      end
    end
    savePlace()
    placeBar()
    IntelWindow.Refresh()
  end)
  frame.grip = grip

  ns.UI.ApplyWindowStatus({
    SetStatusTable = function(_, status)
      frame.status = status
      local width = type(status.width) == "number" and math.min(WIDTH_MAX, math.max(WIDTH_MIN, status.width)) or WIDTH
      frame:SetWidth(width)
      if type(status.left) == "number" and type(status.top) == "number" then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", status.left, status.top)
      end
    end,
  }, "intelWindow", WIDTH, 0)

  binder = Binder.New({
    size = 0,
    canBind = function()
      return overlaysBuilt and not inCombat()
    end,
    apply = applyAttributes,
  })
  frame:Hide()
end

-- Gives the window `count` rows. Refused (false) while the overlays exist and combat lasts. The overlays that do not
-- exist yet hold no name, so their count can change at any time.
function setRows(count)
  if overlaysBuilt and inCombat() then
    return false
  end
  if not binder:Resize(count) then
    binder.size = count
  end
  applied = count
  return layout()
end

-- Makes the window the first time (the plain parts always; the overlays outside combat).
local function ensure()
  if not frame then
    buildFrame()
  end
  buildOverlays()
  if applied == 0 then
    setRows(settings().window.rows)
  else
    layout()
  end
  placeBar()
  refreshButtons()
end

-- Draws the window again from the lists. Cheap when it is hidden.
function IntelWindow.Refresh()
  if not (frame and frame:IsShown() and ns.intel) then
    return
  end
  local current = settings()
  if current.window.rows ~= applied then
    setRows(current.window.rows)
  end
  local platform = ns.Platform
  local view = ns.ViewModel.IntelWindowView(mode, {
    service = ns.intel,
    nearby = ns.IntelNearby(),
    now = platform.ServerTime(),
    limit = applied,
    role = ns.UI.Role(),
    actor = platform.GetIdentityKey(),
    formatDate = platform.FormatDate,
  })
  local slots = binder:Update(view.rows)
  for index = 1, IntelWindow.ROWS_MAX do
    drawRow(index, slots[index])
  end
  frame.empty:SetText(view.total == 0 and view.empty or "")
  frame.more:SetText(view.more > 0 and L("and %d more"):format(view.more) or "")
  refreshButtons()
end

-- The end of combat: the overlays that waited are made, the row count and the width that waited are applied.
function IntelWindow.OnRegen()
  if not frame then
    return
  end
  buildOverlays()
  if pendingLayout or overlaysBuilt then
    layout()
  end
  IntelWindow.Sync()
  IntelWindow.Refresh()
end

function IntelWindow.IsShown()
  return frame ~= nil and frame:IsShown() == true
end

-- The window is the parent of protected frames once the overlays exist, so showing or hiding it is a protected action
-- too: in combat it waits, and OnRegen follows the setting when combat ends.
local function visibilityLocked()
  return overlaysBuilt and inCombat()
end

-- Shows the window and remembers that it is shown. False when it cannot open now; in combat it opens when combat ends.
function IntelWindow.Show()
  if not (ns.active and ns.db and ns.intel) then
    return false
  end
  settings().window.shown = true
  if visibilityLocked() then
    print("Nrage Assistant: " .. L("The Intel window will change when combat ends."))
    return false
  end
  ensure()
  frame:Show()
  IntelWindow.Refresh()
  return true
end

-- Hides the window and remembers it; in combat it closes when combat ends.
function IntelWindow.Hide()
  if ns.db then
    settings().window.shown = false
  end
  if not frame then
    return
  end
  if visibilityLocked() then
    print("Nrage Assistant: " .. L("The Intel window will change when combat ends."))
    return
  end
  frame:Hide()
end

-- Starts the window when the addon activates: shows it when the player left it shown, and listens for the end of
-- combat. Runs once.
function IntelWindow.Start()
  if eventFrame then
    return
  end
  eventFrame = CreateFrame("Frame")
  ns.Platform.TryRegisterEvent(eventFrame, "PLAYER_REGEN_ENABLED")
  eventFrame:SetScript("OnEvent", function()
    if ns.active then
      pcall(IntelWindow.OnRegen)
    end
  end)
  if settings().window.shown then
    IntelWindow.Show()
  end
end

-- Follows the setting "show the window": the window opens or closes to match it.
function IntelWindow.Sync()
  if not (ns.db and ns.intel) or visibilityLocked() then
    return
  end
  local shown = settings().window.shown
  if shown and not IntelWindow.IsShown() then
    IntelWindow.Show()
  elseif not shown and IntelWindow.IsShown() then
    frame:Hide()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The warning

local warning, warningGeneration = nil, 0

local function buildWarning()
  local Kit = ns.Kit
  warning = CreateFrame("Frame", "NrageAssistantIntelWarning", UIParent)
  warning:SetFrameStrata("FULLSCREEN_DIALOG")
  warning:SetClampedToScreen(true)
  warning:SetMovable(true)
  warning:EnableMouse(true)
  warning:RegisterForDrag("LeftButton")
  warning:SetSize(WARNING_WIDTH, WARNING_HEIGHT)
  warning:SetPoint("TOP", UIParent, "TOP", 0, -170)
  warning.shape = Kit.Shape.New(warning, { cut = "md" })
  warning.shape:SetFill("bg")
  warning.text = warning:CreateFontString(nil, "OVERLAY")
  warning.text:SetPoint("LEFT", warning, "LEFT", 14, 0)
  warning.text:SetPoint("RIGHT", warning, "RIGHT", -14, 0)
  warning.text:SetFontObject(Kit.Theme.StyleFont("value"))
  warning.text:SetJustifyH("CENTER")
  warning:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  warning:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local left, top = self:GetLeft(), self:GetTop()
    if self.status and type(left) == "number" and type(top) == "number" then
      self.status.left, self.status.top = left, top
    end
  end)
  ns.UI.ApplyWindowStatus({
    SetStatusTable = function(_, status)
      warning.status = status
      if type(status.left) == "number" and type(status.top) == "number" then
        warning:ClearAllPoints()
        warning:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", status.left, status.top)
      end
    end,
  }, "intelWarning", WARNING_WIDTH, 0)
  warning:Hide()
end

-- `text` escaped, with the first "(<class name>" written in the colour of the class token `class`.
local function warningText(text, class)
  local escaped = ns.ViewModel.Escape(text)
  local name = ns.IntelModel.ClassName(class)
  local hex = ns.Kit.Theme.ClassHex(class)
  local at = name and hex and escaped:find("(" .. name, 1, true)
  if not at then
    return escaped
  end
  local from, to = at + 1, at + #name
  return escaped:sub(1, from - 1) .. "|cff" .. hex .. escaped:sub(from, to) .. "|r" .. escaped:sub(to + 1)
end

-- Shows `text` in the movable warning for a few seconds, tinted by the kind of the alert, with the name of the class
-- token `class` (optional) in the class colour. Returns false when the warning cannot be shown (the caller then falls
-- back to the error area at the top of the screen).
function IntelWindow.Warn(text, kind, class)
  if type(text) ~= "string" or not (ns.db and ns.Kit) then
    return false
  end
  local ok = pcall(function()
    if not warning then
      buildWarning()
    end
    local token = ns.ViewModel.IntelWarnColor(kind)
    warning.shape.border:SetColor(token)
    ns.Kit.SetTextColor(warning.text, token)
    warning.text:SetText(warningText(text, class))
    warning:Show()
  end)
  if not ok then
    return false
  end
  warningGeneration = warningGeneration + 1
  local generation = warningGeneration
  C_Timer.After(WARNING_SECONDS, function()
    if warning and generation == warningGeneration then
      warning:Hide()
    end
  end)
  return true
end

-- The warning that is on screen now, or nil (for the tests).
function IntelWindow.WarningFrame()
  return warning
end

-- Forgets the frames (for the tests).
function IntelWindow.Reset()
  frame, binder, eventFrame, warning = nil, nil, nil, nil
  rowFrames, overlays, drawn = {}, {}, {}
  overlaysBuilt, pendingLayout, applied, mode = false, false, 0, "nearby"
  muteButton = nil
  warningGeneration = 0
end

-- The window, for the tests.
function IntelWindow.Frame()
  return frame
end

function IntelWindow.Overlays()
  return overlays
end

function IntelWindow.Rows()
  return rowFrames
end

function IntelWindow.Drawn()
  return drawn
end

function IntelWindow.WIDTH_LIMITS()
  return WIDTH_MIN, WIDTH_MAX
end

ns.IntelWindow = IntelWindow
