local _, ns = ...

-- The voting window for the people who decide loot (GM, Officer, RL). It opens by itself when a session
-- opens, lists the candidates with their response, upgrade and votes, and lets the voter vote, award or close
-- the session. Votes follow Constants.VOTE_VISIBILITY. It never opens during an encounter lockdown (it waits).
-- What each row says comes from ViewModel; Controller holds the decisions about when to open. Client only.
local VotingFrame = {}

local RETRY_SECONDS = 5
local WIDTH, HEIGHT = 760, 460
local NEED_COLORS = { main = "ff00ff00", off = "ffff9900", other = "ff00ccff" }
local COLUMNS = { 0.21, 0.14, 0.24, 0.14, 0.08, 0.09, 0.09 }

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: openSessionIds() -> ids of the open sessions, canVote() -> boolean, isLockedDown() -> boolean,
--         after(seconds, fn), open(freshIds), update(), close()
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
    self.deps.update()
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
  self.deps.open(fresh)
end

VotingFrame.Controller = Controller

local controller
local frame
local selectedId
local lastMessage

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

local function drawTable(scroll, event, session, actions)
  local AceGUI = LibStub("AceGUI-3.0")
  local open = session.status == "open"
  local reason

  if open and actions.award then
    reason = AceGUI:Create("EditBox")
    reason:SetLabel("Reason for the award (used by the Award buttons)")
    reason:SetFullWidth(true)
    scroll:AddChild(reason)
  end

  for index, title in ipairs({ "Name", "Rank", "Response", "Upgrade", "Votes", "", "" }) do
    addLabel(scroll, title == "" and " " or ("|cffffd100%s|r"):format(title), COLUMNS[index])
  end

  local rows = ns.ViewModel.VotingRows(session, ns.Platform.GetIdentityKey(), rankOf)
  if #rows == 0 then
    addLabel(scroll, "No candidates yet.")
  end
  for _, row in ipairs(rows) do
    addLabel(scroll, row.label, COLUMNS[1])
    addLabel(scroll, row.rank, COLUMNS[2])
    addLabel(scroll, ("|c%s%s|r"):format(NEED_COLORS[row.need] or "ffffffff", row.response), COLUMNS[3])
    addLabel(scroll, row.upgrade == "" and " " or row.upgrade, COLUMNS[4])
    addLabel(scroll, row.votes and tostring(row.votes) or "?", COLUMNS[5])
    if open and actions.vote then
      addButton(scroll, row.mine and "Voted" or "Vote", COLUMNS[6], function()
        run(loot():VoteFor(event, session, row.name))
      end)
    else
      addLabel(scroll, " ", COLUMNS[6])
    end
    if open and actions.award then
      addButton(scroll, "Award", COLUMNS[7], function()
        run(loot():AwardTo(event, session, row.name, reason and reason:GetText() or ""))
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
  })
  controller:Prime()
end

ns.VotingFrame = VotingFrame
table.insert(ns.UI.lootListeners, VotingFrame.Refresh)
