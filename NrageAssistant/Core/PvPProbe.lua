local _, ns = ...

-- Client-side harness for the PvP API measurements (issue #92). Not unit tested: it only wires PvPProbeLog
-- to real events. Every client read is guarded, because an API may be missing on this client or return
-- secret values.
-- Usage: /nrage debug pvp start | stop | status | log | clear
local PvPProbe = {}

local PREFIX = "|cff33ff99Nrage Assistant|r"
local RECHECK_SECONDS = 0.5
local COMBAT_LOG = "COMBAT_LOG_EVENT_UNFILTERED"
local EVENTS = {
  "CHAT_MSG_COMBAT_HONOR_GAIN",
  "PLAYER_PVP_KILLS_CHANGED",
  "PLAYER_ENTERING_WORLD",
  "ZONE_CHANGED_NEW_AREA",
}

local Log = ns.PvPProbeLog

local log
local frame
local lastSnapshot

local function say(text)
  print(PREFIX .. " " .. text)
end

-- Calls a global client function if it exists; "missing" when it does not, the error text when it raises.
local function Read(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then
    return nil, "missing"
  end
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then
    return nil, Log.ToText(a)
  end
  return true, a, b, c, d
end

local function ReadCounters()
  local sessionOk, sessionHK, sessionHonor = Read("GetPVPSessionStats")
  if not sessionOk then
    error("GetPVPSessionStats " .. tostring(sessionHK), 0)
  end
  local lifetimeOk, lifetimeHK, highestRank = Read("GetPVPLifetimeStats")
  if not lifetimeOk then
    error("GetPVPLifetimeStats " .. tostring(lifetimeHK), 0)
  end
  return sessionHK, sessionHonor, lifetimeHK, highestRank
end

local function TakeSnapshot()
  return Log.Snapshot(ReadCounters)
end

local function DescribeInstance()
  local ok, inInstance, instanceType = Read("IsInInstance")
  if not ok then
    return "IsInInstance " .. tostring(inInstance)
  end
  return Log.DescribeInstance(inInstance, instanceType)
end

local function PlayerGuid()
  local ok, guid = Read("UnitGUID", "player")
  return ok and guid or nil
end

-- Logs the counters and returns them, so the next event can be compared with this one.
local function RecordSnapshot(kind, label)
  local snapshot = TakeSnapshot()
  log:Record(kind, label .. Log.DescribeSnapshot(snapshot))
  return snapshot
end

local function OnHonorGain(...)
  log:Record("honor", Log.FormatArgs(...) .. " " .. DescribeInstance())
  local before = RecordSnapshot("counters", "before: ")
  C_Timer.After(RECHECK_SECONDS, function()
    if not frame then
      return
    end
    local after = TakeSnapshot()
    log:Record("counters", "after " .. RECHECK_SECONDS .. "s: " .. Log.DescribeDelta(before, after))
    lastSnapshot = after
  end)
end

local function OnKillsChanged()
  local snapshot = RecordSnapshot("kills", "")
  log:Record("kills", "delta: " .. Log.DescribeDelta(lastSnapshot or snapshot, snapshot))
  lastSnapshot = snapshot
end

-- True when the event's subevent equals `name`; a secret subevent compares as false instead of raising.
local function IsSubevent(subevent, name)
  local ok, same = pcall(function()
    return subevent == name
  end)
  return ok and same
end

local function IsPlayerDeath(destGUID)
  local ok, isPlayer = pcall(function()
    return destGUID:sub(1, 7) == "Player-"
  end)
  return ok and isPlayer
end

local function OnCombatLog()
  local fn = _G.CombatLogGetCurrentEventInfo
  if type(fn) ~= "function" then
    return
  end
  -- timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName,
  -- destFlags: shifted by one here because values[1] is pcall's status.
  local values = { pcall(fn) }
  if not values[1] then
    return
  end
  local subevent, sourceGUID, sourceName = values[3], values[5], values[6]
  local destGUID, destName, destFlags = values[9], values[10], values[11]
  local partyKill = IsSubevent(subevent, "PARTY_KILL")
  if not (partyKill or (IsSubevent(subevent, "UNIT_DIED") and IsPlayerDeath(destGUID))) then
    return
  end
  local text = Log.DescribeCombatEvent({
    subevent = subevent,
    sourceGUID = sourceGUID,
    sourceName = sourceName,
    destGUID = destGUID,
    destName = destName,
    destFlags = destFlags,
  }, PlayerGuid())
  log:Record(partyKill and "party_kill" or "player_died", text .. " " .. DescribeInstance())
end

local function OnEvent(_, event, ...)
  if event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
    OnHonorGain(...)
  elseif event == "PLAYER_PVP_KILLS_CHANGED" then
    OnKillsChanged()
  elseif event == COMBAT_LOG then
    OnCombatLog()
  else
    log:Record("event", event .. " " .. DescribeInstance())
  end
end

local function Register(event)
  local ok, err = pcall(frame.RegisterEvent, frame, event)
  log:Record("register", ("%s %s"):format(event, ok and "registered" or "failed: " .. Log.ToText(err)))
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
  log = log or Log.New(ns.Platform)
  frame = CreateFrame("Frame")
  frame:SetScript("OnEvent", OnEvent)
  log:Record("probe", "started")
  for _, event in ipairs(EVENTS) do
    Register(event)
  end
  -- Blocked or not on this client is one of the things being measured, so a failure is only logged.
  Register(COMBAT_LOG)
  lastSnapshot = RecordSnapshot("counters", "initial: ")
  log:Record("instance", DescribeInstance())
  say("probe started.")
end

local function Stop()
  if not frame then
    say("probe is not running.")
    return
  end
  frame:UnregisterAllEvents()
  frame:SetScript("OnEvent", nil)
  frame = nil
  log:Record("probe", "stopped")
  say("probe stopped.")
end

local function PrintLog()
  if not log then
    say("no log yet.")
    return
  end
  local entries = log:GetLog()
  local first = entries[1] and entries[1].t or 0
  say(("log (%d entries):"):format(#entries))
  for _, entry in ipairs(entries) do
    print(("  %s +%.2fs [%s] %s"):format(entry.wall, entry.t - first, entry.kind, entry.detail))
  end
end

local ACTIONS = {
  start = Start,
  stop = Stop,
  log = PrintLog,
  clear = function()
    if log then
      log:Clear()
    end
    say("log cleared.")
  end,
  status = function()
    say(("running=%s %s %s"):format(tostring(frame ~= nil), Log.DescribeSnapshot(TakeSnapshot()), DescribeInstance()))
  end,
}

function PvPProbe.Handle(action)
  local run = ACTIONS[action or ""]
  if run then
    run()
  else
    say("usage: /nrage debug pvp start | stop | status | log | clear")
  end
end

ns.PvPProbe = PvPProbe
