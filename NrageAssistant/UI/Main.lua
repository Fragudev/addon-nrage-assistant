local _, ns = ...

-- Main window (AceGUI). A thin layer: what to show comes from ViewModel and the domain services,
-- so nothing here needs unit tests beyond loading cleanly. Client only.
local UI = {}

local L = ns.L

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

-- Remembers where a window was left and how big: the saved numbers live in settings.windows[name] and AceGUI
-- keeps them up to date as the window is moved or resized. `width`/`height` are the first-time size.
function UI.ApplyWindowStatus(window, name, width, height)
  local settings = type(ns.db.global.settings) == "table" and ns.db.global.settings or {}
  ns.db.global.settings = settings
  settings.windows = type(settings.windows) == "table" and settings.windows or {}
  local status = type(settings.windows[name]) == "table" and settings.windows[name] or {}
  settings.windows[name] = status
  status.width = type(status.width) == "number" and status.width or width
  status.height = type(status.height) == "number" and status.height or height
  window:SetStatusTable(status)
end

local function Redraw()
  if tabs then
    tabs:SelectTab(currentTab)
  end
end

local pvpDrawnAt
local pvpDrawPending = false

-- Called when a PvP counter changed, here or on a received record: the PvP tab is drawn again if it is the one
-- on screen. Records arrive in bursts (a whole guild logging in), so a redraw that comes too soon after the
-- previous one is postponed, once, to the end of the interval and then shows the latest state.
function UI.PvPChanged()
  if not (frame and currentTab == "pvp") then
    return
  end
  local now = ns.Platform.Now()
  local wait = pvpDrawnAt and (ns.Constants.PVP_REDRAW_SECONDS - (now - pvpDrawnAt)) or 0
  if wait > 0 then
    if not pvpDrawPending then
      pvpDrawPending = true
      C_Timer.After(wait, function()
        pvpDrawPending = false
        UI.PvPChanged()
      end)
    end
    return
  end
  pvpDrawnAt = now
  Redraw()
end

-- Called when the guild's readiness rules changed: the checklist is drawn again if it is on screen. They are rare
-- (one message per change), so there is no throttling.
function UI.RulesChanged()
  if frame and (currentTab == "ready" or currentTab == "rules") then
    Redraw()
  end
end

local blacklistDrawnAt
local blacklistDrawPending = false

-- Called when a blacklist entry arrived from the guild: the tab is drawn again if it is the one on screen, at most
-- once per interval like the PvP tab (a snapshot brings the whole list at once).
function UI.BlacklistChanged()
  if not (frame and currentTab == "blacklist") then
    return
  end
  local now = ns.Platform.Now()
  local wait = blacklistDrawnAt and (ns.Constants.BLACKLIST_REDRAW_SECONDS - (now - blacklistDrawnAt)) or 0
  if wait > 0 then
    if not blacklistDrawPending then
      blacklistDrawPending = true
      C_Timer.After(wait, function()
        blacklistDrawPending = false
        UI.BlacklistChanged()
      end)
    end
    return
  end
  blacklistDrawnAt = now
  Redraw()
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
  local _, summary = ns.ReadinessService.Evaluate(ns.ReadinessRules.Current(), character.profile, character.readiness)
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

local actionMessage

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

local function DrawHome(container)
  local lines = ns.ViewModel.Home({
    version = ns.GetVersion(),
    syncLines = ns.comm and ns.comm:Status() or { L("sync not started") },
    readinessText = ReadinessSummary().text,
  })
  AddLogoHeader(container, table.remove(lines, 1))
  AddLines(container, lines)

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end
  AddHeading(container, L("Your role"))
  AddLines(container, {
    ns.ViewModel.RoleLine(
      ns.Platform.GetIdentityKey(),
      ns.Platform.GetOwnGuildRank(),
      ns.PermissionService.OwnRole(ns.Platform)
    ),
  })
  AddButton(container, L("Request a sync"), 0.4, function()
    Report({ ns.ViewModel.SyncRequestResult(ns.comm:RequestSync()) })
  end)

  AddHeading(container, L("Settings"))
  local box = LibStub("AceGUI-3.0"):Create("CheckBox")
  box:SetLabel(L("Show the minimap button"))
  box:SetValue(not ns.MinimapButton.Settings(ns.db).hide)
  box:SetCallback("OnValueChanged", function(_, _, value)
    ns.MinimapButton.SetHidden(ns.db, not value)
  end)
  container:AddChild(box)
  AddButton(container, L("Reset the button position"), 0.4, function()
    ns.MinimapButton.ResetPosition(ns.db)
    Redraw()
  end)
end

local function DrawProfile(container)
  local AceGUI = LibStub("AceGUI-3.0")
  local character = ns.character

  AddHeading(container, L("Your profile"))
  AddLines(container, EscapeAll(ns.ProfileService.Describe(character.profile)))

  AddHeading(container, L("Your declared details"))
  local declared = character.profile.fields or {}
  for _, field in ipairs({
    { key = "role", label = L("Role (tank, healer, dps...)") },
    { key = "main", label = L("Main character") },
    { key = "notes", label = L("Notes (these stay on this computer)") },
  }) do
    AddTextInput(container, field.label, declared[field.key] and declared[field.key].value or "", 1, function(value)
      local ok, reason = ns.ProfileService.SetField(ns.Platform, character.profile, field.key, value)
      if ok then
        if ns.comm then
          ns.PublishService.PublishIfChanged(ns.comm, character, ns.Platform)
        end
        statusMessage = L("Saved.")
      else
        statusMessage = L("Not saved: ") .. (ns.ViewModel.PROFILE_SET_ERRORS[reason] or tostring(reason))
      end
      Redraw()
    end)
  end

  AddHeading(container, L("Shared with the guild"))
  AddLines(container, EscapeAll(ns.PublishService.Describe(character.profile)))
  AddLines(container, {
    L("Your profile is shared automatically after login and whenever it changes."),
    L("Addon messages are not private: any guild member with the addon can read them."),
  })

  local button = AceGUI:Create("Button")
  button:SetText(L("Publish now"))
  button:SetCallback("OnClick", function()
    local ok, reason = ns.PublishService.Publish(ns.comm, character, ns.Platform)
    statusMessage = ok and L("Profile published to the guild.")
      or (L("Not published: ") .. ns.ViewModel.PublishError(reason))
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
-- Readiness tab: the checklist, with a dropdown for every item confirmed by hand.
local function DrawReady(container)
  local character = ns.character
  local rules = ns.ReadinessRules.Current()
  local results, summary = ns.ReadinessService.Evaluate(rules, character.profile, character.readiness)

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end
  AddLines(container, EscapeAll(ns.ReadinessService.Describe(results, summary)))

  local items = ns.ViewModel.ManualItems(rules, results)
  if #items > 0 then
    AddHeading(container, L("Confirm by hand"))
  end
  local statuses = {}
  for _, status in ipairs(ns.ViewModel.READY_STATUSES) do
    statuses[status] = ns.ViewModel.Word(status)
  end
  for _, item in ipairs(items) do
    AddDropdown(container, item.label, statuses, ns.ViewModel.READY_STATUSES, item.status, 0.5, function(key)
      local ok, reason = ns.ReadinessService.SetManual(ns.Platform, rules, character.readiness, item.ruleId, key)
      actionMessage = not ok and ns.ViewModel.READY_SET_ERRORS[reason] or nil
      Redraw()
    end)
  end
end

-- The event whose Delete button was clicked once, waiting for the second click.
local deleteConfirming

local function DrawEventEditor(container, raid, event)
  AddTextInput(container, L("Title (Enter to rename)"), event.title, 1, function(value)
    Report(raid:RenameEvent(event, value))
  end)

  local statuses = {}
  for _, status in ipairs(ns.ViewModel.EVENT_STATUSES) do
    statuses[status] = ns.ViewModel.Word(status)
  end
  AddDropdown(container, L("Status"), statuses, ns.ViewModel.EVENT_STATUSES, event.status, 0.4, function(key)
    Report(raid:SetEventStatus(event, key))
  end)
  local start = event.startAt and ns.Platform.FormatDate(event.startAt) or ""
  AddTextInput(container, L("Start, local time (YYYY-MM-DD HH:MM)"), start, 0.6, function(value)
    Report(raid:SetEventStart(event, value))
  end)
  AddButton(
    container,
    deleteConfirming == event.eventId and L("Confirm: delete this event") or L("Delete this event"),
    0.5,
    function()
      if deleteConfirming ~= event.eventId then
        deleteConfirming = event.eventId
        Report({ L("Delete '%s'? Click the button again to confirm."):format(event.title) })
        return
      end
      deleteConfirming = nil
      Report(raid:DeleteEvent(event))
    end
  )
end

local attendanceNewState = "present"

-- Attendance: those already recorded with a state dropdown each, and a search to add somebody else, so a
-- guild of hundreds never becomes hundreds of rows.
local function DrawAttendance(container, raid, event, members)
  local states = {}
  for _, state in ipairs(ns.ViewModel.ATTENDANCE_STATES) do
    states[state] = ns.ViewModel.Word(state)
  end
  local recorded, matches, matched =
    ns.ViewModel.AttendanceView(event, members, attendanceFilter, ATTENDANCE_MATCHES_MAX)

  AddHeading(container, L("Recorded (%d)"):format(#recorded))
  if #recorded == 0 then
    AddLines(container, { L("Nobody yet. Search for a member below to add them.") })
  end
  for _, row in ipairs(recorded) do
    AddDropdown(container, row.label, states, ns.ViewModel.ATTENDANCE_STATES, row.state, 0.5, function(key)
      Report(raid:SetAttendance(event, row.name, key))
    end)
  end

  AddHeading(container, L("Add a member"))
  AddTextInput(container, L("Type part of a name and press Enter"), attendanceFilter, 0.6, function(value)
    attendanceFilter = value
    Redraw()
  end)
  AddDropdown(container, L("Record as"), states, ns.ViewModel.ATTENDANCE_STATES, attendanceNewState, 0.4, function(key)
    attendanceNewState = key
  end)
  if attendanceFilter == "" then
    return
  end
  if matched == 0 then
    AddLines(container, { L("No unrecorded member matches. The guild roster may still be loading.") })
  end
  for _, match in ipairs(matches) do
    AddButton(container, match.label, 0.5, function()
      attendanceFilter = ""
      Report(raid:SetAttendance(event, match.name, attendanceNewState))
    end)
  end
  if matched > #matches then
    AddLines(container, { L("%d more match: type more of the name to narrow the list."):format(matched - #matches) })
  end
end

local function DrawAssignments(container, raid, event, members)
  local assignments = ns.RaidCommands.SortedAssignments(event)
  if #assignments == 0 then
    AddLines(container, { L("No assignments yet.") })
  end
  for _, assignment in ipairs(assignments) do
    local task = assignment.task and (" - " .. assignment.task) or ""
    local label = ns.ViewModel.Escape(("%s: %s%s"):format(assignment.encounter, assignment.characterKey, task))
    local text = LibStub("AceGUI-3.0"):Create("Label")
    text:SetText(label)
    text:SetRelativeWidth(0.75)
    container:AddChild(text)
    AddButton(container, L("Remove"), 0.25, function()
      Report(raid:RemoveAssignment(event, assignment))
    end)
  end

  local list = {}
  for _, name in ipairs(members) do
    list[name] = ns.ViewModel.Escape(name)
  end
  local newMember
  AddDropdown(container, L("Member"), list, members, nil, 0.45, function(key)
    newMember = key
  end)
  local encounter = AddField(container, L("Encounter"), 0.3)
  AddButton(container, L("Add"), 0.25, function()
    if not newMember then
      actionMessage = L("Pick a member first.")
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
    AddLines(container, { L("Suggested for this event (nothing is applied until you click):") })
    for _, name in ipairs(suggested) do
      AddButton(container, L("Apply: ") .. ns.ViewModel.Escape(name), 1, function()
        Report(templates:ApplyToEvent(event, name))
      end)
    end
  end

  local chosen
  if #names > 0 then
    AddDropdown(container, L("Saved templates"), list, names, nil, 0.6, function(key)
      chosen = key
    end)
    AddButton(container, L("Apply to this event"), 0.4, function()
      if not chosen then
        actionMessage = L("Pick a template first.")
        Redraw()
        return
      end
      Report(templates:ApplyToEvent(event, chosen))
    end)
    AddButton(container, L("Delete template"), 0.4, function()
      if not chosen then
        actionMessage = L("Pick a template first.")
        Redraw()
        return
      end
      Report(templates:Delete(chosen))
    end)
  else
    AddLines(container, { L("No templates saved yet.") })
  end
  AddTextInput(container, L("Save this event's assignments as (Enter to save)"), "", 1, function(value)
    Report(templates:SaveEvent(event, value))
  end)
end

local raidSubTab = "summary"
-- The reports cover the selected event, or every event.
local reportAllEvents = false

local function DrawReports(container, event)
  local scopes = { event = L("This event"), all = L("All events") }
  AddDropdown(
    container,
    L("Scope"),
    scopes,
    { "event", "all" },
    reportAllEvents and "all" or "event",
    0.4,
    function(key)
      reportAllEvents = key == "all"
      Redraw()
    end
  )
  AddLines(container, ns.ViewModel.ReportLines(ns.db.global.events, event, reportAllEvents))
end

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
    elseif value == "reports" then
      DrawReports(group, event)
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
    AddTextInput(left, L("New event (Enter to create)"), "", 1, function(value)
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

  AddButton(left, L("Export"), 1, function()
    UI.ShowTransfer("export")
  end)
  if actions.events then
    AddButton(left, L("Import"), 1, function()
      UI.ShowTransfer("import")
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
  local spec = AddField(container, L("Spec"), 0.3)
  local upgrade = AddField(container, L("Upgrade (optional)"), 0.7)
  for _, need in ipairs(ns.ViewModel.LOOT_NEEDS) do
    AddButton(container, L("Apply: ") .. ns.ViewModel.Word(need), 0.33, function()
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
  AddDropdown(container, L("Candidate"), list, order, nil, 1, function(key)
    chosen = key
  end)

  local function withCandidate(action)
    return function()
      if not chosen then
        actionMessage = L("Pick a candidate first.")
        Redraw()
        return
      end
      action()
    end
  end

  if actions.vote then
    AddButton(
      container,
      L("Vote"),
      0.3,
      withCandidate(function()
        Report(loot:VoteFor(event, session, chosen))
      end)
    )
  end
  if actions.award then
    local reason = AddField(container, L("Reason for the award"), 0.7)
    AddButton(
      container,
      L("Award"),
      0.3,
      withCandidate(function()
        Report(loot:AwardTo(event, session, chosen, reason:GetText()))
      end)
    )
    AddButton(container, L("Close without awarding"), 0.7, function()
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
  AddDropdown(container, L("Event"), list, order, selectedEventId, 1, function(key)
    selectedEventId = key
    Redraw()
  end)

  if actions.vote then
    AddButton(container, L("Open the voting window"), 0.4, function()
      ns.VotingFrame.Show()
    end)
  end

  if actions.open then
    AddHeading(container, L("Open a session"))
    local item = AddField(container, L("Item link (shift-click the item into this box)"), 0.7)
    AddButton(container, L("Open"), 0.3, function()
      local parsed = ns.LootCommands.ParseItem(item:GetText())
      if not parsed then
        actionMessage = L("Paste or shift-click an item link first.")
        Redraw()
        return
      end
      Report(loot:OpenItem(event, parsed))
    end)
  end

  local sessions = ns.LootService.Sessions(event)
  AddHeading(container, L("Sessions"))
  if #sessions == 0 then
    AddLines(container, { L("No loot sessions for this event yet.") })
  end
  for _, session in ipairs(sessions) do
    DrawLootSession(container, loot, event, session, actions)
  end
  AddLines(container, { "", L("Addon messages are not private: anyone with the addon can read votes.") })
end

local pvpSubTab = "mine"
local pvpSort = { key = "total", descending = true }
-- "total" or "today" (ViewModel.PVP_PERIODS); kept while the session lasts.
local pvpPeriod = "total"

-- Relative column widths of the ranking, with and without the killing blows column (the sum stays under 1 so a
-- row never wraps).
local RANKING_COLUMNS = {
  withBlows = { name = 0.21, rank = 0.2, world = 0.1, bg = 0.1, total = 0.1, blows = 0.1, updated = 0.17 },
  withoutBlows = { name = 0.24, rank = 0.22, world = 0.12, bg = 0.12, total = 0.12, updated = 0.17 },
}
local RANKING_ORDER = { "name", "rank", "world", "bg", "total", "blows", "updated" }
local RANKING_TITLES = {
  name = L("Name"),
  rank = L("Rank"),
  world = L("World"),
  bg = L("BG"),
  total = L("Total"),
  blows = L("Blows"),
  updated = L("Updated"),
}

local function AddCell(container, text, width, color)
  local label = LibStub("AceGUI-3.0"):Create("Label")
  label:SetText(color and ("|c%s%s|r"):format(color, text) or text)
  label:SetRelativeWidth(width)
  container:AddChild(label)
end

local function AddRankingHeader(container, key, width)
  local mark = pvpSort.key == key and (pvpSort.descending and " v" or " ^") or ""
  local header = LibStub("AceGUI-3.0"):Create("InteractiveLabel")
  header:SetText(("|cffffd100%s%s|r"):format(RANKING_TITLES[key], mark))
  header:SetRelativeWidth(width)
  header:SetCallback("OnClick", function()
    pvpSort = ns.ViewModel.NextSort(pvpSort, key, ns.ViewModel.PVP_FIRST_DESCENDING)
    Redraw()
  end)
  container:AddChild(header)
end

-- Admin only, below the ranking: zeroes the PvP counters of one member on every client. The first click asks to
-- confirm, the second one does it.
local pvpResetTarget
local pvpResetConfirming = false

local function DrawPvPAdmin(container, rows)
  local list, order = {}, {}
  for _, row in ipairs(rows) do
    if not row.mine then
      list[row.name] = row.label
      order[#order + 1] = row.name
    end
  end
  if #order == 0 then
    return
  end
  table.sort(order)
  if not list[pvpResetTarget] then
    pvpResetTarget, pvpResetConfirming = nil, false
  end

  AddHeading(container, L("Admin"))
  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage) })
  end
  AddDropdown(container, L("Member"), list, order, pvpResetTarget, 0.5, function(key)
    pvpResetTarget, pvpResetConfirming = key, false
  end)
  AddButton(container, pvpResetConfirming and L("Confirm") or L("Reset PvP counters"), 0.3, function()
    if not pvpResetTarget then
      Report({ L("Pick a member first.") })
      return
    end
    if not pvpResetConfirming then
      pvpResetConfirming = true
      Report({ L("Reset the PvP counters of %s? Click Confirm to do it."):format(pvpResetTarget) })
      return
    end
    local target = pvpResetTarget
    pvpResetTarget, pvpResetConfirming = nil, false
    local ok, outcome, sent = ns.comm:ResetPvP(target)
    if not ok then
      Report({ L("Not reset: ") .. (ns.ViewModel.PVP_RESET_ERRORS[outcome] or tostring(outcome)) })
      return
    end
    Report({
      L("PvP counters of %s reset (revision %d)%s."):format(
        target,
        outcome,
        sent and L(", told to the guild") or L(", NOT sent")
      ),
    })
  end)
end

-- Ranking sub-tab: the guild members with counters, most honourable kills first; click a title to sort.
local function DrawPvPRanking(container)
  local tracker = ns.pvpTracker
  local blowsAvailable = tracker ~= nil and tracker.blowsAvailable
  local rosterNames = {}
  if ns.guildRoster then
    for _, name in ipairs(ns.guildRoster:Names()) do
      rosterNames[name] = true
    end
  end

  local rows, columns = ns.ViewModel.PvPRanking(ns.db.global.pvpStats, {
    own = { name = ns.Platform.GetIdentityKey(), stats = ns.character.pvp },
    rosterNames = rosterNames,
    blowsAvailable = blowsAvailable,
    now = ns.Platform.ServerTime(),
    sort = pvpSort,
    period = pvpPeriod,
    day = tracker and tracker:Day() or nil,
  })
  local widths = columns.blows and RANKING_COLUMNS.withBlows or RANKING_COLUMNS.withoutBlows

  AddDropdown(
    container,
    L("Show"),
    ns.ViewModel.PVP_PERIODS,
    ns.ViewModel.PVP_PERIOD_ORDER,
    pvpPeriod,
    0.3,
    function(key)
      pvpPeriod = key
      Redraw()
    end
  )
  local hint = pvpPeriod == "today" and L("Today's kills (server day, UTC); the rank is the all-time one. ") or ""
  AddLines(container, { hint .. L("Click a column title to sort by it. Your row is green."), "" })
  for _, key in ipairs(RANKING_ORDER) do
    if widths[key] then
      AddRankingHeader(container, key, widths[key])
    end
  end

  local shown = math.min(#rows, ns.Constants.PVP_RANKING_ROWS_MAX)
  for index = 1, shown do
    local row = rows[index]
    local color = row.mine and "ff33ff99" or nil
    local cells = {
      name = row.label,
      rank = row.rank,
      world = tostring(row.world),
      bg = tostring(row.bg),
      total = tostring(row.total),
      blows = row.blows and tostring(row.blows) or "-",
      updated = row.updated,
    }
    for _, key in ipairs(RANKING_ORDER) do
      if widths[key] then
        AddCell(container, cells[key], widths[key], color)
      end
    end
  end
  if shown < #rows then
    AddLines(container, { "", L("Showing the first %d of %d members."):format(shown, #rows) })
  end
  AddLines(container, { "", L("Counters come from members who run the addon, about a minute after a kill.") })
  if ns.comm and ns.PermissionService.Can(ns.PermissionService.OwnRole(ns.Platform), "moderate") then
    DrawPvPAdmin(container, rows)
  end
end

-- Recent kills sub-tab: the own kills since login, not saved. Every kill is shared with the guild.
local function DrawPvPFeed(container)
  local feed = ns.pvpFeed
  AddLines(
    container,
    ns.ViewModel.PvPFeed(feed and feed:Entries() or {}, {
      available = feed ~= nil and feed:Available(),
      formatTime = ns.Platform.FormatClock,
    })
  )
end

-- PvP tab: sub-tabs like the Raid tab.
local function DrawPvP(container)
  local sub = LibStub("AceGUI-3.0"):Create("TabGroup")
  sub:SetLayout("Flow")
  sub:SetFullWidth(true)
  sub:SetTabs(ns.ViewModel.PvPSubTabs())
  sub:SetCallback("OnGroupSelected", function(group, _, value)
    pvpSubTab = value
    group:ReleaseChildren()
    if value == "ranking" then
      DrawPvPRanking(group)
      return
    end
    if value == "feed" then
      DrawPvPFeed(group)
      return
    end
    local tracker = ns.pvpTracker
    AddLines(
      group,
      ns.ViewModel.PvPStats(ns.character.pvp, {
        day = tracker and tracker:Day() or nil,
        honorAvailable = tracker ~= nil and tracker.honorAvailable,
        blowsAvailable = tracker ~= nil and tracker.blowsAvailable,
      })
    )
  end)
  container:AddChild(sub)

  local allowed = false
  for _, tab in ipairs(ns.ViewModel.PvPSubTabs()) do
    allowed = allowed or tab.value == pvpSubTab
  end
  sub:SelectTab(allowed and pvpSubTab or "mine")
end

-- Blacklist tab: a form to add a player (open to everyone) and the list, with a Remove button on each row only
-- for a role that may remove (the receiver checks the role again, so hiding the button is only convenience).
local BLACKLIST_COLUMNS = { name = 0.22, reason = 0.4, added = 0.25, remove = 0.13 }

local function DrawBlacklist(container)
  local role = ns.PermissionService.OwnRole(ns.Platform)
  local commands = ns.BlacklistCommands.New({
    blacklist = ns.db.global.blacklist,
    tombstones = ns.db.global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
    onChange = function()
      if ns.blacklistWatcher then
        pcall(ns.blacklistWatcher.Check, ns.blacklistWatcher)
      end
    end,
  })

  if actionMessage then
    AddLines(container, { ns.ViewModel.Escape(actionMessage), "" })
  end
  AddHeading(container, L("Add a player"))
  local name = AddField(container, L("Name"), 0.3)
  local reason = AddField(container, L("Reason"), 0.5)
  reason:SetMaxLetters(ns.Constants.BLACKLIST_REASON_MAX)
  AddButton(container, L("Add"), 0.2, function()
    Report(commands:Add(name:GetText(), reason:GetText()))
  end)

  local rows = ns.ViewModel.BlacklistRows(ns.db.global.blacklist, {
    canRemove = ns.PermissionService.Can(role, "blacklist_remove"),
    formatDate = ns.Platform.FormatDate,
  })
  AddHeading(container, L("Blacklist (%d)"):format(#rows))
  if #rows == 0 then
    AddLines(container, { L("Nobody is on the blacklist.") })
    return
  end
  for _, row in ipairs(rows) do
    AddCell(container, row.name, BLACKLIST_COLUMNS.name)
    AddCell(container, row.reason, BLACKLIST_COLUMNS.reason)
    AddCell(container, ("%s, %s"):format(row.addedBy, row.added), BLACKLIST_COLUMNS.added)
    if row.canRemove then
      AddButton(container, L("Remove"), BLACKLIST_COLUMNS.remove, function()
        Report(commands:Remove(row.key))
      end)
    end
  end
  AddLines(container, {
    "",
    L("Everyone can add a player. Only the guild master and officers can remove one."),
    L("You are warned once when a listed player is in your group."),
  })
end

-- Rules tab (admins only): the guild's readiness rules, one row each with Remove, a form to add one, and a button
-- to go back to the starting list. Every change is a whole new set sent to the guild (Comm:SetReadinessRules).
local ruleDraftCheck = "level"

local function SaveRules(rules)
  -- On success the second value is the revision, otherwise the reason.
  local ok, outcome = ns.comm:SetReadinessRules(rules)
  if ok then
    Report({ L("Rules saved as revision %d and sent to the guild."):format(outcome) })
  else
    Report({ L("Not saved: ") .. (ns.ViewModel.RULE_ERRORS[outcome] or tostring(outcome)) })
  end
end

local RULE_COLUMNS = { label = 0.3, summary = 0.5, remove = 0.2 }

local function DrawRules(container)
  local role = ns.PermissionService.OwnRole(ns.Platform)
  if not ns.PermissionService.Can(role, "rules_edit") then
    AddLines(container, { L("Only the guild master and officers can edit the readiness rules.") })
    return
  end

  local rules = ns.ReadinessRules.Current()
  local viewModel = ns.ViewModel

  if actionMessage then
    AddLines(container, { viewModel.Escape(actionMessage), "" })
  end
  AddLines(container, EscapeAll({ ns.ReadinessRules.Describe(ns.db.global.readinessRules)[1] }))
  AddHeading(container, L("Rules (%d)"):format(#rules))
  for _, rule in ipairs(rules) do
    AddCell(container, viewModel.Escape(ns.ReadinessService.LabelText(rule.label)), RULE_COLUMNS.label)
    AddCell(container, viewModel.Escape(viewModel.RuleSummary(rule)), RULE_COLUMNS.summary)
    AddButton(container, L("Remove"), RULE_COLUMNS.remove, function()
      local list, reason = viewModel.WithoutRule(rules, rule.id)
      if not list then
        Report({ L("Not saved: ") .. viewModel.RULE_ERRORS[reason] })
        return
      end
      SaveRules(list)
    end)
  end

  AddHeading(container, L("Add a rule"))
  local kinds = {}
  for _, check in ipairs(viewModel.RULE_CHECKS) do
    kinds[check] = viewModel.RULE_CHECK_TEXT[check]
  end
  AddDropdown(container, L("Kind"), kinds, viewModel.RULE_CHECKS, ruleDraftCheck, 0.3, function(key)
    ruleDraftCheck = key
    Redraw()
  end)
  local label = AddField(container, L("Name"), 0.3)
  local details = AddField(container, L("Details: ") .. viewModel.RULE_DETAIL_HINTS[ruleDraftCheck], 0.4)
  AddButton(container, L("Add rule"), 0.3, function()
    local rule, reason = viewModel.RuleFromInput(ruleDraftCheck, label:GetText(), details:GetText(), rules)
    if not rule then
      Report({ L("Not saved: ") .. viewModel.RULE_ERRORS[reason] })
      return
    end
    SaveRules(viewModel.WithRule(rules, rule))
  end)
  AddButton(container, L("Use the starting list"), 0.3, function()
    SaveRules(ns.Constants.DEFAULT_RULES)
  end)
  AddLines(container, {
    "",
    L("These rules are the same for the whole guild and are measured on each player's own game."),
    L("Level, item level, professions, enchants and buffs are checked automatically; the rest are confirmed by hand."),
  })
end

local DRAWERS = {
  home = DrawHome,
  profile = DrawProfile,
  ready = DrawReady,
  raid = DrawRaid,
  loot = DrawLoot,
  pvp = DrawPvP,
  blacklist = DrawBlacklist,
  roster = DrawRoster,
  rules = DrawRules,
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
  scroll:SetLayout((group == "raid" or group == "blacklist" or group == "rules") and "Flow" or "List")
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
  forbidden = L("your guild rank does not allow importing raid data."),
  not_string = L("nothing to import."),
  bad_header = L("that does not look like a Nrage export (it should start with NRAGE1:)."),
  too_large = L("that text is too large to import."),
  bad_encoding = L("the text is damaged (bad encoding)."),
  bad_compression = L("the text is damaged (bad compression)."),
  bad_payload = L("the text is damaged or not a Nrage export."),
}

function UI.ShowTransfer(mode)
  if not ns.active or not ns.character then
    return
  end
  ReleaseTransfer()

  local AceGUI = LibStub("AceGUI-3.0")
  local window = AceGUI:Create("Frame")
  transferFrame = window
  window:SetTitle(mode == "export" and L("Nrage export") or L("Nrage import"))
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
    box:SetLabel(L("Select all and copy (Ctrl+C):"))
    box:DisableButton(true)
    box:SetText(text or (L("Export failed: ") .. tostring(reason)))
    if box.editBox then
      box.editBox:HighlightText()
    end
    return
  end

  box:SetLabel(L("Paste an export here, then press Import:"))
  box:SetButtonText(L("Import"))
  box:SetCallback("OnEnterPressed", function(_, _, text)
    local ctx = {
      events = ns.db.global.events,
      tombstones = ns.db.global.sync.tombstones,
      now = ns.Platform.ServerTime,
    }
    local role = ns.PermissionService.OwnRole(ns.Platform)
    local summary, reason = ns.Transfer.Import(TransferLibs(), text, ctx, role)
    if summary then
      print("Nrage Assistant: " .. ns.Transfer.Describe(summary) .. L(". Imported data stays on this client only."))
    else
      print("Nrage Assistant: " .. L("import failed: ") .. (IMPORT_ERRORS[reason] or tostring(reason)))
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
  UI.ApplyWindowStatus(frame, "main", 720, 480)
  frame:SetLayout("Fill")
  frame:SetCallback("OnClose", function()
    Release()
  end)

  tabs = AceGUI:Create("TabGroup")
  tabs:SetLayout("Fill")
  tabs:SetTabs(ns.ViewModel.TabsFor(ns.PermissionService.OwnRole(ns.Platform)))
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
