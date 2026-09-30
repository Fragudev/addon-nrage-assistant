local _, ns = ...

-- The minimap button: the guild logo inside the usual gold ring, dragged around the edge of the minimap.
-- Left click opens the window. The position and whether it is hidden are saved account-wide
-- (db.global.settings.minimap). The geometry and the settings are plain functions and are tested;
-- Create/Refresh build and update the real frame and only run in the client.
local MinimapButton = {}

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

-- Text for /nrage minimap [show|hide|reset]. Returns the line to print.
function MinimapButton.Command(db, action)
  local settings = MinimapButton.Settings(db)
  if action == "show" then
    settings.hide = false
  elseif action == "hide" then
    settings.hide = true
  elseif action == "reset" then
    settings.hide = false
    settings.angle = ns.Constants.MINIMAP_DEFAULT_ANGLE
  elseif action ~= "" then
    return "usage: /nrage minimap [show | hide | reset]"
  end
  MinimapButton.Refresh()
  return settings.hide and "minimap button hidden. Type /nrage minimap show to bring it back."
    or "minimap button shown. Drag it to move it around the minimap."
end

local button

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
  GameTooltip:AddLine("Left click: open the window", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
  GameTooltip:AddLine("/nrage minimap hide: hide it", 0.6, 0.6, 0.6)
  GameTooltip:Show()
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

  local ring = button:CreateTexture(nil, "OVERLAY")
  ring:SetSize(53, 53)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "LeftButton" then
      ns.UI.Toggle()
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
  if ns.active and not MinimapButton.Settings(ns.db).hide then
    button:Show()
  else
    button:Hide()
  end
end

ns.MinimapButton = MinimapButton
