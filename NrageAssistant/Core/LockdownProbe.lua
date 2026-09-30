local _, ns = ...

-- Client-side harness for the phase 0 two-client lockdown test. Not unit tested: it only
-- wires LockdownGuard to real events, a poll timer and addon messages.
-- Usage: /nrage debug lockdown start | stop | status | send | log | clear
local Probe = {}

local PREFIX = "|cff33ff99Nrage Assistant|r"
local POLL_SECONDS = 0.25
local EVENTS = {
  "ENCOUNTER_START",
  "ENCOUNTER_END",
  "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED",
  "PLAYER_ENTERING_WORLD",
  "CHAT_MSG_ADDON",
}

local guard
local frame
local ticker
local sequence = 0

local function say(text)
  print(PREFIX .. " " .. text)
end

local function ToText(value)
  local ok, text = pcall(tostring, value)
  return ok and text or "<secret>"
end

-- CHAT_MSG_ADDON arguments may be secret values during lockdown; never let that raise.
local function OnAddonMessage(prefix, text, channel, sender)
  local ok, isOurs = pcall(function() return prefix == ns.Constants.ADDON_PREFIX end)
  if not ok then
    guard:Record("recv", "unreadable message (secret values)")
  elseif isOurs then
    guard:Record("recv", ("%s from %s via %s"):format(ToText(text), ToText(sender), ToText(channel)))
  end
end

local function OnEvent(_, event, ...)
  if event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)
  else
    guard:Note(event)
  end
  guard:Poll()
end

local function Start()
  if not ns.active then
    say("probe unavailable: the addon is disabled for this character.")
    return
  end
  if frame then
    say("probe already running.")
    return
  end
  guard = guard or ns.LockdownGuard.New(ns.Platform)
  ns.Platform.RegisterPrefix(ns.Constants.ADDON_PREFIX)
  frame = CreateFrame("Frame")
  for _, event in ipairs(EVENTS) do
    frame:RegisterEvent(event)
  end
  frame:SetScript("OnEvent", OnEvent)
  ticker = C_Timer.NewTicker(POLL_SECONDS, function() guard:Poll() end)
  guard:Record("probe", "started")
  say("probe started.")
end

local function Stop()
  if not frame then
    say("probe is not running.")
    return
  end
  frame:UnregisterAllEvents()
  frame:SetScript("OnEvent", nil)
  ticker:Cancel()
  frame, ticker = nil, nil
  guard:Record("probe", "stopped")
  say("probe stopped.")
end

local function Send()
  if not frame then
    say("start the probe first.")
    return
  end
  sequence = sequence + 1
  local text = "PING:" .. sequence
  -- Sent on purpose even under lockdown: what happens then is what this test measures.
  local canSend = guard:CanSend()
  local ok, result = pcall(ns.Platform.SendGuildMessage, ns.Constants.ADDON_PREFIX, text)
  guard:Record("send", ("%s canSend=%s ok=%s result=%s"):format(text, tostring(canSend), tostring(ok), ToText(result)))
end

local function PrintLog()
  if not guard then
    say("no log yet.")
    return
  end
  local log = guard:GetLog()
  local first = log[1] and log[1].t or 0
  say(("log (%d entries):"):format(#log))
  for _, entry in ipairs(log) do
    print(("  %s +%.2fs [%s] %s (locked=%s)"):format(
      entry.wall, entry.t - first, entry.kind, entry.detail, tostring(entry.locked)))
  end
end

local ACTIONS = {
  start = Start,
  stop = Stop,
  send = Send,
  log = PrintLog,
  clear = function()
    if guard then guard:Clear() end
    say("log cleared.")
  end,
  status = function()
    local locked = ns.Platform.IsChatMessagingLockedDown()
    say(("running=%s locked=%s"):format(tostring(frame ~= nil), tostring(locked)))
  end,
}

function Probe.Handle(action)
  local run = ACTIONS[action or ""]
  if run then
    run()
  else
    say("usage: /nrage debug lockdown start | stop | status | send | log | clear")
  end
end

ns.Probe = Probe
