local _, ns = ...

-- The popup of a layer swap, for both sides: the requester follows the request step by step, a helper is asked to
-- help and, when picked, to invite. It never appears during an encounter lockdown (it waits and tries again). In
-- combat it does not pop up either: a small icon next to the Groups icon holds it until combat ends (or the icon is
-- clicked), and then it opens with its alert. It only ever prompts: every action that invites or leaves a group is a
-- button the player clicks.
-- What to show comes from ViewModel.LayerSwapView; this file only builds the frame with the kit. Client only.
local LayerPopup = {}

local L = ns.L

local WIDTH = 380

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: status() -> LayerSwap:Status() or nil, isLockedDown() -> boolean, after(seconds, fn), show(view),
--         hide(), view(status) -> the view (default ViewModel.LayerSwapView); optional: alert() when a helper is
--         asked for help, countdown(text) to show the time left, inCombat() -> boolean and waiting(view or nil) to
--         show or hide the icon that holds a new popup back during combat (both or neither)
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
    waitingKey = nil,
    openNowKey = nil,
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

-- Hides the icon that holds the popup back, if it is shown.
function Controller:StopWaiting()
  if self.waitingKey then
    self.waitingKey = nil
    self.deps.waiting(nil)
  end
end

function Controller:Hide()
  self:StopWaiting()
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

-- The player clicked the icon: the popup opens now, even in combat.
function Controller:OpenNow()
  local status = self.deps.status()
  self.openNowKey = status and keyOf(status) or nil
  self:Refresh()
end

-- A new popup waits behind the icon while the player fights. A popup already on screen keeps following the swap.
function Controller:HoldsBack(key)
  local deps = self.deps
  return self.shownKey == nil
    and key ~= self.openNowKey
    and deps.waiting ~= nil
    and deps.inCombat ~= nil
    and deps.inCombat() == true
end

-- Shows, updates or closes the popup to match the swap. Called whenever the swap changes.
function Controller:Refresh()
  local deps = self.deps
  local status = deps.status()
  if not status or status.hidden then
    self:Hide()
    return
  end
  -- Only the swap on screen can still be alerted about: the ones before it are forgotten.
  for rid in pairs(self.alerted) do
    if rid ~= status.rid then
      self.alerted[rid] = nil
    end
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
  if key ~= self.shownKey and self:HoldsBack(key) then
    self.waitingKey = key
    deps.waiting(view)
  elseif key ~= self.shownKey then
    self:StopWaiting()
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
local content
local countdownLabel
local controller
local waitIcon, waitView

local function close()
  if frame then
    frame:Hide()
  end
  if content then
    content:Release()
    content = nil
  end
  countdownLabel = nil
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

-- Draws the view into `stack`: the text, the time left and one button per action. The frame around it is built apart,
-- so this can be tested with the fake kit. Returns the label of the time left (nil when there is none).
function LayerPopup.Draw(stack, view, onPress)
  local Kit = ns.Kit
  Kit.Label(stack, { text = view.text, wrap = true })
  local countdown
  if view.countdown then
    countdown = Kit.Label(stack, { text = view.countdown, style = "small", color = "muted" })
  end
  local row = Kit.Row(stack, { gap = 8, align = "center" })
  for index, spec in ipairs(view.buttons) do
    Kit.Button(row, {
      text = spec.text,
      variant = index == 1 and "primary" or "secondary",
      layout = { weight = 1 },
      onClick = function()
        onPress(spec.id)
      end,
    })
  end
  return countdown
end

-- The floating card: made once, then filled again whenever the swap moves to another step.
local function ensureFrame()
  if not frame then
    frame = ns.PopupFrame.New({
      name = "NrageAssistantLayerPopup",
      title = "Nrage Layers",
      width = WIDTH,
      windowName = "layerPopup",
      closeTooltip = L("Close"),
      onClose = function()
        controller:Closed()
        close()
        -- A helper who closes the window only stops seeing the request.
        local status = ns.layerSwap and ns.layerSwap:Status()
        if status and status.role == "helper" and status.stage == "request" then
          ns.layerSwap:Ignore()
        end
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
  countdownLabel = LayerPopup.Draw(content, view, press)
  ns.PopupFrame.Fit(frame, content, WIDTH)
end

-- The icon that holds the popup back in combat: on the left of the Groups icon when that one shows, otherwise in its
-- place. Hovering tells what the swap asks; a click opens the popup at once.
local function showWaitTooltip(self)
  if not waitView then
    return
  end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(waitView.title)
  GameTooltip:AddLine(waitView.text, 1, 1, 1, true)
  if waitView.countdown then
    GameTooltip:AddLine(waitView.countdown, 1, 1, 1)
  end
  GameTooltip:AddLine(L("It opens when combat ends. Click to open it now."), 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

local function placeWaitIcon()
  waitIcon:ClearAllPoints()
  local groups = ns.GroupsIcon.Frame()
  if groups and groups:IsShown() then
    waitIcon:SetPoint("TOPRIGHT", groups, "TOPLEFT", -4, 0)
  else
    waitIcon:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", ns.GroupsIcon.Place())
  end
end

local function waiting(view)
  waitView = view
  if not view then
    if waitIcon then
      waitIcon:Hide()
    end
    return
  end
  if not waitIcon then
    waitIcon = ns.GroupsIcon.RoundButton("NrageAssistantLayerWaitButton", "Interface\\Icons\\INV_Misc_Map_01")
    waitIcon:SetScript("OnClick", function()
      GameTooltip:Hide()
      controller:OpenNow()
    end)
    waitIcon:SetScript("OnEnter", showWaitTooltip)
    waitIcon:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
  end
  placeWaitIcon()
  waitIcon:Show()
  if GameTooltip:IsShown() and GameTooltip:GetOwner() == waitIcon then
    showWaitTooltip(waitIcon)
  end
end

function LayerPopup.Refresh()
  if ns.modules and not ns.modules:IsEnabled("layers") then
    return
  end
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
    inCombat = ns.Platform.IsInCombat,
    waiting = function(view)
      pcall(waiting, view)
    end,
    after = C_Timer.After,
    show = build,
    hide = close,
    alert = function()
      ns.Platform.ShowRaidNotice(ns.L("A guildmate wants to join your layer."))
      ns.Platform.PlayAlertSound()
    end,
    countdown = function(text)
      if countdownLabel then
        countdownLabel:SetText(text)
      end
    end,
  })
  -- A popup held back in combat opens when combat ends.
  local events = CreateFrame("Frame")
  ns.Platform.TryRegisterEvent(events, "PLAYER_REGEN_ENABLED")
  events:SetScript("OnEvent", LayerPopup.Refresh)
end

ns.LayerPopup = LayerPopup
