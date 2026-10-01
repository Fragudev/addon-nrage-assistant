local _, ns = ...

-- The voting window for the people who decide loot (GM, Officer, RL). It opens by itself when a session
-- opens, lists the candidates with their response, upgrade and votes, and lets the voter vote, award or close
-- the session. Votes follow Constants.VOTE_VISIBILITY. It never opens during an encounter lockdown (it waits).
-- What each row says comes from ViewModel; Controller holds the decisions about when to open. Client only.
local VotingFrame = {}

local RETRY_SECONDS = 5
-- Candidacies and votes arrive in bursts; the window is redrawn at most this often because of them.
local MIN_REDRAW_SECONDS = 0.2
local WIDTH, HEIGHT = 760, 460
local NEED_COLORS = { main = "ff00ff00", off = "ffff9900", other = "ff00ccff" }
local COLUMNS = { 0.21, 0.14, 0.24, 0.14, 0.08, 0.09, 0.09 }

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
local frame
local selectedId
local lastMessage
-- How the table is shown: the sort and the response filter, kept while the window is used.
local sort = { key = "votes", descending = true }
local needFilter
-- An award waits for a second click on the same candidate, so a slip does not give the item away.
local awardConfirm
-- What was typed in the reason field, kept across the redraws a confirmation causes.
local awardReason = ""

local function events()
  return ns.db.global.events
end

local function loot()
  return ns.LootCommands.New({
    events = events(),
    platform = ns.Platform,
    comm = ns.comm,
    onChange = ns.UI.LootChanged,
  })
end

local function close()
  if frame then
    LibStub("AceGUI-3.0"):Release(frame)
    frame = nil
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

local function addLabel(parent, text, width)
  local label = LibStub("AceGUI-3.0"):Create("Label")
  label:SetText(text)
  if width then
    label:SetRelativeWidth(width)
  else
    label:SetFullWidth(true)
  end
  parent:AddChild(label)
end

local function addButton(parent, text, width, onClick)
  local button = LibStub("AceGUI-3.0"):Create("Button")
  button:SetText(text)
  button:SetRelativeWidth(width)
  button:SetCallback("OnClick", onClick)
  parent:AddChild(button)
end

local draw

local function run(lines)
  lastMessage = table.concat(lines, " ")
  draw()
end

local FILTER_LIST = { all = "All", main = "Main spec", off = "Off spec", other = "Other" }
local FILTER_ORDER = { "all", "main", "off", "other" }
local HEADERS = { "name", "rank", "response", nil, "votes" }
local HEADER_TITLES = { name = "Name", rank = "Rank", response = "Response", votes = "Votes" }

local function addHeader(parent, index)
  local key = HEADERS[index]
  if not key then
    addLabel(parent, index == 4 and "|cffffd100Upgrade|r" or " ", COLUMNS[index])
    return
  end
  local mark = sort.key == key and (sort.descending and " v" or " ^") or ""
  local header = LibStub("AceGUI-3.0"):Create("InteractiveLabel")
  header:SetText(("|cffffd100%s%s|r"):format(HEADER_TITLES[key], mark))
  header:SetRelativeWidth(COLUMNS[index])
  header:SetCallback("OnClick", function()
    sort = ns.ViewModel.NextSort(sort, key)
    draw()
  end)
  parent:AddChild(header)
end

local function drawTable(scroll, event, session, actions)
  local AceGUI = LibStub("AceGUI-3.0")
  local open = session.status == "open"
  local reason

  if open and actions.award then
    reason = AceGUI:Create("EditBox")
    reason:SetLabel("Reason for the award (used by the Award buttons)")
    reason:SetFullWidth(true)
    reason:SetText(awardReason)
    scroll:AddChild(reason)
  end

  local filter = AceGUI:Create("Dropdown")
  filter:SetLabel("Show")
  filter:SetList(FILTER_LIST, FILTER_ORDER)
  filter:SetValue(needFilter or "all")
  filter:SetRelativeWidth(0.4)
  filter:SetCallback("OnValueChanged", function(_, _, key)
    needFilter = key ~= "all" and key or nil
    draw()
  end)
  scroll:AddChild(filter)
  addLabel(scroll, "Click a column title to sort by it.", 0.55)

  for index = 1, #COLUMNS do
    addHeader(scroll, index)
  end

  local rows =
    ns.ViewModel.VotingRows(session, ns.Platform.GetIdentityKey(), rankOf, { sort = sort, need = needFilter })
  if #rows == 0 then
    addLabel(scroll, needFilter and "Nobody answered that way." or "No candidates yet.")
  end
  for _, row in ipairs(rows) do
    addLabel(scroll, row.label, COLUMNS[1])
    addLabel(scroll, row.rank, COLUMNS[2])
    addLabel(scroll, ("|c%s%s|r"):format(NEED_COLORS[row.need] or "ffffffff", row.response), COLUMNS[3])
    addLabel(scroll, row.upgrade == "" and " " or row.upgrade, COLUMNS[4])
    addLabel(scroll, row.votes and tostring(row.votes) or "?", COLUMNS[5])
    if open and actions.vote then
      addButton(scroll, row.mine and "Voted" or "Vote", COLUMNS[6], function()
        awardConfirm = nil
        run(loot():VoteFor(event, session, row.name))
      end)
    else
      addLabel(scroll, " ", COLUMNS[6])
    end
    if open and actions.award then
      local confirming = awardConfirm and awardConfirm.sessionId == session.sessionId and awardConfirm.name == row.name
      addButton(scroll, confirming and "Confirm" or "Award", COLUMNS[7], function()
        if not confirming then
          awardReason = reason and reason:GetText() or ""
          awardConfirm = { sessionId = session.sessionId, name = row.name }
          lastMessage = ("Award %s to %s? Click Confirm to give it away."):format(session.itemName, row.name)
          draw()
          return
        end
        awardConfirm = nil
        local why = reason and reason:GetText() or ""
        awardReason = ""
        run(loot():AwardTo(event, session, row.name, why))
      end)
    else
      addLabel(scroll, " ", COLUMNS[7])
    end
  end
end

draw = function()
  if not frame then
    return
  end
  local AceGUI = LibStub("AceGUI-3.0")
  frame:ReleaseChildren()
  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("Flow")
  frame:AddChild(scroll)

  local actions = ns.ViewModel.LootActions(ns.PermissionService.OwnRole(ns.Platform))
  local sessions = ns.ViewModel.VotingSessions(events(), selectedId)
  if #sessions == 0 then
    addLabel(scroll, "No loot sessions are open.")
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

  -- The items to choose from: icon, name and tooltip, the selected one in gold.
  for _, entry in ipairs(sessions) do
    local text = entry.selected and ("|cffffd100%s|r"):format(entry.itemName) or entry.itemName
    ns.UI.AddItemLabel(
      scroll,
      { itemId = entry.itemId, text = text, width = 1 / math.min(#sessions, 3) - 0.01 },
      function()
        selectedId = entry.sessionId
        draw()
      end
    )
  end

  local event, session = findSession(selectedId)
  if not session then
    return
  end
  addLabel(
    scroll,
    ("|cffffd100%s|r  (%s)"):format(ns.ViewModel.Escape(session.itemName), ns.ViewModel.Escape(event.title))
  )
  addLabel(scroll, ns.ViewModel.VotingStatus(session))
  if lastMessage then
    addLabel(scroll, ns.ViewModel.Escape(lastMessage))
  end
  if session.status == "open" and actions.award then
    addButton(scroll, "Close without awarding", 0.4, function()
      run(loot():CloseSession(event, session))
    end)
  end
  drawTable(scroll, event, session, actions)
  addLabel(scroll, "")
  addLabel(scroll, "Addon messages are not private: anyone with the addon can read votes.")
end

local function ensureFrame()
  if frame then
    return
  end
  frame = LibStub("AceGUI-3.0"):Create("Frame")
  frame:SetTitle("Nrage Loot Council")
  frame:SetStatusText("Votes follow the guild's visibility setting.")
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  frame:SetLayout("Fill")
  frame:SetCallback("OnClose", function()
    close()
  end)
end

-- Opens the window by hand (the Loot tab has a button for it), on the open session if there is one.
function VotingFrame.Show()
  if not (ns.active and ns.db and ns.comm) then
    return
  end
  lastMessage = nil
  ensureFrame()
  draw()
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
      return ns.comm ~= nil and ns.ViewModel.LootActions(ns.PermissionService.OwnRole(ns.Platform)).vote
    end,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    open = function(freshIds)
      selectedId = freshIds[1]
      lastMessage = nil
      ensureFrame()
      draw()
    end,
    update = draw,
    close = close,
    isOpen = function()
      return frame ~= nil
    end,
    now = ns.Platform.Now,
  })
  controller:Prime()
end

ns.VotingFrame = VotingFrame
table.insert(ns.UI.lootListeners, VotingFrame.Refresh)
