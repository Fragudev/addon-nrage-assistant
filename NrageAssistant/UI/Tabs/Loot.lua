local _, ns = ...

-- Loot (plan 3.3): the shared roster selector (plan 2.2) and the event selector, a form to open a session (with a live
-- preview of the pasted item and a strip with the items of the last boss you looted), one card per session with its
-- candidates table and per-row Vote and Award (the award asks for its reason under the row), and the minutes. The
-- roster rank sees it read-only: it answers for an item only from the loot popup. Every control calls the same
-- LootCommands method as the old slash commands, so the checks and the messages sent are the same.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local state = {
  selectedId = nil,
  itemText = "",
  upgrade = "",
  awarding = nil,
  awardReason = "",
  minutesOpen = false,
}

local function loot()
  local global = ns.db.global
  return ns.LootCommands.New({
    events = global.events,
    platform = ns.Platform,
    comm = ns.comm,
    rosters = global.rosters,
    members = global.members,
    onChange = UI.LootChanged,
  })
end

local NO_ROSTER = ns.Locale.Table(function()
  return {
    title = L("You are not in a roster yet"),
    hint = L("An admin has to assign you one."),
  }
end)

local function rankOf(name)
  local entry = ns.guildRoster and ns.guildRoster:Lookup(name)
  return entry and entry.rankName or nil
end

local function qualityColor(quality)
  return quality and Kit.Theme.QualityColor(quality) or "text"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Opening a session

local function bossStrip(card, event, commands)
  if not ns.Platform.LootWindowAvailable() then
    return
  end
  local items = ViewModel.BossLootItems(ns.bossLoot)
  if #items == 0 then
    return
  end
  Kit.Label(card, { text = L("Last boss loot"), style = "small", color = "muted", layout = { gap = 12 } })
  for _, item in ipairs(items) do
    local row = Kit.Row(card, { gap = 10, align = "center" })
    Kit.ItemLabel(row, {
      itemId = item.itemId,
      text = ViewModel.Escape(item.itemName),
      color = qualityColor(item.quality),
      layout = { weight = 1 },
    })
    Kit.Button(row, {
      text = L("Open"),
      layout = { width = 80 },
      onClick = function()
        UI.Report(commands:OpenItem(event, { itemId = item.itemId, itemName = item.itemName }))
      end,
    })
  end
end

local function openCard(page, event, commands)
  local card = Kit.Card(page, { title = L("Open a session"), gap = 10 })
  local field = Kit.Field(card, { label = L("Item link (shift-click the item into this box)") })
  local region
  Kit.EditBox(field, {
    text = state.itemText,
    onChange = function(text)
      state.itemText = text
      if region then
        region:Clear()
        UI.Loot_FillPreview(region, event, commands)
        UI.Relayout()
      end
    end,
  })
  region = Kit.Stack(card, { gap = 10 })
  UI.Loot_FillPreview(region, event, commands)
  bossStrip(card, event, commands)
end

-- The preview of the pasted item and the Open button, which only works for an item a session accepts.
function UI.Loot_FillPreview(region, event, commands)
  local preview = ViewModel.ItemPreview(state.itemText)
  if preview then
    Kit.ItemLabel(region, {
      itemId = preview.itemId,
      text = ViewModel.Escape(preview.itemName),
      color = qualityColor(preview.quality),
    })
  else
    Kit.Label(region, { text = L("Paste or shift-click an item link first."), style = "small", color = "muted" })
  end
  Kit.Button(region, {
    text = L("Open"),
    variant = "primary",
    disabled = preview == nil,
    layout = { width = 140 },
    onClick = function()
      local parsed = ViewModel.ItemPreview(state.itemText)
      if not parsed then
        return
      end
      state.itemText = ""
      UI.Report(commands:OpenItem(event, { itemId = parsed.itemId, itemName = parsed.itemName }))
    end,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- A session card

local NEED_BUTTONS = ns.Locale.Table(function()
  return {
    { need = "main", text = L("Main spec") },
    { need = "off", text = L("Off spec") },
    { need = "other", text = L("Other") },
  }
end)

local function applyRow(card, event, session, commands)
  local profile = ns.character.profile
  local mine = session.candidates[ns.Platform.GetIdentityKey()]
  local row = Kit.Row(card, { gap = 8 })
  for _, entry in ipairs(NEED_BUTTONS) do
    Kit.Button(row, {
      text = entry.text,
      variant = mine and mine.need == entry.need and "primary" or "secondary",
      layout = { weight = 1 },
      onClick = function()
        local spec = ViewModel.LootApplySpec(profile, entry.need)
        if not spec then
          UI.Notify("warning", L("Pick your spec in the Profile tab first."))
          return
        end
        UI.Report(commands:Apply(event, session, {
          spec = spec,
          need = entry.need,
          upgrade = state.upgrade ~= "" and state.upgrade or nil,
        }))
      end,
    })
  end
  Kit.Button(row, {
    text = L("Pass"),
    variant = "ghost",
    layout = { width = 70 },
    onClick = function()
      if ns.LootPopup and ns.LootPopup.Pass then
        ns.LootPopup.Pass(session.sessionId)
      end
      UI.Notify("success", L("You passed on %s. Nothing was sent."):format(ViewModel.Escape(session.itemName)))
    end,
  })
  local spec = ViewModel.LootApplySpec(profile, "main")
  local specText = spec and L("Spec: %s (from your profile)"):format(spec) or L("Pick your spec in the Profile tab.")
  local line = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Label(line, { text = specText, style = "small", color = "muted", layout = { weight = 1 } })
  Kit.EditBox(line, {
    text = state.upgrade,
    placeholder = L("Upgrade (optional)"),
    layout = { width = 220 },
    onChange = function(text)
      state.upgrade = text
    end,
  })
end

-- The candidates of a session with Vote and Award per row, and the reason of an award under the table. The Loot tab and
-- the voting window both draw it. ctx = { state = { awarding, awardReason }, commands, report(lines), redraw(),
-- sort, onSort(key) (the columns sort only when onSort is given) }.
function UI.LootCandidates(card, event, session, cardData, ctx)
  local cstate, commands = ctx.state, ctx.commands
  if #cardData.candidates == 0 then
    Kit.Label(card, { text = L("no candidates yet"), color = "muted" })
    return
  end
  local rows = {}
  for _, candidate in ipairs(cardData.candidates) do
    local key = session.sessionId .. ":" .. candidate.name
    local cells = {
      name = { text = candidate.label, color = candidate.mine and "info" or nil },
      response = { widget = "badge", opts = { text = candidate.responseText, color = candidate.needToken } },
      spec = { text = candidate.spec, color = "dim" },
      upgrade = { text = candidate.upgrade ~= "" and candidate.upgrade or "-", color = "muted" },
      votes = { text = candidate.votes and tostring(candidate.votes) or "?" },
    }
    if candidate.canVote then
      cells.vote = {
        widget = "button",
        opts = {
          text = candidate.mine and L("Voted") or L("Vote"),
          layout = {},
          onClick = function()
            cstate.awarding = nil
            ctx.report(commands:VoteFor(event, session, candidate.name))
          end,
        },
      }
    end
    if candidate.canAward then
      cells.award = {
        widget = "button",
        opts = {
          text = L("Award"),
          variant = cstate.awarding == key and "primary" or "secondary",
          layout = {},
          onClick = function()
            cstate.awarding = key
            cstate.awardReason = ""
            ctx.redraw()
          end,
        },
      }
    end
    rows[#rows + 1] = { cells = cells, highlight = cstate.awarding == key }
  end
  local sortable = ctx.onSort ~= nil
  Kit.Table(card, {
    columns = {
      { key = "name", title = L("Name"), weight = 2, sortable = sortable },
      { key = "response", title = L("Response"), weight = 1.4, sortable = sortable },
      { key = "spec", title = L("Spec"), weight = 1.2 },
      { key = "upgrade", title = L("Upgrade"), weight = 1.4 },
      { key = "votes", title = L("Votes"), width = 50, align = "RIGHT", sortable = sortable },
      { key = "vote", title = "", width = 80 },
      { key = "award", title = "", width = 80 },
    },
    rows = rows,
    sort = ctx.sort,
    onSort = ctx.onSort,
  })
  -- The reason of an award, asked under the table once a candidate was picked.
  for _, candidate in ipairs(cardData.candidates) do
    if cstate.awarding == session.sessionId .. ":" .. candidate.name then
      local line = Kit.Row(card, { gap = 10, align = "center" })
      Kit.EditBox(line, {
        text = cstate.awardReason,
        placeholder = L("Reason for the award for %s"):format(candidate.name),
        maxLetters = 100,
        layout = { weight = 1 },
        onChange = function(text)
          cstate.awardReason = text
        end,
      })
      Kit.Button(line, {
        text = L("Confirm award"),
        variant = "primary",
        layout = { width = "auto" },
        onClick = function()
          local reason = cstate.awardReason
          cstate.awarding, cstate.awardReason = nil, ""
          ctx.report(commands:AwardTo(event, session, candidate.name, reason))
        end,
      })
      Kit.Button(line, {
        text = L("Cancel"),
        layout = { width = "auto" },
        onClick = function()
          cstate.awarding = nil
          ctx.redraw()
        end,
      })
    end
  end
end

local function sessionCard(page, event, cardData, actions, commands)
  local session = cardData.session
  local card = Kit.Card(page, { gap = 10 })
  if not cardData.open then
    -- A closed session collapses to one line: item -> winner (response), and the reason.
    local line = Kit.Row(card, { gap = 10, align = "center" })
    Kit.ItemLabel(
      line,
      { itemId = cardData.itemId, text = cardData.summary or cardData.itemName, layout = { weight = 1 } }
    )
    Kit.Badge(line, {
      text = cardData.statusText,
      color = cardData.statusToken,
      fixed = true,
      layout = { width = "auto" },
    })
    if cardData.award then
      Kit.Label(card, { text = cardData.award.reason, style = "small", color = "muted", wrap = true })
    end
    return
  end
  local head = Kit.Row(card, { gap = 10, align = "center" })
  Kit.ItemLabel(head, { itemId = cardData.itemId, text = cardData.itemName, layout = { weight = 1 } })
  if cardData.timeLeft then
    Kit.Label(head, { text = cardData.timeLeft, style = "small", color = "muted", layout = { width = "auto" } })
  end
  Kit.Badge(head, {
    text = cardData.statusText,
    color = cardData.statusToken,
    fixed = true,
    layout = { width = "auto" },
  })
  Kit.Label(card, { text = cardData.subtitle, style = "small", color = "muted" })
  if actions.apply then
    applyRow(card, event, session, commands)
  end
  UI.LootCandidates(
    card,
    event,
    session,
    cardData,
    { state = state, commands = commands, report = UI.Report, redraw = UI.Redraw }
  )
  if cardData.canClose then
    local key = "close:" .. session.sessionId
    local armed = UI.IsArmed(key)
    Kit.Button(card, {
      text = armed and L("Confirm: close without awarding") or L("Close without awarding"),
      variant = armed and "dangerSolid" or "secondary",
      layout = { width = 280 },
      onClick = function()
        if not armed then
          UI.Arm(key)
          return
        end
        UI.Disarm()
        UI.Report(commands:CloseSession(event, session))
      end,
    })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The minutes

local function minutesCard(page, event)
  local card = Kit.Card(page, { gap = 10 })
  local head = Kit.Row(card, { gap = 10, align = "center" })
  Kit.SectionLabel(head, { text = L("Minutes"), layout = { weight = 1 } })
  Kit.Button(head, {
    text = state.minutesOpen and L("Hide") or L("Show"),
    variant = "ghost",
    layout = { width = "auto" },
    onClick = function()
      state.minutesOpen = not state.minutesOpen
      UI.Redraw()
    end,
  })
  if not state.minutesOpen then
    return
  end
  local rows = {}
  for _, row in ipairs(ViewModel.MinutesTable(event, ns.Platform.FormatDate)) do
    rows[#rows + 1] = { cells = row }
  end
  Kit.Table(card, {
    columns = {
      { key = "item", title = L("Item"), weight = 2 },
      { key = "winner", title = L("Winner"), weight = 1.6 },
      { key = "response", title = L("Response"), weight = 1.2 },
      { key = "reason", title = L("Reason"), weight = 3 },
      { key = "date", title = L("Date"), weight = 1.6 },
    },
    rows = rows,
    emptyText = L("No closed loot sessions yet."),
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The tab

UI.Register("loot", function(page)
  local global = ns.db.global
  local role = UI.Role()
  local ownRosterId = UI.OwnRosterId()
  local selection = UI.RosterSelection("loot", "loot_view")
  local viewer = UI.Viewer(selection.selected)
  if viewer.mode == "roster" and ns.PermissionService.IsGlobal(role) then
    -- Events no roster owns yet stay in sight of who can give them one.
    viewer.legacy = true
  end
  local events = ns.RosterService.FilterEvents(global.events, viewer)
  if UI.nav.eventId and events[UI.nav.eventId] then
    state.selectedId = UI.nav.eventId
    UI.nav.eventId = nil
  end
  if not (state.selectedId and events[state.selectedId]) then
    state.selectedId = ViewModel.DefaultLootEvent(events)
  end

  Kit.PageHeader(page, {
    title = L("Raid"),
    description = L("Open a session after an encounter, answer for the items and let the council decide."),
  })
  UI.DrawSectionTabs(page, "loot")
  if viewer.mode == "blocked" then
    Kit.EmptyState(page, { icon = "users", title = NO_ROSTER.title, hint = NO_ROSTER.hint })
    return
  end

  UI.DrawRosterSelector(page, "loot", selection, function()
    state.selectedId, state.awarding = nil, nil
  end)

  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.Dropdown(bar, {
    items = ViewModel.LootEventChoices(events),
    value = state.selectedId,
    placeholder = L("No events yet"),
    layout = { weight = 1 },
    onChange = function(value)
      state.selectedId = value
      state.awarding = nil
      UI.Redraw()
    end,
  })
  -- Without a sync transport nothing could be sent, so the tab stays read-only.
  if ViewModel.LootActions(ns.comm and role or nil, ownRosterId).vote then
    Kit.Button(bar, {
      text = L("Open the voting window"),
      layout = { width = "auto" },
      onClick = function()
        ns.VotingFrame.Show()
      end,
    })
  end

  local event = state.selectedId and events[state.selectedId]
  if not event then
    Kit.EmptyState(page, {
      icon = "gem",
      title = L("No events yet"),
      hint = L("A raid leader creates them in the Raid tab."),
    })
    return
  end

  -- Without a sync transport nothing could be sent, so the tab stays read-only.
  local actions = ViewModel.LootActions(ns.comm and role or nil, ownRosterId, event)
  local commands = loot()
  if actions.open then
    openCard(page, event, commands)
  end
  local cards = ViewModel.LootSessionCards(event, {
    actor = ns.Platform.GetIdentityKey(),
    rankOf = rankOf,
    actions = actions,
    timeLeft = ns.LootPopup and ns.LootPopup.TimeLeft or nil,
  })
  if #cards == 0 then
    Kit.EmptyState(page, {
      icon = "gem",
      title = L("No loot sessions for this event yet."),
      hint = L("The council opens one for each item after an encounter."),
    })
  end
  for _, cardData in ipairs(cards) do
    sessionCard(page, event, cardData, actions, commands)
  end
  minutesCard(page, event)
  Kit.Label(page, {
    text = L("Addon messages are not private: anyone with the addon can read votes."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end)
