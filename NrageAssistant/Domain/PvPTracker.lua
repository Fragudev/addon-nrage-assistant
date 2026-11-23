local _, ns = ...

-- Counts PvP kills as they happen. The client facts come from the injected platform, so it is tested with a
-- fake; the event wiring (Core/Init.lua) only forwards events to it.
--
--   * Honourable kills: the change of the session counter (GetPVPSessionStats) since the last reading, so the
--     addon cannot inflate it and group credit counts as the game gives it. The reading at Start() is the
--     baseline, which keeps a /reload from counting the session's kills twice.
--   * Killing blows: a PARTY_KILL combat log event with the player as source and a player as victim. Only
--     counted when the wiring managed to register the combat log (`blowsAvailable`).
--
-- Nothing here raises: every client read is guarded, and a value that cannot be compared (a secret value)
-- simply counts nothing. Victim names are not read or stored here (the kill feed reads them).
local PvPTracker = {}
PvPTracker.__index = PvPTracker

local function safe(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

-- deps = { platform, stats (the saved table), schedule = C_Timer.After, onChange = function(),
--          seasonId = function() -> id of the active PvP season or nil (default: ns.pvpSeason) }
function PvPTracker.New(deps)
  local tracker = setmetatable({}, PvPTracker)
  tracker.platform = deps.platform
  tracker.stats = ns.PvPService.Ensure(deps.stats)
  tracker.schedule = deps.schedule
  tracker.onChange = deps.onChange
  tracker.seasonIdOf = deps.seasonId
  tracker.baseline = nil
  -- Both are decided at start-up: honour by whether the session counter can be read, blows by the wiring.
  tracker.honorAvailable = false
  tracker.blowsAvailable = false
  return tracker
end

function PvPTracker:Day()
  local timestamp = safe(self.platform.ServerTime)
  return safe(self.platform.ServerDay, timestamp)
end

-- "bg" inside a battleground; "world" anywhere else and when the client does not say.
function PvPTracker:Where()
  return safe(self.platform.IsInBattleground) == true and "bg" or "world"
end

-- The id of the season the kills count for now: the active season while its dates hold, nil otherwise. The season
-- service is looked up when it is needed (it starts after the tracker).
function PvPTracker:SeasonId()
  if self.seasonIdOf then
    return safe(self.seasonIdOf)
  end
  local service = ns.pvpSeason
  local season = service and safe(service.ActiveSeason, service)
  if type(season) ~= "table" or season.state ~= "active" then
    return nil
  end
  local now = safe(self.platform.ServerTime)
  if type(now) == "number" and type(season.endsAt) == "number" and type(season.startsAt) == "number" then
    if now < season.startsAt or now > season.endsAt then
      return nil
    end
  end
  return season.id
end

function PvPTracker:Changed()
  if self.onChange then
    safe(self.onChange)
  end
end

function PvPTracker:Start()
  self.baseline = safe(self.platform.GetPvPSessionKills)
  self.honorAvailable = self.baseline ~= nil
end

-- Reads the session counter and counts what it gained since the last reading. A lower value (the counter was
-- reset) only moves the baseline.
function PvPTracker:CheckHonor()
  local current = safe(self.platform.GetPvPSessionKills)
  if type(current) ~= "number" then
    return
  end
  local baseline = self.baseline
  self.baseline = current
  self.honorAvailable = true
  if baseline and current > baseline then
    if ns.PvPService.RecordHonorKills(self.stats, current - baseline, self:Where(), self:Day(), self:SeasonId()) then
      self:Changed()
    end
  end
end

-- An honour event: read now and once more shortly after, because the counter may update after the event.
-- Reading twice cannot count twice, as the baseline moves with each reading.
function PvPTracker:OnHonorEvent()
  self:CheckHonor()
  if self.schedule then
    self.schedule(ns.Constants.PVP_RECHECK_SECONDS, function()
      self:CheckHonor()
    end)
  end
end

-- `info` = { subevent, sourceGUID, destGUID } of a combat log event. Every comparison is guarded because any
-- of the values may be secret. Returns true when it was a killing blow of the player on a player (counted), so
-- the caller can pass the event on, for example to the kill feed.
function PvPTracker:OnCombatLog(info)
  if not self.blowsAvailable then
    return false
  end
  local ok, counted = pcall(function()
    if info.subevent ~= "PARTY_KILL" then
      return false
    end
    local own = self.platform.GetGUID()
    local victim = info.destGUID
    return type(own) == "string"
      and info.sourceGUID == own
      and type(victim) == "string"
      and victim:sub(1, 7) == "Player-"
  end)
  if not (ok and counted) then
    return false
  end
  if ns.PvPService.RecordKillingBlow(self.stats, self:Where(), self:Day()) then
    self:Changed()
  end
  return true
end

ns.PvPTracker = PvPTracker
