local _, ns = ...

-- The popup of a guild announcement (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md B.5): when an announcement with a popup
-- reaches a member, a card shows its title, author, date and text, with "Got it" and "Open board". Several waiting at
-- once are shown one at a time ("1 of N", next and previous). It never appears in combat or during an encounter
-- lockdown: the card waits and shows when it is over. At most ANNOUNCE_POPUP_QUEUE_MAX wait; the older ones count as
-- unread on the board only. What to show comes from ViewModel.AnnouncementPopupView; this file only builds the frame
-- with the kit. Client only.
local AnnouncementPopup = {}

local L = ns.L

local WIDTH = 380
local BODY_HEIGHT = 170

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: get(id) -> the announcement or nil, markSeen(id), isBlocked() -> boolean (combat or a lockdown),
--         after(seconds, fn), now() -> server time, show(view), hide(), openBoard(), view(announcement, index, total,
--         now) -> the view (default ViewModel.AnnouncementPopupView); optional: alert() when a new announcement
--         arrives, enabled() -> boolean (an announcement is only queued while it is true)
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable(
    { deps = deps, queue = {}, index = 1, visible = false, arrived = false, retrying = false },
    Controller
  )
end

function Controller:Count()
  return #self.queue
end

function Controller:Hide()
  if self.visible then
    self.visible = false
    self.deps.hide()
  end
end

local function indexOf(queue, id)
  for position, queued in ipairs(queue) do
    if queued == id then
      return position
    end
  end
  return nil
end

-- Newest first, so the card opens on the latest news.
local function sortQueue(self)
  local get = self.deps.get
  table.sort(self.queue, function(a, b)
    local left, right = get(a), get(b)
    local leftAt, rightAt = left and left.updatedAt or 0, right and right.updatedAt or 0
    if leftAt ~= rightAt then
      return leftAt > rightAt
    end
    return a < b
  end)
end

-- Queues the popup of `announcement` (or refreshes it when it is queued already). Past the limit the oldest are given
-- up and marked as seen: they stay on the board as unread.
function Controller:Add(announcement)
  local deps = self.deps
  if deps.enabled and not deps.enabled() then
    return
  end
  local current = self.queue[self.index]
  if not indexOf(self.queue, announcement.id) then
    self.queue[#self.queue + 1] = announcement.id
    self.arrived = true
  end
  sortQueue(self)
  while #self.queue > ns.Constants.ANNOUNCE_POPUP_QUEUE_MAX do
    deps.markSeen(table.remove(self.queue))
  end
  self.index = current and indexOf(self.queue, current) or 1
  self.index = self.index or 1
  self:Refresh()
end

-- Shows, updates or closes the card to match the queue. Called whenever it changes, and again when the player leaves
-- combat.
function Controller:Refresh()
  local deps = self.deps
  for position = #self.queue, 1, -1 do
    if not deps.get(self.queue[position]) then
      table.remove(self.queue, position)
    end
  end
  if #self.queue == 0 then
    self.index = 1
    self:Hide()
    return
  end
  self.index = math.max(1, math.min(self.index, #self.queue))
  if deps.isBlocked() then
    if not self.retrying then
      self.retrying = true
      deps.after(ns.Constants.ANNOUNCE_POPUP_RETRY_SECONDS, function()
        self.retrying = false
        self:Refresh()
      end)
    end
    return
  end
  local announcement = deps.get(self.queue[self.index])
  local view = (deps.view or ns.ViewModel.AnnouncementPopupView)(announcement, self.index, #self.queue, deps.now())
  local fresh = self.arrived or not self.visible
  self.arrived = false
  self.visible = true
  deps.show(view)
  if fresh and deps.alert then
    pcall(deps.alert)
  end
end

function Controller:Next()
  if self.index < #self.queue then
    self.index = self.index + 1
    self:Refresh()
  end
end

function Controller:Previous()
  if self.index > 1 then
    self.index = self.index - 1
    self:Refresh()
  end
end

-- "Got it": the announcement on the card is seen; the next one, if any, takes its place.
function Controller:GotIt()
  local id = self.queue[self.index]
  if id then
    self.deps.markSeen(id)
    table.remove(self.queue, self.index)
  end
  self:Refresh()
end

-- Every waiting announcement is seen once the player closes the card or goes to the board, where they all are.
function Controller:DismissAll()
  for _, id in ipairs(self.queue) do
    self.deps.markSeen(id)
  end
  self.queue = {}
  self.index = 1
  self:Hide()
end

function Controller:OpenBoard()
  self:DismissAll()
  self.deps.openBoard()
end

AnnouncementPopup.Controller = Controller

local frame
local content
local controller

local function close()
  if frame then
    frame:Hide()
  end
  if content then
    content:Release()
    content = nil
  end
end

-- Draws the view into `stack`: the title, who and when, the text, the position among several and the buttons. The
-- frame around it is built apart, so this can be tested with the fake kit. `actions` = { gotIt, openBoard, next,
-- previous }.
function AnnouncementPopup.Draw(stack, view, actions)
  local Kit = ns.Kit
  Kit.Label(stack, { text = view.title, style = "value", wrap = true })
  Kit.Label(stack, { text = view.meta, style = "small", color = "muted", wrap = true })
  if view.long then
    Kit.TextArea(stack, { text = view.body, readOnly = true, height = BODY_HEIGHT })
  elseif view.body ~= "" then
    Kit.Label(stack, { text = view.body, wrap = true })
  end
  if view.counter then
    local row = Kit.Row(stack, { gap = 8, align = "center" })
    Kit.Button(row, {
      text = "<",
      disabled = not view.canPrev,
      layout = { width = 30 },
      onClick = actions.previous,
    })
    Kit.Label(row, { text = view.counter, align = "CENTER", color = "muted", layout = { weight = 1 } })
    Kit.Button(row, {
      text = ">",
      disabled = not view.canNext,
      layout = { width = 30 },
      onClick = actions.next,
    })
  end
  local buttons = Kit.Row(stack, { gap = 8, align = "center" })
  Kit.Button(buttons, {
    text = L("Got it"),
    variant = "primary",
    layout = { weight = 1 },
    onClick = actions.gotIt,
  })
  Kit.Button(buttons, {
    text = L("Open board"),
    variant = "secondary",
    layout = { weight = 1 },
    onClick = actions.openBoard,
  })
end

local function ensureFrame()
  if not frame then
    frame = ns.PopupFrame.New({
      name = "NrageAssistantAnnouncementPopup",
      title = L("Guild announcement"),
      width = WIDTH,
      windowName = "announcementPopup",
      closeTooltip = L("Close"),
      onClose = function()
        controller:DismissAll()
      end,
    })
  end
  return frame
end

local function build(view)
  ensureFrame()
  if content then
    content:Release()
  end
  content = ns.Kit.Stack(frame, { gap = 12 })
  AnnouncementPopup.Draw(content, view, {
    gotIt = function()
      controller:GotIt()
    end,
    openBoard = function()
      controller:OpenBoard()
    end,
    next = function()
      controller:Next()
    end,
    previous = function()
      controller:Previous()
    end,
  })
  ns.PopupFrame.Fit(frame, content, WIDTH)
end

-- An announcement with a popup reached this client.
function AnnouncementPopup.Add(announcement)
  if controller and ns.active then
    controller:Add(announcement)
  end
end

function AnnouncementPopup.Refresh()
  if controller and ns.active then
    controller:Refresh()
  end
end

-- Starts the popup; ns.announcements (the service) must exist when something is shown. A card waiting for the end of
-- combat shows when the player leaves it. The module flag of Part A (`announcements`) goes into `enabled`.
function AnnouncementPopup.Start()
  local platform = ns.Platform
  controller = Controller.New({
    get = function(id)
      return ns.announcements and ns.announcements:Get(id) or nil
    end,
    markSeen = function(id)
      if ns.announcements then
        ns.announcements:MarkSeen(id)
      end
    end,
    isBlocked = function()
      return platform.IsInCombat() or platform.IsChatMessagingLockedDown()
    end,
    after = C_Timer.After,
    now = platform.ServerTime,
    enabled = function()
      return not ns.modules or ns.modules:IsEnabled("announcements")
    end,
    show = build,
    hide = close,
    openBoard = function()
      ns.UI.OpenTab("announcements")
    end,
    alert = function()
      platform.ShowRaidNotice(L("New guild announcement"))
      platform.PlayAlertSound()
    end,
  })
  local events = CreateFrame("Frame")
  platform.TryRegisterEvent(events, "PLAYER_REGEN_ENABLED")
  events:SetScript("OnEvent", function()
    AnnouncementPopup.Refresh()
  end)
  return controller
end

ns.AnnouncementPopup = AnnouncementPopup
