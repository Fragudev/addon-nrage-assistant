local _, ns = ...

-- Client-side harness for the PvP API measurements (issue #92), tested with simulated client events.
-- Every client read is guarded, because an API may be missing on this client or return
-- secret values.
-- Besides the honour counters it measures what the PvP missions need (docs/PVP_MISSIONS_PLAN.md, section 5):
-- M1 the map id and zone, M2 the victim name of the honour message next to the names of the target, M3 class, race and
-- name of the units the player sees, M4 whether the unit events fire (and whether registering them shows the
-- "blocked action" dialog), M5 the battleground winner.
-- Usage: /nrage debug pvp kills | killlog for independent PARTY_KILL; start | log for raw unit/honour events.
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
local killFrame
local killLog
local killTicker
local killWindowId = 0
local killFinish
local killQuiet = false
local worldDecisionRecord
local lastSnapshot
-- The unit descriptions already logged since the probe started, so a nameplate event does not fill the log.
local seenUnits = {}

local function say(text)
  print(PREFIX .. " " .. text)
end

local function WorldFieldsText(fields)
  local keys, parts = {}, {}
  for key in pairs(fields) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. Log.SavedText(fields[key])
  end
  return table.concat(parts, " ")
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
  local stopped = false
  if killFinish then
    killFinish()
    killFinish = nil
  end
  if killTicker then
    killTicker:Cancel()
    killTicker = nil
  end
  if killFrame then
    killFrame:UnregisterAllEvents()
    killFrame:SetScript("OnEvent", nil)
    killFrame = nil
    killQuiet = false
    worldDecisionRecord = nil
    stopped = true
    say("PARTY_KILL probe stopped.")
  end
  if watchTicker then
    watchTicker:Cancel()
    watchTicker = nil
    stopped = true
    say("mission watch stopped.")
  end
  if not frame then
    if not stopped then
      say("probe is not running.")
    end
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

local function PrintMissionCache()
  local missions = ns.pvpMissions
  if not missions then
    say("mission service is not running.")
    return
  end
  local rows = missions.deps.cache:DebugRows()
  say(("mission cache (%d entries):"):format(#rows))
  for index, row in ipairs(rows) do
    print(
      ("  [%d] name=%s class=%s race=%s age=%ss"):format(
        index,
        Log.ToText(row.name),
        Log.ToText(row.class),
        Log.ToText(row.race),
        Log.ToText(row.age)
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

-- Separate from the combat log and the mission writer. Keep these records away from noisy unit scans.
local function WatchPartyKills(quiet)
  if killFrame then
    say("PARTY_KILL probe already running.")
    return
  end
  if not ns.active then
    say("probe unavailable: the addon is disabled for this character.")
    return
  end
  if quiet and not ns.character then
    say("persistent capture unavailable: character data is not loaded.")
    return
  end
  killLog = killLog or Log.New(ns.Platform)
  local capture = quiet and Log.NewCapture(ns.character, ns.Platform) or nil
  if capture then
    capture.rulesVersion = 2
    capture.diagnosticVersion = 3
  end
  killQuiet = quiet == true
  local window
  local candidate = CreateFrame("Frame")
  local function record(kind, text, fields)
    killLog:Record(kind, text)
    if capture then
      Log.CaptureRecord(capture, ns.Platform, window and window.id, kind, text, fields)
    else
      say(("[%.2f %s] %s"):format(ns.Platform.Now(), kind, text))
    end
  end
  worldDecisionRecord = record
  -- Sample before notifications arrive: counters can already have changed inside the event handler.
  -- A six-second observation window handles either event order, without asserting victim attribution.
  local function missionState()
    local state = { rows = {}, progress = {}, feed = {} }
    if ns.pvpFeed then
      for _, entry in ipairs(ns.pvpFeed:Entries()) do
        state.feed[entry] = Log.ToText(entry.blow)
      end
    end
    local missions = ns.pvpMissions
    if not missions then
      state.status = "service_unavailable"
      return state
    end
    for _, row in ipairs(missions:Events()) do
      state.rows[row] = true
    end
    local season = missions.deps.season:ActiveSeason()
    state.status = season and "season=" .. Log.ToText(season.id) or "no_active_season"
    for _, mission in ipairs(season and missions.deps.season:Missions(season.id) or {}) do
      if mission.active then
        local result = missions:Progress(mission.id)
        if result then
          local parts = {}
          for _, bar in ipairs(result.bars or {}) do
            parts[#parts + 1] = ("%s=%s/%s"):format(bar.label, bar.done, bar.total)
          end
          parts[#parts + 1] = "unknown=" .. Log.ToText(result.unknown)
          parts[#parts + 1] = "complete=" .. Log.ToText(result.complete)
          state.progress[mission.id] = table.concat(parts, " ")
        end
      end
    end
    return state
  end
  local function safeMissionState()
    local ok, state = pcall(missionState)
    return ok and state or { rows = {}, progress = {}, feed = {}, status = "unreadable:" .. Log.ToText(state) }
  end
  local previousCounters, previousMissions = TakeSnapshot(), safeMissionState()
  local function counterContext()
    return Log.SavedText(DescribeInstance() .. " " .. DescribeMap())
  end
  local counterGuard = Log.NewCounterGuard(previousCounters, counterContext())
  local lastGuardReason
  local function beginWindow()
    if not window then
      killWindowId = killWindowId + 1
      window = {
        id = killWindowId,
        at = ns.Platform.Now(),
        before = previousCounters,
        missions = previousMissions,
        victims = {},
        honor = 0,
        unknownDeaths = 0,
      }
      if capture then
        window.saved = Log.CaptureWindow(capture, ns.Platform, window.id)
        window.saved.context = Log.SavedText(DescribeInstance() .. " " .. DescribeMap())
      end
      record("chain_begin", "id=" .. window.id .. " " .. Log.DescribeSnapshot(window.before))
    end
    return window
  end
  local function hkStatus(before, after)
    if before.epoch ~= after.epoch or before.guardReason or after.guardReason then
      return "counters_rebased"
    end
    local readable, reset = false, false
    for _, key in ipairs({ "sessionHK", "lifetimeHK" }) do
      local a, b = before[key], after[key]
      if type(a) == "number" and type(b) == "number" then
        readable = true
        if b > a then
          return "increase_observed"
        end
        reset = reset or b < a
      end
    end
    return reset and "counter_reset" or (readable and "no_increase_observed" or "unavailable")
  end
  local function pollChain(force)
    local counters = counterGuard:Observe(TakeSnapshot(), counterContext(), ns.Platform.Now())
    local missions = safeMissionState()
    if counters.guardReason ~= lastGuardReason then
      record("counter_guard", "state=" .. (counters.guardReason or "ready") .. " " .. Log.DescribeSnapshot(counters))
      lastGuardReason = counters.guardReason
    end
    if not window and hkStatus(previousCounters, counters) == "increase_observed" then
      beginWindow()
    end
    if window and (force or ns.Platform.Now() - window.at >= 6) then
      local count, only = 0, nil
      for guid in pairs(window.victims) do
        count, only = count + 1, guid
      end
      local hkDelta = 0
      for _, key in ipairs({ "sessionHK", "lifetimeHK" }) do
        local a, b = window.before[key], counters[key]
        if type(a) == "number" and type(b) == "number" then
          hkDelta = math.max(hkDelta, b - a)
        end
      end
      local credit = hkStatus(window.before, counters)
      if credit ~= "increase_observed" then
        hkDelta = 0
      end
      local relation = window.unknownDeaths > 0 and "ambiguous"
        or (count == 0 and "no_victim" or ((count > 1 or hkDelta > 1) and "ambiguous" or "single_temporal_candidate"))
      for entry, blow in pairs(missions.feed) do
        if window.missions.feed[entry] ~= blow then
          record("chain_feed", ("id=%d victim=%s blow=%s"):format(window.id, Log.ToText(entry.victim), blow))
        end
      end
      local added = 0
      for row in pairs(missions.rows) do
        if not window.missions.rows[row] then
          added = added + 1
          record(
            "chain_mission_event",
            ("id=%d kind=%s victim=%s class=%s race=%s honor=%s"):format(
              window.id,
              Log.ToText(row.kind),
              Log.ToText(row.victim),
              Log.ToText(row.class),
              Log.ToText(row.race),
              Log.ToText(row.honor)
            )
          )
        end
      end
      local changed, active = 0, 0
      for id, value in pairs(missions.progress) do
        active = active + 1
        if window.missions.progress[id] ~= value then
          changed = changed + 1
          record(
            "chain_progress",
            ("id=%d mission=%s before={%s} after={%s}"):format(
              window.id,
              Log.ToText(id),
              window.missions.progress[id] or "unavailable",
              value
            )
          )
        end
      end
      record(
        "chain_summary",
        (
          "id=%d candidates=%d relation=%s victimGUID=%s hk=%s hkDelta=%d honorMessages=%d "
          .. "missionEvents=%d progressChanges=%d activeMissions=%d missionStatus=%s unknownDeaths=%d delta={%s}"
        ):format(
          window.id,
          count,
          relation,
          count == 1 and (only:match("^Player%-") and only or "restricted_identity") or "unresolved",
          hkStatus(window.before, counters),
          hkDelta,
          window.honor,
          added,
          changed,
          active,
          missions.status,
          window.unknownDeaths,
          Log.DescribeDelta(window.before, counters)
        )
      )
      if window.saved then
        local saved = window.saved
        saved.status = ns.Platform.Now() - window.at >= 6 and "complete" or "partial"
        saved.hk = hkStatus(window.before, counters)
        saved.hkDelta = hkDelta
        saved.unknownDeaths = window.unknownDeaths
        saved.candidates, saved.relation = count, relation
        saved.honorMessages, saved.missionEvents, saved.progressChanges = window.honor, added, changed
        saved.missionStatus = Log.SavedText(missions.status)
        saved.delta = Log.SavedText(Log.DescribeDelta(window.before, counters))
      end
      window = nil
    end
    previousCounters, previousMissions = counters, missions
  end
  local function attackerKind(guid)
    local function matches(unit)
      local ok, value = Read("UnitGUID", unit)
      return ok and value ~= nil and value == guid
    end
    if matches("player") then
      return "player"
    elseif matches("pet") then
      return "pet"
    end
    for _, prefix in ipairs({ "party", "raid" }) do
      for index = 1, prefix == "party" and 4 or 40 do
        local unit = prefix .. index
        if matches(unit) then
          return "group:" .. unit
        elseif matches(prefix .. "pet" .. index) then
          return "group-pet:" .. unit
        end
      end
    end
    return "other-or-unreadable"
  end
  local function inspectGUID(guid)
    local ok, value, state = pcall(function()
      if type(_G.issecretvalue) == "function" and _G.issecretvalue(guid) then
        return nil, "restricted"
      end
      if type(guid) ~= "string" or guid == "" then
        return nil, "invalid"
      end
      if not guid:find("^Player%-") then
        return nil, "non_player"
      end
      return guid, "readable"
    end)
    if not ok then
      return nil, "restricted"
    end
    return value, state
  end
  local function classifyVictim(guid, result)
    if guid then
      local ok, source = pcall(attackerKind, guid)
      if ok and source == "player" then
        return "self"
      end
      if ok and source ~= "other-or-unreadable" then
        return "ally"
      end
      local units = { "target", "focus", "mouseover" }
      for index = 1, 40 do
        units[#units + 1] = "nameplate" .. index
      end
      for _, unit in ipairs(units) do
        local matched, side = pcall(function()
          local read, value = Read("UnitGUID", unit)
          if not read or value ~= guid then
            return nil
          end
          local enemyOk, enemy = Read("UnitIsEnemy", "player", unit)
          if enemyOk and enemy == true then
            return "enemy_unit"
          end
          local friendOk, friend = Read("UnitIsFriend", "player", unit)
          if friendOk and friend == true then
            return "ally"
          end
        end)
        if matched and side then
          return side
        end
      end
    end
    -- Race is a conservative fallback, not proof of a battleground team (e.g. mercenary modes).
    local alliance = { HUMAN = true, DWARF = true, GNOME = true, NIGHTELF = true }
    local horde = { ORC = true, SCOURGE = true, UNDEAD = true, TAUREN = true, TROLL = true }
    local race = result.race and result.race:upper()
    local ok, faction = Read("UnitFactionGroup", "player")
    faction = ok and Log.SavedText(faction) or nil
    if faction == "Alliance" then
      if alliance[race] then
        return "ally_race"
      end
      if horde[race] then
        return "enemy_race"
      end
    elseif faction == "Horde" then
      if horde[race] then
        return "ally_race"
      end
      if alliance[race] then
        return "enemy_race"
      end
    end
    return "unknown"
  end
  local lastVictim, lastAt
  local function victimInfo(key, guidText, info, classification, event, source)
    if window and window.saved then
      local victims = window.saved.victims
      local row
      for _, value in ipairs(victims) do
        if (value.identityKey or value.guid) == key then
          row = value
        end
      end
      if not row and #victims < 64 then
        row = { guid = guidText, identityKey = key, classification = classification }
        victims[#victims + 1] = row
      end
      if row then
        row.info = Log.SavedText(info)
        row[event] = true
        if source then
          row.source = Log.SavedText(source)
        end
      else
        window.saved.truncatedVictims = true
      end
    end
    return info
  end
  killFinish = function()
    local ok, err = pcall(pollChain, true)
    if not ok then
      record("chain_unreadable", Log.ToText(err))
    end
    if capture then
      capture.ended = Log.SavedText(ns.Platform.WallClock())
    end
  end
  candidate:SetScript("OnEvent", function(_, event, ...)
    if killFrame ~= candidate or not ns.active then
      return
    end
    local ok, err = pcall(function(...)
      if event == "PLAYER_LOGOUT" then
        killFinish()
        return
      end
      if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        counterGuard:Reset(event, ns.Platform.Now())
        record("counter_guard", "rebase=" .. event)
        return
      end
      local victimKey, victimText, queryText, classification
      if event == "PARTY_KILL" or event == "UNIT_DIED" then
        local victim = select(event == "PARTY_KILL" and 2 or 1, ...)
        -- This must precede EVERY comparison, prefix check, string conversion and table lookup of victim.
        local result = Log.QueryGUID(victim)
        local guid, state = inspectGUID(victim)
        if state == "non_player" then
          return
        end
        queryText = Log.DescribeGUIDQuery(result)
        classification = classifyVictim(guid, result)
        if classification == "self" or classification == "ally" or classification == "ally_race" then
          record("death_ignored", event .. " reason=" .. classification .. " " .. queryText)
          return
        end
        local observation = beginWindow()
        record(
          "guid_probe",
          event .. " guidState=" .. state .. " classification=" .. classification .. " " .. queryText
        )
        victimKey = guid
        victimText = guid or "<" .. state .. ">"
        if not victimKey and result.status == "resolved" and result.realm ~= nil then
          victimKey = "identity:" .. result.name .. "-" .. result.realm
        end
        if not victimKey or classification == "unknown" then
          observation.unknownDeaths = observation.unknownDeaths + 1
          record(
            "unreadable",
            event .. " victimGUID=" .. Log.SavedText(victim) .. " identity_or_side_unresolved " .. queryText
          )
          if not victimKey then
            return
          end
        else
          observation.victims[victimKey] = true
        end
      end
      if event == "PARTY_KILL" then
        local attacker = ...
        -- Inspect GUIDs only inside this protected handler; restricted identity is diagnostic, not a match.
        local sourceOk, source = pcall(attackerKind, attacker)
        local kind = sourceOk and source or "other-or-unreadable"
        local now = ns.Platform.Now()
        local duplicate = lastVictim ~= nil and victimKey == lastVictim and now - lastAt < 3
        lastVictim, lastAt = victimKey, now
        record(
          "party_kill_direct",
          "attacker="
            .. Log.ToText(attacker)
            .. " source="
            .. kind
            .. " victimGUID="
            .. victimText
            .. " duplicate="
            .. tostring(duplicate)
            .. " "
            .. victimInfo(victimKey, victimText, queryText, classification, event, kind)
            .. " "
            .. DescribeInstance()
            .. " "
            .. DescribeMap()
        )
      elseif event == "UNIT_DIED" then
        -- Unlike PARTY_KILL, this event has no attacker or credit information.
        record(
          "unit_died_direct",
          "victimGUID="
            .. victimText
            .. " "
            .. victimInfo(victimKey, victimText, queryText, classification, event)
            .. " "
            .. DescribeInstance()
            .. " "
            .. DescribeMap()
            .. " "
            .. Log.DescribeSnapshot(TakeSnapshot())
        )
      else
        record(event, Log.FormatArgs(...) .. " " .. Log.DescribeSnapshot(TakeSnapshot()))
        local observation = beginWindow()
        if event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
          observation.honor = observation.honor + 1
          local parsed, victim = pcall(ns.Platform.ParseHonorVictim, ...)
          record(
            "chain_parser",
            "id="
              .. observation.id
              .. " victim="
              .. (parsed and Log.ToText(victim) or "unavailable:" .. Log.ToText(victim))
          )
          if parsed and type(victim) == "string" and ns.pvpMissions then
            local class, race = ns.pvpMissions.deps.cache:Lookup(victim)
            record(
              "chain_cache",
              "id="
                .. observation.id
                .. " victim="
                .. victim
                .. " class="
                .. Log.ToText(class)
                .. " race="
                .. Log.ToText(race)
            )
          end
        end
      end
      C_Timer.After(RECHECK_SECONDS, function()
        if killFrame == candidate then
          record("counters_after", "trigger=" .. event .. " " .. Log.DescribeSnapshot(TakeSnapshot()))
        end
      end)
    end, ...)
    if not ok then
      record("unreadable", event .. " " .. Log.ToText(err))
    end
  end)
  killFrame = candidate
  for _, event in ipairs({
    "PARTY_KILL",
    "UNIT_DIED",
    "CHAT_MSG_COMBAT_HONOR_GAIN",
    "PLAYER_PVP_KILLS_CHANGED",
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA",
  }) do
    local ok, reason = pcall(candidate.RegisterEvent, candidate, event)
    record("register", event .. (ok and " registered" or " failed: " .. Log.ToText(reason)))
  end
  if capture then
    local ok, reason = pcall(candidate.RegisterEvent, candidate, "PLAYER_LOGOUT")
    record("register", "PLAYER_LOGOUT " .. (ok and "registered" or "failed: " .. Log.ToText(reason)))
  end
  record("probe", "PARTY_KILL + UNIT_DIED independent probe started. " .. Log.DescribeSnapshot(TakeSnapshot()))
  record("chain_baseline", previousMissions.status)
  if not quiet then
    say("chain_summary follows after 6s: HK, victims, mission events and progress changes; attribution is temporal.")
  end
  killTicker = C_Timer.NewTicker(1, function()
    if killFrame == candidate and ns.active then
      local ok, err = pcall(pollChain)
      if not ok then
        record("chain_unreadable", Log.ToText(err))
      end
    end
  end)
  if capture then
    say("silent capture session=" .. capture.id .. "; use /nrage debug pvp report or stop. Saved across reloads.")
  else
    say("Use /nrage debug pvp killlog to review; /nrage debug pvp stop to stop. Kills are not credited to missions.")
  end
end

local function CaptureSession(id)
  local archive = ns.character and ns.character.pvpProbe
  local sessions = archive and archive.sessions or {}
  for index = #sessions, 1, -1 do
    if not id or sessions[index].id == tonumber(id) then
      return sessions[index]
    end
  end
end

local function PrintSessions()
  local archive = ns.character and ns.character.pvpProbe
  for _, session in ipairs(archive and archive.sessions or {}) do
    say(
      ("session=%d started=%s ended=%s windows=%d droppedWindows=%d droppedRecords=%d"):format(
        session.id,
        session.started,
        session.ended or "running/interrupted",
        #session.windows,
        session.droppedWindows,
        session.droppedRecords
      )
    )
  end
  if not CaptureSession() then
    say("no saved captures.")
  end
end

local function PrintReport(args)
  local filter, pageText, sessionId = args:match("^(%S*)%s*(%S*)%s*(%S*)")
  filter = filter ~= "" and filter or "hk"
  local page = tonumber(pageText) or 1
  if (filter ~= "hk" and filter ~= "ambiguous" and filter ~= "all") or page < 1 or page % 1 ~= 0 then
    say("usage: /nrage debug pvp report [hk|ambiguous|all] [page] [session]")
    return
  end
  local session = CaptureSession(sessionId ~= "" and sessionId or nil)
  if not session then
    say("no saved capture found.")
    return
  end
  local rows, hkWindows, ambiguous = {}, 0, 0
  for _, row in ipairs(session.windows) do
    if row.hk == "increase_observed" then
      hkWindows = hkWindows + 1
    end
    if row.relation == "ambiguous" then
      ambiguous = ambiguous + 1
    end
    if
      filter == "all"
      or (filter == "hk" and row.hk == "increase_observed")
      or (filter == "ambiguous" and row.relation == "ambiguous")
    then
      rows[#rows + 1] = row
    end
  end
  say(
    ("session=%d windows=%d hkWindows=%d ambiguous=%d filter=%s page=%d/%d droppedWindows=%d droppedRecords=%d"):format(
      session.id,
      #session.windows,
      hkWindows,
      ambiguous,
      filter,
      page,
      math.max(1, math.ceil(#rows / 5)),
      session.droppedWindows,
      session.droppedRecords
    )
  )
  say("diagnosticRules=" .. (session.rulesVersion or 1) .. "; older captures retain their original classifications.")
  for index = (page - 1) * 5 + 1, math.min(page * 5, #rows) do
    local row = rows[index]
    say(
      (
        "window=%d %s status=%s hk=%s candidates=%s relation=%s unknownDeaths=%s "
        .. "missionEvents=%s progressChanges=%s delta={%s}"
      ):format(
        row.id,
        row.wall,
        row.status,
        row.hk,
        Log.ToText(row.candidates),
        row.relation or "pending",
        Log.ToText(row.unknownDeaths),
        Log.ToText(row.missionEvents),
        Log.ToText(row.progressChanges),
        row.delta or "pending"
      )
    )
    for victimIndex = 1, math.min(5, #row.victims) do
      local victim = row.victims[victimIndex]
      print(
        "  "
          .. victim.guid
          .. " "
          .. victim.info
          .. " source="
          .. (victim.source or "unknown")
          .. " classification="
          .. (victim.classification or "legacy_unknown")
      )
    end
    if #row.victims > 5 or row.truncatedVictims then
      say("more victims: use detail " .. row.id)
    end
  end
  say("Temporal candidates only. Use detail <window> [page] [session] for raw evidence; sessions lists captures.")
end

local function PrintDetail(args)
  local id, pageText, sessionId = args:match("^(%S*)%s*(%S*)%s*(%S*)")
  local session = CaptureSession(sessionId ~= "" and sessionId or nil)
  local page, found = tonumber(pageText) or 1, nil
  for _, row in ipairs(session and session.windows or {}) do
    if row.id == tonumber(id) then
      found = row
    end
  end
  if not found or page < 1 or page % 1 ~= 0 then
    say("usage: /nrage debug pvp detail <window> [page] [session]; window must exist.")
    return
  end
  say(
    ("session=%d window=%d status=%s hk=%s truncatedVictims=%s"):format(
      session.id,
      found.id,
      found.status,
      found.hk,
      tostring(found.truncatedVictims)
    )
  )
  if page == 1 then
    say(found.context or "context unavailable")
    for _, victim in ipairs(found.victims) do
      print(
        "  "
          .. victim.guid
          .. " "
          .. victim.info
          .. " source="
          .. (victim.source or "unknown")
          .. " classification="
          .. (victim.classification or "legacy_unknown")
      )
    end
  end
  local records = {}
  for _, entry in ipairs(session.records) do
    if not entry.windowId or entry.windowId == found.id then
      records[#records + 1] = entry
    end
  end
  say(
    ("evidence page=%d/%d droppedRecords=%d"):format(
      page,
      math.max(1, math.ceil(#records / 20)),
      session.droppedRecords
    )
  )
  for index = (page - 1) * 20 + 1, math.min(page * 20, #records) do
    local entry = records[index]
    print(("  %s [%.2f %s] %s"):format(entry.wall, entry.t, entry.kind, entry.detail))
  end
end

local function PrintCaptureLog(args)
  local pageText, sessionId = args:match("^(%S*)%s*(%S*)")
  local page = tonumber(pageText) or 1
  local session = CaptureSession(sessionId ~= "" and sessionId or nil)
  if not session or page < 1 or page % 1 ~= 0 then
    say("usage: /nrage debug pvp capturelog [page] [session]; session must exist.")
    return
  end
  say(
    ("session=%d evidence page=%d/%d droppedRecords=%d"):format(
      session.id,
      page,
      math.max(1, math.ceil(#session.records / 20)),
      session.droppedRecords
    )
  )
  for index = (page - 1) * 20 + 1, math.min(page * 20, #session.records) do
    local entry = session.records[index]
    print(
      ("  %s [%.2f %s] window=%s %s"):format(entry.wall, entry.t, entry.kind, Log.ToText(entry.windowId), entry.detail)
    )
  end
end

local ACTIONS = {
  world = function()
    local world = ns.pvpWorldKills
    if not world then
      say("world kill attribution unavailable.")
      return
    end
    say("world kill attribution enabled=" .. tostring(world.enabled))
    for _, decision in ipairs(world.decisions) do
      say(("%.2f reason=%s victim=%s"):format(decision.at, decision.reason, decision.victim or "unknown"))
      if decision.details then
        say(WorldFieldsText(decision.details))
      end
    end
  end,
  kills = function()
    WatchPartyKills(false)
  end,
  quiet = function()
    if killFrame and killQuiet then
      say("silent capture already running.")
      return
    end
    if killFrame or frame or watchTicker then
      Stop()
    end
    WatchPartyKills(true)
  end,
  report = PrintReport,
  detail = PrintDetail,
  sessions = PrintSessions,
  capturelog = PrintCaptureLog,
  killlog = function()
    if not killLog then
      say("no PARTY_KILL probe log yet.")
      return
    end
    for _, entry in ipairs(killLog:GetLog()) do
      print(("  %s [%.2f %s] %s"):format(entry.wall, entry.t, entry.kind, entry.detail))
    end
  end,
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
  cache = PrintMissionCache,
  clear = function()
    if log then
      log:Clear()
    end
    say("log cleared.")
  end,
  status = function()
    say("PARTY_KILL probe running=" .. tostring(killFrame ~= nil))
    say("silent capture=" .. tostring(killFrame ~= nil and killQuiet))
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

function PvPProbe.Handle(action, args)
  -- Release builds ship this file but never run it (ns.IsDevBuild).
  if not ns.IsDevBuild() then
    say("the pvp probe is only available in a development build.")
    return
  end
  local run = ACTIONS[action or ""]
  if run then
    run(args or "")
  else
    say("usage: /nrage debug pvp quiet | report | detail | sessions | kills | killlog | start | stop | status")
  end
end

ns.PvPProbe = PvPProbe

function PvPProbe.RecordWorldDecision(decision)
  if worldDecisionRecord then
    local fields =
      { reason = decision.reason, victim = decision.victim or "unknown", guid = decision.guid or "unknown" }
    for key, value in pairs(decision.details or {}) do
      fields[key] = value
    end
    worldDecisionRecord("world_kill_decision", WorldFieldsText(fields), fields)
  end
end

function PvPProbe.RecordWorldTrace(kind, fields)
  if worldDecisionRecord then
    worldDecisionRecord(kind, WorldFieldsText(fields), fields)
  end
end
