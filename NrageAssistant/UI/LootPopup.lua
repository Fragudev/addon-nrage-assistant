local _, ns = ...

-- The loot popup every member gets when the council opens a session: the item and one click to put yourself
-- forward as main spec, off spec or other, or to pass. It never appears during an encounter lockdown (it
-- waits and tries again) and it is only ever a prompt: nothing is sent until a button is clicked.
-- What to show comes from ViewModel.PendingLoot; this file only builds the frame. Client only.
local LootPopup = {}

local L = ns.L

local RETRY_SECONDS = 5
local WIDTH = 380
-- How many items show at once; more scroll.
local VISIBLE_ROWS = 3
local ROW_HEIGHT = 108

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: pending(dismissed) -> entries, isLockedDown() -> boolean, after(seconds, fn),
--         show(entries), hide(); optional, for the countdown: now() -> seconds, timeout (seconds, nil for none),
--         status(text) to show the time left
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable({
    deps = deps,
    dismissed = {},
    shownKey = nil,
    retryScheduled = false,
    firstShown = {},
    ticking = false,
  }, Controller)
end

-- Sessions the player answered, passed on or closed the popup over are not offered again.
function Controller:Dismiss(sessionId)
  self.dismissed[sessionId] = true
end

-- Seconds left to answer for a session, or nil when it is not counting down (not shown yet, answered, or no timeout).
function Controller:TimeLeft(sessionId)
  local first = self.firstShown[sessionId]
  if not (first and self.deps.timeout and self.deps.now) or self.dismissed[sessionId] then
    return nil
  end
  return math.max(0, self.deps.timeout - (self.deps.now() - first))
end

function Controller:Hide()
  self.shownKey = nil
  self.deps.hide()
end

-- Shows, updates or closes the popup to match what is waiting for an answer. Called whenever loot changes.
function Controller:Refresh()
  local entries = self.deps.pending(self.dismissed)
  if #entries == 0 then
    if self.shownKey then
      self:Hide()
    end
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

  -- Votes and candidacies keep arriving while the popup is up; only rebuild when the list itself changed.
  local ids = {}
  for _, entry in ipairs(entries) do
    ids[#ids + 1] = entry.sessionId
  end
  local key = table.concat(ids, ",")
  if key == self.shownKey then
    return
  end
  self.deps.show(entries)
  self.shownKey = key
  self:StartCountdown(entries)
end

-- With a timeout, each item waits that long from the moment it was first shown (a lockdown does not count,
-- nothing is shown then), and is passed on if nobody answered. Passing is local: nothing is sent.
function Controller:StartCountdown(entries)
  if not (self.deps.timeout and self.deps.now) then
    return
  end
  local now = self.deps.now()
  for _, entry in ipairs(entries) do
    self.firstShown[entry.sessionId] = self.firstShown[entry.sessionId] or now
  end
  if not self.ticking then
    self.ticking = true
    self.deps.after(1, function()
      self.ticking = false
      self:Tick()
    end)
  end
end

function Controller:Tick()
  local entries = self.deps.pending(self.dismissed)
  if #entries == 0 then
    return
  end
  local now = self.deps.now()
  local expired, soonest = false, self.deps.timeout
  for _, entry in ipairs(entries) do
    local left = self.deps.timeout - (now - (self.firstShown[entry.sessionId] or now))
    if left <= 0 then
      self:Dismiss(entry.sessionId)
      expired = true
    elseif left < soonest then
      soonest = left
    end
  end
  if expired then
    self:Refresh()
    return
  end
  if self.deps.status then
    self.deps.status(L("Passing on the next item in %d s unless you answer."):format(math.ceil(soonest)))
  end
  self:StartCountdown(entries)
end

LootPopup.Controller = Controller

local frame, content, lastEntries, footer
local controller

-- Only the players who may apply (rank roster and above) to the roster of a session are asked about it
-- (ViewModel.PendingLoot checks it).
function LootPopup.Pending(dismissed)
  local global = ns.db.global
  local viewer = ns.RosterService.OwnViewer(ns.Platform, global.rosters, global.members)
  local events = ns.RosterService.FilterEvents(global.events, viewer)
  local ownRosterId = ns.RosterService.RosterOf(global.members, global.rosters, ns.Platform.GetIdentityKey())
  return ns.ViewModel.PendingLoot(
    events,
    ns.Platform.GetIdentityKey(),
    dismissed,
    ns.PermissionService.OwnRole(ns.Platform),
    ownRosterId
  )
end

local NEED_BUTTONS = ns.Locale.Table(function()
  return {
    { text = L("Main spec"), need = "main" },
    { text = L("Off spec"), need = "off" },
    { text = L("Other"), need = "other" },
  }
end)

-- Draws the items into `stack` (the newest on top; more than VISIBLE_ROWS scroll). handlers = { answer(entry, need),
-- pass(entry), timeLeft(sessionId) -> seconds or nil, timeout (seconds or nil), spec (the spec a click puts, text),
-- footer (text under the items) }. The frame around it is built apart, so this can be tested with the fake kit.
function LootPopup.Draw(stack, entries, handlers)
  local Kit = ns.Kit
  local host = stack
  if #entries > VISIBLE_ROWS then
    host = Kit.ScrollArea(stack, { gap = 12, height = VISIBLE_ROWS * ROW_HEIGHT })
  end
  for position = #entries, 1, -1 do
    local entry = entries[position]
    local card = Kit.Stack(host, { gap = 6 })
    local head = Kit.Row(card, { gap = 8, align = "center" })
    Kit.ItemLabel(head, {
      itemId = entry.itemId,
      text = ns.ViewModel.Escape(entry.itemName),
      size = 28,
      layout = { weight = 1 },
    })
    local detail = ns.ViewModel.Escape(entry.eventTitle or "")
    if handlers.spec and handlers.spec ~= "unknown" then
      detail = detail .. " \194\183 " .. L("Spec: %s (from your profile)"):format(ns.ViewModel.Escape(handlers.spec))
    end
    Kit.Label(card, { text = detail, style = "small", color = "muted" })
    local buttons = Kit.Row(card, { gap = 6, align = "center" })
    for _, spec in ipairs(NEED_BUTTONS) do
      Kit.Button(buttons, {
        text = spec.text,
        layout = { weight = 1 },
        onClick = function()
          handlers.answer(entry, spec.need)
        end,
      })
    end
    Kit.Button(buttons, {
      text = L("Pass"),
      variant = "ghost",
      layout = { weight = 1 },
      onClick = function()
        handlers.pass(entry)
      end,
    })
    local left = handlers.timeLeft(entry.sessionId)
    if left and handlers.timeout and handlers.timeout > 0 then
      Kit.ProgressBar(card, { value = left / handlers.timeout, height = 2, color = "accent" })
    end
  end
  Kit.Label(stack, { text = handlers.footer, style = "small", color = "muted", wrap = true })
end

local function answer(entry, need)
  local event = ns.db.global.events[entry.eventId]
  local session = event and event.loot[entry.sessionId]
  controller:Dismiss(entry.sessionId)
  if session and ns.comm then
    local loot = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      rosters = ns.db.global.rosters,
      members = ns.db.global.members,
      onChange = LootPopup.Refresh,
    })
    local lines = loot:Apply(event, session, { spec = ns.ViewModel.DefaultSpec(ns.character.profile), need = need })
    for _, line in ipairs(lines) do
      print("Nrage Assistant: " .. line)
    end
  end
  LootPopup.Refresh()
end

local function handlers()
  return {
    answer = answer,
    pass = function(entry)
      controller:Dismiss(entry.sessionId)
      LootPopup.Refresh()
    end,
    timeLeft = function(sessionId)
      return controller:TimeLeft(sessionId)
    end,
    timeout = ns.Constants.LOOT_RESPONSE_TIMEOUT_SECONDS,
    spec = ns.ViewModel.DefaultSpec(ns.character.profile),
    footer = footer or L("Nothing is sent until you click a button."),
  }
end

local statusTarget = {
  SetStatusTable = function(_, status)
    frame.status = status
    if type(status.left) == "number" and type(status.top) == "number" then
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", status.left, status.top)
    end
  end,
}

-- The floating card: made once, then filled again whenever the list or the time left changes.
local function ensureFrame()
  if frame then
    return frame
  end
  local Kit = ns.Kit
  local Theme = Kit.Theme
  frame = CreateFrame("Frame", "NrageAssistantLootPopup", UIParent)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  -- A cut surface on the plain ground: it sits over the game, so it shows no scene and is not translucent.
  frame.shape = Kit.Shape.New(frame, { cut = "lg" })
  frame.shape:SetFill("bg")
  frame.shape.border:SetColor("border")
  frame.title = frame:CreateFontString(nil, "OVERLAY")
  frame.title:SetPoint("TOPLEFT", 16, -14)
  frame.title:SetFontObject(Theme.StyleFont("window"))
  Kit.SetTextColor(frame.title, "text")
  frame.title:SetText("Nrage Loot")
  frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local status = self.status
    local left, top = self:GetLeft(), self:GetTop()
    if status and type(left) == "number" and type(top) == "number" then
      status.left, status.top = left, top
    end
  end)
  frame.hide = Kit.IconButton(frame, {
    icon = "close",
    tooltip = L("Hide"),
    onClick = function()
      -- Hiding keeps the items waiting: they come back with the next session event, or from the Loot tab.
      controller:Hide()
    end,
  })
  frame.hide:Layout(28)
  frame.hide.frame:ClearAllPoints()
  frame.hide.frame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  ns.UI.ApplyWindowStatus(statusTarget, "popup", WIDTH, 0)
  frame:Hide()
  return frame
end

local function render()
  ensureFrame()
  if content then
    content:Release()
  end
  content = ns.Kit.Stack(frame, { gap = 12 })
  LootPopup.Draw(content, lastEntries or {}, handlers())
  local height = content:Layout(WIDTH - 32)
  ns.Kit.Place(content, frame, 16, 48)
  frame:SetSize(WIDTH, height + 48 + 16)
  frame.shape:Resize()
  frame:Show()
end

local function build(entries)
  lastEntries = entries
  footer = nil
  render()
end

local function close()
  if frame then
    frame:Hide()
  end
  if content then
    content:Release()
    content = nil
  end
  lastEntries = nil
end

-- The time left for a session, for the Loot tab.
function LootPopup.TimeLeft(sessionId)
  return controller and controller:TimeLeft(sessionId) or nil
end

-- Passes on a session from the Loot tab: local only, nothing is sent.
function LootPopup.Pass(sessionId)
  if controller then
    controller:Dismiss(sessionId)
    LootPopup.Refresh()
  end
end

function LootPopup.Refresh()
  if controller and ns.active and ns.character and ns.db then
    controller:Refresh()
  end
end

-- Starts the popup. Sessions already open at login are not popped up: only ones that open from now on.
function LootPopup.Start()
  controller = Controller.New({
    pending = LootPopup.Pending,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    show = build,
    hide = close,
    now = ns.Platform.Now,
    timeout = ns.Constants.LOOT_RESPONSE_TIMEOUT_SECONDS,
    status = function(text)
      footer = text
      if frame and frame:IsShown() and lastEntries then
        render()
      end
    end,
  })
  for _, event in pairs(ns.db.global.events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      controller:Dismiss(session.sessionId)
    end
  end
end

ns.LootPopup = LootPopup
table.insert(ns.UI.lootListeners, LootPopup.Refresh)
