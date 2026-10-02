local _, ns = ...

-- The minimap button: the guild logo inside the usual gold ring, dragged around the edge of the minimap.
-- Left click opens the window, right click opens a menu of shortcuts. The position and whether it is hidden
-- are saved account-wide (db.global.settings.minimap). The geometry and the settings are plain functions and
-- are tested; Create/Refresh build and update the real frame and only run in the client.
local MinimapButton = {}

local L = ns.L

-- Degrees, kept in [0, 360). Anything that is not a number falls back to the default position.
function MinimapButton.NormalizeAngle(angle)
  if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
    return ns.Constants.MINIMAP_DEFAULT_ANGLE
  end
  return angle % 360
end

-- Offset of the button from the minimap centre for an angle (0 = right, 90 = up) on a circle of `radius`.
function MinimapButton.Position(angle, radius)
  local radians = math.rad(MinimapButton.NormalizeAngle(angle))
  return math.cos(radians) * radius, math.sin(radians) * radius
end

-- The angle of the cursor around the minimap centre, in [0, 360).
function MinimapButton.AngleFromCursor(centerX, centerY, cursorX, cursorY)
  return MinimapButton.NormalizeAngle(math.deg(math.atan2(cursorY - centerY, cursorX - centerX)))
end

-- The saved settings, created and repaired as needed: { angle = degrees, hide = boolean }.
-- Returns the table stored in `db`, so changes to it are saved.
function MinimapButton.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.minimap = type(settings.minimap) == "table" and settings.minimap or {}
  local minimap = settings.minimap
  minimap.angle = MinimapButton.NormalizeAngle(minimap.angle)
  minimap.hide = minimap.hide == true
  return minimap
end

-- Shows or hides the button.
function MinimapButton.SetHidden(db, hidden)
  MinimapButton.Settings(db).hide = hidden == true
  MinimapButton.Refresh()
end

-- Brings the button back, at its default place.
function MinimapButton.ResetPosition(db)
  local settings = MinimapButton.Settings(db)
  settings.hide = false
  settings.angle = ns.Constants.MINIMAP_DEFAULT_ANGLE
  MinimapButton.Refresh()
end

local button, warning

local function place()
  if not button then
    return
  end
  local settings = MinimapButton.Settings(ns.db)
  local radius = Minimap:GetWidth() / 2 + ns.Constants.MINIMAP_RADIUS_MARGIN
  local x, y = MinimapButton.Position(settings.angle, radius)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging: follow the cursor around the minimap.
local function follow()
  local centerX, centerY = Minimap:GetCenter()
  local cursorX, cursorY = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local angle = MinimapButton.AngleFromCursor(centerX, centerY, cursorX / scale, cursorY / scale)
  MinimapButton.Settings(ns.db).angle = angle
  place()
end

local function showTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Nrage Assistant " .. ns.GetVersion())
  if ns.active and ns.character and ns.db then
    local character = ns.character
    local _, summary = ns.ReadinessService.Evaluate(ns.ReadinessRules.Current(), character.profile, character.readiness)
    local queue = ns.comm and ns.comm.queue
    for _, line in
      ipairs(ns.ViewModel.MinimapTooltip({
        events = ns.db.global.events,
        now = ns.Platform.ServerTime(),
        formatDate = ns.Platform.FormatDate,
        readinessText = summary.text,
        pending = queue and queue:Pending() or 0,
        paused = queue and queue:IsPaused() or false,
      }))
    do
      GameTooltip:AddLine(line, 1, 1, 1)
    end
  end
  if ns.selfTestFailures and #ns.selfTestFailures > 0 then
    for _, line in ipairs(ns.ViewModel.SelfTestFailures(ns.selfTestFailures)) do
      GameTooltip:AddLine(line, 1, 0.4, 0.3)
    end
  end
  GameTooltip:AddLine(L("Left click: open the window"), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(L("Right click: shortcuts and sync"), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(L("Drag: move this button"), 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

-- Right-click menu: a small frame of buttons. A full-screen invisible button behind it closes it on any
-- click outside, and Escape closes it too.
local menu, catcher
local MENU_WIDTH, ROW_HEIGHT = 140, 20

local function closeMenu()
  if menu then
    menu:Hide()
  end
  if catcher then
    catcher:Hide()
  end
end

local function runEntry(entry)
  closeMenu()
  if entry.action == "tab" then
    ns.UI.OpenTab(entry.value)
  elseif ns.comm then
    print("Nrage Assistant: " .. ns.ViewModel.SyncRequestResult(ns.comm:RequestSync()))
  end
end

local function buildMenu()
  catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("DIALOG")
  catcher:RegisterForClicks("anyUp")
  catcher:SetScript("OnClick", closeMenu)
  catcher:Hide()

  menu =
    CreateFrame("Frame", "NrageAssistantMinimapMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetClampedToScreen(true)
  if menu.SetBackdrop then
    menu:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
  end
  menu:Hide()
  table.insert(UISpecialFrames, "NrageAssistantMinimapMenu")

  local entries = ns.ViewModel.MinimapMenu()
  menu:SetSize(MENU_WIDTH, #entries * ROW_HEIGHT + 12)
  for index, entry in ipairs(entries) do
    local row = CreateFrame("Button", nil, menu)
    row:SetSize(MENU_WIDTH - 12, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 6, -6 - (index - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 4, 0)
    label:SetText(entry.text)
    row:SetScript("OnClick", function()
      runEntry(entry)
    end)
  end
end

local function showMenu()
  if not (ns.active and ns.character) then
    return
  end
  if not menu then
    buildMenu()
  end
  GameTooltip:Hide()
  local scale = UIParent:GetEffectiveScale()
  local cursorX, cursorY = GetCursorPosition()
  menu:ClearAllPoints()
  menu:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", cursorX / scale, cursorY / scale)
  catcher:Show()
  menu:Show()
end

-- Builds the button once. It follows the layout LibDBIcon-based addons use, so it looks like theirs:
-- a dark disc, the icon, and the gold ring (the tracking-button border) on top.
function MinimapButton.Create()
  if button or not Minimap then
    return
  end

  button = CreateFrame("Button", "NrageAssistantMinimapButton", Minimap)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:SetSize(31, 31)
  button:RegisterForClicks("anyUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetTexture(ns.Constants.LOGO_TEXTURE)
  icon:SetPoint("CENTER", background, "CENTER", 0, 0)

  -- A warning mark on the ring's corner while the silent self test reports a failure.
  warning = button:CreateTexture(nil, "OVERLAY", nil, 7)
  warning:SetSize(14, 14)
  warning:SetTexture("Interface\\DialogFrame\\DialogAlertIcon")
  warning:SetPoint("BOTTOMRIGHT", 2, -2)
  warning:Hide()

  local ring = button:CreateTexture(nil, "OVERLAY")
  ring:SetSize(53, 53)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "LeftButton" then
      ns.UI.Toggle()
    elseif mouseButton == "RightButton" then
      showMenu()
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", follow)
    GameTooltip:Hide()
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", showTooltip)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  MinimapButton.Refresh()
end

-- Shows the button only while the addon is active and the player has not hidden it.
function MinimapButton.Refresh()
  if not button then
    return
  end
  place()
  if ns.selfTestFailures and #ns.selfTestFailures > 0 then
    warning:Show()
  else
    warning:Hide()
  end
  if ns.active and not MinimapButton.Settings(ns.db).hide then
    button:Show()
  else
    button:Hide()
  end
end

ns.MinimapButton = MinimapButton
