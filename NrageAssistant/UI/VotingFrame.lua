local _, ns = ...

-- The voting window for the people who decide loot (GM, CoGM, Officer, RL). It opens by itself when a session
-- opens, lists the candidates with their response, upgrade and votes, and lets the voter vote, award or close
-- the session. Votes follow Constants.VOTE_VISIBILITY. It never opens during an encounter lockdown (it waits).
-- What each row says comes from ViewModel; Controller holds the decisions about when to open. Client only.
local VotingFrame = {}

local L = ns.L

local RETRY_SECONDS = 5
-- Candidacies and votes arrive in bursts; the window is redrawn at most this often because of them.
local MIN_REDRAW_SECONDS = 0.2
local WIDTH, HEIGHT = 820, 520
local PAGE_PAD = { 22, 18, 22, 18 }

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: openSessionIds() -> ids of the open sessions, canVote() -> boolean, isLockedDown() -> boolean,
--         after(seconds, fn), open(freshIds), update(), close(); optional: isOpen() -> boolean (default true),
--         now() -> seconds (default 0, so no throttling)
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable({ deps = deps, seen = {}, retryScheduled = false }, Controller)
end

-- Sessions open right now are not announced: only ones that open from now on.
function Controller:Prime()
  for _, id in ipairs(self.deps.openSessionIds()) do
    self.seen[id] = true
  end
end

-- Redraws an open window because of something that arrived, but not more than once per MIN_REDRAW_SECONDS: a
-- redraw that is too soon is postponed to the end of the interval, once, and shows the latest state.
function Controller:Update()
  if self.deps.isOpen and not self.deps.isOpen() then
    return
  end
  local now = self.deps.now and self.deps.now() or 0
  local wait = self.lastDrawAt and (MIN_REDRAW_SECONDS - (now - self.lastDrawAt)) or 0
  if wait > 0 then
    if not self.drawPending then
      self.drawPending = true
      self.deps.after(wait, function()
        self.drawPending = false
        self:Update()
      end)
    end
    return
  end
  self.lastDrawAt = now
  self.deps.update()
end

-- Called whenever loot changes: opens the window for a new session, or refreshes it if it is already open.
function Controller:Refresh()
  if not self.deps.canVote() then
    self.deps.close()
    return
  end

  local fresh = {}
  for _, id in ipairs(self.deps.openSessionIds()) do
    if not self.seen[id] then
      fresh[#fresh + 1] = id
    end
  end
  if #fresh == 0 then
    self:Update()
    return
  end

  if self.deps.isLockedDown() then
    if not self.retryScheduled then
      self.retryScheduled = true
      self.deps.after(RETRY_SECONDS, function()
        self.retryScheduled = false
        self:Refresh()
      end)
    end
    return
  end
  for _, id in ipairs(fresh) do
    self.seen[id] = true
  end
  self.lastDrawAt = self.deps.now and self.deps.now() or 0
  self.deps.open(fresh)
end

VotingFrame.Controller = Controller

local controller
local window, page
local bodyWidth, bodyHeight = WIDTH, HEIGHT - 52
local selectedId
-- What the last action said, shown at the top until the next one: { kind, text }.
local lastMessage
-- How the table is shown: the sort and the response filter, kept while the window is used.
local sort = { key = "votes", descending = true }
local needFilter
-- The state of the candidates table (the Award button and its reason), and the armed "close without awarding".
local tableState = { awarding = nil, awardReason = "" }
local closeArmed

-- The events of the roster of this player (the guild master sees all of them): the window opens for the council and
-- the raid leaders of the roster of a session, not for the others.
local function events()
  local global = ns.db.global
  local viewer = ns.RosterService.OwnViewer(ns.Platform, global.rosters, global.members)
  return ns.RosterService.FilterEvents(global.events, viewer)
end

local function ownRosterId()
  local global = ns.db.global
  return ns.RosterService.RosterOf(global.members, global.rosters, ns.Platform.GetIdentityKey())
end

local function loot()
  return ns.LootCommands.New({
    events = ns.db.global.events,
    platform = ns.Platform,
    comm = ns.comm,
    rosters = ns.db.global.rosters,
    members = ns.db.global.members,
    onChange = ns.UI.LootChanged,
  })
end

local function isOpen()
  return window ~= nil and window:IsShown()
end

local function close()
  if isOpen() then
    window:Hide()
  end
end

local function findSession(sessionId)
  for _, event in pairs(events()) do
    local session = event.loot and event.loot[sessionId]
    if session then
      return event, session
    end
  end
end

local function rankOf(name)
  local entry = ns.guildRoster and ns.guildRoster:Lookup(name)
  return entry and entry.rankName or nil
end

local FILTER_CHOICES = ns.Locale.Table(function()
  return {
    { value = "all", text = L("All") },
    { value = "main", text = L("Main spec") },
    { value = "off", text = L("Off spec") },
    { value = "other", text = L("Other") },
  }
end)

local redraw

-- What an action returned, shown in the window.
local function report(lines)
  local kind = "success"
  if ns.Validate.IsFailure(lines) then
    kind = "danger"
  elseif lines[2] then
    kind = "warning"
  end
  lastMessage = { kind = kind, text = table.concat(lines, " ") }
  closeArmed = nil
  redraw()
end

-- The sessions to choose from, when there are several: one row each, in the style of the navigation.
local function sessionList(parent, sessions)
  local list = ns.Kit.Stack(parent, { gap = 2, layout = { width = 210 } })
  for _, entry in ipairs(sessions) do
    ns.Kit.NavRow(list, {
      text = ("%s (%d)"):format(entry.itemName, entry.candidates),
      icon = "gem",
      value = entry.sessionId,
      selected = entry.selected,
      onClick = function()
        selectedId = entry.sessionId
        tableState.awarding = nil
        closeArmed = nil
        lastMessage = nil
        redraw()
      end,
    })
  end
end

local function sessionHeader(main, event, session)
  local Kit = ns.Kit
  local head = Kit.Row(main, { gap = 10, align = "center" })
  Kit.ItemLabel(head, {
    itemId = session.itemId,
    text = ns.ViewModel.Escape(session.itemName),
    size = 28,
    layout = { weight = 1 },
  })
  local open = session.status == "open"
  Kit.Badge(head, {
    text = ns.ViewModel.Word(session.status),
    color = open and "success" or "muted",
    layout = { width = "auto" },
  })
  local details = ns.ViewModel.ItemDetailsLine(ns.Platform.GetItemDetails(session.itemId))
  local subtitle = ns.ViewModel.Escape(event.title)
  if details then
    subtitle = subtitle .. " \194\183 " .. details
  end
  Kit.Label(main, { text = subtitle, style = "small", color = "muted" })
  Kit.Label(main, { text = ns.ViewModel.VotingStatus(session), color = "dim", wrap = true })
end

-- The candidates card: the response filter, the shared table of the Loot tab and the close button.
local function candidates(main, event, session, actions)
  local Kit = ns.Kit
  local card = Kit.Card(main, { gap = 10 })
  local bar = Kit.Row(card, { gap = 10, align = "center" })
  Kit.Dropdown(bar, {
    items = FILTER_CHOICES,
    value = needFilter or "all",
    layout = { width = 180 },
    onChange = function(value)
      needFilter = value ~= "all" and value or nil
      redraw()
    end,
  })
  Kit.Label(bar, {
    text = L("Click a column title to sort by it."),
    style = "small",
    color = "muted",
    layout = { weight = 1 },
  })
  local cards = ns.ViewModel.LootSessionCards(event, {
    actor = ns.Platform.GetIdentityKey(),
    rankOf = rankOf,
    actions = actions,
    sort = sort,
    need = needFilter,
  })
  local cardData
  for _, candidate in ipairs(cards) do
    if candidate.sessionId == session.sessionId then
      cardData = candidate
    end
  end
  if not cardData then
    return
  end
  if #cardData.candidates == 0 and needFilter then
    Kit.Label(card, { text = L("Nobody answered that way."), color = "muted" })
  else
    ns.UI.LootCandidates(card, event, session, cardData, {
      state = tableState,
      commands = loot(),
      report = report,
      redraw = redraw,
      sort = sort,
      onSort = function(key)
        sort = ns.ViewModel.NextSort(sort, key)
        redraw()
      end,
    })
  end
  if cardData.canClose then
    Kit.Button(card, {
      text = closeArmed == session.sessionId and L("Confirm: close without awarding") or L("Close without awarding"),
      variant = closeArmed == session.sessionId and "dangerSolid" or "secondary",
      layout = { width = 280 },
      onClick = function()
        if closeArmed ~= session.sessionId then
          closeArmed = session.sessionId
          redraw()
          return
        end
        closeArmed = nil
        report(loot():CloseSession(event, session))
      end,
    })
  end
end

-- Draws the window content into `parent` (a stack): the open sessions on the left when there are several, and the
-- selected one on the right. Everything it needs comes from the saved data, so it can be drawn with the fake kit.
function VotingFrame.Draw(parent)
  local Kit = ns.Kit
  local sessions = ns.ViewModel.VotingSessions(events(), selectedId)
  if #sessions == 0 then
    Kit.EmptyState(parent, {
      icon = "gem",
      title = L("No loot sessions are open."),
      hint = L("The council opens one for each item after an encounter."),
    })
    return
  end
  local found = false
  for _, entry in ipairs(sessions) do
    found = found or entry.sessionId == selectedId
  end
  if not found then
    selectedId = sessions[1].sessionId
    sessions = ns.ViewModel.VotingSessions(events(), selectedId)
  end
  local event, session = findSession(selectedId)
  if not session then
    return
  end

  local layout = Kit.Row(parent, { gap = 18, align = "top" })
  if #sessions > 1 then
    sessionList(layout, sessions)
  end
  local main = Kit.Stack(layout, { gap = 12, layout = { weight = 1 } })
  sessionHeader(main, event, session)
  if lastMessage then
    Kit.Banner(main, { kind = lastMessage.kind, text = ns.ViewModel.Escape(lastMessage.text) })
  end
  local role = ns.PermissionService.OwnRole(ns.Platform)
  candidates(main, event, session, ns.ViewModel.LootActions(role, ownRosterId(), event))
  Kit.Label(main, {
    text = L("Addon messages are not private: anyone with the addon can read votes."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

redraw = function()
  if not (isOpen() and page) then
    return
  end
  local offset = page:GetScroll()
  page:Clear()
  VotingFrame.Draw(page)
  page:Layout(bodyWidth, bodyHeight)
  page:SetScroll(offset)
end

local function ensureWindow()
  if window then
    return
  end
  local Kit = ns.Kit
  window = Kit.Window.New({
    name = "NrageAssistantVotingFrame",
    title = L("Nrage Loot Council"),
    width = WIDTH,
    height = HEIGHT,
    minWidth = 600,
    minHeight = 340,
    onResize = function(width, height)
      bodyWidth, bodyHeight = width, height
      if isOpen() and page then
        page:Layout(bodyWidth, bodyHeight)
      end
    end,
    onClose = function()
      tableState.awarding, tableState.awardReason = nil, ""
      closeArmed = nil
    end,
  })
  ns.UI.ApplyWindowStatus(window, "voting", WIDTH, HEIGHT)
  page = Kit.ScrollArea(window.body, { gap = 12, pad = PAGE_PAD })
  Kit.Place(page, window.body, 0, 0)
end

local function show()
  ensureWindow()
  if not window:IsShown() then
    window:Show()
  end
  redraw()
end

-- Opens the window by hand (the Loot tab has a button for it), on the open session if there is one.
function VotingFrame.Show()
  if not (ns.active and ns.db and ns.comm) then
    return
  end
  lastMessage = nil
  show()
end

function VotingFrame.Refresh()
  if controller and ns.active and ns.db and ns.character then
    controller:Refresh()
  end
end

local function openSessionIds()
  local ids = {}
  for _, event in pairs(events()) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      if session.status == "open" then
        ids[#ids + 1] = session.sessionId
      end
    end
  end
  return ids
end

function VotingFrame.Start()
  controller = Controller.New({
    openSessionIds = openSessionIds,
    canVote = function()
      return ns.comm ~= nil and ns.ViewModel.LootActions(ns.PermissionService.OwnRole(ns.Platform), ownRosterId()).vote
    end,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    open = function(freshIds)
      selectedId = freshIds[1]
      lastMessage = nil
      show()
    end,
    update = function()
      redraw()
    end,
    close = close,
    isOpen = isOpen,
    now = ns.Platform.Now,
  })
  controller:Prime()
end

ns.VotingFrame = VotingFrame
table.insert(ns.UI.lootListeners, VotingFrame.Refresh)
