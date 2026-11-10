local _, ns = ...

-- The popup of Groups (docs/LFG_PLAN.md 6.2): a leader is told about a new applicant and can invite or decline from
-- the popup; an applicant is told that the leader accepted or declined. It never appears during an encounter lockdown
-- (it waits and tries again) and it only ever prompts: inviting is a button the player clicks. What to show comes from
-- ViewModel.LfgPopupView; this file only builds the frame with the kit. Client only.
local LfgPopup = {}

local L = ns.L

local WIDTH = 340

-- The decisions, apart from the frame so they can be tested with fakes.
--   deps: status() -> LfgService:Status() or nil, isLockedDown() -> boolean, after(seconds, fn), show(view), hide(),
--         view(status) -> the view (default ViewModel.LfgPopupView); optional: alert() when a new applicant is shown
local Controller = {}
Controller.__index = Controller

function Controller.New(deps)
  return setmetatable(
    { deps = deps, shownKey = nil, closedKey = nil, alertedKey = nil, retryScheduled = false },
    Controller
  )
end

function Controller:Hide()
  if self.shownKey then
    self.shownKey = nil
    self.deps.hide()
  end
end

-- The player closed the window with its own button: it stays closed until what it says changes.
function Controller:Closed()
  self.closedKey = self.shownKey or self.closedKey
  self.shownKey = nil
end

-- Shows, updates or closes the popup to match the flow. Called whenever it changes.
function Controller:Refresh()
  local deps = self.deps
  local view = (deps.view or ns.ViewModel.LfgPopupView)(deps.status())
  if not view then
    -- What it said is over: the same words may be shown again later.
    self.closedKey, self.alertedKey = nil, nil
    self:Hide()
    return
  end
  if view.key == self.closedKey then
    return
  end
  if deps.isLockedDown() then
    if not self.retryScheduled then
      self.retryScheduled = true
      deps.after(ns.Constants.LFG_POPUP_RETRY_SECONDS, function()
        self.retryScheduled = false
        self:Refresh()
      end)
    end
    return
  end
  if view.key ~= self.shownKey then
    self.shownKey = view.key
    deps.show(view)
    if view.alert and view.key ~= self.alertedKey then
      self.alertedKey = view.key
      if deps.alert then
        pcall(deps.alert)
      end
    end
  end
end

LfgPopup.Controller = Controller

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

local function say(text)
  print("Nrage Assistant: " .. text)
end

-- What each button does. A refusal is told in the chat; the flow itself is unchanged.
local ACTIONS = { invite = "Invite", decline = "Decline" }

local function press(id, view)
  local service = ns.lfgService
  if id == "close" then
    controller:Closed()
    close()
    -- An applicant who closes a notice has read it.
    if service then
      service:Dismiss()
    end
    return
  end
  if not (service and ACTIONS[id]) then
    return
  end
  local ok, reason = service[ACTIONS[id]](service, view.target)
  if not ok then
    say(ns.ViewModel.GroupReason(reason))
  end
  LfgPopup.Refresh()
end

-- Draws the view into `stack`: the text and one button per action. The frame around it is built apart, so this can be
-- tested with the fake kit.
function LfgPopup.Draw(stack, view, onPress)
  local Kit = ns.Kit
  Kit.Label(stack, { text = view.text, wrap = true })
  local row = Kit.Row(stack, { gap = 8, align = "center" })
  for index, spec in ipairs(view.buttons) do
    Kit.Button(row, {
      text = spec.text,
      variant = index == 1 and "primary" or "secondary",
      layout = { weight = 1 },
      onClick = function()
        onPress(spec.id, view)
      end,
    })
  end
end

local function ensureFrame()
  if not frame then
    frame = ns.PopupFrame.New({
      name = "NrageAssistantLfgPopup",
      title = "Nrage Groups",
      width = WIDTH,
      windowName = "lfgPopup",
      closeTooltip = L("Close"),
      onClose = function()
        controller:Closed()
        close()
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
  frame.title:SetText(view.title)
  content = ns.Kit.Stack(frame, { gap = 12 })
  LfgPopup.Draw(content, view, press)
  ns.PopupFrame.Fit(frame, content, WIDTH)
end

function LfgPopup.Refresh()
  if ns.modules and not ns.modules:IsEnabled("groups") then
    return
  end
  if controller and ns.active then
    controller:Refresh()
  end
end

-- Starts the popup; ns.lfgService must exist when something is shown.
function LfgPopup.Start()
  controller = Controller.New({
    status = function()
      return ns.lfgService and ns.lfgService:Status() or nil
    end,
    isLockedDown = ns.Platform.IsChatMessagingLockedDown,
    after = C_Timer.After,
    show = build,
    hide = close,
    alert = function()
      ns.Platform.ShowRaidNotice(L("Someone wants to join your group."))
      ns.Platform.PlayAlertSound()
    end,
  })
end

ns.LfgPopup = LfgPopup
