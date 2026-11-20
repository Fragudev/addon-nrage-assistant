local _, ns = ...

-- Client-side harness for the PvP API measurements (issue #92). Not unit tested: it only wires PvPProbeLog
-- to real events. Every client read is guarded, because an API may be missing on this client or return
-- secret values.
-- Besides the honour counters it measures what the PvP missions need (docs/PVP_MISSIONS_PLAN.md, section 5):
-- M1 the map id and zone, M2 the victim name of the honour message next to the names of the target, M3 class, race and
-- name of the units the player sees, M4 whether the unit events fire (and whether registering them shows the
-- "blocked action" dialog), M5 the battleground winner.
-- Usage: /nrage debug pvp start | stop | status | log | clear
local PvPProbe = {}

local PREFIX = "|cffff0019Nrage Assistant|r"
local RECHECK_SECONDS = 0.5
local COMBAT_LOG = "COMBAT_LOG_EVENT_UNFILTERED"
local EVENTS = {
  "CHAT_MSG_COMBAT_HONOR_GAIN",
  "PLAYER_PVP_KILLS_CHANGED",
  "PLAYER_ENTERING_WORLD",
  "ZONE_CHANGED_NEW_AREA",
}
-- M3 and M4: the unit events; the unit is the argument of a nameplate event, the one named here for the others.
local UNIT_EVENTS = { PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover" }
local NAMEPLATE_EVENT = "NAME_PLATE_UNIT_ADDED"
-- M5.
local BATTLEFIELD_EVENT = "UPDATE_BATTLEFIELD_STATUS"

local Log = ns.PvPProbeLog

local log
local frame
local watchTicker
local lastSnapshot
-- The unit descriptions already logged since the probe started, so a nameplate event does not fill the log.
local seenUnits = {}

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

-- Like Read for a function inside a table of the client (C_Map.GetBestMapForUnit).
local function ReadIn(tableName, name, ...)
  local container = _G[tableName]
  if type(container) ~= "table" or type(container[name]) ~= "function" then
    return nil, "missing"
  end
  local ok, a, b, c, d = pcall(container[name], ...)
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

-- M1: the map id the client gives for the player, and the name of that map.
local function DescribeMap()
  local ok, mapId = ReadIn("C_Map", "GetBestMapForUnit", "player")
  local text = Log.DescribeRead("GetBestMapForUnit", ok, mapId)
  if ok and type(mapId) == "number" then
    local infoOk, info = ReadIn("C_Map", "GetMapInfo", mapId)
    local name
    if infoOk and type(info) == "table" then
      local fieldOk, field = pcall(function()
        return info.name
      end)
      name = fieldOk and field or nil
    end
    text = text .. " " .. Log.DescribeRead("mapName", infoOk, name)
  end
  return text
end

-- M3: what the client says about a unit; GetUnitName(unit, true) and UnitName are the two candidates for the name
-- the kill feed uses.
local function DescribeUnit(unit)
  return table.concat({
    "unit=" .. unit,
    Log.DescribeRead("UnitIsPlayer", Read("UnitIsPlayer", unit)),
    Log.DescribeRead("UnitIsEnemy", Read("UnitIsEnemy", "player", unit)),
    Log.DescribeRead("UnitClass", Read("UnitClass", unit)),
    Log.DescribeRead("UnitRace", Read("UnitRace", unit)),
    Log.DescribeRead("GetUnitName", Read("GetUnitName", unit, true)),
    Log.DescribeRead("UnitName", Read("UnitName", unit)),
  }, " ")
end

-- M5: the battleground winner and the faction to compare it with.
local function DescribeWinner()
  return table.concat({
    Log.DescribeRead("GetBattlefieldWinner", Read("GetBattlefieldWinner")),
    Log.DescribeRead("UnitFactionGroup", Read("UnitFactionGroup", "player")),
    DescribeInstance(),
  }, " ")
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
  -- M2 and M1: the victim the addon would use, the names of the target to compare it with, and the zone.
  local text = ...
  log:Record(
    "victim",
    Log.DescribeRead("ParseHonorVictim", true, ns.Platform.ParseHonorVictim(text))
      .. " "
      .. Log.DescribeRead("target GetUnitName", Read("GetUnitName", "target", true))
      .. " "
      .. Log.DescribeRead("target UnitName", Read("UnitName", "target"))
      .. " "
      .. DescribeMap()
  )
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

-- M7: class and race for a combat-log destination, without requiring a unit token such as target or mouseover.
local function DescribePlayerInfoByGUID(guid)
  if type(guid) ~= "string" then
    return "GetPlayerInfoByGUID no GUID"
  end
  local getPlayerInfo = _G.GetPlayerInfoByGUID
  if type(getPlayerInfo) ~= "function" then
    return "GetPlayerInfoByGUID missing"
  end
  local ok, localizedClass, class, localizedRace, race, sex, name, realm = pcall(getPlayerInfo, guid)
  if not ok then
    return "GetPlayerInfoByGUID error=" .. Log.ToText(localizedClass)
  end
  return ("class=%s classToken=%s race=%s raceToken=%s sex=%s name=%s realm=%s"):format(
    tostring(localizedClass),
    tostring(class),
    tostring(localizedRace),
    tostring(race),
    tostring(sex),
    tostring(name),
    tostring(realm)
  )
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
  local playerInfo = DescribePlayerInfoByGUID(destGUID)
  log:Record(partyKill and "party_kill" or "player_died", text .. " " .. playerInfo .. " " .. DescribeInstance())
end

-- A unit event: the unit is logged once per distinct description.
local function OnUnit(unit)
  if type(unit) ~= "string" then
    log:Record("unit", "event without a unit")
    return
  end
  local text = DescribeUnit(unit)
  local guidOk, guid = Read("UnitGUID", unit)
  if guidOk and type(guid) == "string" then
    text = text .. " guid=" .. Log.ToText(guid) .. " " .. DescribePlayerInfoByGUID(guid)
  else
    text = text .. " guid=" .. Log.DescribeRead("UnitGUID", guidOk, guid)
  end
  if not seenUnits[text] then
    seenUnits[text] = true
    log:Record("unit", text)
  end
end

local function OnEvent(_, event, ...)
  if UNIT_EVENTS[event] then
    OnUnit(UNIT_EVENTS[event])
  elseif event == NAMEPLATE_EVENT then
    OnUnit((...))
  elseif event == BATTLEFIELD_EVENT then
    log:Record("winner", DescribeWinner())
  elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
    OnHonorGain(...)
  elseif event == "PLAYER_PVP_KILLS_CHANGED" then
    OnKillsChanged()
  elseif event == COMBAT_LOG then
    OnCombatLog()
  else
    log:Record("event", event .. " " .. DescribeInstance() .. " " .. DescribeMap())
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
  -- COMBAT_LOG_EVENT_UNFILTERED is protected on this client and registering it can show a blocked-action dialog.
  -- The probe deliberately does not register it; unit GUID lookups are enough to measure GetPlayerInfoByGUID safely.
  for event in pairs(UNIT_EVENTS) do
    Register(event)
  end
  Register(NAMEPLATE_EVENT)
  Register(BATTLEFIELD_EVENT)
  seenUnits = {}
  log:Record("map", DescribeMap())
  log:Record("winner", DescribeWinner())
  lastSnapshot = RecordSnapshot("counters", "initial: ")
  log:Record("instance", DescribeInstance())
  say("probe started.")
end

local function Stop()
  if watchTicker then
    watchTicker:Cancel()
    watchTicker = nil
    say("mission watch stopped.")
  end
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

-- The mission log is separate from the probe log: this shows whether an honour message actually reached the mission
-- service, and which victim data was available when it was appended.
local function PrintMissionEvents()
  local missions = ns.pvpMissions
  if not missions then
    say("mission service is not running.")
    return
  end
  local events = missions:Events()
  if #events == 0 then
    say("mission events: none.")
    return
  end
  local first = math.max(1, #events - 9)
  say(("mission events (%d total, showing %d-%d):"):format(#events, first, #events))
  for index = first, #events do
    local event = events[index]
    print(
      ("  [%d] kind=%s at=%s victim=%s place=%s class=%s race=%s mapId=%s"):format(
        index,
        tostring(event.kind),
        tostring(event.at),
        tostring(event.victim),
        tostring(event.place),
        tostring(event.class),
        tostring(event.race),
        tostring(event.mapId)
      )
    )
  end
end

-- Observe the real mission pipeline; reference sets stay bounded by the retained mission log, including at its cap.
local function WatchMissions()
  if watchTicker then
    say("mission watch already running.")
    return
  end
  if not ns.pvpMissions then
    say("mission service is not running.")
    return
  end
  local previous, lastScan = {}, nil
  for _, event in ipairs(ns.pvpMissions:Events()) do
    previous[event] = true
  end
  local function tick()
    if not ns.active or not ns.modules:IsEnabled("pvp") then
      return
    end
    local missions = ns.pvpMissions
    local count = missions:RescanUnits()
    local summary = ("mission scan: %d readable enemy units; %d cached names."):format(
      count,
      missions.deps.cache:Count()
    )
    if summary ~= lastScan then
      say(summary)
      lastScan = summary
    end
    local current = {}
    for _, event in ipairs(missions:Events()) do
      current[event] = true
      if not previous[event] then
        say(
          ("mission event: kind=%s victim=%s class=%s race=%s place=%s mapId=%s"):format(
            Log.ToText(event.kind),
            Log.ToText(event.victim),
            Log.ToText(event.class),
            Log.ToText(event.race),
            Log.ToText(event.place),
            Log.ToText(event.mapId)
          )
        )
      end
    end
    previous = current
  end
  tick()
  watchTicker = C_Timer.NewTicker(ns.Constants.INTEL_RESCAN_SECONDS, function()
    local ok, err = pcall(tick)
    if not ok then
      say("mission watch error: " .. Log.ToText(err))
      watchTicker:Cancel()
      watchTicker = nil
    end
  end)
  say("mission watch started; use /nrage debug pvp stop to stop.")
end

local ACTIONS = {
  watch = WatchMissions,
  scan = function()
    if not ns.pvpMissions then
      say("mission service is not running.")
      return
    end
    say(
      ("mission scan: %d readable enemy units; %d cached names."):format(
        ns.pvpMissions:RescanUnits(),
        ns.pvpMissions.deps.cache:Count()
      )
    )
  end,
  start = Start,
  stop = Stop,
  log = PrintLog,
  events = PrintMissionEvents,
  clear = function()
    if log then
      log:Clear()
    end
    say("log cleared.")
  end,
  status = function()
    say(
      ("running=%s %s %s %s"):format(
        tostring(frame ~= nil),
        Log.DescribeSnapshot(TakeSnapshot()),
        DescribeInstance(),
        DescribeMap()
      )
    )
  end,
}

function PvPProbe.Handle(action)
  -- Release builds ship this file but never run it (ns.IsDevBuild).
  if not ns.IsDevBuild() then
    say("the pvp probe is only available in a development build.")
    return
  end
  local run = ACTIONS[action or ""]
  if run then
    run()
  else
    say("usage: /nrage debug pvp start | stop | status | log | events | scan | watch | clear")
  end
end

ns.PvPProbe = PvPProbe
