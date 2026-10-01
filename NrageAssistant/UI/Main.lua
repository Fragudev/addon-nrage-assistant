local _, ns = ...

-- Main window (AceGUI). A thin layer: what to show comes from ViewModel and the domain services,
-- so nothing here needs unit tests beyond loading cleanly. Client only.
local UI = {}

-- The loot screens that want to know when loot changes, here or on a received message. Each registers its
-- refresh function; UI.LootChanged calls them all.
UI.lootListeners = {}

function UI.LootChanged()
  for _, listener in ipairs(UI.lootListeners) do
    listener()
  end
end

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

-- An item as the client shows it elsewhere: its icon, its name beside it, and its tooltip on hover. Used by the
-- loot windows. `options` = { itemId, text, width (relative, or nil for the full width) }. Clicking calls
-- `onClick` when given. Returns the widget.
function UI.AddItemLabel(parent, options, onClick)
  local label = LibStub("AceGUI-3.0"):Create("InteractiveLabel")
  label:SetText(options.text)
  label:SetImage(ns.Platform.GetItemIcon(options.itemId))
  label:SetImageSize(24, 24)
  if options.width then
    label:SetRelativeWidth(options.width)
  else
    label:SetFullWidth(true)
  end
  if onClick then
    label:SetCallback("OnClick", onClick)
  end
  label:SetCallback("OnEnter", function(widget)
    if type(options.itemId) == "number" then
      GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
      -- The tooltip may refuse an item the client has not seen; the icon and name still show.
      if pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. options.itemId) then
        GameTooltip:Show()
      else
        GameTooltip:Hide()
      end
    end
  end)
  label:SetCallback("OnLeave", function()
    GameTooltip:Hide()
  end)
  parent:AddChild(label)
  return label
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

local function DrawRoster(container)
  AddLines(container, ns.ViewModel.Roster(ns.db.global.roster, ns.Platform.ServerTime()))
end

-- Raid tab. Reading is open to everyone; each group of controls only appears for a role that may use it
-- (ViewModel.RaidActions), and every control calls the same RaidCommands / TemplateCommands methods as
-- the slash commands, so the checks and the messages sent to the guild are the same.
local selectedEventId
local attendanceFilter = ""
local actionMessage
local ATTENDANCE_MATCHES_MAX = 8

local function RaidServices()
  local raid = ns.RaidCommands.New({
    events = ns.db.global.events,
    tombstones = ns.db.global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
  })
  local templates = ns.TemplateCommands.New({
    events = ns.db.global.events,
    templates = ns.db.global.templates,
    platform = ns.Platform,
    comm = ns.comm,
  })
  return raid, templates
end

-- Shows what an action reported and redraws the tab with the new state.
local function Report(lines)
  local parts = {}
  for _, line in ipairs(lines) do
    parts[#parts + 1] = line
  end
  actionMessage = table.concat(parts, " ")
  Redraw()
end

local function AddDropdown(container, label, list, order, value, width, onChange)
  local dropdown = LibStub("AceGUI-3.0"):Create("Dropdown")
  dropdown:SetLabel(label)
  dropdown:SetList(list, order)
  if value then
    dropdown:SetValue(value)
  end
  dropdown:SetRelativeWidth(width)
  dropdown:SetCallback("OnValueChanged", function(_, _, key)
    onChange(key)
  end)
  container:AddChild(dropdown)
end

-- A text box that acts when Enter or Okay is pressed.
local function AddTextInput(container, label, text, width, onSubmit)
  local box = LibStub("AceGUI-3.0"):Create("EditBox")
  box:SetLabel(label)
  box:SetText(text or "")
  box:SetRelativeWidth(width)
  box:SetCallback("OnEnterPressed", function(_, _, value)
    onSubmit(value)
  end)
  container:AddChild(box)
end

-- A text box read at the moment a button is clicked, so the text counts without pressing Enter first.
local function AddField(container, label, width)
  local box = LibStub("AceGUI-3.0"):Create("EditBox")
  box:SetLabel(label)
  box:SetRelativeWidth(width)
  container:AddChild(box)
  return box
end

local function AddButton(container, text, width, onClick)
  local button = LibStub("AceGUI-3.0"):Create("Button")
  button:SetText(text)
  button:SetRelativeWidth(width)
  button:SetCallback("OnClick", onClick)
  container:AddChild(button)
end

-- Readiness tab: the checklist, with a dropdown for every item confirmed by hand.
local function DrawReady(container)
  local character = ns.character
  local rules = ns.Constants.DEFAULT_RULES
  local results, summary = ns.ReadinessService.Evaluate(rules, character.profile, character.readiness)

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end
  AddLines(container, EscapeAll(ns.ReadinessService.Describe(results, summary)))

  local items = ns.ViewModel.ManualItems(rules, results)
  if #items > 0 then
    AddHeading(container, "Confirm by hand")
  end
  local statuses = {}
  for _, status in ipairs(ns.ViewModel.READY_STATUSES) do
    statuses[status] = status
  end
  for _, item in ipairs(items) do
    AddDropdown(container, item.label, statuses, ns.ViewModel.READY_STATUSES, item.status, 0.5, function(key)
      local ok, reason = ns.ReadinessService.SetManual(ns.Platform, rules, character.readiness, item.ruleId, key)
      actionMessage = not ok and ns.ViewModel.READY_SET_ERRORS[reason] or nil
      Redraw()
    end)
  end
end

local function DrawEventEditor(container, raid, event)
  AddTextInput(container, "Title (Enter to rename)", event.title, 1, function(value)
    Report(raid:RenameEvent(event, value))
  end)

  local statuses = {}
  for _, status in ipairs(ns.ViewModel.EVENT_STATUSES) do
    statuses[status] = status
  end
  AddDropdown(container, "Status", statuses, ns.ViewModel.EVENT_STATUSES, event.status, 0.4, function(key)
    Report(raid:SetEventStatus(event, key))
  end)
  local start = event.startAt and ns.Platform.FormatDate(event.startAt) or ""
  AddTextInput(container, "Start, local time (YYYY-MM-DD HH:MM)", start, 0.6, function(value)
    Report(raid:SetEventStart(event, value))
  end)
end

local attendanceNewState = "present"

-- Attendance: those already recorded with a state dropdown each, and a search to add somebody else, so a
-- guild of hundreds never becomes hundreds of rows.
local function DrawAttendance(container, raid, event, members)
  local states = {}
  for _, state in ipairs(ns.ViewModel.ATTENDANCE_STATES) do
    states[state] = state
  end
  local recorded, matches, matched =
    ns.ViewModel.AttendanceView(event, members, attendanceFilter, ATTENDANCE_MATCHES_MAX)

  AddHeading(container, ("Recorded (%d)"):format(#recorded))
  if #recorded == 0 then
    AddLines(container, { "Nobody yet. Search for a member below to add them." })
  end
  for _, row in ipairs(recorded) do
    AddDropdown(container, row.label, states, ns.ViewModel.ATTENDANCE_STATES, row.state, 0.5, function(key)
      Report(raid:SetAttendance(event, row.name, key))
    end)
  end

  AddHeading(container, "Add a member")
  AddTextInput(container, "Type part of a name and press Enter", attendanceFilter, 0.6, function(value)
    attendanceFilter = value
    Redraw()
  end)
  AddDropdown(container, "Record as", states, ns.ViewModel.ATTENDANCE_STATES, attendanceNewState, 0.4, function(key)
    attendanceNewState = key
  end)
  if attendanceFilter == "" then
    return
  end
  if matched == 0 then
    AddLines(container, { "No unrecorded member matches. The guild roster may still be loading." })
  end
  for _, match in ipairs(matches) do
    AddButton(container, match.label, 0.5, function()
      attendanceFilter = ""
      Report(raid:SetAttendance(event, match.name, attendanceNewState))
    end)
  end
  if matched > #matches then
    AddLines(container, { ("%d more match: type more of the name to narrow the list."):format(matched - #matches) })
  end
end

local function DrawAssignments(container, raid, event, members)
  local assignments = ns.RaidCommands.SortedAssignments(event)
  if #assignments == 0 then
    AddLines(container, { "No assignments yet." })
  end
  for _, assignment in ipairs(assignments) do
    local task = assignment.task and (" - " .. assignment.task) or ""
    local label = ns.ViewModel.Escape(("%s: %s%s"):format(assignment.encounter, assignment.characterKey, task))
    local text = LibStub("AceGUI-3.0"):Create("Label")
    text:SetText(label)
    text:SetRelativeWidth(0.75)
    container:AddChild(text)
    AddButton(container, "Remove", 0.25, function()
      Report(raid:RemoveAssignment(event, assignment))
    end)
  end

  local list = {}
  for _, name in ipairs(members) do
    list[name] = ns.ViewModel.Escape(name)
  end
  local newMember
  AddDropdown(container, "Member", list, members, nil, 0.45, function(key)
    newMember = key
  end)
  local encounter = AddField(container, "Encounter", 0.3)
  AddButton(container, "Add", 0.25, function()
    if not newMember then
      actionMessage = "Pick a member first."
      Redraw()
      return
    end
    Report(raid:AddAssignment(event, newMember, encounter:GetText()))
  end)
end

local function DrawTemplates(container, templates, event)
  local names = ns.TemplateService.List(ns.db.global.templates)
  local list = {}
  for _, name in ipairs(names) do
    list[name] = ns.ViewModel.Escape(name)
  end

  local suggested = ns.TemplateService.Suggest(ns.db.global.templates, event)
  if #suggested > 0 then
    AddLines(container, { "Suggested for this event (nothing is applied until you click):" })
    for _, name in ipairs(suggested) do
      AddButton(container, "Apply: " .. ns.ViewModel.Escape(name), 1, function()
        Report(templates:ApplyToEvent(event, name))
      end)
    end
  end

  local chosen
  if #names > 0 then
    AddDropdown(container, "Saved templates", list, names, nil, 0.6, function(key)
      chosen = key
    end)
    AddButton(container, "Apply to this event", 0.4, function()
      if not chosen then
        actionMessage = "Pick a template first."
        Redraw()
        return
      end
      Report(templates:ApplyToEvent(event, chosen))
    end)
  else
    AddLines(container, { "No templates saved yet." })
  end
  AddTextInput(container, "Save this event's assignments as (Enter to save)", "", 1, function(value)
    Report(templates:SaveEvent(event, value))
  end)
end

local raidSubTab = "summary"

-- The right-hand pane: one sub-tab per group of controls the role may use, for the selected event.
local function DrawEventPane(pane, actions, raid, templates, event)
  local members = ns.guildRoster and ns.guildRoster:Names() or {}
  local sub = LibStub("AceGUI-3.0"):Create("TabGroup")
  sub:SetLayout("List")
  sub:SetRelativeWidth(0.68)
  sub:SetTabs(ns.ViewModel.RaidSubTabs(actions))
  sub:SetCallback("OnGroupSelected", function(group, _, value)
    raidSubTab = value
    group:ReleaseChildren()
    if value == "details" then
      DrawEventEditor(group, raid, event)
    elseif value == "attendance" then
      DrawAttendance(group, raid, event, members)
    elseif value == "assignments" then
      DrawAssignments(group, raid, event, members)
    elseif value == "templates" then
      DrawTemplates(group, templates, event)
    else
      local index = 1
      for position, listed in ipairs(ns.EventService.List({ events = ns.db.global.events })) do
        if listed.eventId == event.eventId then
          index = position
        end
      end
      AddLines(group, ns.ViewModel.RaidEventLines(event, index, ns.Platform.FormatDate))
    end
  end)
  pane:AddChild(sub)

  -- Fall back to the summary when the remembered sub-tab is not available to this role.
  local allowed = false
  for _, tab in ipairs(ns.ViewModel.RaidSubTabs(actions)) do
    allowed = allowed or tab.value == raidSubTab
  end
  sub:SelectTab(allowed and raidSubTab or "summary")
end

-- Raid tab: the events on the left, the selected event on the right. Everyone can read; the sub-tabs on the
-- right only offer what the role may do (ViewModel.RaidActions).
local function DrawRaid(container)
  local AceGUI = LibStub("AceGUI-3.0")
  -- Without a sync transport nothing could be sent, so the tab stays read-only.
  local actions = ns.ViewModel.RaidActions(ns.comm and ns.PermissionService.OwnRole(ns.Platform) or nil)
  local raid, templates = RaidServices()

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end

  local left = AceGUI:Create("SimpleGroup")
  left:SetLayout("List")
  left:SetRelativeWidth(0.3)
  container:AddChild(left)

  if actions.events then
    AddTextInput(left, "New event (Enter to create)", "", 1, function(value)
      local before = {}
      for eventId in pairs(ns.db.global.events) do
        before[eventId] = true
      end
      local lines = raid:CreateEvent(value)
      -- Open the new event, so templates that match its title are suggested right away.
      for eventId in pairs(ns.db.global.events) do
        if not before[eventId] then
          selectedEventId = eventId
          raidSubTab = "summary"
        end
      end
      Report(lines)
    end)
  end

  local list, order = ns.ViewModel.EventChoices(ns.db.global.events)
  if #order == 0 then
    AddLines(left, ns.ViewModel.Raid(ns.db.global.events, ns.Platform.FormatDate))
    return
  end
  if not list[selectedEventId] then
    selectedEventId = order[1]
  end
  for _, eventId in ipairs(order) do
    local selected = eventId == selectedEventId
    AddButton(left, (selected and "> " or "") .. list[eventId], 1, function()
      selectedEventId = eventId
      Redraw()
    end)
  end

  DrawEventPane(container, actions, raid, templates, ns.db.global.events[selectedEventId])
end

-- Loot tab. Anyone can apply to an open session; opening, voting and awarding only show for the roles
-- that may (ViewModel.LootActions). Each control calls the same LootCommands method as the slash command.
local function DrawLootApply(container, loot, event, session)
  local spec = AddField(container, "Spec", 0.3)
  local upgrade = AddField(container, "Upgrade (optional)", 0.7)
  for _, need in ipairs(ns.ViewModel.LOOT_NEEDS) do
    AddButton(container, "Apply: " .. need, 0.33, function()
      local text = upgrade:GetText()
      Report(loot:Apply(event, session, {
        spec = spec:GetText(),
        need = need,
        upgrade = text ~= "" and text or nil,
      }))
    end)
  end
end

local function DrawLootCouncil(container, loot, event, session, actions)
  local list, order = ns.ViewModel.CandidateChoices(session)
  if #order == 0 then
    return
  end
  local chosen
  AddDropdown(container, "Candidate", list, order, nil, 1, function(key)
    chosen = key
  end)

  local function withCandidate(action)
    return function()
      if not chosen then
        actionMessage = "Pick a candidate first."
        Redraw()
        return
      end
      action()
    end
  end

  if actions.vote then
    AddButton(
      container,
      "Vote",
      0.3,
      withCandidate(function()
        Report(loot:VoteFor(event, session, chosen))
      end)
    )
  end
  if actions.award then
    local reason = AddField(container, "Reason for the award", 0.7)
    AddButton(
      container,
      "Award",
      0.3,
      withCandidate(function()
        Report(loot:AwardTo(event, session, chosen, reason:GetText()))
      end)
    )
    AddButton(container, "Close without awarding", 0.7, function()
      Report(loot:CloseSession(event, session))
    end)
  end
end

local function DrawLootSession(container, loot, event, session, actions)
  AddLines(container, { "" })
  AddLines(container, ns.ViewModel.LootSession(session))
  if session.status == "closed" then
    return
  end
  if actions.apply then
    DrawLootApply(container, loot, event, session)
  end
  if actions.vote or actions.award then
    DrawLootCouncil(container, loot, event, session, actions)
  end
end

local function DrawLoot(container)
  -- Without a sync transport nothing could be sent, so the tab stays read-only.
  local actions = ns.ViewModel.LootActions(ns.comm and ns.PermissionService.OwnRole(ns.Platform) or nil)
  local list, order = ns.ViewModel.EventChoices(ns.db.global.events)
  if #order == 0 then
    AddLines(container, ns.ViewModel.Loot(ns.db.global.events))
    return
  end
  if not list[selectedEventId] then
    selectedEventId = order[1]
  end
  local event = ns.db.global.events[selectedEventId]
  local loot = ns.LootCommands.New({
    events = ns.db.global.events,
    platform = ns.Platform,
    comm = ns.comm,
    onChange = ns.UI.LootChanged,
  })

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end
  AddDropdown(container, "Event", list, order, selectedEventId, 1, function(key)
    selectedEventId = key
    Redraw()
  end)

  if actions.vote then
    AddButton(container, "Open the voting window", 0.4, function()
      ns.VotingFrame.Show()
    end)
  end

  if actions.open then
    AddHeading(container, "Open a session")
    local item = AddField(container, "Item link (shift-click the item into this box)", 0.7)
    AddButton(container, "Open", 0.3, function()
      local parsed = ns.LootCommands.ParseItem(item:GetText())
      if not parsed then
        actionMessage = "Paste or shift-click an item link first."
        Redraw()
        return
      end
      Report(loot:OpenItem(event, parsed))
    end)
  end

  local sessions = ns.LootService.Sessions(event)
  AddHeading(container, "Sessions")
  if #sessions == 0 then
    AddLines(container, { "No loot sessions for this event yet." })
  end
  for _, session in ipairs(sessions) do
    DrawLootSession(container, loot, event, session, actions)
  end
  AddLines(container, { "", "Addon messages are not private: anyone with the addon can read votes." })
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
  if group ~= currentTab then
    actionMessage = nil
  end
  currentTab = group
  container:ReleaseChildren()

  if group == "profile" or group == "ready" then
    ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  end

  local AceGUI = LibStub("AceGUI-3.0")
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout(group == "raid" and "Flow" or "List")
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
  return { serialize = LibStub("NrageAssistant-LibSerialize"), deflate = LibStub("LibDeflate") }
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
  frame:SetWidth(720)
  frame:SetHeight(480)
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

-- Opens the window on `tab` (a value of ViewModel.TABS), or switches to it when the window is already open.
function UI.OpenTab(tab)
  if not ns.active or not ns.character then
    return
  end
  currentTab = tab
  if frame then
    Redraw()
  else
    UI.Toggle()
  end
end

ns.UI = UI
