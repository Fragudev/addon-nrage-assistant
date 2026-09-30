local _, ns = ...

-- Main window (AceGUI). A thin layer: what to show comes from ViewModel and the domain services,
-- so nothing here needs unit tests beyond loading cleanly. Client only.
local UI = {}

local frame
local tabs
local currentTab = "home"
local statusMessage

local function Release()
  if frame then
    LibStub("AceGUI-3.0"):Release(frame)
  end
  frame, tabs = nil, nil
end

local function AddLines(container, lines)
  local AceGUI = LibStub("AceGUI-3.0")
  for _, text in ipairs(lines) do
    local label = AceGUI:Create("Label")
    label:SetText(text == "" and " " or text)
    label:SetFullWidth(true)
    container:AddChild(label)
  end
end

local function AddHeading(container, text)
  local heading = LibStub("AceGUI-3.0"):Create("Heading")
  heading:SetText(text)
  heading:SetFullWidth(true)
  container:AddChild(heading)
end

local function Redraw()
  if tabs then
    tabs:SelectTab(currentTab)
  end
end

local function EscapeAll(lines)
  local escaped = {}
  for index, line in ipairs(lines) do
    escaped[index] = ns.ViewModel.Escape(line)
  end
  return escaped
end

local function ReadinessSummary()
  local character = ns.character
  local _, summary = ns.ReadinessService.Evaluate(ns.Constants.DEFAULT_RULES, character.profile, character.readiness)
  return summary
end

local function DrawHome(container)
  AddLines(container, ns.ViewModel.Home({
    version = ns.GetVersion(),
    syncLines = ns.comm and ns.comm:Status() or { "sync not started" },
    readinessText = ReadinessSummary().text,
  }))
end

local function DrawProfile(container)
  local AceGUI = LibStub("AceGUI-3.0")
  local character = ns.character

  AddHeading(container, "Your profile")
  AddLines(container, EscapeAll(ns.ProfileService.Describe(character.profile)))

  AddHeading(container, "What you agree to share")
  for _, key in ipairs(ns.PublishService.CONSENT_KEYS) do
    local box = AceGUI:Create("CheckBox")
    box:SetLabel(key)
    box:SetValue(character.consent[key] and true or false)
    box:SetCallback("OnValueChanged", function(_, _, value)
      ns.PublishService.SetConsent(character.consent, key, value)
      Redraw()
    end)
    container:AddChild(box)
  end

  AddHeading(container, "Preview of what would be published")
  AddLines(container, EscapeAll(ns.PublishService.Describe(character.profile, character.consent)))
  AddLines(container, { "Addon messages are not private: any guild member with the addon can read them." })

  local button = AceGUI:Create("Button")
  button:SetText("Publish")
  button:SetCallback("OnClick", function()
    local ok, reason = ns.PublishService.Publish(ns.comm, character, ns.Platform)
    statusMessage = ok and "Profile published to the guild." or ("Not published: " .. ns.ViewModel.PublishError(reason))
    Redraw()
  end)
  container:AddChild(button)

  if statusMessage then
    AddLines(container, { ns.ViewModel.Escape(statusMessage) })
  end
end

local function DrawReady(container)
  local character = ns.character
  local results, summary = ns.ReadinessService.Evaluate(ns.Constants.DEFAULT_RULES, character.profile,
    character.readiness)
  AddLines(container, EscapeAll(ns.ReadinessService.Describe(results, summary)))
  AddLines(container, { "", "Confirm manual items with /nrage ready set <item> <met|missing|waived|unknown>." })
end

local function DrawRoster(container)
  AddLines(container, ns.ViewModel.Roster(ns.db.global.roster, ns.Platform.ServerTime()))
end

local DRAWERS = {
  home = DrawHome,
  profile = DrawProfile,
  ready = DrawReady,
  roster = DrawRoster,
}

local function OnTabSelected(container, _, group)
  currentTab = group
  container:ReleaseChildren()

  if group ~= "home" and group ~= "roster" then
    ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  end

  local AceGUI = LibStub("AceGUI-3.0")
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("List")
  container:SetLayout("Fill")
  container:AddChild(scroll)
  DRAWERS[group](scroll)
end

function UI.Toggle()
  if not ns.active or not ns.character then
    return
  end
  if frame then
    Release()
    return
  end

  local AceGUI = LibStub("AceGUI-3.0")
  frame = AceGUI:Create("Frame")
  frame:SetTitle("Nrage Assistant")
  frame:SetStatusText(ns.GetVersion())
  frame:SetWidth(560)
  frame:SetHeight(440)
  frame:SetLayout("Fill")
  frame:SetCallback("OnClose", function()
    Release()
  end)

  tabs = AceGUI:Create("TabGroup")
  tabs:SetLayout("Fill")
  tabs:SetTabs(ns.ViewModel.TABS)
  tabs:SetCallback("OnGroupSelected", OnTabSelected)
  frame:AddChild(tabs)
  tabs:SelectTab(currentTab)
end

ns.UI = UI
