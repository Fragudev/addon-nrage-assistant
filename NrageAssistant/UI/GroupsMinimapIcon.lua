local _, ns = ...

-- The Groups icon on the edge of the minimap, like the unread mail icon: it shows while another member has an open
-- group. Hovering lists the groups, a left click opens the Groups tab, and it can be dragged around the edge. Its
-- angle is saved account-wide (db.global.settings.minimapGroups). The settings and the state for the view model are
-- plain functions and are tested; Create/Refresh build and update the real frame and only run in the client.
local GroupsMinimapIcon = {}

local MinimapButton = ns.MinimapButton

-- Degrees in [0, 360). Anything that is not a usable number falls back to the groups default, not to the one of the
-- addon button.
local function normalize(angle)
  if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
    return ns.Constants.MINIMAP_GROUPS_DEFAULT_ANGLE
  end
  return MinimapButton.NormalizeAngle(angle)
end

-- The saved settings, created and repaired as needed: { angle = degrees }.
-- Returns the table stored in `db`, so changes to it are saved.
function GroupsMinimapIcon.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.minimapGroups = type(settings.minimapGroups) == "table" and settings.minimapGroups or {}
  local saved = settings.minimapGroups
  saved.angle = normalize(saved.angle)
  return saved
end

-- The state the view model reads. env = { modules, lfgBoard, lfgService, identity = function() -> own name }.
-- Every piece may be missing; nothing here raises.
function GroupsMinimapIcon.State(env)
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

local function place()
  if not button then
    return
  end
  local settings = GroupsMinimapIcon.Settings(ns.db)
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
  GroupsMinimapIcon.Settings(ns.db).angle =
    MinimapButton.AngleFromCursor(centerX, centerY, cursorX / scale, cursorY / scale)
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

-- Builds the icon once, with the layout of the addon button: a dark disc, the icon and the gold ring on top.
function GroupsMinimapIcon.Create()
  if button or not Minimap then
    return
  end

  button = CreateFrame("Button", "NrageAssistantGroupsMinimapButton", Minimap)
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
  icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon:SetPoint("CENTER", background, "CENTER", 0, 0)

  local ring = button:CreateTexture(nil, "OVERLAY")
  ring:SetSize(53, 53)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetPoint("TOPLEFT")

  -- The count of open groups, on the bottom right corner, above the ring.
  countText = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  countText:SetPoint("BOTTOMRIGHT", 2, 2)
  countText:Hide()

  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "LeftButton" then
      ns.UI.OpenTab("groups")
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
  button:Hide()

  GroupsMinimapIcon.Refresh()
end

local function refresh()
  if not button or not (ns.ViewModel and ns.ViewModel.GroupsMinimapView) then
    return
  end
  local view = ns.ViewModel.GroupsMinimapView(GroupsMinimapIcon.State({
    modules = ns.modules,
    lfgBoard = ns.lfgBoard,
    lfgService = ns.lfgService,
    identity = ns.Platform and ns.Platform.GetIdentityKey,
  }))
  lastView = view
  place()
  if view.countText then
    countText:SetText(view.countText)
    countText:Show()
  else
    countText:Hide()
  end
  if view.shown then
    button:Show()
  else
    button:Hide()
  end
  if button:IsShown() and GameTooltip:IsShown() and GameTooltip:GetOwner() == button then
    showTooltip(button)
  end
end

-- Shows or hides the icon and updates its count and tooltip. Does nothing before Create, and never raises.
function GroupsMinimapIcon.Refresh()
  pcall(refresh)
end

ns.GroupsMinimapIcon = GroupsMinimapIcon
