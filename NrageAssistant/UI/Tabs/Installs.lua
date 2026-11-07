local _, ns = ...

-- Installed check (Admin, gm and cogm): every guild member with whether it runs the addon and which version. A member
-- with the addon announces itself when it logs in (HELLO), and any message it sends proves it too; what was heard is
-- saved (InstallDirectory), so an offline member shows the last version seen. The search box, the status chips, the
-- version dropdown and "Online only" filter the table; "Ask online members" makes everyone online answer again.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local ROWS_STEP = 100

-- What the table shows, kept while the session lasts.
local state = {
  search = "",
  filter = nil,
  version = nil,
  onlineOnly = false,
  sort = { key = "name", descending = false },
  limit = ROWS_STEP,
}

local function view()
  return ViewModel.InstallRows({
    entries = ns.guildRoster and ns.guildRoster.entries or {},
    installs = ns.db.global.installs,
    ownKey = ns.Platform.GetIdentityKey(),
    ownVersion = ns.GetVersion(),
    now = ns.Platform.ServerTime(),
    search = state.search,
    filter = state.filter,
    version = state.version,
    onlineOnly = state.onlineOnly,
    sort = state.sort,
  })
end

local function columns()
  return {
    { key = "name", title = L("Name"), weight = 2, sortable = true },
    { key = "class", title = L("Class"), weight = 1.2, sortable = true },
    { key = "rank", title = L("Rank"), weight = 1.4, sortable = true },
    { key = "status", title = L("Status"), weight = 1.4, sortable = true },
    { key = "version", title = L("Version"), weight = 1, sortable = true },
    { key = "seen", title = L("Last seen"), weight = 1.3, sortable = true },
  }
end

local function cellsOf(row)
  local muted = row.status == "unseen" and "muted" or nil
  return {
    name = { text = row.name, color = row.mine and "info" or muted },
    class = { text = row.class, color = row.classToken and Kit.Theme.ClassColor(row.classToken) or "muted" },
    rank = { text = row.rank, color = muted },
    status = { widget = "badge", opts = { text = row.statusText, color = row.statusColor } },
    version = { text = row.version, color = row.status == "outdated" and "warning" or muted },
    seen = { text = row.online and not row.mine and (row.seen .. " \194\183 " .. L("online")) or row.seen },
  }
end

local function drawTable(region)
  local data = view()
  local shown = math.min(#data.rows, state.limit)
  local tableRows = {}
  for index = 1, shown do
    local row = data.rows[index]
    tableRows[index] = { cells = cellsOf(row), highlight = row.mine }
  end
  Kit.Table(region, {
    columns = columns(),
    rows = tableRows,
    sort = state.sort,
    emptyText = data.total == 0 and L("No members yet. The guild roster may still be loading.")
      or L("Nobody matches those filters."),
    onSort = function(key)
      state.sort = ViewModel.NextSort(state.sort, key, ViewModel.INSTALL_FIRST_DESCENDING)
      UI.Redraw()
    end,
  })
  if shown < #data.rows then
    Kit.Label(region, {
      text = L("Showing %d of %d members."):format(shown, #data.rows),
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
    text = L("Offline members show the last version seen. Never seen may only mean not logged in since."),
    style = "small",
    color = "muted",
    layout = { gap = 10 },
  })
end

local function ask()
  if not ns.comm then
    UI.Notify("warning", L("Sync is not running: nobody can be asked."))
    return
  end
  local ok, reason, left = ns.comm:AskVersions()
  if ok then
    UI.Notify("success", L("Asked the members online for their version. The answers arrive over a few seconds."))
  elseif reason == "cooldown" then
    UI.Notify("warning", L("Asked a moment ago: try again in %d seconds."):format(left or 0))
  else
    UI.Notify("danger", L("Could not ask the members online. Try again later."))
  end
end

local function toolbar(page, getRegion, data)
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.EditBox(bar, {
    text = state.search,
    placeholder = L("Search by name"),
    layout = { weight = 1 },
    onChange = function(text, userInput)
      if userInput then
        state.search = text
        state.limit = ROWS_STEP
        UI.Refill(getRegion(), drawTable)
      end
    end,
  })
  Kit.Dropdown(bar, {
    items = ViewModel.InstallVersionChoices(data.versions),
    value = state.version or false,
    layout = { width = 150 },
    onChange = function(value)
      state.version = value or nil
      state.limit = ROWS_STEP
      UI.Redraw()
    end,
  })
  Kit.Button(bar, {
    text = L("Ask online members"),
    layout = { width = "auto" },
    onClick = ask,
  })

  local chips = Kit.Flow(page, { gap = 8, rowGap = 8 })
  for _, filter in ipairs(ViewModel.INSTALL_FILTERS) do
    Kit.Chip(chips, {
      text = ("%s (%d)"):format(ViewModel.INSTALL_FILTER_TEXT[filter], data.counts[filter]),
      active = state.filter == filter,
      onToggle = function(active)
        state.filter = active and filter or nil
        state.limit = ROWS_STEP
        UI.Redraw()
      end,
    })
  end
  Kit.Chip(chips, {
    text = L("Online only"),
    fixed = true,
    active = state.onlineOnly,
    color = "success",
    onToggle = function(active)
      state.onlineOnly = active
      state.limit = ROWS_STEP
      UI.Redraw()
    end,
  })
end

UI.Register("installs", function(page)
  local data = view()
  Kit.PageHeader(page, {
    title = L("Installed check"),
    description = data.newest and L("Who in the guild runs the addon, and which version. Newest seen: %s."):format(
      ViewModel.Escape(data.newest)
    ) or L("Who in the guild runs the addon, and which version."),
  })
  local region
  toolbar(page, function()
    return region
  end, data)
  region = Kit.Stack(page, { gap = 0 })
  drawTable(region)
end)
