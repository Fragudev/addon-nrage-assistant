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
    local rules = ns.ReadinessRules.Current(ns.UI.OwnRosterId())
    local _, summary = ns.ReadinessService.Evaluate(rules, character.profile, character.readiness)
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
  -- The enemies nearby, from Intel.
  if ns.active and ns.intel and ns.IntelNearby then
    for _, line in ipairs(ns.ViewModel.IntelMinimapLines(ns.IntelNearby())) do
      GameTooltip:AddLine(line, 1, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(L("Left click: open the window"), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(L("Right click: shortcuts"), 0.6, 0.6, 0.6)
  GameTooltip:AddLine(L("Drag: move this button"), 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

-- Right-click menu: the popover menu of the kit (dark, closes on a click outside or Escape) with the tabs the role can
-- open, like the sidebar, the Intel window toggle, and the settings.
local function showMenu()
  if not (ns.active and ns.character) then
    return
  end
  GameTooltip:Hide()
  local entries = ns.ViewModel.MinimapMenu(ns.UI.Role(), ns.UI.OwnRosterId())
  local items, byValue = {}, {}
  for _, entry in ipairs(entries) do
    items[#items + 1] = { value = entry.value, text = entry.text, icon = entry.icon }
    byValue[entry.value] = entry
  end
  ns.Kit.Menu.Open(button, items, function(value)
    local entry = byValue[value]
    if entry and entry.action == "tab" then
      ns.UI.OpenTab(entry.value)
    elseif entry and entry.action == "intel" then
      if ns.IntelWindow and ns.IntelWindow.IsShown() then
        ns.UI.IntelHide()
      else
        ns.UI.IntelShow()
      end
    elseif entry and entry.action == "settings" then
      ns.UI.OpenSettings()
    end
  end, { point = "BOTTOMRIGHT" })
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

-- The tooltip of the minimap lists the players under the cursor. This adds the level and class of the enemies Intel
-- knows and, with the setting, feeds them to Nearby (docs/PVP_INTEL_PLAN.md section 3.4). The lines are read as plain
-- text; a line that is secret or unreadable makes the whole pass do nothing. deps = { service, settings = function() ->
-- Settings.Intel, feed = function(details) }. Runs once; returns true when the hook was installed. Not measured yet
-- (M11).
local tooltipHooked = false
local addingLines = false

-- A plain copy of text from the client, or nil.
local function plain(value)
  local ok, copy = pcall(function()
    if type(value) == "string" then
      return value .. ""
    end
    return nil
  end)
  return ok and copy or nil
end

local function tooltipLines()
  local lines = {}
  for index = 1, math.min(GameTooltip:NumLines() or 0, 40) do
    local left = _G["GameTooltipTextLeft" .. index]
    local text = left and plain(left:GetText())
    if text then
      local r, g, b = left:GetTextColor()
      lines[#lines + 1] = { text = text, r = r, g = g, b = b, index = index }
    end
  end
  return lines
end

local function annotate(deps)
  local owner = GameTooltip:GetOwner()
  if addingLines or owner == nil or not (owner == Minimap or owner == MinimapCluster) or not ns.active then
    return
  end
  local settings = deps.settings()
  if not (settings.minimapTooltip or settings.minimapFeed) then
    return
  end
  local names = ns.IntelMinimapTooltip.Parse(tooltipLines())
  local plan = ns.IntelMinimapTooltip.Plan(names, deps.service, settings)
  for _, details in ipairs(plan.feed) do
    deps.feed(details)
  end
  if #plan.extras > 0 then
    addingLines = true
    for _, extra in ipairs(plan.extras) do
      GameTooltip:AddLine(extra.name .. ": " .. extra.text, 0.8, 0.8, 0.8)
    end
    -- Showing again makes the tooltip grow to the new lines.
    GameTooltip:Show()
    addingLines = false
  end
end

function MinimapButton.HookTooltip(deps)
  if tooltipHooked or not (GameTooltip and GameTooltip.HookScript) then
    return false
  end
  tooltipHooked = true
  GameTooltip:HookScript("OnShow", function()
    -- Whatever goes wrong here must never reach the game's own tooltip.
    if not pcall(annotate, deps) then
      addingLines = false
    end
  end)
  return true
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
