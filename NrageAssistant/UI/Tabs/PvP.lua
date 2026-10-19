local _, ns = ...

-- PvP (plan 3.6): My stats (two grids, Today and Total), the Ranking (a sortable table with a Total/Today switch, a
-- search
-- and the top three colored) and the Recent kills. PvP is guild-wide: rosters do not apply.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- What the tab remembers while the session lasts.
local state = {
  sub = "mine",
  sort = { key = "total", descending = true },
  period = "total",
  search = "",
  resetTarget = nil,
}

-- ---------------------------------------------------------------------------------------------------------------
-- My stats

local function myStats(page)
  local tracker = ns.pvpTracker
  local grids = ViewModel.PvPStatGrids(ns.character.pvp, {
    day = tracker and tracker:Day() or nil,
    honorAvailable = tracker ~= nil and tracker.honorAvailable,
    blowsAvailable = tracker ~= nil and tracker.blowsAvailable,
  })
  local row = Kit.Grid(page, { columns = 2, gap = 20 })
  local today = Kit.Card(row, { title = L("Today") })
  Kit.StatGrid(today, { columns = 3, stats = grids.today })
  local total = Kit.Card(row, { title = L("Total") })
  Kit.StatGrid(total, { columns = 3, stats = grids.total })
  Kit.Label(page, {
    text = L("Today is the server day (UTC). Counters come from the game and are shared with the guild."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The ranking

local function adminCard(page, rows)
  local list = {}
  for _, row in ipairs(rows) do
    if not row.mine then
      list[#list + 1] = { value = row.member, text = row.name }
    end
  end
  if #list == 0 then
    return
  end
  table.sort(list, function(a, b)
    return a.value < b.value
  end)
  local card = Kit.Card(page, { title = L("Admin"), gap = 10 })
  local row = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Dropdown(row, {
    items = list,
    value = state.resetTarget,
    placeholder = L("Member"),
    layout = { weight = 1 },
    onChange = function(value)
      state.resetTarget = value
      UI.Redraw()
    end,
  })
  local key = "pvpreset:" .. tostring(state.resetTarget)
  local armed = UI.IsArmed(key)
  Kit.Button(row, {
    text = armed and L("Confirm: reset") or L("Reset PvP counters"),
    variant = armed and "dangerSolid" or "danger",
    layout = { width = "auto" },
    onClick = function()
      if not state.resetTarget then
        UI.Notify("warning", L("Pick a member first."))
        return
      end
      if not armed then
        UI.Arm(key)
        return
      end
      UI.Disarm()
      local target = state.resetTarget
      state.resetTarget = nil
      local ok, outcome, sent = ns.comm:ResetPvP(target)
      if not ok then
        UI.Notify("danger", L("Not reset: ") .. (ViewModel.PVP_RESET_ERRORS[outcome] or tostring(outcome)))
        return
      end
      UI.Notify(
        sent and "success" or "warning",
        L("PvP counters of %s reset (revision %d)%s."):format(
          ViewModel.Escape(target),
          outcome,
          sent and L(", told to the guild") or L(", NOT sent")
        )
      )
    end,
  })
end

-- The table sizes its columns to their text (`fit`): none of the headers is ever cut, the figures and the short texts
-- (rank, updated) get the width of their widest cell, and the name takes what is left. When the window is too narrow
-- for that, the table cuts the text and shows it whole in a tooltip.
local function rankingColumns(withBlows)
  local columns = {
    { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
    { key = "name", title = L("Name"), weight = 2, sortable = true },
    { key = "rank", title = L("Rank"), weight = 2, sortable = true, fit = true },
    { key = "world", title = L("World"), width = 62, align = "RIGHT", sortable = true, fit = true },
    { key = "bg", title = L("BG"), width = 54, align = "RIGHT", sortable = true, fit = true },
    { key = "total", title = L("Total"), width = 62, align = "RIGHT", sortable = true, fit = true },
  }
  if withBlows then
    columns[#columns + 1] =
      { key = "blows", title = L("Blows"), width = 62, align = "RIGHT", sortable = true, fit = true }
  end
  columns[#columns + 1] = { key = "updated", title = L("Updated"), weight = 1.2, sortable = true, fit = true }
  return columns
end

local function drawRankingTable(region, data, withBlows)
  local rows = {}
  for _, row in ipairs(data.rows) do
    rows[#rows + 1] = {
      highlight = row.mine,
      cells = {
        position = { text = tostring(row.position), color = row.positionToken },
        name = { text = row.name, color = row.mine and "accent" or nil },
        rank = row.rank,
        world = row.world,
        bg = row.bg,
        total = { text = row.total, style = "smallMedium" },
        blows = row.blows,
        updated = { text = row.updated, color = "muted" },
      },
    }
  end
  Kit.Table(region, {
    columns = rankingColumns(withBlows),
    fit = true,
    rows = rows,
    sort = state.sort,
    emptyText = L("Nobody matches."),
    onSort = function(key)
      state.sort = ViewModel.NextSort(state.sort, key, ViewModel.PVP_FIRST_DESCENDING)
      UI.Redraw()
    end,
  })
  if data.shown < data.total then
    Kit.Label(region, {
      text = L("Showing the first %d of %d members."):format(data.shown, data.total),
      style = "small",
      color = "muted",
      wrap = true,
      layout = { gap = 10 },
    })
  end
end

local function ranking(page)
  local tracker = ns.pvpTracker
  local rosterNames = {}
  if ns.guildRoster then
    for _, name in ipairs(ns.guildRoster:Names()) do
      rosterNames[name] = true
    end
  end
  local rows, columns = ViewModel.PvPRanking(ns.db.global.pvpStats, {
    own = { name = ns.Platform.GetIdentityKey(), stats = ns.character.pvp },
    rosterNames = rosterNames,
    blowsAvailable = tracker ~= nil and tracker.blowsAvailable,
    now = ns.Platform.ServerTime(),
    sort = state.sort,
    period = state.period,
    day = tracker and tracker:Day() or nil,
  })

  local bar = Kit.Row(page, { gap = 12, align = "center" })
  Kit.Segmented(bar, {
    items = ViewModel.PVP_PERIOD_CHOICES,
    value = state.period,
    layout = { width = "auto" },
    onChange = function(value)
      state.period = value
      UI.Redraw()
    end,
  })
  local region
  Kit.EditBox(bar, {
    text = state.search,
    placeholder = L("Search by name"),
    layout = { weight = 1 },
    onChange = function(text, userInput)
      if userInput and region then
        state.search = text
        region:Clear()
        drawRankingTable(
          region,
          ViewModel.RankingTable(rows, { search = state.search, limit = ns.Constants.PVP_RANKING_ROWS_MAX }),
          columns.blows
        )
        UI.Relayout()
      end
    end,
  })
  region = Kit.Stack(page, { gap = 0 })
  drawRankingTable(
    region,
    ViewModel.RankingTable(rows, { search = state.search, limit = ns.Constants.PVP_RANKING_ROWS_MAX }),
    columns.blows
  )
  local hint = state.period == "today" and L("Today's kills (server day, UTC); the rank is the all-time one. ") or ""
  Kit.Label(page, {
    text = hint .. L("Counters come from members who run the addon, about a minute after a kill."),
    style = "small",
    color = "muted",
    wrap = true,
  })
  if ns.comm and ns.PermissionService.Can(UI.Role(), "moderate") then
    adminCard(page, ViewModel.RankingTable(rows, { limit = ns.Constants.PVP_RANKING_ROWS_MAX }).rows)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Recent kills

local function feed(page)
  local source = ns.pvpFeed
  local data = ViewModel.FeedRows(source and source:Entries() or {}, {
    available = source ~= nil and source:Available(),
    formatTime = ns.Platform.FormatClock,
  })
  if data.notice == "unavailable" then
    Kit.Banner(page, {
      kind = "warning",
      text = L("The kill feed is not available on this client: the name of a killed player cannot be read."),
    })
  end
  if #data.rows == 0 then
    Kit.EmptyState(page, {
      icon = "swords",
      title = L("No kills yet"),
      hint = L("Your kills show up here."),
    })
    return
  end
  local rows = {}
  for _, row in ipairs(data.rows) do
    rows[#rows + 1] = {
      title = row.text,
      subtitle = row.time .. " \194\183 " .. row.place,
      badge = row.blow and { text = L("Killing blow"), color = "danger" } or nil,
      tooltipWhenCut = true,
    }
  end
  Kit.List(page, { rows = rows })
end

UI.Register("pvp", function(page)
  Kit.PageHeader(page, {
    title = "PvP",
    description = L("Your honourable kills, the guild ranking and the latest kills."),
  })
  Kit.TabStrip(page, {
    tabs = ViewModel.PvPSubTabs(),
    value = state.sub,
    onSelect = function(value)
      state.sub = value
      UI.Redraw()
    end,
  })
  if state.sub == "ranking" then
    ranking(page)
  elseif state.sub == "feed" then
    feed(page)
  else
    myStats(page)
  end
end)
