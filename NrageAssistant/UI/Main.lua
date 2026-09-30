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

local LOGO_SIZE = 64

-- The title line with the guild logo beside it. The logo is white, so it sits on the window's dark
-- background.
local function AddLogoHeader(container, title)
  local header = LibStub("AceGUI-3.0"):Create("Label")
  header:SetImage(ns.Constants.LOGO_TEXTURE)
  header:SetImageSize(LOGO_SIZE, LOGO_SIZE)
  header:SetText(title)
  header:SetFontObject(GameFontNormalLarge)
  header:SetFullWidth(true)
  container:AddChild(header)
end

local function DrawHome(container)
  local lines = ns.ViewModel.Home({
    version = ns.GetVersion(),
    syncLines = ns.comm and ns.comm:Status() or { "sync not started" },
    readinessText = ReadinessSummary().text,
  })
  AddLogoHeader(container, table.remove(lines, 1))
  AddLines(container, lines)
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
  local results, summary =
    ns.ReadinessService.Evaluate(ns.Constants.DEFAULT_RULES, character.profile, character.readiness)
  AddLines(container, EscapeAll(ns.ReadinessService.Describe(results, summary)))
  AddLines(container, { "", "Confirm manual items with /nrage ready set <item> <met|missing|waived|unknown>." })
end

local function DrawRoster(container)
  AddLines(container, ns.ViewModel.Roster(ns.db.global.roster, ns.Platform.ServerTime()))
end

local function DrawRaid(container)
  AddLines(container, ns.ViewModel.Raid(ns.db.global.events, ns.Platform.FormatDate))
  AddLines(container, { "Manage events with /nrage event, /nrage attendance and /nrage assign." })
end

local function DrawLoot(container)
  AddLines(container, ns.ViewModel.Loot(ns.db.global.events))
  AddLines(container, { "Manage sessions with /nrage loot." })
end

local DRAWERS = {
  home = DrawHome,
  profile = DrawProfile,
  ready = DrawReady,
  raid = DrawRaid,
  loot = DrawLoot,
  roster = DrawRoster,
}

local function OnTabSelected(container, _, group)
  currentTab = group
  container:ReleaseChildren()

  if group == "profile" or group == "ready" then
    ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  end

  local AceGUI = LibStub("AceGUI-3.0")
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("List")
  container:SetLayout("Fill")
  container:AddChild(scroll)
  DRAWERS[group](scroll)
end

-- Small window with a text box: shows the export text, or takes pasted text to import.
local transferFrame

local function ReleaseTransfer()
  if transferFrame then
    LibStub("AceGUI-3.0"):Release(transferFrame)
    transferFrame = nil
  end
end

local function TransferLibs()
  return { serialize = LibStub("LibSerialize"), deflate = LibStub("LibDeflate") }
end

local IMPORT_ERRORS = {
  forbidden = "your guild rank does not allow importing raid data.",
  not_string = "nothing to import.",
  bad_header = "that does not look like a Nrage export (it should start with NRAGE1:).",
  too_large = "that text is too large to import.",
  bad_encoding = "the text is damaged (bad encoding).",
  bad_compression = "the text is damaged (bad compression).",
  bad_payload = "the text is damaged or not a Nrage export.",
}

function UI.ShowTransfer(mode)
  if not ns.active or not ns.character then
    return
  end
  ReleaseTransfer()

  local AceGUI = LibStub("AceGUI-3.0")
  local window = AceGUI:Create("Frame")
  transferFrame = window
  window:SetTitle(mode == "export" and "Nrage export" or "Nrage import")
  window:SetWidth(520)
  window:SetHeight(360)
  window:SetLayout("Fill")
  window:SetCallback("OnClose", ReleaseTransfer)

  local box = AceGUI:Create("MultiLineEditBox")
  box:SetFullWidth(true)
  box:SetFullHeight(true)
  window:AddChild(box)

  if mode == "export" then
    local text, reason = ns.Transfer.Export(TransferLibs(), ns.db.global.events, ns.db.global.sync.tombstones)
    box:SetLabel("Select all and copy (Ctrl+C):")
    box:DisableButton(true)
    box:SetText(text or ("Export failed: " .. tostring(reason)))
    if box.editBox then
      box.editBox:HighlightText()
    end
    return
  end

  box:SetLabel("Paste an export here, then press Import:")
  box:SetButtonText("Import")
  box:SetCallback("OnEnterPressed", function(_, _, text)
    local ctx = {
      events = ns.db.global.events,
      tombstones = ns.db.global.sync.tombstones,
      now = ns.Platform.ServerTime,
    }
    local role = ns.PermissionService.OwnRole(ns.Platform)
    local summary, reason = ns.Transfer.Import(TransferLibs(), text, ctx, role)
    if summary then
      print("Nrage Assistant: " .. ns.Transfer.Describe(summary) .. ". Imported data stays on this client only.")
    else
      print("Nrage Assistant: import failed: " .. (IMPORT_ERRORS[reason] or tostring(reason)))
    end
  end)
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
