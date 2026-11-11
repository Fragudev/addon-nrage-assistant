local _, ns = ...

-- The Groups icon, like the unread mail icon but floating on the screen instead of on the minimap, so it also works
-- with UIs that replace or reshape the minimap: it shows while another member has an open group. Hovering lists the
-- groups, a left click opens the Groups tab, and it can be dragged anywhere. Its position (offsets of its top right
-- corner from the top right of the screen) is saved account-wide (db.global.settings.groupsIcon). The settings, the
-- offset maths and the state for the view model are plain functions and are tested; Create/Refresh build and update
-- the real frame and only run in the client.
local GroupsIcon = {}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The saved settings, created and repaired as needed: { x = offset, y = offset }. An unusable pair falls back to the
-- default place. Returns the table stored in `db`, so changes to it are saved.
function GroupsIcon.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.groupsIcon = type(settings.groupsIcon) == "table" and settings.groupsIcon or {}
  local saved = settings.groupsIcon
  if not (finite(saved.x) and finite(saved.y)) then
    saved.x = ns.Constants.GROUPS_ICON_DEFAULT_X
    saved.y = ns.Constants.GROUPS_ICON_DEFAULT_Y
  end
  return saved
end

-- The offsets to save after a drag: where the icon's top right corner ended, relative to the top right of the screen.
-- Both pairs must be in the same coordinates (the icon is a child of UIParent at scale 1, so its own are fine).
function GroupsIcon.Offsets(right, top, screenRight, screenTop)
  return math.floor(right - screenRight + 0.5), math.floor(top - screenTop + 0.5)
end

-- The state the view model reads. env = { modules, lfgBoard, lfgService, identity = function() -> own name }.
-- Every piece may be missing; nothing here raises.
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
  local settings = GroupsIcon.Settings(ns.db)
  button:ClearAllPoints()
  button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", settings.x, settings.y)
end

-- After a drag: keep where it was dropped, anchored again to the top right so it stays put when the screen changes.
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

-- Builds the icon once, with the layout of the minimap button: a dark disc, the icon and the gold ring on top.
function GroupsIcon.Create()
  if button or not UIParent then
    return
  end

  button = CreateFrame("Button", "NrageAssistantGroupsButton", UIParent)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:SetSize(31, 31)
  button:RegisterForClicks("anyUp")
  button:RegisterForDrag("LeftButton")
  button:SetMovable(true)
  button:SetClampedToScreen(true)
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
    GameTooltip:Hide()
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
  button:Hide()

  GroupsIcon.Refresh()
end

local function refresh()
  if not button or not (ns.ViewModel and ns.ViewModel.GroupsIconView) then
    return
  end
  local view = ns.ViewModel.GroupsIconView(GroupsIcon.State({
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
function GroupsIcon.Refresh()
  pcall(refresh)
end

ns.GroupsIcon = GroupsIcon
