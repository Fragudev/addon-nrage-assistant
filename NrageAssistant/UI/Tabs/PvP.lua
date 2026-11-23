local _, ns = ...

-- PvP (plan 3.6 and docs/PVP_MISSIONS_PLAN.md phases 4 and 5): sub-tabs Season, Missions, Stats (My stats and the
-- kill Ranking), Recent kills, History and Intel (UI/Tabs/PvPIntel.lua); the admin views are in UI/Tabs/PvPAdmin.lua.
-- PvP is guild-wide: rosters do
-- not apply. The season data comes from `ns.pvpSeason` (the ledger service) and the progress of the missions from
-- `ns.pvpMissions` (the detection), which may be missing: then the missions show without progress and cannot be
-- claimed.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- What the tab remembers while the session lasts.
local state = {
  sub = "season",
  stats = "mine",
  history = "season",
  sort = { key = "total", descending = true },
  period = "total",
  search = "",
  noteOpen = nil,
  notes = {},
  openFinal = {},
}

local function service()
  return ns.pvpSeason
end

-- The name of a zone of the zone tree (PVP_MISSION_REGIONS), from the mission tracker; nil lets the view model write
-- the map id.
local function zoneName(mapId)
  local tracker = ns.PvPMissionTracker
  if tracker and tracker.ZoneName then
    return tracker.ZoneName(mapId)
  end
  return nil
end

-- A progress bar label ("Kills") in the player's language, through the tracker when it can translate it.
local function barLabel(label)
  local tracker = ns.PvPMissionTracker
  if tracker and tracker.LabelText then
    return tracker.LabelText(label)
  end
  return label
end

-- The map id of the zone the player stands in, or nil when the client cannot say (or this build cannot read it).
local function currentZone()
  local read = ns.Platform and ns.Platform.GetPlayerMapId
  if type(read) ~= "function" then
    return nil
  end
  local ok, mapId = pcall(read)
  if ok and type(mapId) == "number" then
    return mapId
  end
  return nil
end

local function fail(reason)
  UI.Notify("danger", ViewModel.PvPError(reason))
end

local function noSeason(page)
  Kit.EmptyState(page, {
    icon = "swords",
    title = L("No season is running"),
    hint = L("When an admin starts one, its missions and ranking show up here."),
  })
end

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

local rankingData

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
        name = { text = row.name, color = row.mine and "info" or nil },
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

-- The guild may hold a record of this character above the local counters (saved counters lost while the guild kept
-- them): the others show that record, so this character takes it over instead of showing zeros. Never lowers anything.
local function adoptHeldRecord()
  local held = ns.db and ns.db.global.pvpStats and ns.db.global.pvpStats[ns.Platform.GetIdentityKey()]
  if held and ns.character and ns.PvPService.Adopt(ns.character.pvp, held) and ns.pvpPublisher then
    ns.pvpPublisher:Changed()
  end
end

function rankingData()
  adoptHeldRecord()
  local tracker = ns.pvpTracker
  local rosterNames = {}
  if ns.guildRoster then
    for _, name in ipairs(ns.guildRoster:Names()) do
      rosterNames[name] = true
    end
  end
  return ViewModel.PvPRanking(ns.db.global.pvpStats, {
    own = { name = ns.Platform.GetIdentityKey(), stats = ns.character.pvp },
    rosterNames = rosterNames,
    blowsAvailable = tracker ~= nil and tracker.blowsAvailable,
    now = ns.Platform.ServerTime(),
    sort = state.sort,
    period = state.period,
    day = tracker and tracker:Day() or nil,
  })
end

local function ranking(page)
  local rows, columns = rankingData()

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
        UI.Refill(region, function(target)
          drawRankingTable(
            target,
            ViewModel.RankingTable(rows, { search = state.search, limit = ns.Constants.PVP_RANKING_ROWS_MAX }),
            columns.blows
          )
        end)
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

-- ---------------------------------------------------------------------------------------------------------------
-- Season

local function standingColumns()
  return {
    { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
    { key = "name", title = L("Name"), weight = 2 },
    { key = "tier", title = L("Prize"), weight = 1, fit = true },
    { key = "missions", title = L("Missions"), width = 62, align = "RIGHT", fit = true },
    { key = "points", title = L("Points"), width = 62, align = "RIGHT", fit = true },
    { key = "last", title = L("Last"), weight = 1.2, fit = true },
  }
end

-- The standings as a table: the own row on the accent wash, and a quiet row under the last prize.
local function standingsTable(region, data)
  local rows = {}
  for _, row in ipairs(data.rows) do
    if row.separator then
      rows[#rows + 1] = { cells = { name = { text = L("No prizes below this line"), color = "muted" } } }
    else
      rows[#rows + 1] = {
        highlight = row.mine,
        cells = {
          position = { text = tostring(row.pos), color = row.positionToken },
          name = { text = row.name, color = row.mine and "info" or nil },
          tier = row.tier and { widget = "badge", opts = { text = row.tier.text, color = row.tier.color } } or "-",
          missions = row.missions,
          points = { text = row.points, style = "smallMedium" },
          last = { text = row.last, color = "muted" },
        },
      }
    end
  end
  Kit.Table(region, {
    columns = standingColumns(),
    fit = true,
    rows = rows,
    emptyText = L("Nobody has points yet."),
  })
end

local function seasonView(page)
  local svc = service()
  local season = svc and svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local player = ns.Platform.GetIdentityKey()
  local standings = svc:Standings(season.id)
  local summary = ViewModel.PvPSeasonSummary({
    season = season,
    standings = standings,
    player = player,
    now = ns.Platform.ServerTime(),
  })

  local card = Kit.Card(page, { title = L("Active season"), gap = 12 })
  local head = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Label(head, { text = summary.name, style = "hero", glow = true, layout = { weight = 1 } })
  Kit.Label(head, {
    text = summary.range .. " \194\183 " .. summary.status,
    style = "small",
    color = summary.ended and "warning" or "dim",
    align = "RIGHT",
    layout = { weight = 1.4 },
  })
  Kit.StatGrid(card, { columns = 3, stats = summary.stats })

  local prizes = svc:Prizes(season.id)
  local prizeCard = Kit.Card(page, { title = L("Prizes when the season closes"), gap = 8 })
  local list = {}
  for _, row in ipairs(ViewModel.PvPPrizeRows(prizes and prizes.tiers)) do
    list[#list + 1] = { title = row.label, titleColor = row.token, value = row.text, valueColor = "text" }
  end
  Kit.List(prizeCard, { rows = list })

  local data = ViewModel.PvPStandingRows(standings, {
    player = player,
    missions = ViewModel.PvPGrantCounts(svc:Grants(season.id)),
    now = ns.Platform.ServerTime(),
    limit = ns.Constants.PVP_FINAL_STANDINGS_MAX,
  })
  standingsTable(page, data)
  Kit.Label(page, {
    text = L("On a tie, whoever reached that score first wins. At least 1 point is needed to get a prize."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Missions

local function sendClaim(missionId)
  local tracker = ns.pvpMissions
  if not tracker then
    return
  end
  local note = state.notes[missionId]
  local claim, reason = tracker:Claim(missionId, (note and note ~= "") and note or nil)
  if not claim then
    fail(reason or "unknown")
    return
  end
  state.noteOpen = nil
  state.notes[missionId] = nil
  UI.Notify("success", L("Claim sent. An admin has to approve it."))
end

local function drawMissionCard(page, card)
  local box = Kit.Card(page, { gap = 10 })
  local head = Kit.Row(box, { gap = 12, align = "center" })
  Kit.Label(head, { text = card.title, style = "value", layout = { weight = 1 } })
  Kit.Label(head, { text = card.points, style = "value", color = "accent", layout = { width = "auto" } })
  if card.desc ~= "" then
    Kit.Label(box, { text = card.desc, color = "dim", wrap = true })
  end
  local chips = Kit.Flow(box, { gap = 6, rowGap = 6 })
  for _, text in ipairs(card.chips) do
    Kit.Badge(chips, { text = text, color = "muted" })
  end
  -- The rules in plain words, and since when they count.
  Kit.Label(box, { text = card.rules, style = "small", color = "muted", wrap = true })
  if card.countsFrom then
    Kit.Label(box, { text = card.countsFrom, style = "small", color = "dim", wrap = true })
  end
  for _, bar in ipairs(card.bars) do
    local line = Kit.Row(box, { gap = 8, layout = { gap = 8 } })
    Kit.Label(line, { text = bar.label, style = "small", color = "dim", layout = { weight = 1 } })
    Kit.Label(line, { text = bar.text, style = "small", layout = { width = "auto" } })
    Kit.ProgressBar(box, {
      value = bar.ratio,
      color = bar.complete and "success" or "accent",
      xp = true,
      height = 10,
      layout = { gap = 4 },
    })
  end

  local actions = Kit.Row(box, { gap = 10, align = "center" })
  if card.canClaim and not card.noteRequired then
    Kit.Button(actions, {
      text = L("Claim"),
      variant = "primary",
      layout = { width = "auto" },
      onClick = function()
        sendClaim(card.id)
      end,
    })
  end
  if card.canClaim then
    Kit.Button(actions, {
      text = L("Claim with note"),
      layout = { width = "auto" },
      onClick = function()
        state.noteOpen = state.noteOpen ~= card.id and card.id or nil
        UI.Redraw()
      end,
    })
  end
  if card.status then
    Kit.Badge(
      actions,
      { text = card.status.text, color = card.status.color, fixed = true, layout = { width = "auto" } }
    )
  end
  if card.unavailable then
    Kit.Label(actions, { text = card.unavailable, style = "small", color = "muted", layout = { weight = 1 } })
  end
  if state.noteOpen == card.id and card.canClaim then
    local noteRow = Kit.Row(box, { gap = 8, layout = { gap = 8 } })
    Kit.EditBox(noteRow, {
      text = state.notes[card.id] or "",
      placeholder = card.noteRequired and L("Note for the approver (required)") or L("Note for the approver"),
      maxLetters = ns.Constants.PVP_NOTE_MAX,
      layout = { weight = 1 },
      onChange = function(text)
        state.notes[card.id] = text
      end,
    })
    Kit.Button(noteRow, {
      text = L("Send claim"),
      variant = "primary",
      icon = "send",
      layout = { width = "auto" },
      onClick = function()
        local note = state.notes[card.id]
        if card.noteRequired and not (note and note:match("%S")) then
          UI.Notify("warning", L("Write a note for the approver first."))
          return
        end
        sendClaim(card.id)
      end,
    })
  end
  if card.note then
    Kit.Label(box, { text = card.note, style = "small", color = "warning", wrap = true })
  end
end

local function missionsView(page)
  local svc = service()
  local season = svc and svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local ended = ns.Platform.ServerTime() > season.endsAt
  if ended then
    Kit.Banner(page, {
      kind = "warning",
      text = L("The season has ended and is waiting to be closed. New claims are not accepted."),
    })
  end
  local missions = svc:Missions(season.id)
  if #missions == 0 then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("No missions yet"),
      hint = L("An admin adds the missions of the season."),
    })
    return
  end
  local tracker = ns.pvpMissions
  local cards = ViewModel.PvPMissionCards(missions, {
    tracker = tracker ~= nil,
    progressOf = function(id)
      return tracker:Progress(id)
    end,
    claimStateOf = function(id)
      return tracker:ClaimState(id)
    end,
    availability = tracker and tracker:Availability() or nil,
    ended = ended,
    labelText = barLabel,
    zoneName = zoneName,
    now = ns.Platform.ServerTime(),
    season = season,
  })
  for _, card in ipairs(cards) do
    drawMissionCard(page, card)
  end
  Kit.Label(page, {
    text = L("Automatic missions count while you play; an admin approves your claim when you complete one.")
      .. " "
      .. L("The same victim counts at most %d times a day and grey kills do not count."):format(
        ns.Constants.PVP_VICTIM_DAILY_CAP or 3
      ),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stats

local function statsView(page)
  Kit.Segmented(page, {
    items = ViewModel.PvPStatsViews(),
    value = state.stats,
    layout = { width = "auto" },
    onChange = function(value)
      state.stats = value
      UI.Redraw()
    end,
  })
  if state.stats == "ranking" then
    ranking(page)
  else
    myStats(page)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- History

local function historyView(page)
  local svc = service()
  Kit.Segmented(page, {
    items = ViewModel.PvPHistoryViews(),
    value = state.history,
    layout = { width = "auto" },
    onChange = function(value)
      state.history = value
      UI.Redraw()
    end,
  })
  local finals = svc and svc:Finals() or {}
  if #finals == 0 then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("No closed seasons yet"),
      hint = L("The final standing of each season shows up here when an admin closes it."),
    })
    return
  end
  if state.history == "total" then
    local rows = {}
    for _, row in ipairs(ViewModel.PvPCumulativeRows(svc:Cumulative(), ns.Platform.GetIdentityKey())) do
      rows[#rows + 1] = {
        highlight = row.mine,
        cells = {
          position = { text = tostring(row.pos), color = row.positionToken },
          name = { text = row.name, color = row.mine and "info" or nil },
          seasons = row.seasons,
          podiums = row.podiums,
          points = { text = row.points, style = "smallMedium" },
        },
      }
    end
    Kit.Table(page, {
      columns = {
        { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
        { key = "name", title = L("Name"), weight = 2 },
        { key = "seasons", title = L("Seasons"), width = 80, align = "RIGHT", fit = true },
        { key = "podiums", title = L("Podiums"), width = 80, align = "RIGHT", fit = true },
        { key = "points", title = L("Points"), width = 70, align = "RIGHT", fit = true },
      },
      fit = true,
      rows = rows,
    })
    Kit.Label(page, {
      text = L("Sum of all the closed seasons. The running season counts when it closes."),
      style = "small",
      color = "muted",
      wrap = true,
    })
    return
  end

  local finalsById = {}
  for _, final in ipairs(finals) do
    finalsById[final.seasonId] = final
  end
  local cards = ViewModel.PvPHistoryCards(finals, function(seasonId)
    return svc:Deliveries(seasonId)
  end)
  for _, card in ipairs(cards) do
    local box = Kit.Card(page, { gap = 12 })
    local head = Kit.Row(box, { gap = 12, align = "center" })
    Kit.Label(head, { text = card.name, style = "value", layout = { weight = 1 } })
    Kit.Label(head, { text = card.dates, style = "small", color = "muted", layout = { width = "auto" } })
    if card.delivery then
      Kit.Badge(
        head,
        { text = card.delivery.text, color = card.delivery.color, fixed = true, layout = { width = "auto" } }
      )
    end
    local podium = Kit.Grid(box, { columns = 3, gap = 16 })
    for _, place in ipairs(card.podium) do
      Kit.StatBlock(podium, { caption = place.pos, value = place.name .. "  " .. place.points, color = place.token })
    end
    local open = state.openFinal[card.seasonId] == true
    Kit.Button(box, {
      text = open and L("Hide the full standing") or L("See the full standing"),
      variant = "ghost",
      layout = { width = "auto" },
      onClick = function()
        state.openFinal[card.seasonId] = not open
        UI.Redraw()
      end,
    })
    if open then
      local rows = {}
      for _, row in ipairs(ViewModel.PvPFinalRows(finalsById[card.seasonId])) do
        rows[#rows + 1] = {
          cells = {
            position = { text = tostring(row.pos), color = row.positionToken },
            name = row.name,
            tier = row.tier and { widget = "badge", opts = { text = row.tier.text, color = row.tier.color } } or "-",
            points = { text = row.points, style = "smallMedium" },
          },
        }
      end
      Kit.Table(box, {
        columns = {
          { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
          { key = "name", title = L("Name"), weight = 2 },
          { key = "tier", title = L("Prize"), weight = 1, fit = true },
          { key = "points", title = L("Points"), width = 70, align = "RIGHT", fit = true },
        },
        fit = true,
        rows = rows,
      })
    end
  end
end

-- What the PvP admin tab (UI/Tabs/PvPAdmin.lua) shares with this one.
UI.PvPShared = {
  sub = function()
    return state.sub
  end,
  service = service,
  fail = fail,
  noSeason = noSeason,
  rankingData = rankingData,
  zoneName = zoneName,
  currentZone = currentZone,
}

UI.Register("pvp", function(page)
  Kit.PageHeader(page, {
    title = "PvP",
    description = L("Season missions with a points ranking and prizes, and the guild's honourable kills."),
  })
  local tabs = ViewModel.PvPSubTabs()
  -- A link from another place (the Intel window, /nrage intel config) names the sub-tab to start on.
  if UI.nav.pvpSub then
    state.sub, UI.nav.pvpSub = UI.nav.pvpSub, nil
  end
  state.sub = ViewModel.PvPPick(tabs, state.sub)
  Kit.TabStrip(page, {
    tabs = tabs,
    value = state.sub,
    onSelect = function(value)
      state.sub = value
      UI.Redraw()
    end,
  })
  if state.sub == "missions" then
    missionsView(page)
  elseif state.sub == "stats" then
    statsView(page)
  elseif state.sub == "feed" then
    feed(page)
  elseif state.sub == "history" then
    historyView(page)
  elseif state.sub == "intel" then
    UI.PvPIntel(page)
  else
    seasonView(page)
  end
end)
