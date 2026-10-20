local _, ns = ...

-- Home (plan 3.1): a 2x2 grid of cards: your readiness, the sync state (read-only: sync is automatic), the next raid
-- event and the open loot sessions. Who you are is in the card at the bottom of the sidebar, and the settings are
-- behind
-- the gear of the header.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local NO_ROSTER_TITLE = ns.Locale.Table(function()
  return {
    title = L("You are not in a roster yet"),
    hint = L("An admin has to assign you one."),
  }
end)

local function readinessCard(grid)
  local character = ns.character
  local results, summary =
    ns.ReadinessService.Evaluate(ns.ReadinessRules.Current(), character.profile, character.readiness)
  local data = ViewModel.ReadinessCard(results, summary)
  local card = Kit.Card(grid, { title = L("Your readiness") })
  local head = Kit.Row(card, { gap = 14, align = "center" })
  Kit.StatusChip(head, { status = data.status, size = 40, layout = { width = 40 } })
  Kit.Label(head, { text = data.stateText, style = "hero", layout = { weight = 1 } })
  Kit.Label(card, { text = data.line, color = "dim" })
  Kit.ProgressBar(card, { value = data.ratio, color = Kit.Theme.StatusToken(data.status) })
  if data.missingText then
    Kit.Label(card, { text = data.missingText, wrap = true, style = "small", color = "muted" })
  end
  Kit.Button(card, {
    text = L("See details"),
    variant = "ghost",
    icon = "chevron",
    layout = { width = "auto" },
    onClick = function()
      UI.OpenTab("ready")
    end,
  })
end

local function syncCard(grid)
  local info = ns.comm and ns.comm:StatusInfo() or nil
  local data = ViewModel.SyncRows(info, ns.Platform.Now())
  local card = Kit.Card(grid, { title = L("Sync"), gap = 6 })
  for _, row in ipairs(data.rows) do
    Kit.KeyValue(card, { label = row.label, value = row.value, dot = row.dot })
  end
  for _, warning in ipairs(data.warnings) do
    Kit.Label(card, { text = warning, style = "small", color = "warning", wrap = true })
  end
  Kit.Label(card, { text = L("Sync is automatic."), style = "small", color = "muted", layout = { gap = 10 } })
end

local function nextEventCard(grid, events, viewer)
  local card = Kit.Card(grid, { title = L("Next raid event") })
  if viewer.mode == "blocked" then
    Kit.Label(card, { text = NO_ROSTER_TITLE.title, color = "text" })
    Kit.Label(card, { text = NO_ROSTER_TITLE.hint, style = "small", color = "muted", wrap = true })
    return
  end
  local nextEvent = ViewModel.NextEventCard(events, ns.Platform.ServerTime())
  if not nextEvent then
    Kit.Label(card, { text = L("No upcoming events"), color = "text" })
    Kit.Label(card, { text = L("Nothing is planned yet."), style = "small", color = "muted" })
    return
  end
  local head = Kit.Row(card, { gap = 10, align = "center" })
  Kit.Label(head, { text = nextEvent.title, style = "value", layout = { weight = 1 } })
  Kit.Badge(head, { text = nextEvent.statusText, color = nextEvent.statusToken, layout = { width = "auto" } })
  Kit.Label(card, { text = nextEvent.when or L("No date"), color = "dim" })
  Kit.Button(card, {
    text = L("Open in Raid"),
    variant = "ghost",
    icon = "chevron",
    layout = { width = "auto" },
    onClick = function()
      UI.OpenTab("raid", { eventId = nextEvent.eventId })
    end,
  })
end

local function lootCard(grid, events, viewer)
  local card = Kit.Card(grid, { title = L("Open loot sessions") })
  if viewer.mode == "blocked" then
    Kit.Label(card, { text = NO_ROSTER_TITLE.title, color = "text" })
    Kit.Label(card, { text = NO_ROSTER_TITLE.hint, style = "small", color = "muted", wrap = true })
    return
  end
  local rows, total = ViewModel.OpenLootSessions(events, 3)
  if #rows == 0 then
    Kit.Label(card, { text = L("No open loot sessions"), color = "text" })
    Kit.Label(card, { text = L("The council opens them after an encounter."), style = "small", color = "muted" })
    return
  end
  for _, row in ipairs(rows) do
    local line = Kit.Row(card, { gap = 8, align = "center" })
    Kit.ItemLabel(line, { itemId = row.itemId, text = row.itemName, size = 22, layout = { weight = 1 } })
    Kit.Label(line, { text = row.candidatesText, style = "small", color = "muted", layout = { width = "auto" } })
    Kit.Label(card, { text = row.eventTitle, style = "small", color = "muted", layout = { gap = 0 } })
  end
  if total > #rows then
    Kit.Label(card, { text = L("%d more"):format(total - #rows), style = "small", color = "muted" })
  end
  Kit.Button(card, {
    text = L("Open in Loot"),
    variant = "ghost",
    icon = "chevron",
    layout = { width = "auto" },
    onClick = function()
      UI.OpenTab("loot", { eventId = rows[1].eventId })
    end,
  })
end

UI.Register("home", function(page)
  Kit.PageHeader(page, {
    title = L("Home"),
    description = L("Your readiness, the sync state and what is coming up."),
  })
  local viewer = UI.Viewer()
  local events = ns.RosterService.FilterEvents(ns.db.global.events, viewer)
  local grid = Kit.Grid(page, { columns = 2, gap = 20 })
  readinessCard(grid)
  syncCard(grid)
  nextEventCard(grid, events, viewer)
  lootCard(grid, events, viewer)
end)
