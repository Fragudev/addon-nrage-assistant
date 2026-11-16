local _, ns = ...

-- The floating Groups icon shows open groups from other guild members, independently of the minimap.
-- Hovering lists the groups, left click opens the Groups tab, right click opens the settings panel,
-- and dragging moves the icon. Position, size and visibility are saved account-wide in
-- db.global.settings.groupsIcon. Settings, offset maths and state are testable without the client;
-- Create and Refresh build and update the real frames only in WoW.
local GroupsIcon = {}

local DEFAULT_SIZE = 52
local MIN_SIZE = 32
local MAX_SIZE = 80

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Repairs missing, fractional or out-of-range sizes without requiring a WoW frame.
function GroupsIcon.NormalizeSize(size)
  if not finite(size) then
    return DEFAULT_SIZE
  end
  return math.max(MIN_SIZE, math.min(MAX_SIZE, math.floor(size + 0.5)))
end

-- The saved position and size, created and repaired as needed. Returns the table stored in db so changes persist.
function GroupsIcon.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.groupsIcon = type(settings.groupsIcon) == "table" and settings.groupsIcon or {}
  local saved = settings.groupsIcon
  if not (finite(saved.x) and finite(saved.y)) then
    saved.x = ns.Constants.GROUPS_ICON_DEFAULT_X
    saved.y = ns.Constants.GROUPS_ICON_DEFAULT_Y
  end
  saved.size = GroupsIcon.NormalizeSize(saved.size)
  -- New and existing installations default to an always-visible icon.
  -- Only an explicit false enables automatic visibility based on open groups.S
  saved.alwaysShow = saved.alwaysShow ~= false
  return saved
end

-- The offsets to save after a drag, relative to the top right of the screen.
function GroupsIcon.Offsets(right, top, screenRight, screenTop)
  return math.floor(right - screenRight + 0.5), math.floor(top - screenTop + 0.5)
end

-- The state the view model reads. Missing services and failed board queries do not raise errors.
function GroupsIcon.State(env)
  local modules = env.modules
  local board = env.lfgBoard
  local service = env.lfgService
  local ownName
  if env.identity then
    local ok, name = pcall(env.identity)
    ownName = ok and name or nil
  end
  local posts = {}
  if board then
    local ok, found = pcall(function()
      return board:Query()
    end)
    if ok and type(found) == "table" then
      posts = found
    end
  end
  return {
    -- The Groups module can be enabled before the LFG board is initialized.
    moduleEnabled = not modules or modules:IsEnabled("groups"),

    -- Group data is available only after the LFG board is initialized.
    enabled = (not modules or modules:IsEnabled("groups")) and board ~= nil and board ~= false,

    posts = posts,
    ownName = ownName,
    canApply = function(pid)
      local ok, yes = pcall(function()
        return service and service:CanApply(pid)
      end)
      return ok and yes == true
    end,
  }
end

local button, countText, lastView
local sizePanel, sizeSlider, sizeValue, alwaysShowSwitch
-- Unsaved settings edited in the panel until the user applies them.
local pendingSize, pendingAlwaysShow

-- Calculates the count badge font size and offsets relative to the icon size.
-- The default 52px icon uses a 20px font with offsets of 14 and -5.
function GroupsIcon.CountLayout(size)
  size = GroupsIcon.NormalizeSize(size)

  return {
    fontSize = math.floor(20 * size / DEFAULT_SIZE + 0.5),
    x = math.floor(14 * size / DEFAULT_SIZE + 0.5),
    y = -math.floor(5 * size / DEFAULT_SIZE + 0.5),
  }
end

-- Updates the count badge font and position to match the icon size.
-- The layout calculation is independent of WoW and covered by unit tests.
local function updateCountSize(size)
  if not countText then
    return
  end

  local layout = GroupsIcon.CountLayout(size)

  countText:SetFont("Fonts\\FRIZQT__.TTF", layout.fontSize, "THICKOUTLINE")
  countText:ClearAllPoints()
  countText:SetPoint("TOPRIGHT", button, "TOPLEFT", layout.x, layout.y)
end

local function place()
  if not button then
    return
  end
  button:ClearAllPoints()
  button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", GroupsIcon.Place())
end

-- Saves the dragged position using the button's top-right corner, preserving the screen-relative anchor.
local function save()
  local right, top = button:GetRight(), button:GetTop()
  local screenRight, screenTop = UIParent:GetRight(), UIParent:GetTop()
  if right and top and screenRight and screenTop then
    local settings = GroupsIcon.Settings(ns.db)
    settings.x, settings.y = GroupsIcon.Offsets(right, top, screenRight, screenTop)
  end
  place()
end

local function showTooltip(self)
  local view = lastView
  if not view then
    return
  end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(view.title)
  for _, line in ipairs(view.lines or {}) do
    if line.joinable then
      GameTooltip:AddLine(line.text, 0.25, 1, 0.25)
    else
      GameTooltip:AddLine(line.text, 1, 1, 1)
    end
  end
  if view.more then
    GameTooltip:AddLine(view.more, 1, 1, 1)
  end
  GameTooltip:AddLine(view.hint, 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

-- A floating button with the guild TGA and a subtle mouseover highlight; hidden until Refresh decides to show it.
function GroupsIcon.Button(name, texture)
  local round = CreateFrame("Button", name, UIParent)
  round:SetFrameStrata("MEDIUM")
  round:SetFrameLevel(8)
  round:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
  round:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  round:SetClampedToScreen(true)

  local icon = round:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(round)
  icon:SetTexture(texture)
  icon:SetTexCoord(0, 1, 0, 1)

  local highlight = round:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints(round)
  highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  highlight:SetBlendMode("ADD")

  round:Hide()
  return round
end

-- The frame of the Groups icon, or nil before Create.
function GroupsIcon.Frame()
  return button
end

-- The saved offsets from the top right of the screen.
function GroupsIcon.Place()
  local settings = GroupsIcon.Settings(ns.db)
  return settings.x, settings.y
end

-- Returns the saved size of the icon.
function GroupsIcon.Size()
  return GroupsIcon.Settings(ns.db).size
end

-- Applies and saves a new size while keeping the button's top-right anchor and position unchanged.
function GroupsIcon.SetSize(size)
  local settings = GroupsIcon.Settings(ns.db)
  settings.size = GroupsIcon.NormalizeSize(size)
  if button then
    -- Resize the icon and its count badge together.
    button:SetSize(settings.size, settings.size)
    updateCountSize(settings.size)
    place()
  end
  return settings.size
end

-- Returns whether the icon should remain visible even when no other guild member has an open group.
function GroupsIcon.AlwaysShow()
  return GroupsIcon.Settings(ns.db).alwaysShow
end

-- Saves the visibility preference and updates both the icon and its settings switch.
function GroupsIcon.SetAlwaysShow(enabled)
  local settings = GroupsIcon.Settings(ns.db)
  settings.alwaysShow = enabled == true

  -- Keep the settings switch synchronized with slash commands.
  if alwaysShowSwitch then
    alwaysShowSwitch:SetChecked(settings.alwaysShow)
  end

  GroupsIcon.Refresh()
  return settings.alwaysShow
end

-- Previews the icon size without changing the saved settings.
local function previewSize(size)
  pendingSize = GroupsIcon.NormalizeSize(size)
  if button then
    -- Preview both the icon and its count badge at the selected size.
    button:SetSize(pendingSize, pendingSize)
    updateCountSize(pendingSize)
    place()
  end
  if sizeValue then
    sizeValue:SetText(pendingSize .. " px")
  end
end

-- Discards unsaved changes and restores the saved icon size.
local function cancelSizeChanges()
  local size = GroupsIcon.Size()

  pendingSize = size
  pendingAlwaysShow = GroupsIcon.AlwaysShow()

  if button then
    -- Restore the saved dimensions of the icon and its count badge.
    button:SetSize(size, size)
    updateCountSize(size)
    place()
  end
end

-- Builds the icon settings panel with the same theme, shapes and controls as the main addon.
-- The slider is native but uses themed textures because Kit has no slider widget.
local function createSizePanel()
  if sizePanel then
    return
  end

  local Kit = ns.Kit
  local Theme = Kit.Theme
  sizePanel = CreateFrame("Frame", nil, UIParent)
  -- Provide separate rows for size, visibility and confirmation actions.
  sizePanel:SetSize(290, 280)
  sizePanel:SetFrameStrata("DIALOG")
  sizePanel:SetClampedToScreen(true)
  sizePanel:EnableMouse(true)

  -- Reevaluate the icon visibility whenever the settings panel closes.
  -- This applies automatic hiding only after the user finishes configuring it.
  sizePanel:SetScript("OnHide", function()
    GroupsIcon.Refresh()
  end)

  sizePanel:Hide()

  -- The panel uses the same cut corners and color tokens as the addon windows.
  local shape = Kit.Shape.New(sizePanel, { cut = "md" })
  shape:SetFill("panel")
  shape.border:SetColor("border")

  local title = sizePanel:CreateFontString(nil, "OVERLAY")
  title:SetFontObject(Theme.StyleFont("small"))
  Kit.SetTextColor(title, "dim")
  title:SetPoint("TOPLEFT", sizePanel, "TOPLEFT", 16, -14)
  title:SetText(ns.L("Groups icon"))

  -- A compact close button using the addon's theme colors.
  -- Closing the panel triggers its OnHide handler, which refreshes icon visibility.
  local close = CreateFrame("Button", nil, sizePanel)
  close:SetSize(24, 24)
  close:SetPoint("TOPRIGHT", sizePanel, "TOPRIGHT", -8, -7)

  local closeText = close:CreateFontString(nil, "OVERLAY")
  closeText:SetFontObject(Theme.StyleFont("body"))
  Kit.SetTextColor(closeText, "dim")
  closeText:SetPoint("CENTER", close, "CENTER", 0, 0)
  closeText:SetText("X")

  -- Highlight the close control when the cursor is over it.
  close:SetScript("OnEnter", function()
    Kit.SetTextColor(closeText, "text")
  end)

  close:SetScript("OnLeave", function()
    Kit.SetTextColor(closeText, "dim")
  end)

  close:SetScript("OnClick", function()
    sizePanel:Hide()
  end)

  sizeValue = sizePanel:CreateFontString(nil, "OVERLAY")
  sizeValue:SetFontObject(Theme.StyleFont("small"))
  Kit.SetTextColor(sizeValue, "text")
  sizeValue:SetPoint("TOPRIGHT", sizePanel, "TOPRIGHT", -18, -49)

  local sizeLabel = sizePanel:CreateFontString(nil, "OVERLAY")
  sizeLabel:SetFontObject(Theme.StyleFont("body"))
  Kit.SetTextColor(sizeLabel, "text")
  sizeLabel:SetPoint("TOPLEFT", sizePanel, "TOPLEFT", 16, -48)
  sizeLabel:SetText(ns.L("Groups icon size"))

  -- A plain slider with the theme's input track and accent-colored thumb.
  sizeSlider = CreateFrame("Slider", nil, sizePanel)
  sizeSlider:SetPoint("TOPLEFT", sizePanel, "TOPLEFT", 20, -81)
  sizeSlider:SetSize(250, 15)
  sizeSlider:SetOrientation("HORIZONTAL")
  sizeSlider:SetMinMaxValues(MIN_SIZE, MAX_SIZE)
  sizeSlider:SetValueStep(1)

  local track = sizeSlider:CreateTexture(nil, "BACKGROUND")
  track:SetTexture("Interface\\Buttons\\WHITE8X8")
  track:SetVertexColor(Theme.Color("input"))
  track:SetPoint("LEFT", sizeSlider, "LEFT", 0, 0)
  track:SetPoint("RIGHT", sizeSlider, "RIGHT", 0, 0)
  track:SetHeight(5)

  local thumb = sizeSlider:CreateTexture(nil, "OVERLAY")
  thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
  thumb:SetVertexColor(Theme.Color("accent"))
  thumb:SetSize(10, 18)
  sizeSlider:SetThumbTexture(thumb)

  -- Preview size changes without saving them until Apply is pressed.
  sizeSlider:SetScript("OnValueChanged", function(_, value)
    previewSize(value)
  end)

  local low = sizePanel:CreateFontString(nil, "OVERLAY")
  low:SetFontObject(Theme.StyleFont("small"))
  Kit.SetTextColor(low, "dim")
  low:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -2)
  low:SetText(MIN_SIZE .. " px")

  local high = sizePanel:CreateFontString(nil, "OVERLAY")
  high:SetFontObject(Theme.StyleFont("small"))
  Kit.SetTextColor(high, "dim")
  high:SetPoint("TOPRIGHT", sizeSlider, "BOTTOMRIGHT", 0, -2)
  high:SetText(MAX_SIZE .. " px")

  -- Reuse the same red switch as the addon's Settings tab.
  -- Keep visibility changes pending until the user confirms them.
  alwaysShowSwitch = Kit.Switch(sizePanel, {
    label = ns.L("Always show the Groups icon"),
    checked = GroupsIcon.AlwaysShow(),
    onChange = function(checked)
      pendingAlwaysShow = checked == true
    end,
  })
  -- Keep the visibility switch below the size controls.
  -- Leave enough space for the reset button above it.
  alwaysShowSwitch:Layout(258)
  alwaysShowSwitch.frame:SetPoint("TOPLEFT", sizePanel, "TOPLEFT", 16, -168)

  -- Reset only the pending icon size; visibility remains unchanged.
  local reset = Kit.Button(sizePanel, {
    text = ns.L("Reset icon size"),
    variant = "secondary",
    onClick = function()
      sizeSlider:SetValue(DEFAULT_SIZE)
      previewSize(DEFAULT_SIZE)
    end,
  })
  -- Place the reset button directly below the size slider.
  -- Keep it separate from the visibility preference.
  reset:Layout(145)
  reset.frame:SetPoint("TOPRIGHT", sizePanel, "TOPRIGHT", -16, -128)

  -- Apply both pending preferences and close the panel.
  local apply = Kit.Button(sizePanel, {
    text = ns.L("Apply"),
    onClick = function()
      GroupsIcon.SetSize(pendingSize)
      GroupsIcon.SetAlwaysShow(pendingAlwaysShow)
      sizePanel:Hide()
    end,
  })

  apply:Layout(100)
  apply.frame:SetPoint("BOTTOMRIGHT", sizePanel, "BOTTOMRIGHT", -16, 12)

  -- Restore the saved settings without committing pending changes.
  local cancel = Kit.Button(sizePanel, {
    text = ns.L("Cancel"),
    variant = "secondary",
    onClick = function()
      cancelSizeChanges()
      sizePanel:Hide()
    end,
  })

  cancel:Layout(100)
  cancel.frame:SetPoint("RIGHT", apply.frame, "LEFT", -8, 0)
end

-- Opens the settings panel with the saved preferences.
-- Closing it without applying discards all pending changes.
function GroupsIcon.ToggleSizeMenu()
  if not button then
    return
  end

  createSizePanel()

  -- Right-clicking again cancels the current editing session.
  if sizePanel:IsShown() then
    cancelSizeChanges()
    sizePanel:Hide()
    return
  end

  -- Start a new editing session using the saved preferences.
  pendingSize = GroupsIcon.Size()
  pendingAlwaysShow = GroupsIcon.AlwaysShow()

  -- Position the panel beside the floating Groups icon.
  sizePanel:ClearAllPoints()
  sizePanel:SetPoint("TOPRIGHT", button, "TOPLEFT", -8, 0)

  -- Synchronize the controls without saving any changes.
  sizeSlider:SetValue(pendingSize)
  sizeValue:SetText(pendingSize .. " px")
  alwaysShowSwitch:SetChecked(pendingAlwaysShow)

  sizePanel:Show()
end

-- Builds the icon once and restores the saved size, drag handlers, tooltip and mouse actions.
function GroupsIcon.Create()
  if button or not UIParent then
    return
  end

  button = GroupsIcon.Button(
    "NrageAssistantGroupsButton",
    "Interface\\AddOns\\NrageAssistant\\Media\\Icons\\groups-icon.tga"
  )
  local size = GroupsIcon.Size()
  button:SetSize(size, size)
  button:RegisterForDrag("LeftButton")
  button:SetMovable(true)

  -- Display the group count outside the icon's upper-left corner.
  -- A larger yellow font with a thick black outline keeps small counts readable.
  countText = button:CreateFontString(nil, "OVERLAY")
  countText:SetFont("Fonts\\FRIZQT__.TTF", 20, "THICKOUTLINE")
  countText:SetTextColor(1, 0.82, 0.05, 1)
  countText:SetShadowColor(0, 0, 0, 1)
  countText:SetShadowOffset(1, -1)
  -- Anchor the group count to the icon's upper-left corner.
  -- Keep a slight overlap so the badge looks attached to the icon.
  countText:SetPoint("TOPRIGHT", button, "TOPLEFT", 10, -3)
  countText:Hide()

  -- Match the badge dimensions to the saved icon size on startup.
  updateCountSize(GroupsIcon.Size())

  -- Left click opens Groups; right click opens the local size panel.
  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "LeftButton" then
      if sizePanel then
        sizePanel:Hide()
      end
      ns.UI.OpenTab("groups")
    elseif mouseButton == "RightButton" then
      GameTooltip:Hide()
      GroupsIcon.ToggleSizeMenu()
    end
  end)

  button:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    if sizePanel then
      sizePanel:Hide()
    end
    self:StartMoving()
  end)
  button:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    save()
  end)
  button:SetScript("OnEnter", showTooltip)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  GroupsIcon.Refresh()
end

local function refresh()
  if not button or not (ns.ViewModel and ns.ViewModel.GroupsIconView) then
    return
  end
  local state = GroupsIcon.State({
    modules = ns.modules,
    lfgBoard = ns.lfgBoard,
    lfgService = ns.lfgService,
    identity = ns.Platform and ns.Platform.GetIdentityKey,
  })
  local view = ns.ViewModel.GroupsIconView(state)
  lastView = view
  place()

  -- Display only the real number of open groups.
  -- The badge stays hidden when there are no groups.
  if view.countText then
    countText:SetText(view.countText)
    countText:Show()
  else
    countText:Hide()
  end

  -- Keep the icon visible while its settings panel is open.
  -- This lets users change the visibility preference without losing access
  -- to the panel before they finish configuring it.
  local panelOpen = sizePanel and sizePanel:IsShown()

  if view.shown or (GroupsIcon.AlwaysShow() and state.moduleEnabled) or panelOpen then
    button:Show()
  else
    button:Hide()
  end
  if button:IsShown() and GameTooltip:IsShown() and GameTooltip:GetOwner() == button then
    showTooltip(button)
  end
end

-- Updates the icon from the view model. Does nothing before Create and never raises.
function GroupsIcon.Refresh()
  pcall(refresh)
end

ns.GroupsIcon = GroupsIcon
