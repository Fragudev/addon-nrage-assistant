local _, ns = ...

-- PvP (plan 3.6 and docs/PVP_MISSIONS_PLAN.md phases 4 and 5): sub-tabs Season, Missions, Stats (My stats and the
-- kill Ranking), Recent kills, History and Admin. PvP is guild-wide: rosters do not apply. The season data comes from
-- `ns.pvpSeason` (the ledger service) and the progress of the missions from `ns.pvpMissions` (the detection), which
-- may be missing: then the missions show without progress and cannot be claimed.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local DAY = 86400
local NEW_SEASON_DAYS = 30

-- What the tab remembers while the session lasts.
local state = {
  sub = "season",
  stats = "mine",
  history = "season",
  admin = "approvals",
  sort = { key = "total", descending = true },
  period = "total",
  search = "",
  resetTarget = nil,
  noteOpen = nil,
  notes = {},
  openClaim = nil,
  missionDraft = nil,
  seasonDraft = nil,
  prize = { tier = "1", gold = "", link = "", count = "1" },
  deliverySeason = nil,
  openFinal = {},
  cloneFrom = nil,
}

local function service()
  return ns.pvpSeason
end

local function isApprover()
  local svc = service()
  return svc ~= nil and svc:IsApprover()
end

local function canManage()
  local svc = service()
  return svc ~= nil and svc:CanPvP("pvp_season_manage")
end

-- The name of a zone: the constant list when the project has one (PVP_MISSION_ZONES = { { mapId, nameKey } }), else the
-- mission tracker's own naming when it has one; nil lets the view model write the map id.
local function zoneName(mapId)
  for _, zone in ipairs(ns.Constants.PVP_MISSION_ZONES or {}) do
    if zone.mapId == mapId and zone.nameKey then
      return L(zone.nameKey)
    end
  end
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

-- Admin -> Season: reset the kill counters of a member (the old Admin card of the ranking).
local function killCounters(page)
  local rows = ViewModel.RankingTable((rankingData()), { limit = ns.Constants.PVP_RANKING_ROWS_MAX }).rows
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
  local card = Kit.Card(page, { title = L("Kill counters"), gap = 10 })
  Kit.Label(card, {
    text = L("Resets the counters of a member on every client. It does not touch the season points."),
    style = "small",
    color = "dim",
    wrap = true,
  })
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

function rankingData()
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
          name = { text = row.name, color = row.mine and "accent" or nil },
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
  Kit.Label(head, { text = summary.name, style = "hero", layout = { weight = 1 } })
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
  UI.Notify("success", L("Claim sent. An admin or PvP officer has to approve it."))
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
  for _, bar in ipairs(card.bars) do
    local line = Kit.Row(box, { gap = 8, layout = { gap = 8 } })
    Kit.Label(line, { text = bar.label, style = "small", color = "dim", layout = { weight = 1 } })
    Kit.Label(line, { text = bar.text, style = "small", layout = { width = "auto" } })
    Kit.ProgressBar(box, { value = bar.ratio, color = bar.complete and "success" or "accent", layout = { gap = 4 } })
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
    Kit.Badge(actions, { text = card.status.text, color = card.status.color, layout = { width = "auto" } })
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
          name = { text = row.name, color = row.mine and "accent" or nil },
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
      Kit.Badge(head, { text = card.delivery.text, color = card.delivery.color, layout = { width = "auto" } })
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

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: approvals

local function decide(action, claimId)
  local svc = service()
  local record, reason = svc[action](svc, claimId)
  if not record then
    fail(reason)
    return
  end
  if state.openClaim == claimId then
    state.openClaim = nil
  end
  UI.Notify(
    "success",
    action == "Approve" and L("Claim approved. The points are in the ranking.") or L("Claim rejected.")
  )
end

local function evidenceTable(box, row)
  local rows = {}
  for _, entry in ipairs(row.evidence) do
    rows[#rows + 1] = {
      cells = {
        time = { text = entry.time, color = "muted" },
        victim = entry.victim,
        zone = entry.zone,
        info = { text = entry.info, color = entry.unknown and "warning" or "dim" },
      },
    }
  end
  Kit.Table(box, {
    columns = {
      { key = "time", title = L("Time"), width = 60, fit = true },
      { key = "victim", title = L("Victim"), weight = 1.5 },
      { key = "zone", title = L("Zone"), weight = 1.5 },
      { key = "info", title = L("Class and race"), weight = 1.5 },
    },
    fit = true,
    rows = rows,
    layout = { gap = 8 },
  })
  if row.more then
    Kit.Label(box, { text = row.more, style = "small", color = "muted" })
  end
end

local function approvals(page)
  local svc = service()
  local rows = ViewModel.PvPClaimRows(svc:Queue(), {
    missionOf = function(id)
      return svc:Mission(id)
    end,
    now = ns.Platform.ServerTime(),
    formatClock = ns.Platform.FormatClock,
    zoneName = zoneName,
  })
  local rejected = ViewModel.PvPClaimRows(svc:Rejected(), {
    missionOf = function(id)
      return svc:Mission(id)
    end,
    now = ns.Platform.ServerTime(),
    formatClock = ns.Platform.FormatClock,
    zoneName = zoneName,
  })
  if #rows == 0 and #rejected == 0 then
    Kit.EmptyState(page, {
      icon = "check-circle",
      title = L("No claims waiting"),
      hint = L("Claims show up here when the members complete a mission."),
    })
  end
  if #rows > 0 then
    local box = Kit.Card(page, { gap = 14 })
    for _, row in ipairs(rows) do
      local line = Kit.Row(box, { gap = 8, align = "center" })
      local text = Kit.Stack(line, { gap = 2, layout = { weight = 1 } })
      Kit.Label(text, { text = ("%s \194\183 %s  %s"):format(row.who, row.mission, row.points), wrap = true })
      Kit.Label(text, {
        text = row.summary .. " \194\183 " .. row.when,
        style = "small",
        color = "muted",
        wrap = true,
      })
      local open = state.openClaim == row.id
      Kit.Button(line, {
        text = open and L("Hide evidence") or L("View evidence"),
        variant = "ghost",
        layout = { width = "auto" },
        onClick = function()
          state.openClaim = (not open) and row.id or nil
          UI.Redraw()
        end,
      })
      Kit.Button(line, {
        text = L("Reject"),
        variant = "danger",
        layout = { width = "auto" },
        onClick = function()
          decide("Reject", row.id)
        end,
      })
      Kit.Button(line, {
        text = L("Approve"),
        variant = "primary",
        layout = { width = "auto" },
        onClick = function()
          decide("Approve", row.id)
        end,
      })
      if open then
        if row.note then
          Kit.Label(box, { text = L("Note: %s"):format(row.note), style = "small", color = "dim", wrap = true })
        end
        if #row.evidence > 0 then
          evidenceTable(box, row)
        end
      end
    end
  end
  if #rejected > 0 then
    local box = Kit.Card(page, { title = L("Rejected claims"), gap = 10 })
    for _, row in ipairs(rejected) do
      local line = Kit.Row(box, { gap = 8, align = "center" })
      Kit.Label(line, {
        text = ("%s \194\183 %s"):format(row.who, row.mission),
        color = "dim",
        layout = { weight = 1 },
      })
      Kit.Button(line, {
        text = L("Approve"),
        layout = { width = "auto" },
        onClick = function()
          decide("Approve", row.id)
        end,
      })
    end
  end
  Kit.Label(page, {
    text = L("The evidence is the kills the player's addon recorded.") .. " " .. L(
      "You decide whether kills without a known class or race count."
    ) .. " " .. L("Approving the same claim twice adds it only once."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: missions

local function fieldRow(parent, label, build, layout)
  local field = Kit.Field(parent, { label = label, layout = layout or { weight = 1 } })
  build(field)
  return field
end

local function saveMission()
  local svc = service()
  local fields, reason = ViewModel.PvPMissionFields(state.missionDraft)
  if not fields then
    fail(reason)
    return
  end
  local mission, why = svc:UpsertMission(fields)
  if not mission then
    fail(why)
    return
  end
  state.missionDraft = nil
  UI.Notify("success", L("Mission saved."))
end

-- Toggles a zone of the constant list in the draft's zone text.
local function toggleZone(draft, mapId, on)
  local zones = ViewModel.PvPParseZones(draft.zones) or {}
  local kept = {}
  for _, id in ipairs(zones) do
    if id ~= mapId then
      kept[#kept + 1] = id
    end
  end
  if on then
    kept[#kept + 1] = mapId
  end
  draft.zones = table.concat(kept, ", ")
end

local function zonesField(parent, draft)
  local field = Kit.Field(parent, { label = L("Zones (optional)") })
  local list = ns.Constants.PVP_MISSION_ZONES
  local row
  if list then
    -- The listed zones, then any selected zone the list does not have (added as the current zone), so it can be
    -- seen and taken out again.
    local selected = ViewModel.PvPParseZones(draft.zones) or {}
    local isSelected, listed = {}, {}
    for _, mapId in ipairs(selected) do
      isSelected[mapId] = true
    end
    local flow = Kit.Flow(field, { gap = 6, rowGap = 6 })
    local function chip(mapId)
      Kit.Chip(flow, {
        text = zoneName(mapId) or tostring(mapId),
        active = isSelected[mapId] == true,
        onToggle = function(active)
          toggleZone(draft, mapId, active)
        end,
      })
    end
    for _, zone in ipairs(list) do
      listed[zone.mapId] = true
      chip(zone.mapId)
    end
    for _, mapId in ipairs(selected) do
      if not listed[mapId] then
        chip(mapId)
      end
    end
    row = Kit.Row(field, { gap = 8 })
  else
    row = Kit.Row(field, { gap = 8 })
    Kit.EditBox(row, {
      text = draft.zones,
      placeholder = L("Map ids, separated by commas"),
      layout = { weight = 1 },
      onChange = function(text)
        draft.zones = text
      end,
    })
  end
  if type(ns.Platform.GetPlayerMapId) == "function" then
    Kit.Button(row, {
      text = L("Add current zone"),
      layout = { width = "auto" },
      onClick = function()
        local mapId = currentZone()
        if not mapId then
          UI.Notify("warning", L("The current zone could not be read."))
          return
        end
        toggleZone(draft, mapId, true)
        UI.Redraw()
      end,
    })
  end
end

local function missionForm(page)
  local draft = state.missionDraft
  local tracker = ns.pvpMissions
  local title = draft.id and L("Edit mission") or L("New mission")
  local card = Kit.Card(page, { title = title, gap = 12 })
  fieldRow(card, L("Title"), function(field)
    Kit.EditBox(field, {
      text = draft.title,
      maxLetters = ns.Constants.PVP_MISSION_TITLE_MAX,
      onChange = function(text)
        draft.title = text
      end,
    })
  end, { weight = 1 })
  fieldRow(card, L("Description"), function(field)
    Kit.EditBox(field, {
      text = draft.desc,
      maxLetters = ns.Constants.PVP_MISSION_DESC_MAX,
      onChange = function(text)
        draft.desc = text
      end,
    })
  end, { weight = 1 })

  local goal = Kit.Row(card, { gap = 16 })
  fieldRow(goal, L("Goal"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPGoalChoices(tracker and tracker:Availability() or nil),
      value = draft.kind,
      onChange = function(value)
        draft.kind = value
        UI.Redraw()
      end,
    })
  end)
  if draft.kind ~= "manual" then
    fieldRow(goal, L("Count"), function(field)
      Kit.EditBox(field, {
        text = draft.count,
        numeric = true,
        maxLetters = 3,
        onChange = function(text)
          draft.count = text
        end,
      })
    end)
  end
  fieldRow(goal, L("Points"), function(field)
    Kit.EditBox(field, {
      text = draft.points,
      numeric = true,
      maxLetters = 4,
      onChange = function(text)
        draft.points = text
      end,
    })
  end)

  if draft.kind ~= "manual" then
    zonesField(card, draft)
  end
  if draft.kind == "kills" then
    local where = Kit.Row(card, { gap = 16 })
    fieldRow(where, L("Place"), function(field)
      Kit.Dropdown(field, {
        items = ViewModel.PvPPlaceChoices(),
        value = draft.place,
        onChange = function(value)
          draft.place = value
        end,
      })
    end)
    fieldRow(where, L("Distinct by"), function(field)
      Kit.Dropdown(field, {
        items = ViewModel.PvPDistinctChoices(),
        value = draft.distinct,
        onChange = function(value)
          draft.distinct = value
        end,
      })
    end)
  end

  local when = Kit.Row(card, { gap = 16 })
  fieldRow(when, L("Repeats"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPRepeatChoices(),
      value = draft.repeatKind,
      onChange = function(value)
        draft.repeatKind = value
      end,
    })
  end)
  fieldRow(when, L("Times per player"), function(field)
    Kit.EditBox(field, {
      text = draft.perPlayer,
      numeric = true,
      maxLetters = 2,
      onChange = function(text)
        draft.perPlayer = text
      end,
    })
  end)
  fieldRow(when, L("Status"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPActiveChoices(),
      value = draft.active,
      onChange = function(value)
        draft.active = value
      end,
    })
  end)

  local buttons = Kit.Row(card, { gap = 10, layout = { gap = 14 } })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  Kit.Button(buttons, {
    text = L("Cancel"),
    variant = "ghost",
    layout = { width = "auto" },
    onClick = function()
      state.missionDraft = nil
      UI.Redraw()
    end,
  })
  Kit.Button(buttons, {
    text = draft.id and L("Save mission") or L("Create mission"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = saveMission,
  })
end

local function cloneMissions(seasonId)
  local svc = service()
  local season = svc:ActiveSeason()
  local copied = 0
  for _, mission in ipairs(svc:Missions(seasonId, true)) do
    local zones = {}
    for index, mapId in ipairs(mission.goal.zones or {}) do
      zones[index] = mapId
    end
    local goal = {
      kind = mission.goal.kind,
      count = mission.goal.count,
      zones = zones,
      place = mission.goal.place,
      distinct = mission.goal.distinct,
    }
    local clone, reason = svc:UpsertMission({
      title = mission.title,
      desc = mission.desc,
      points = mission.points,
      goal = goal,
      repeatKind = mission.repeatKind,
      perPlayer = mission.perPlayer,
      active = mission.active,
    })
    if not clone then
      fail(reason)
      return
    end
    copied = copied + 1
  end
  state.cloneFrom = nil
  UI.Notify(
    "success",
    L("Copied %d mission(s) into '%s'."):format(copied, ViewModel.Escape(season and season.name or "?"))
  )
end

local function missionsAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.Button(bar, {
    text = L("New mission"),
    icon = "plus",
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      state.missionDraft = ViewModel.PvPMissionDraft(nil)
      UI.Redraw()
    end,
  })
  local sources = ViewModel.PvPCloneChoices(svc:Seasons(), season.id, function(seasonId)
    return #svc:Missions(seasonId, true)
  end)
  if #sources > 0 then
    Kit.Dropdown(bar, {
      items = sources,
      value = state.cloneFrom,
      placeholder = L("Copy from another season"),
      layout = { width = 240 },
      onChange = function(value)
        state.cloneFrom = value
        cloneMissions(value)
      end,
    })
  end

  local missions = svc:Missions(season.id, true)
  local rows = {}
  for _, row in ipairs(ViewModel.PvPMissionRows(missions, zoneName)) do
    rows[#rows + 1] = {
      cells = {
        title = row.title,
        criteria = { text = row.criteria, color = "dim" },
        points = row.points,
        status = { widget = "badge", opts = { text = row.status, color = row.token } },
        edit = {
          widget = "button",
          opts = {
            text = L("Edit"),
            variant = "ghost",
            onClick = function()
              state.missionDraft = ViewModel.PvPMissionDraft(svc:Mission(row.id))
              UI.Redraw()
            end,
          },
        },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "title", title = L("Mission"), weight = 1.4 },
      { key = "criteria", title = L("Criteria"), weight = 2.4 },
      { key = "points", title = L("Points"), width = 60, align = "RIGHT", fit = true },
      { key = "status", title = L("Status"), width = 90, fit = true },
      { key = "edit", title = "", width = 70 },
    },
    fit = true,
    rows = rows,
    emptyText = L("There are no missions yet."),
  })
  if state.missionDraft then
    missionForm(page)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: season

local function seasonDraft(season)
  local draft = state.seasonDraft
  local key = season and season.id or false
  if draft and draft.key == key then
    return draft
  end
  local now = ns.Platform.ServerTime()
  draft = {
    key = key,
    name = season and season.name or "",
    startsAt = season and season.startsAt or now,
    endsAt = season and season.endsAt or (now + NEW_SEASON_DAYS * DAY),
  }
  state.seasonDraft = draft
  return draft
end

local function saveSeason(season, draft)
  local svc = service()
  local fields = { name = draft.name, startsAt = draft.startsAt, endsAt = draft.endsAt }
  local record, reason
  if season then
    record, reason = svc:EditSeason(season.id, fields)
  else
    record, reason = svc:CreateSeason(fields)
  end
  if not record then
    fail(reason)
    return
  end
  state.seasonDraft = nil
  UI.Notify("success", L("Season saved."))
end

local function closeSeason(season)
  local svc = service()
  local final, expired = svc:CloseSeason(season.id)
  UI.Disarm()
  if not final then
    fail(expired)
    return
  end
  state.seasonDraft = nil
  state.deliverySeason = final.seasonId
  UI.Notify(
    "success",
    L("Season closed: %d player(s) ranked, %d claim(s) expired."):format(#final.standings, expired or 0)
  )
end

local function dateField(parent, label, value, onChange)
  local field = Kit.Field(parent, { label = label, layout = { weight = 1 } })
  Kit.DateField(field, {
    value = value,
    placeholder = L("Pick a date and time"),
    format = ViewModel.DateText,
    now = ns.Platform.ServerTime,
    monthName = function(month)
      return ViewModel.MONTHS_LONG[month]
    end,
    weekdayName = function(index)
      return ViewModel.WEEKDAYS[index]:sub(1, 2)
    end,
    onChange = onChange,
    onError = function()
      UI.Notify("danger", L("That time does not exist on that day (the clocks change)."))
    end,
  })
end

local function seasonAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  local draft = seasonDraft(season)
  local card = Kit.Card(page, { title = season and L("Active season") or L("New season"), gap = 12 })
  local name = Kit.Field(card, { label = L("Name") })
  Kit.EditBox(name, {
    text = draft.name,
    maxLetters = ns.Constants.PVP_SEASON_NAME_MAX,
    onChange = function(text)
      draft.name = text
    end,
  })
  local dates = Kit.Row(card, { gap = 16 })
  dateField(dates, L("Start"), draft.startsAt, function(timestamp)
    draft.startsAt = timestamp
  end)
  dateField(dates, L("End"), draft.endsAt, function(timestamp)
    draft.endsAt = timestamp
  end)
  Kit.Label(card, {
    text = L(
      "The end date only stops new claims. Close the season with the button when you have reviewed the pending ones."
    ),
    style = "small",
    color = "dim",
    wrap = true,
  })
  local buttons = Kit.Row(card, { gap = 10, align = "center" })
  Kit.Button(buttons, {
    text = season and L("Save") or L("Create season"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      saveSeason(season, draft)
    end,
  })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  if season then
    local key = "pvpclose:" .. season.id
    local armed = UI.IsArmed(key)
    Kit.Button(buttons, {
      text = armed and L("Confirm: close and freeze the ranking") or L("Close season"),
      variant = armed and "dangerSolid" or "danger",
      layout = { width = "auto" },
      onClick = function()
        if not armed then
          UI.Arm(key)
          return
        end
        closeSeason(season)
      end,
    })
    if armed then
      Kit.Label(card, {
        text = ViewModel.PvPCloseWarning(#svc:Queue()),
        style = "small",
        color = "warning",
        wrap = true,
      })
    end
  end
  if ns.comm and ns.PermissionService.Can(UI.Role(), "moderate") then
    killCounters(page)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: prizes

local function savePrizes(seasonId, tiers)
  local record, reason = service():SetPrizes(seasonId, tiers)
  if not record then
    fail(reason)
    return false
  end
  return true
end

local function addReward(season, tiers, reward, reason)
  if not reward then
    fail(reason)
    return
  end
  local updated, why = ViewModel.PvPAddReward(tiers, state.prize.tier, reward)
  if not updated then
    fail(why)
    return
  end
  if savePrizes(season.id, updated) then
    state.prize.gold, state.prize.link = "", ""
    UI.Redraw()
  end
end

local function prizesAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local prizes = svc:Prizes(season.id)
  local tiers = prizes and prizes.tiers or {}
  local card = Kit.Card(page, { gap = 12 })
  for _, row in ipairs(ViewModel.PvPPrizeRows(tiers)) do
    local line = Kit.Row(card, { gap = 12 })
    Kit.Label(line, { text = row.label, color = row.token, layout = { width = 64 } })
    local chips = Kit.Flow(line, { gap = 6, rowGap = 6, layout = { weight = 1 } })
    if #row.rewards == 0 then
      Kit.Label(chips, { text = "-", color = "muted" })
    end
    for index, reward in ipairs(row.rewards) do
      Kit.Chip(chips, {
        text = ViewModel.PvPRewardText(reward),
        active = true,
        tooltip = L("Click to remove"),
        onToggle = function()
          savePrizes(season.id, ViewModel.PvPRemoveReward(tiers, row.tier, index))
          UI.Redraw()
        end,
      })
    end
  end

  local add = Kit.Card(page, { title = L("Add a reward"), gap = 10 })
  local tierRow = Kit.Row(add, { gap = 12, align = "center" })
  Kit.Label(tierRow, { text = L("Tier"), color = "dim", layout = { width = 64 } })
  local tierItems = {}
  for _, row in ipairs(ViewModel.PvPPrizeRows(tiers)) do
    tierItems[#tierItems + 1] = { value = row.tier, text = row.label }
  end
  Kit.Dropdown(tierRow, {
    items = tierItems,
    value = state.prize.tier,
    layout = { width = 140 },
    onChange = function(value)
      state.prize.tier = value
      UI.Redraw()
    end,
  })
  local gold = Kit.Row(add, { gap = 8 })
  Kit.EditBox(gold, {
    text = state.prize.gold,
    numeric = true,
    placeholder = L("Gold amount"),
    maxLetters = 6,
    layout = { weight = 1 },
    onChange = function(text)
      state.prize.gold = text
    end,
  })
  Kit.Button(gold, {
    text = L("Add gold"),
    icon = "plus",
    layout = { width = "auto" },
    onClick = function()
      addReward(season, tiers, ViewModel.PvPGoldReward(state.prize.gold))
    end,
  })
  local item = Kit.Row(add, { gap = 8 })
  Kit.EditBox(item, {
    text = state.prize.link,
    placeholder = L("Paste an item link"),
    layout = { weight = 1 },
    onChange = function(text)
      state.prize.link = text
    end,
  })
  Kit.EditBox(item, {
    text = state.prize.count,
    numeric = true,
    placeholder = L("Count"),
    maxLetters = 3,
    layout = { width = 70 },
    onChange = function(text)
      state.prize.count = text
    end,
  })
  Kit.Button(item, {
    text = L("Add item"),
    icon = "plus",
    layout = { width = "auto" },
    onClick = function()
      addReward(season, tiers, ViewModel.PvPItemReward(state.prize.link, state.prize.count))
    end,
  })
  Kit.Label(page, {
    text = L("Every player in a tier gets the full prize. To add an item, paste its link.") .. " " .. L(
      "The addon does not send gold or mail."
    ),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: deliveries

local function deliveriesAdmin(page)
  local svc = service()
  local finals = svc:Finals()
  if #finals == 0 then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("No closed seasons yet"),
      hint = L("When a season closes, the prizes to hand over are listed here."),
    })
    return
  end
  local chosen = finals[1]
  for _, final in ipairs(finals) do
    if final.seasonId == state.deliverySeason then
      chosen = final
    end
  end
  if #finals > 1 then
    Kit.Dropdown(page, {
      items = ViewModel.PvPFinalChoices(finals),
      value = chosen.seasonId,
      layout = { width = 260 },
      onChange = function(value)
        state.deliverySeason = value
        UI.Redraw()
      end,
    })
  end
  local data = ViewModel.PvPDeliveryRows(svc:Deliveries(chosen.seasonId))
  Kit.Label(page, {
    text = chosen.name .. " \194\183 " .. ViewModel.PvPDeliveryHeader(chosen, data.delivered, data.total),
    color = "dim",
    wrap = true,
  })
  local rows = {}
  for _, row in ipairs(data.rows) do
    rows[#rows + 1] = {
      cells = {
        position = { text = tostring(row.pos), color = row.positionToken },
        player = row.player,
        tier = { widget = "badge", opts = { text = row.tier.text, color = row.tier.color } },
        reward = row.reward,
        status = row.delivered and { text = row.delivered, color = "success" } or {
          widget = "button",
          opts = {
            text = L("Mark delivered"),
            onClick = function()
              local record, reason = svc:MarkDelivery(chosen.seasonId, row.raw, true)
              if not record then
                fail(reason)
                return
              end
              UI.Redraw()
            end,
          },
        },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
      { key = "player", title = L("Player"), weight = 1.5 },
      { key = "tier", title = L("Tier"), width = 80, fit = true },
      { key = "reward", title = L("Reward"), weight = 2 },
      { key = "status", title = L("Status"), weight = 2 },
    },
    fit = true,
    rows = rows,
    emptyText = L("Nobody won a prize."),
  })
  Kit.Label(page, {
    text = L(
      "The addon does not send gold or mail: hand it over in game and mark it here. It stays in the season history."
    ),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin

local function adminView(page)
  local svc = service()
  local manage = canManage()
  local sections = ViewModel.PvPAdminSections({ manage = manage, pending = #svc:Queue() })
  state.admin = ViewModel.PvPPick(sections, state.admin)
  Kit.Segmented(page, {
    items = sections,
    value = state.admin,
    layout = { width = "auto" },
    onChange = function(value)
      state.admin = value
      UI.Redraw()
    end,
  })
  if state.admin == "missions" then
    missionsAdmin(page)
  elseif state.admin == "season" then
    seasonAdmin(page)
  elseif state.admin == "prizes" then
    prizesAdmin(page)
  elseif state.admin == "deliveries" then
    deliveriesAdmin(page)
  else
    approvals(page)
  end
end

UI.Register("pvp", function(page)
  Kit.PageHeader(page, {
    title = "PvP",
    description = L("Season missions with a points ranking and prizes, and the guild's honourable kills."),
  })
  local tabs = ViewModel.PvPSubTabs({ admin = isApprover() })
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
  elseif state.sub == "admin" then
    adminView(page)
  else
    seasonView(page)
  end
end)
