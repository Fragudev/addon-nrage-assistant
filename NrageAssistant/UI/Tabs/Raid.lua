local _, ns = ...

-- Raid (plan 3.4): master/detail. The events of the roster you see on the left (Upcoming or Past, with a new-event form
-- and an overflow menu for export and import); on the right the selected event with a sub-navigation strip: summary,
-- details, attendance, assignments, templates and reports, each only for the roles that may use it. Every control calls
-- the same RaidCommands and TemplateCommands methods as the old slash commands did, so the checks and the messages sent
-- to the guild are the same.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local ATTENDANCE_MATCHES_MAX = 8

-- What the tab remembers while the session lasts.
local state = {
  selectedId = nil,
  filter = "upcoming",
  subTab = "summary",
  roster = nil,
  newOpen = false,
  draft = { title = "", startAt = nil, status = "planned", rosterId = nil },
  attendanceFilter = "",
  attendanceNewState = "present",
  reportAll = false,
  assignMember = nil,
  assignEncounter = nil,
  assignNewEncounter = "",
  assignTask = "",
  chosenTemplate = nil,
  templateName = "",
}

local function services()
  local global = ns.db.global
  local raid = ns.RaidCommands.New({
    events = global.events,
    tombstones = global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
    rosters = global.rosters,
    members = global.members,
  })
  local templates = ns.TemplateCommands.New({
    events = global.events,
    templates = global.templates,
    platform = ns.Platform,
    comm = ns.comm,
    rosters = global.rosters,
    members = global.members,
  })
  return raid, templates
end

local function memberNames()
  return ns.guildRoster and ns.guildRoster:Names() or {}
end

local NO_ROSTER = ns.Locale.Table(function()
  return {
    title = L("You are not in a roster yet"),
    hint = L("An admin has to assign you one."),
  }
end)

-- ---------------------------------------------------------------------------------------------------------------
-- The roster selector (the guild master)

local function rosterSelector(parent, viewer)
  local items = {
    { value = "all", text = L("All rosters") },
    { value = "none", text = L("No roster") },
  }
  for _, roster in ipairs(ns.RosterService.List(ns.db.global.rosters)) do
    items[#items + 1] = { value = roster.id, text = ViewModel.Escape(roster.name) }
  end
  local current = viewer.mode == "all" and "all" or (viewer.mode == "none" and "none" or viewer.rosterId)
  Kit.Dropdown(parent, {
    items = items,
    value = current,
    layout = { width = 220 },
    onChange = function(value)
      state.roster = value
      state.selectedId = nil
      UI.Redraw()
    end,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The new-event form

local function newEventForm(parent, raid, actions, role)
  local global = ns.db.global
  local card = Kit.Card(parent, { title = L("New event"), gap = 10 })
  local title = Kit.Field(card, { label = L("Title") })
  Kit.EditBox(title, {
    text = state.draft.title,
    maxLetters = 60,
    onChange = function(text)
      state.draft.title = text
    end,
  })
  local when = Kit.Field(card, { label = L("Date and time") })
  Kit.DateField(when, {
    value = state.draft.startAt,
    placeholder = L("Pick a date and time"),
    format = ViewModel.DateText,
    now = ns.Platform.ServerTime,
    monthName = function(month)
      return ViewModel.MONTHS_LONG[month]
    end,
    weekdayName = function(index)
      return ViewModel.WEEKDAYS[index]:sub(1, 2)
    end,
    onChange = function(timestamp)
      state.draft.startAt = timestamp
    end,
    onError = function()
      UI.Notify("danger", L("That time does not exist on that day (the clocks change)."))
    end,
  })
  local status = Kit.Field(card, { label = L("Status") })
  Kit.Dropdown(status, {
    items = ViewModel.EventStatusChoices(),
    value = state.draft.status,
    onChange = function(value)
      state.draft.status = value
    end,
  })
  -- The guild master picks the roster; a raid leader's event is of their own roster automatically.
  local rosterChoices = ViewModel.RosterChoices(global.rosters, true)
  if ns.PermissionService.Can(role, "roster_view_all") and #rosterChoices > 1 then
    local roster = Kit.Field(card, { label = L("Roster") })
    Kit.Dropdown(roster, {
      items = rosterChoices,
      value = state.draft.rosterId or false,
      onChange = function(value)
        state.draft.rosterId = value or nil
      end,
    })
  end
  local buttons = Kit.Row(card, { gap = 10, layout = { gap = 14 } })
  Kit.Button(buttons, {
    text = L("Create"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      local lines, event = raid:CreateEventWith({
        title = state.draft.title,
        startAt = state.draft.startAt,
        status = state.draft.status,
        rosterId = state.draft.rosterId,
      })
      if event then
        state.selectedId, state.subTab, state.newOpen = event.eventId, "summary", false
        state.draft = { title = "", startAt = nil, status = "planned", rosterId = nil }
      end
      UI.Report(lines)
    end,
  })
  Kit.Button(buttons, {
    text = L("Cancel"),
    layout = { width = "auto" },
    onClick = function()
      state.newOpen = false
      UI.Redraw()
    end,
  })
  if not actions.events then
    card:SetShown(false)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The left column

local function overflowMenu(parent, actions)
  local button
  button = Kit.IconButton(parent, {
    icon = "dots",
    tooltip = L("Export and import"),
    layout = { width = 28 },
    onClick = function()
      local items = { { value = "export", text = L("Export"), icon = "list" } }
      if actions.events then
        items[#items + 1] = { value = "import", text = L("Import"), icon = "plus" }
      end
      Kit.Menu.Open(button.frame, items, function(value)
        UI.ShowTransfer(value)
      end)
    end,
  })
end

local function eventList(parent, events, actions, raid, role)
  local column = Kit.Stack(parent, { gap = 10, layout = { width = 270 } })
  local top = Kit.Row(column, { gap = 8, align = "center" })
  Kit.Segmented(top, {
    items = ViewModel.EVENT_FILTERS,
    value = state.filter,
    layout = { weight = 1 },
    onChange = function(value)
      state.filter = value
      state.selectedId = nil
      UI.Redraw()
    end,
  })
  overflowMenu(top, actions)
  if actions.events then
    Kit.Button(column, {
      text = L("New event"),
      icon = "plus",
      variant = "primary",
      onClick = function()
        state.newOpen = not state.newOpen
        UI.Redraw()
      end,
    })
  end
  if state.newOpen and actions.events then
    newEventForm(column, raid, actions, role)
  end

  local rows = ViewModel.EventListRows(events, {
    filter = state.filter,
    now = ns.Platform.ServerTime(),
    rosters = ns.db.global.rosters,
  })
  if #rows == 0 then
    Kit.EmptyState(column, {
      icon = "calendar",
      title = state.filter == "past" and L("No past events") or L("No upcoming events"),
      hint = actions.events and L("Create one with New event.") or "",
    })
    return rows
  end
  local listRows = {}
  for index, row in ipairs(rows) do
    listRows[index] = {
      title = row.title,
      subtitle = row.dateText .. (row.rosterName and (" \194\183 " .. row.rosterName) or ""),
      badge = { text = row.statusText, color = row.statusToken },
      selected = row.eventId == state.selectedId,
      onClick = function()
        state.selectedId, state.subTab = row.eventId, "summary"
        UI.Redraw()
      end,
    }
  end
  Kit.List(column, { rows = listRows })
  return rows
end

-- ---------------------------------------------------------------------------------------------------------------
-- The sub-tabs of the selected event

local function summaryTab(parent, event)
  local summary = ViewModel.EventSummary(event)
  local card = Kit.Card(parent, { title = L("Attendance") })
  if summary.recorded then
    Kit.StatGrid(card, { columns = math.min(#summary.attendance, 4), stats = summary.attendance })
  else
    Kit.Label(card, { text = L("Attendance: none recorded"), color = "muted" })
  end
  local assignments = Kit.Card(parent, { title = L("Assignments"), gap = 6 })
  local groups = ViewModel.AssignmentGroups(event)
  if #groups == 0 then
    Kit.Label(assignments, { text = L("No assignments yet."), color = "muted" })
  end
  for _, group in ipairs(groups) do
    Kit.Label(assignments, { text = group.encounter, style = "smallMedium", color = "dim" })
    for _, row in ipairs(group.rows) do
      Kit.Label(assignments, { text = row.text })
    end
  end
end

local function detailsTab(parent, event, raid, role)
  local global = ns.db.global
  local card = Kit.Card(parent, { title = L("Details"), gap = 12 })
  local first = Kit.Row(card, { gap = 16 })
  local title = Kit.Field(first, { label = L("Title"), layout = { weight = 1 } })
  Kit.EditBox(title, {
    text = event.title,
    maxLetters = 60,
    onCommit = function(value)
      UI.Report(raid:RenameEvent(event, value))
    end,
  })
  local status = Kit.Field(first, { label = L("Status"), layout = { width = 180 } })
  Kit.Dropdown(status, {
    items = ViewModel.EventStatusChoices(),
    value = event.status,
    onChange = function(value)
      UI.Report(raid:SetEventStatus(event, value))
    end,
  })
  local second = Kit.Row(card, { gap = 16 })
  local when = Kit.Field(second, { label = L("Date and time"), layout = { weight = 1 } })
  Kit.DateField(when, {
    value = event.startAt,
    placeholder = L("Pick a date and time"),
    format = ViewModel.DateText,
    now = ns.Platform.ServerTime,
    monthName = function(month)
      return ViewModel.MONTHS_LONG[month]
    end,
    weekdayName = function(index)
      return ViewModel.WEEKDAYS[index]:sub(1, 2)
    end,
    onChange = function(timestamp)
      UI.Report(raid:SetEventStartAt(event, timestamp))
    end,
    onError = function()
      UI.Notify("danger", L("That time does not exist on that day (the clocks change)."))
    end,
  })
  if ns.PermissionService.Can(role, "roster_view_all") then
    local roster = Kit.Field(second, { label = L("Roster"), layout = { weight = 1 } })
    Kit.Dropdown(roster, {
      items = ViewModel.RosterChoices(global.rosters, false),
      value = event.rosterId,
      placeholder = L("No roster yet"),
      onChange = function(value)
        UI.Report(raid:SetEventRoster(event, value))
      end,
    })
  end
  local key = "event:" .. event.eventId
  local armed = UI.IsArmed(key)
  Kit.Button(card, {
    text = armed and L("Confirm: delete this event") or L("Delete this event"),
    variant = armed and "dangerSolid" or "danger",
    layout = { width = 260, gap = 18 },
    onClick = function()
      if not armed then
        UI.Arm(key)
        return
      end
      UI.Disarm()
      state.selectedId = nil
      UI.Report(raid:DeleteEvent(event))
    end,
  })
end

local function attendanceTab(parent, event, raid)
  local states = ViewModel.AttendanceStateChoices()
  local rows = ViewModel.AttendanceRows(event, ns.Platform.ServerTime())
  local card = Kit.Card(parent, { title = L("Recorded (%d)"):format(#rows), gap = 10 })
  if ns.Platform.GroupApiAvailable() and ns.Platform.IsInGroup() then
    Kit.Button(card, {
      text = L("Fill from current group"),
      icon = "users",
      layout = { width = 240 },
      onClick = function()
        UI.Report(raid:FillFromGroup(event, ns.Platform.GetFullGroupNames(), memberNames()))
      end,
    })
  end
  if #rows == 0 then
    Kit.Label(card, { text = L("Nobody yet. Search for a member below to add them."), color = "muted" })
  else
    local tableRows = {}
    for _, row in ipairs(rows) do
      tableRows[#tableRows + 1] = {
        cells = {
          name = row.label,
          state = {
            widget = "dropdown",
            opts = {
              items = states,
              value = row.state,
              onChange = function(value)
                UI.Report(raid:SetAttendance(event, row.name, value))
              end,
            },
          },
          when = { text = row.recordedAt or "-", color = "muted" },
        },
      }
    end
    Kit.Table(card, {
      columns = {
        { key = "name", title = L("Name"), weight = 2 },
        { key = "state", title = L("State"), weight = 2 },
        { key = "when", title = L("Recorded"), weight = 1 },
      },
      rows = tableRows,
    })
  end

  local add = Kit.Card(parent, { title = L("Add a member"), gap = 10 })
  local row = Kit.Row(add, { gap = 12 })
  Kit.EditBox(row, {
    text = state.attendanceFilter,
    placeholder = L("Type part of a name and press Enter"),
    layout = { weight = 1 },
    onEnter = function(value)
      state.attendanceFilter = value
      UI.Redraw()
    end,
  })
  Kit.Dropdown(row, {
    items = states,
    value = state.attendanceNewState,
    layout = { width = 170 },
    onChange = function(value)
      state.attendanceNewState = value
    end,
  })
  if state.attendanceFilter == "" then
    return
  end
  local _, matches, matched =
    ViewModel.AttendanceView(event, memberNames(), state.attendanceFilter, ATTENDANCE_MATCHES_MAX)
  if matched == 0 then
    Kit.Label(
      add,
      { text = L("No unrecorded member matches. The guild roster may still be loading."), color = "muted" }
    )
  end
  local flow = Kit.Flow(add, { gap = 8, rowGap = 8 })
  for _, match in ipairs(matches) do
    Kit.Chip(flow, {
      text = match.label,
      onToggle = function()
        state.attendanceFilter = ""
        UI.Report(raid:SetAttendance(event, match.name, state.attendanceNewState))
      end,
    })
  end
  if matched > #matches then
    Kit.Label(add, {
      text = L("%d more match: type more of the name to narrow the list."):format(matched - #matches),
      style = "small",
      color = "muted",
    })
  end
end

local function assignmentsTab(parent, event, raid)
  for _, group in ipairs(ViewModel.AssignmentGroups(event)) do
    local card = Kit.Card(parent, { title = group.encounter, gap = 6 })
    for _, row in ipairs(group.rows) do
      local line = Kit.Row(card, { gap = 8, align = "center" })
      Kit.Label(line, { text = row.text, layout = { weight = 1 } })
      Kit.IconButton(line, {
        icon = "trash",
        variant = "danger",
        tooltip = L("Remove"),
        layout = { width = 28 },
        onClick = function()
          UI.Report(raid:RemoveAssignment(event, row.assignment))
        end,
      })
    end
  end
  if #ViewModel.AssignmentGroups(event) == 0 then
    Kit.EmptyState(parent, { icon = "list", title = L("No assignments yet."), hint = "" })
  end

  local form = Kit.Card(parent, { title = L("Add an assignment"), gap = 10 })
  local top = Kit.Row(form, { gap = 12 })
  local member = Kit.Field(top, { label = L("Member"), layout = { weight = 1 } })
  Kit.Dropdown(member, {
    items = ViewModel.MemberChoices(memberNames()),
    value = state.assignMember,
    placeholder = L("Pick a member"),
    onChange = function(value)
      state.assignMember = value
    end,
  })
  local encounter = Kit.Field(top, { label = L("Encounter"), layout = { weight = 1 } })
  Kit.Dropdown(encounter, {
    items = ViewModel.EncounterChoices(event),
    value = state.assignEncounter,
    placeholder = L("Pick an encounter"),
    onChange = function(value)
      state.assignEncounter = value
      UI.Redraw()
    end,
  })
  local bottom = Kit.Row(form, { gap = 12 })
  if state.assignEncounter == ViewModel.NEW_ENCOUNTER then
    local name = Kit.Field(bottom, { label = L("New encounter"), layout = { weight = 1 } })
    Kit.EditBox(name, {
      text = state.assignNewEncounter,
      maxLetters = 60,
      onChange = function(text)
        state.assignNewEncounter = text
      end,
    })
  end
  local task = Kit.Field(bottom, { label = L("Task (optional)"), layout = { weight = 1 } })
  Kit.EditBox(task, {
    text = state.assignTask,
    maxLetters = 60,
    onChange = function(text)
      state.assignTask = text
    end,
  })
  Kit.Button(form, {
    text = L("Add"),
    variant = "primary",
    layout = { width = 140 },
    onClick = function()
      if not state.assignMember then
        UI.Notify("warning", L("Pick a member first."))
        return
      end
      local name = state.assignEncounter == ViewModel.NEW_ENCOUNTER and state.assignNewEncounter
        or state.assignEncounter
      state.assignTask, state.assignNewEncounter = "", ""
      UI.Report(raid:AddAssignment(event, state.assignMember, name or "", state.assignTask))
    end,
  })
end

local function templatesTab(parent, event, templates, viewer)
  local global = ns.db.global
  local suggested = ns.TemplateService.Suggest(global.templates, event)
  if #suggested > 0 then
    local grid = Kit.Grid(parent, { columns = 2, gap = 14 })
    for _, name in ipairs(suggested) do
      local card = Kit.Card(grid, { title = L("Suggested for this event"), gap = 8 })
      Kit.Label(card, { text = ViewModel.Escape(name) })
      Kit.Button(card, {
        text = L("Apply"),
        layout = { width = 120 },
        onClick = function()
          UI.Report(templates:ApplyToEvent(event, name))
        end,
      })
    end
  end

  local card = Kit.Card(parent, { title = L("Templates"), gap = 10 })
  local names = ns.TemplateService.List(global.templates, viewer)
  if #names > 0 then
    local row = Kit.Row(card, { gap = 10 })
    Kit.Dropdown(row, {
      items = ViewModel.TemplateChoices(names),
      value = state.chosenTemplate,
      placeholder = L("Saved templates"),
      layout = { weight = 1 },
      onChange = function(value)
        state.chosenTemplate = value
        UI.Redraw()
      end,
    })
    Kit.Button(row, {
      text = L("Apply to this event"),
      layout = { width = "auto" },
      onClick = function()
        if not state.chosenTemplate then
          UI.Notify("warning", L("Pick a template first."))
          return
        end
        UI.Report(templates:ApplyToEvent(event, state.chosenTemplate))
      end,
    })
    local key = "template:" .. tostring(state.chosenTemplate)
    local armed = UI.IsArmed(key)
    Kit.Button(row, {
      text = armed and L("Confirm: delete") or L("Delete template"),
      variant = armed and "dangerSolid" or "danger",
      layout = { width = "auto" },
      onClick = function()
        if not state.chosenTemplate then
          UI.Notify("warning", L("Pick a template first."))
          return
        end
        if not armed then
          UI.Arm(key)
          return
        end
        UI.Disarm()
        local name = state.chosenTemplate
        state.chosenTemplate = nil
        UI.Report(templates:Delete(name))
      end,
    })
  else
    Kit.Label(card, { text = L("No templates saved yet."), color = "muted" })
  end
  local save = Kit.Field(card, { label = L("Save this event's assignments as (Enter to save)") })
  Kit.EditBox(save, {
    text = state.templateName,
    maxLetters = ns.Constants.TEMPLATE_NAME_MAX,
    onChange = function(text)
      state.templateName = text
    end,
    onEnter = function(value)
      state.templateName = ""
      UI.Report(templates:SaveEvent(event, value))
    end,
  })
end

local function reportTable(parent, columns, rows, emptyText)
  Kit.Table(parent, { columns = columns, rows = rows, emptyText = emptyText })
end

local function reportsTab(parent, event, events)
  Kit.Segmented(parent, {
    items = ViewModel.REPORT_SCOPES,
    value = state.reportAll and "all" or "event",
    onChange = function(value)
      state.reportAll = value == "all"
      UI.Redraw()
    end,
  })
  local data = ViewModel.ReportTables(events, event, state.reportAll)
  local attendance = Kit.Card(parent, { title = L("Attendance"), gap = 10 })
  if data.attendance.note then
    Kit.Label(attendance, { text = data.attendance.note, color = "muted", wrap = true })
  else
    local rows = {}
    for _, row in ipairs(data.attendance.rows) do
      rows[#rows + 1] = { cells = row }
    end
    reportTable(attendance, {
      { key = "name", title = L("Name"), weight = 2 },
      { key = "attended", title = L("Attended"), width = 80, align = "RIGHT" },
      { key = "outcomes", title = L("Outcomes"), width = 80, align = "RIGHT" },
      { key = "rate", title = L("Rate"), width = 60, align = "RIGHT" },
      { key = "detail", title = L("States"), weight = 3 },
    }, rows)
  end
  local loot = Kit.Card(parent, { title = L("Loot"), gap = 10 })
  Kit.Label(loot, { text = data.loot.note, color = "muted", wrap = true })
  if #data.loot.rows > 0 then
    local rows = {}
    for _, row in ipairs(data.loot.rows) do
      rows[#rows + 1] = { cells = row }
    end
    reportTable(loot, {
      { key = "name", title = L("Name"), weight = 2 },
      { key = "awards", title = L("Awards"), width = 70, align = "RIGHT" },
      { key = "items", title = L("Items"), weight = 4 },
    }, rows)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The right column

local function eventPane(parent, event, events, actions, raid, templates, role, viewer)
  local pane = Kit.Stack(parent, { gap = 14, layout = { weight = 1 } })
  local header = ViewModel.EventHeader(event, ns.db.global.rosters)
  local top = Kit.Row(pane, { gap = 10, align = "center" })
  Kit.Label(top, { text = header.title, style = "hero", layout = { weight = 1 } })
  if header.rosterName then
    Kit.Badge(top, { text = header.rosterName, color = "muted", layout = { width = "auto" } })
  end
  Kit.Badge(top, { text = header.statusText, color = header.statusToken, layout = { width = "auto" } })
  Kit.Label(pane, { text = header.dateText, color = "dim", layout = { gap = 4 } })

  local tabs = ViewModel.RaidSubTabs(actions)
  local allowed = false
  for _, tab in ipairs(tabs) do
    allowed = allowed or tab.value == state.subTab
  end
  if not allowed then
    state.subTab = "summary"
  end
  Kit.TabStrip(pane, {
    tabs = tabs,
    value = state.subTab,
    onSelect = function(value)
      state.subTab = value
      UI.Redraw()
    end,
  })
  if state.subTab == "details" then
    detailsTab(pane, event, raid, role)
  elseif state.subTab == "attendance" then
    attendanceTab(pane, event, raid)
  elseif state.subTab == "assignments" then
    assignmentsTab(pane, event, raid)
  elseif state.subTab == "templates" then
    templatesTab(pane, event, templates, viewer)
  elseif state.subTab == "reports" then
    reportsTab(pane, event, events)
  else
    summaryTab(pane, event)
  end
end

UI.Register("raid", function(page)
  local global = ns.db.global
  local role = UI.Role()
  -- Without a sync transport nothing could be sent, so the tab stays read-only.
  local actions = ViewModel.RaidActions(ns.comm and role or nil)
  local raid, templates = services()
  local viewer = UI.Viewer(state.roster)
  local events = ns.RosterService.FilterEvents(global.events, viewer)

  if UI.nav.eventId and global.events[UI.nav.eventId] then
    state.selectedId, state.subTab = UI.nav.eventId, "summary"
    local event = global.events[UI.nav.eventId]
    state.filter = ViewModel.IsPastEvent(event, ns.Platform.ServerTime()) and "past" or "upcoming"
    UI.nav.eventId = nil
  end

  Kit.PageHeader(page, {
    title = L("Raid"),
    description = L("Events, attendance, assignments and reports for your roster."),
  })
  if viewer.canSelect then
    local bar = Kit.Row(page, { gap = 10, align = "center" })
    rosterSelector(bar, viewer)
  end
  if viewer.mode == "blocked" then
    Kit.EmptyState(page, { icon = "users", title = NO_ROSTER.title, hint = NO_ROSTER.hint })
    return
  end

  local body = Kit.Row(page, { gap = 20 })
  local rows = eventList(body, events, actions, raid, role)
  local selected
  for _, row in ipairs(rows) do
    if row.eventId == state.selectedId then
      selected = row
    end
  end
  if not selected and rows[1] then
    state.selectedId = rows[1].eventId
  end
  local event = state.selectedId and events[state.selectedId]
  if event and (selected or rows[1]) then
    eventPane(body, event, events, actions, raid, templates, role, viewer)
  else
    local empty = Kit.Stack(body, { layout = { weight = 1 } })
    Kit.EmptyState(empty, {
      icon = "calendar",
      title = L("Select an event"),
      hint = L("Pick one on the left to see its details."),
    })
  end
end)
