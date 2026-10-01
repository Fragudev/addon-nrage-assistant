local _, ns = ...

-- The loot popup every member gets when the council opens a session: the item and one click to put yourself
-- forward as main spec, off spec or other, or to pass. It never appears during an encounter lockdown (it
-- waits and tries again) and it is only ever a prompt: nothing is sent until a button is clicked.
-- What to show comes from ViewModel.PendingLoot; this file only builds the frame. Client only.
local LootPopup = {}

local RETRY_SECONDS = 5
local ROW_HEIGHT = 58
local WIDTH = 440

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: pending(dismissed) -> entries, isLockedDown() -> boolean, after(seconds, fn),
--         show(entries), hide()
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable({ deps = deps, dismissed = {}, shownKey = nil, retryScheduled = false }, Controller)
end

-- Sessions the player answered, passed on or closed the popup over are not offered again.
function Controller:Dismiss(sessionId)
  self.dismissed[sessionId] = true
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
end

LootPopup.Controller = Controller

local frame
local controller

local function pending(dismissed)
  return ns.ViewModel.PendingLoot(ns.db.global.events, ns.Platform.GetIdentityKey(), dismissed)
end

local function close()
  if frame then
    LibStub("AceGUI-3.0"):Release(frame)
    frame = nil
  end
end

local NEED_BUTTONS = {
  { text = "Main spec", need = "main" },
  { text = "Off spec", need = "off" },
  { text = "Other", need = "other" },
}

local function answer(entry, need)
  local event = ns.db.global.events[entry.eventId]
  local session = event and event.loot[entry.sessionId]
  controller:Dismiss(entry.sessionId)
  if session and ns.comm then
    local loot = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      onChange = LootPopup.Refresh,
    })
    local lines = loot:Apply(event, session, { spec = ns.ViewModel.DefaultSpec(ns.character.profile), need = need })
    for _, line in ipairs(lines) do
      print("Nrage Assistant: " .. line)
    end
  end
  LootPopup.Refresh()
end

local function build(entries)
  local AceGUI = LibStub("AceGUI-3.0")
  close()
  frame = AceGUI:Create("Frame")
  frame:SetTitle("Nrage Loot")
  frame:SetStatusText("Nothing is sent until you click a button.")
  frame:SetWidth(WIDTH)
  frame:SetHeight(math.min(120 + #entries * ROW_HEIGHT, 520))
  frame:SetLayout("List")
  frame:SetCallback("OnClose", function()
    for _, entry in ipairs(pending(controller.dismissed)) do
      controller:Dismiss(entry.sessionId)
    end
    controller:Hide()
  end)

  for _, entry in ipairs(entries) do
    ns.UI.AddItemLabel(frame, {
      itemId = entry.itemId,
      text = ("%s  (%s)"):format(ns.ViewModel.Escape(entry.itemName), ns.ViewModel.Escape(entry.eventTitle)),
    })

    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    for _, spec in ipairs(NEED_BUTTONS) do
      local button = AceGUI:Create("Button")
      button:SetText(spec.text)
      button:SetRelativeWidth(0.25)
      button:SetCallback("OnClick", function()
        answer(entry, spec.need)
      end)
      row:AddChild(button)
    end
    local pass = AceGUI:Create("Button")
    pass:SetText("Pass")
    pass:SetRelativeWidth(0.25)
    pass:SetCallback("OnClick", function()
      controller:Dismiss(entry.sessionId)
      LootPopup.Refresh()
    end)
    row:AddChild(pass)
    frame:AddChild(row)
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
    pending = pending,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    show = build,
    hide = close,
  })
  for _, event in pairs(ns.db.global.events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      controller:Dismiss(session.sessionId)
    end
  end
end

ns.LootPopup = LootPopup
table.insert(ns.UI.lootListeners, LootPopup.Refresh)
