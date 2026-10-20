local _, ns = ...

-- The popup of a layer swap, for both sides: the requester follows the request step by step, a helper is asked to
-- help and, when picked, to invite. It never appears during an encounter lockdown (it waits and tries again) and it
-- only ever prompts: every action that invites or leaves a group is a button the player clicks.
-- What to show comes from ViewModel.LayerSwapView; this file only builds the frame. Client only.
local LayerPopup = {}

local WIDTH = 420
local HEIGHT = 170

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: status() -> LayerSwap:Status() or nil, isLockedDown() -> boolean, after(seconds, fn), show(view),
--         hide(), view(status) -> the view (default ViewModel.LayerSwapView); optional: alert() when a helper is
--         asked for help, countdown(text) to show the time left
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable({
    deps = deps,
    shownKey = nil,
    closedKey = nil,
    retryScheduled = false,
    ticking = false,
    alerted = {},
  }, Controller)
end

-- Identifies what the popup shows: when it changes the frame is rebuilt, otherwise only the countdown moves.
local function keyOf(status)
  return table.concat({
    tostring(status.rid),
    tostring(status.stage),
    tostring(status.outcome),
    tostring(status.offered),
    tostring(status.joined),
  }, "|")
end

function Controller:Hide()
  if self.shownKey then
    self.shownKey = nil
    self.deps.hide()
  end
end

-- The player closed the window with its own close button: it stays closed until the swap moves to another step.
function Controller:Closed()
  local status = self.deps.status()
  self.shownKey = nil
  self.closedKey = status and keyOf(status) or nil
end

-- Shows, updates or closes the popup to match the swap. Called whenever the swap changes.
function Controller:Refresh()
  local deps = self.deps
  local status = deps.status()
  if not status or status.hidden then
    self:Hide()
    return
  end
  local key = keyOf(status)
  if key == self.closedKey then
    return
  end
  if deps.isLockedDown() then
    if not self.retryScheduled then
      self.retryScheduled = true
      deps.after(ns.Constants.LAYER_POPUP_RETRY_SECONDS, function()
        self.retryScheduled = false
        self:Refresh()
      end)
    end
    return
  end

  local view = (deps.view or ns.ViewModel.LayerSwapView)(status)
  if not view then
    self:Hide()
    return
  end
  if key ~= self.shownKey then
    self.shownKey = key
    deps.show(view)
    if view.alert and not self.alerted[status.rid] then
      self.alerted[status.rid] = true
      if deps.alert then
        pcall(deps.alert)
      end
    end
  end
  if view.countdown and deps.countdown then
    deps.countdown(view.countdown)
    if not self.ticking then
      self.ticking = true
      deps.after(1, function()
        self.ticking = false
        self:Refresh()
      end)
    end
  end
end

LayerPopup.Controller = Controller

local frame
local controller

local function close()
  if frame then
    LibStub("AceGUI-3.0"):Release(frame)
    frame = nil
  end
end

local function say(text)
  print("Nrage Assistant: " .. text)
end

-- What each button does on the swap flow. A refusal is told in the chat; the swap itself is unchanged.
local ACTIONS = {
  help = "Offer",
  ignore = "Ignore",
  invite = "Invite",
  decline = "Decline",
  cancel = "Cancel",
  leave = "LeaveGroup",
  close = "Dismiss",
}

local function press(id)
  local swap = ns.layerSwap
  if not swap then
    return
  end
  local ok, reason = swap[ACTIONS[id]](swap)
  if not ok then
    say(ns.L("Not done: ") .. ns.ViewModel.LayerReason(reason))
  end
  LayerPopup.Refresh()
end

local function build(view)
  local AceGUI = LibStub("AceGUI-3.0")
  close()
  frame = AceGUI:Create("Frame")
  frame:SetTitle("Nrage Layers")
  frame:SetStatusText(view.countdown or "")
  ns.UI.ApplyWindowStatus(frame, "layerPopup", WIDTH, HEIGHT)
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  frame:SetLayout("List")
  frame:SetCallback("OnClose", function()
    controller:Closed()
    close()
    -- A helper who closes the window only stops seeing the request.
    local status = ns.layerSwap and ns.layerSwap:Status()
    if status and status.role == "helper" and status.stage == "request" then
      ns.layerSwap:Ignore()
    end
  end)

  local label = AceGUI:Create("Label")
  label:SetText(view.text)
  label:SetFullWidth(true)
  label:SetFontObject(GameFontNormalLarge)
  frame:AddChild(label)

  local row = AceGUI:Create("SimpleGroup")
  row:SetLayout("Flow")
  row:SetFullWidth(true)
  for _, spec in ipairs(view.buttons) do
    local button = AceGUI:Create("Button")
    button:SetText(spec.text)
    button:SetRelativeWidth(0.45)
    button:SetCallback("OnClick", function()
      press(spec.id)
    end)
    row:AddChild(button)
  end
  frame:AddChild(row)
end

function LayerPopup.Refresh()
  if controller and ns.active then
    controller:Refresh()
  end
end

-- Starts the popup; ns.layerSwap must exist.
function LayerPopup.Start()
  controller = Controller.New({
    status = function()
      return ns.layerSwap and ns.layerSwap:Status() or nil
    end,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    show = build,
    hide = close,
    alert = function()
      ns.Platform.ShowRaidNotice(ns.L("A guildmate wants to join your layer."))
      ns.Platform.PlayAlertSound()
    end,
    countdown = function(text)
      if frame then
        frame:SetStatusText(text)
      end
    end,
  })
end

ns.LayerPopup = LayerPopup
