local _, ns = ...

-- The Kill on Sight button by the target frame (docs/PVP_INTEL_PLAN.md section 3.4): shown while the target is an enemy
-- player, it toggles his place on the personal Kill on Sight list. It is a plain button on UIParent, anchored to
-- the target frame and never parented to it, and it is anchored outside combat only. The enemy player menu gets the
-- same action as an entry when the client has Menu.ModifyMenu.
local IntelTargetButton = {}

local L = ns.L

local SIZE = 22

-- What the button shows. args = { enabled (the setting), details (Platform.GetEnemyDetails("target") or nil), kos
-- ("personal" | "guild" | nil) }. Returns { visible, name, kos, tooltip }.
function IntelTargetButton.State(args)
  local details = args.details
  if not args.enabled or type(details) ~= "table" or type(details.name) ~= "string" then
    return { visible = false }
  end
  local name = ns.IntelModel.CleanName(details.name)
  if not name then
    return { visible = false }
  end
  local tooltip = L("Add to my Kill on Sight list")
  if args.kos == "personal" then
    tooltip = L("Remove from my Kill on Sight list")
  elseif args.kos == "guild" then
    tooltip = L("On the guild list. Click to add to yours.")
  end
  return { visible = true, name = name, kos = args.kos, tooltip = tooltip }
end

local button, eventFrame, anchored
local lastName

local function current()
  local service = ns.intel
  if not (ns.active and ns.db and service) then
    return { visible = false }
  end
  local details = ns.Platform.GetEnemyDetails("target")
  local kos = details and service:IsKos(details.name) or nil
  return IntelTargetButton.State({ enabled = ns.Settings.Intel(ns.db).targetButton, details = details, kos = kos })
end

local function toggle()
  local state = current()
  if not (state.visible and ns.intelCommands) then
    return
  end
  local row = { name = state.name, key = ns.IntelModel.Key(state.name), kos = state.kos }
  local lines = ns.ViewModel.IntelRun("kos", row, {
    commands = ns.intelCommands,
    service = ns.intel,
    alerts = ns.intelAlerts,
  })
  if lines[1] then
    print("Nrage Assistant: " .. tostring(lines[1]))
  end
  IntelTargetButton.Refresh()
end

-- Anchors the button to the target frame. Outside combat only; returns true when it is anchored.
local function anchor()
  if anchored then
    return true
  end
  if ns.Platform.IsInCombat() or not TargetFrame then
    return false
  end
  button.frame:ClearAllPoints()
  button.frame:SetPoint("TOPLEFT", TargetFrame, "TOPRIGHT", -4, -14)
  anchored = true
  return true
end

local function build()
  button = ns.Kit.IconButton(UIParent, {
    icon = "swords",
    size = SIZE,
    tooltip = L("Add to my Kill on Sight list"),
    variant = "secondary",
    onClick = toggle,
  })
  button:Layout(SIZE)
  button.frame:SetFrameStrata("MEDIUM")
  button.frame:Hide()
end

-- Shows or hides the button to match the target, and tints it when the target is on a list.
function IntelTargetButton.Refresh()
  local state = current()
  if not state.visible then
    if button then
      button.frame:Hide()
    end
    return
  end
  if not button then
    build()
  end
  if not anchor() then
    -- The target frame cannot be used in combat: the button shows up when combat ends.
    button.frame:Hide()
    return
  end
  button.opts.tooltip = state.tooltip
  button.opts.color = state.kos and "danger" or nil
  button:refresh()
  lastName = state.name
  button.frame:Show()
end

-- The kit widget of the button, or nil before it was made (for the tests).
function IntelTargetButton.Widget()
  return button
end

-- The name the button was last shown for (for the tests).
function IntelTargetButton.LastName()
  return lastName
end

-- Listens for target changes and adds the menu entry. Runs once.
function IntelTargetButton.Start()
  if eventFrame then
    return
  end
  eventFrame = CreateFrame("Frame")
  ns.Platform.TryRegisterEvent(eventFrame, "PLAYER_TARGET_CHANGED")
  ns.Platform.TryRegisterEvent(eventFrame, "PLAYER_REGEN_ENABLED")
  eventFrame:SetScript("OnEvent", function()
    pcall(IntelTargetButton.Refresh)
  end)
  ns.Platform.AddEnemyPlayerMenuEntry(function(name)
    local kos = ns.intel and ns.intel:IsKos(name) or nil
    return kos == "personal" and L("Remove from my Kill on Sight list") or L("Add to my Kill on Sight list")
  end, function(name)
    if not (ns.active and ns.intel and ns.intelCommands) then
      return
    end
    local key = ns.IntelModel.Key(name)
    if key then
      local lines = ns.ViewModel.IntelRun(
        "kos",
        { name = name, key = key, kos = ns.intel:IsKos(key) },
        { commands = ns.intelCommands, service = ns.intel, alerts = ns.intelAlerts }
      )
      if lines[1] then
        print("Nrage Assistant: " .. tostring(lines[1]))
      end
    end
  end)
end

-- Forgets the frames (for the tests).
function IntelTargetButton.Reset()
  button, eventFrame, anchored, lastName = nil, nil, nil, nil
end

ns.IntelTargetButton = IntelTargetButton
