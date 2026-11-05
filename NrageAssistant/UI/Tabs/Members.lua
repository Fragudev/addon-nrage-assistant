local _, ns = ...

-- Members (plan 4.2): the guild in one table, merged with the profiles received from the members that run the addon.
-- gm, cogm and officer see every member (the roster chips filter by roster); an rl sees its own roster plus the members
-- with no roster, so it can add them. Only gm and cogm get the Rosters card and a Roster dropdown with every roster on
-- each row; an rl gets one with its own roster and "No roster" on the rows it may change; the officer reads only. The
-- dropdowns save on change and sync by themselves. Clicking a row opens its detail under it.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local ROWS_STEP = 100

-- What the table shows, kept while the session lasts.
local state = {
  search = "",
  roster = nil,
  spec = nil,
  addonOnly = false,
  sort = { key = "name", descending = false },
  expanded = nil,
  limit = ROWS_STEP,
  renaming = nil,
  newRoster = "",
}

-- Redraws the part of a tab that a search box filters (clear, draw again, lay out), without rebuilding the page.
function UI.Refill(region, draw)
  region:Clear()
  draw(region)
  UI.Relayout()
end

local function commands()
  local global = ns.db.global
  return ns.RosterCommands.New({
    rosters = global.rosters,
    members = global.members,
    tombstones = global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
  })
end

local function memberNames()
  return ns.guildRoster and ns.guildRoster:Names() or {}
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Rosters card (the guild master only)

local function roster_row(card, roster, count, cmd)
  local row = Kit.Row(card, { gap = 8, align = "center" })
  if state.renaming == roster.id then
    Kit.EditBox(row, {
      text = roster.name,
      maxLetters = ns.Constants.ROSTER_NAME_MAX,
      layout = { weight = 1 },
      onCommit = function(value)
        state.renaming = nil
        UI.Report(cmd:RenameRoster(roster.id, value))
      end,
      onEnter = function(value)
        state.renaming = nil
        if value == roster.name then
          UI.Redraw()
        end
      end,
    })
    Kit.IconButton(row, {
      icon = "close",
      tooltip = L("Cancel"),
      layout = { width = 28 },
      onClick = function()
        state.renaming = nil
        UI.Redraw()
      end,
    })
    return
  end
  Kit.Label(row, { text = ViewModel.Escape(roster.name), layout = { weight = 1 } })
  Kit.Label(row, { text = L("%d member(s)"):format(count), style = "small", color = "muted", layout = { width = 110 } })
  Kit.IconButton(row, {
    icon = "pencil",
    tooltip = L("Rename"),
    layout = { width = 28 },
    onClick = function()
      state.renaming = roster.id
      UI.Redraw()
    end,
  })
  local key = "roster:" .. roster.id
  if UI.IsArmed(key) then
    Kit.Button(row, {
      text = L("Confirm: delete"),
      variant = "dangerSolid",
      layout = { width = "auto" },
      onClick = function()
        UI.Disarm()
        UI.Report(cmd:DeleteRoster(roster.id))
      end,
    })
  else
    Kit.IconButton(row, {
      icon = "trash",
      variant = "danger",
      tooltip = L("Delete the roster"),
      layout = { width = 28 },
      onClick = function()
        UI.Arm(key)
      end,
    })
  end
end

local function rostersCard(page)
  local global = ns.db.global
  local cmd = commands()
  local card = Kit.Card(page, { title = L("Rosters"), gap = 8 })
  local counts = ns.RosterService.Counts(global.rosters, global.members, memberNames())
  local list = ns.RosterService.List(global.rosters)
  if #list == 0 then
    Kit.Label(
      card,
      { text = L("There are no rosters yet. Create one to start assigning members."), color = "muted", wrap = true }
    )
  end
  for _, roster in ipairs(list) do
    roster_row(card, roster, counts[roster.id] or 0, cmd)
  end
  Kit.Label(card, { text = L("No roster: %d member(s)"):format(counts.none or 0), style = "small", color = "muted" })
  local add = Kit.Row(card, { gap = 8, layout = { gap = 12 } })
  Kit.EditBox(add, {
    text = state.newRoster,
    placeholder = L("New roster name"),
    maxLetters = ns.Constants.ROSTER_NAME_MAX,
    layout = { weight = 1 },
    onChange = function(text)
      state.newRoster = text
    end,
    onEnter = function(value)
      state.newRoster = ""
      UI.Report(cmd:CreateRoster(value))
    end,
  })
  Kit.Button(add, {
    text = L("New roster"),
    icon = "plus",
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      local name = state.newRoster
      state.newRoster = ""
      UI.Report(cmd:CreateRoster(name))
    end,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The table

local function columns()
  return {
    { key = "name", title = L("Name"), weight = 2, sortable = true },
    { key = "class", title = L("Class"), weight = 1.2, sortable = true },
    { key = "level", title = L("Lv"), width = 40, align = "RIGHT", sortable = true },
    { key = "ilvl", title = L("iLvl"), width = 48, align = "RIGHT", sortable = true },
    { key = "spec", title = L("Main spec"), weight = 1, sortable = true },
    { key = "spec2", title = L("Second spec"), weight = 1 },
    { key = "roster", title = L("Roster"), weight = 1.6, sortable = true },
    { key = "role", title = L("Role"), weight = 1.4, sortable = true },
    { key = "updated", title = L("Updated"), weight = 1.3, sortable = true },
  }
end

local function updatedCell(row)
  if row.noAddon then
    return { widget = "badge", opts = { text = L("No addon"), color = "muted" } }
  end
  if row.stale then
    return { widget = "badge", opts = { text = L("Stale") .. " \194\183 " .. (row.updated or ""), color = "warning" } }
  end
  return row.updated or "-"
end

local function cellsOf(row, choices, cmd)
  local muted = row.noAddon and "muted" or nil
  local cells = {
    name = { text = row.name, color = row.mine and "info" or muted },
    class = {
      text = row.class,
      color = (not row.noAddon or row.classToken) and Kit.Theme.ClassColor(row.classToken) or muted,
    },
    level = { text = row.level and tostring(row.level) or "-", color = muted },
    ilvl = { text = row.ilvl and tostring(row.ilvl) or "-", color = muted },
    spec = { text = row.spec or "-", color = muted },
    spec2 = { text = row.spec2 or "-", color = muted },
    roster = { text = row.rosterName or "-", color = row.rosterName and nil or "muted" },
    -- The role is the guild rank: it is changed in the game, so it is only shown here.
    role = { text = row.roleText, color = row.role ~= "member" and "text" or "dim" },
    updated = updatedCell(row),
  }
  if choices then
    cells.roster = {
      widget = "dropdown",
      opts = {
        items = choices,
        value = row.rosterId or false,
        onChange = function(value)
          UI.Report(cmd:AssignMember(row.key, { rosterId = value }))
        end,
      },
    }
  end
  return cells
end

local function detailOf(row)
  return function(card)
    local detail = ViewModel.MemberDetail(row)
    Kit.KeyValue(card, { label = L("Primary professions"), value = detail.primary })
    Kit.KeyValue(card, { label = L("Secondary professions"), value = detail.secondary })
    Kit.KeyValue(card, { label = L("Main character"), value = detail.main })
    Kit.KeyValue(card, { label = L("Last profile received"), value = detail.updated })
  end
end

local function drawTable(region, role, selection)
  local global = ns.db.global
  local ownRosterId = UI.OwnRosterId()
  local cmd = ns.PermissionService.Can(role, "members_manage") and commands() or nil
  local rows, total = ViewModel.MemberRows({
    entries = ns.guildRoster and ns.guildRoster.entries or {},
    received = global.roster,
    rosters = global.rosters,
    members = global.members,
    now = ns.Platform.ServerTime(),
    ownKey = ns.Platform.GetIdentityKey(),
    search = state.search,
    roster = state.roster,
    onlyRoster = not selection.visible and selection.selected or nil,
    spec = state.spec,
    addonOnly = state.addonOnly,
    sort = state.sort,
  })
  local shown = math.min(#rows, state.limit)
  local tableRows = {}
  for index = 1, shown do
    local row = rows[index]
    tableRows[index] = {
      cells = cellsOf(row, cmd and ViewModel.MemberRosterChoices(role, ownRosterId, row, global.rosters), cmd),
      highlight = row.mine,
      detail = state.expanded == row.key and detailOf(row) or nil,
      onClick = function()
        state.expanded = state.expanded ~= row.key and row.key or nil
        UI.Redraw()
      end,
    }
  end
  Kit.Table(region, {
    columns = columns(),
    rows = tableRows,
    sort = state.sort,
    emptyText = total == 0 and L("No members yet. The guild roster may still be loading.")
      or L("Nobody matches those filters."),
    onSort = function(key)
      state.sort = ViewModel.NextSort(state.sort, key, ViewModel.MEMBER_FIRST_DESCENDING)
      UI.Redraw()
    end,
  })
  if shown < #rows then
    Kit.Label(region, {
      text = L("Showing %d of %d members."):format(shown, #rows),
      style = "small",
      color = "muted",
      layout = { gap = 10 },
    })
    Kit.Button(region, {
      text = L("Show more"),
      layout = { width = 160, gap = 8 },
      onClick = function()
        state.limit = state.limit + ROWS_STEP
        UI.Redraw()
      end,
    })
  end
  Kit.Label(region, {
    text = L("Nothing received here is verified: a profile older than a week is marked stale."),
    style = "small",
    color = "muted",
    layout = { gap = 10 },
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The tab

local function toolbar(page, getRegion, role, selection)
  local global = ns.db.global
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.EditBox(bar, {
    text = state.search,
    placeholder = L("Search by name"),
    layout = { weight = 1 },
    onChange = function(text, userInput)
      if userInput then
        state.search = text
        state.limit = ROWS_STEP
        UI.Refill(getRegion(), function(region)
          drawTable(region, role, selection)
        end)
      end
    end,
  })
  local chips = Kit.Flow(page, { gap = 8, rowGap = 8 })
  local counts = ns.RosterService.Counts(global.rosters, global.members, memberNames())
  local ownRoster = ns.RosterService.RosterOf(global.members, global.rosters, ns.Platform.GetIdentityKey())
  for _, chip in ipairs(ViewModel.RosterChips(global.rosters, counts, role, ownRoster)) do
    Kit.Chip(chips, {
      text = chip.text,
      active = state.roster == chip.value,
      onToggle = function(active)
        state.roster = active and chip.value or nil
        state.limit = ROWS_STEP
        UI.Redraw()
      end,
    })
  end
  for _, spec in ipairs({ { "Tank", L("Tank") }, { "Heal", L("Healer") }, { "Dps", L("DPS") } }) do
    Kit.Chip(chips, {
      text = spec[2],
      fixed = true,
      active = state.spec == spec[1],
      color = "success",
      onToggle = function(active)
        state.spec = active and spec[1] or nil
        UI.Redraw()
      end,
    })
  end
  Kit.Chip(chips, {
    text = L("With addon only"),
    fixed = true,
    active = state.addonOnly,
    color = "warning",
    onToggle = function(active)
      state.addonOnly = active
      UI.Redraw()
    end,
  })
end

UI.Register("roster", function(page)
  local role = UI.Role()
  -- gm, cogm and officer pick any roster with the chips below; an rl is fixed to its own, shown as a label.
  local selection = UI.RosterSelection("roster", "members_view")
  Kit.PageHeader(page, {
    title = L("Members"),
    description = L("The guild members and what each one shares. Click a row for details."),
  })
  UI.DrawRosterSelector(page, "roster", { visible = false, label = selection.label })
  if ns.PermissionService.CanAll(role, "members_manage") then
    rostersCard(page)
  end
  local region
  toolbar(page, function()
    return region
  end, role, selection)
  region = Kit.Stack(page, { gap = 0 })
  drawTable(region, role, selection)
end)
