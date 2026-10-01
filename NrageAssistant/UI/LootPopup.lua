local _, ns = ...

-- The loot popup every member gets when the council opens a session: the item and one click to put yourself
-- forward as main spec, off spec or other, or to pass. It never appears during an encounter lockdown (it
-- waits and tries again) and it is only ever a prompt: nothing is sent until a button is clicked.
-- What to show comes from ViewModel.PendingLoot; this file only builds the frame. Client only.
local LootPopup = {}

local RETRY_SECONDS = 5
local ROW_HEIGHT = 58
local WIDTH = 440

local frame
local shownKey
local retryScheduled = false
-- Sessions the player answered, passed on or closed the popup over; they are not offered again.
local dismissed = {}

local function pending()
  return ns.ViewModel.PendingLoot(ns.db.global.events, ns.Platform.GetIdentityKey(), dismissed)
end

local function close()
  if frame then
    LibStub("AceGUI-3.0"):Release(frame)
    frame = nil
  end
  shownKey = nil
end

local NEED_BUTTONS = {
  { text = "Main spec", need = "main" },
  { text = "Off spec", need = "off" },
  { text = "Other", need = "other" },
}

local function answer(entry, need)
  local event = ns.db.global.events[entry.eventId]
  local session = event and event.loot[entry.sessionId]
  dismissed[entry.sessionId] = true
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
    for _, entry in ipairs(pending()) do
      dismissed[entry.sessionId] = true
    end
    close()
  end)

  for _, entry in ipairs(entries) do
    local label = AceGUI:Create("Label")
    label:SetText(("%s  (%s)"):format(ns.ViewModel.Escape(entry.itemName), ns.ViewModel.Escape(entry.eventTitle)))
    label:SetFontObject(GameFontNormalLarge)
    label:SetFullWidth(true)
    frame:AddChild(label)

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
      dismissed[entry.sessionId] = true
      LootPopup.Refresh()
    end)
    row:AddChild(pass)
    frame:AddChild(row)
  end
end

-- Shows, updates or closes the popup to match what is waiting for an answer. Called whenever loot changes.
function LootPopup.Refresh()
  if not ns.active or not ns.character or not ns.db then
    return
  end
  local entries = pending()
  if #entries == 0 then
    close()
    return
  end
  if ns.Platform.IsChatMessagingLockedDown() then
    if not retryScheduled then
      retryScheduled = true
      C_Timer.After(RETRY_SECONDS, function()
        retryScheduled = false
        LootPopup.Refresh()
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
  if frame and key == shownKey then
    return
  end
  build(entries)
  shownKey = key
end

-- Sessions already open at login are not popped up: only ones that open from now on.
function LootPopup.Prime()
  for _, event in pairs(ns.db.global.events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      dismissed[session.sessionId] = true
    end
  end
end

ns.LootPopup = LootPopup
ns.UI.LootChanged = LootPopup.Refresh
