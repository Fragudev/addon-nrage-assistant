local _, ns = ...

-- The detection side of the PvP missions (docs/PVP_MISSIONS_PLAN.md, sections 2 and 10): the kill log of this
-- character, the battleground wins, the progress of each mission and the claims. Nothing here touches the client: the
-- readers, the clock, the timers and the season service are injected, so the rules are tested with fakes.
--
--   * An honour kill of the feed (and a battleground win) is logged in `char.pvpMissions.kills` while a season is
--     active and the kill is inside its dates. The class and race of the victim come from the unit cache when it has
--     seen the victim, otherwise they stay unknown. The log belongs to one season: another season starts a new one.
--   * Progress is the pure PvPMissionTracker over that log.
--   * A claim is built from the progress (summary and evidence), submitted with PvPSeasonService:SubmitClaim and
--     kept in `char.pvpMissions.claims` as `{ claim, state }`. Its state follows the ledger (approved, rejected) and is
--     "pending" until then. Pending claims are announced again a while after login and then every
--     PVP_CLAIM_REANNOUNCE_SECONDS while any is pending, so an approver who logs in later still gets them.
--
-- deps = { season = PvPSeasonService, log = function() -> char.pvpMissions, cache = PvPUnitCache,
--          now = function() -> server time, platform = { GetPlayerMapId, GetEnemyPlayerInfo, GetBattlegroundWinner,
--          GetPlayerFaction, IsInBattleground, HasBattlegroundWinner }, killsAvailable = function() -> boolean,
--          schedule = function(delay, fn), random = function(min, max), isActive = function() -> boolean,
--          onChange = function() (optional), isGuildKos = function(name) -> boolean (optional: is the victim on the
--          guild Kill On Sight list right now) }
-- The wiring sets `unitSource` and `winSource` to true when the events behind them could be registered.
local PvPMissionService = {}
PvPMissionService.__index = PvPMissionService

function PvPMissionService.New(deps)
  return setmetatable(
    { deps = deps, unitSource = false, winSource = false, looping = false, winLogged = false, refused = {} },
    PvPMissionService
  )
end

function PvPMissionService:Changed()
  if self.deps.onChange then
    self.deps.onChange()
  end
end

-- The season missions are counted for: the active one while the clock is inside its dates, or nil.
function PvPMissionService:Season()
  local season = self.deps.season:ActiveSeason()
  if season and season.state == "active" and ns.PvPSeasonModel.Contains(season, self.deps.now()) then
    return season
  end
  return nil
end

-- The log of this character for `season`, to read: empty when the saved one belongs to another season.
function PvPMissionService:ReadLog(season)
  local log = self.deps.log()
  if type(log) ~= "table" or log.seasonId ~= season.id then
    return { kills = {}, claims = {} }
  end
  return { kills = log.kills or {}, claims = log.claims or {} }
end

-- The log of this character for `season`, to write: a log of another season is dropped first (a season that closed
-- cleans its own through ClearMissionLog; this covers the one a client never saw close).
function PvPMissionService:WriteLog(season)
  local log = self.deps.log()
  if type(log) ~= "table" then
    return nil
  end
  if log.seasonId ~= season.id then
    log.seasonId = season.id
    log.kills = {}
    log.claims = {}
    log.bgWinLogged = nil
  end
  log.kills = log.kills or {}
  log.claims = log.claims or {}
  return log
end

local function append(log, row)
  local kills = log.kills
  kills[#kills + 1] = row
  while #kills > ns.Constants.PVP_MISSION_KILLS_MAX do
    table.remove(kills, 1)
  end
end

-- An own honour kill, as the feed entry (`victim`, `where`, `time`). Returns true when it was logged.
function PvPMissionService:OnHonorKill(entry)
  local season = self:Season()
  if not (season and entry and entry.victim and entry.time) or not ns.PvPSeasonModel.Contains(season, entry.time) then
    return false
  end
  local log = self:WriteLog(season)
  if not log then
    return false
  end
  local class, race = self.deps.cache:Lookup(entry.victim)
  -- A bounty counts a kill by what the guild KOS said at this moment: the flag is saved with the kill and later list
  -- changes do not touch it.
  local isKos = self.deps.isGuildKos
  append(log, {
    kos = isKos and isKos(entry.victim) == true or nil,
    at = entry.time,
    victim = entry.victim,
    mapId = self.deps.platform.GetPlayerMapId(),
    place = entry.where,
    class = class,
    race = race,
  })
  self:Changed()
  return true
end

-- A unit the player can see ("target", "mouseover", "nameplate4"): an enemy player is remembered with its class and
-- race. Only while a season runs, so nothing is read for nothing.
function PvPMissionService:OnUnit(unit)
  if not self:Season() then
    return false
  end
  local info = self.deps.platform.GetEnemyPlayerInfo(unit)
  return info ~= nil and self.deps.cache:Remember(info.name, info.class, info.race)
end

-- The battleground status changed: when the player's side won, a win is logged, once per battleground instance.
-- Returns true when a win was logged.
function PvPMissionService:OnBattlegroundStatus()
  local season = self:Season()
  local platform = self.deps.platform
  if not season or self:WinLogged() or platform.IsInBattleground() ~= true then
    return false
  end
  local winner = platform.GetBattlegroundWinner()
  if not winner or winner ~= platform.GetPlayerFaction() then
    return false
  end
  local now = self.deps.now()
  local log = self:WriteLog(season)
  if not log then
    return false
  end
  -- The marker is saved with the log, so a reload inside the same battleground does not log the win again. A real
  -- world entry clears it (OnWorldEntered).
  log.bgWinLogged = true
  self.winLogged = true
  append(log, { at = now, bgWin = true, mapId = platform.GetPlayerMapId() })
  self:Changed()
  return true
end

-- Has the win of the battleground the player is in been logged already? The saved marker survives a /reload.
function PvPMissionService:WinLogged()
  local log = self.deps.log()
  if type(log) == "table" then
    return log.bgWinLogged == true
  end
  return self.winLogged
end

-- PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi). A loading screen into another world makes the next
-- battleground win a new one. A /reload or a login keeps the marker: the player may still be in the same battleground
-- (a login into another place is cleared by the next loading screen). Without arguments it counts as a new world.
function PvPMissionService:OnWorldEntered(isInitialLogin, isReloadingUi)
  if isInitialLogin or isReloadingUi then
    return
  end
  self.winLogged = false
  local log = self.deps.log()
  if type(log) == "table" then
    log.bgWinLogged = nil
  end
end

-- Which sources of data this client has: kills (the feed has a victim name), zones (the map id is readable), class
-- and race (the unit events could be registered), battleground wins (the winner can be read and the event could be
-- registered). A mission whose source is missing shows "Not available on this client".
function PvPMissionService:Availability()
  local kills = self.deps.killsAvailable() == true
  return {
    kills = kills,
    zones = kills and self.deps.platform.GetPlayerMapId() ~= nil,
    classRace = self.unitSource == true,
    bgWins = self.winSource == true and self.deps.platform.HasBattlegroundWinner() == true,
  }
end

-- The mission and the active season it belongs to, or nil plus the reason.
function PvPMissionService:Resolve(missionId)
  local mission = self.deps.season:Mission(missionId)
  if not mission then
    return nil, nil, "unknown_mission"
  end
  local season = self.deps.season:ActiveSeason()
  if not season or season.state ~= "active" or mission.seasonId ~= season.id then
    return nil, nil, "no_season"
  end
  return mission, season
end

-- { bars = { { label, done, total } }, unknown, complete, claimable, periodKey, evidence, couldComplete, nextN } for
-- the current period of the mission, or nil when the mission is unknown or its season is not the active one.
function PvPMissionService:Progress(missionId)
  local mission, season = self:Resolve(missionId)
  if not mission then
    return nil
  end
  local log = self:ReadLog(season)
  return ns.PvPMissionTracker.Progress(mission, log.kills, self.deps.now(), log.claims, season)
end

local BEST = { approved = 3, pending = 2, rejected = 1 }

-- The state of a local claim: the ledger knows an approval and a rejection; until then it is pending.
function PvPMissionService:EntryState(entry)
  local known = self.deps.season:ClaimState(entry.claim.id)
  if known == "approved" or known == "rejected" then
    entry.state = known
  end
  return entry.state or "pending"
end

-- "none" | "pending" | "approved" | "rejected" for the claims of the current period of the mission.
function PvPMissionService:ClaimState(missionId)
  local mission, season = self:Resolve(missionId)
  if not mission then
    return "none"
  end
  local periodKey = ns.PvPSeasonModel.PeriodKey(mission.repeatKind, self.deps.now())
  local best = "none"
  for _, entry in pairs(self:ReadLog(season).claims) do
    local claim = entry.claim
    if claim and claim.missionId == missionId and claim.periodKey == periodKey then
      local state = self:EntryState(entry)
      if (BEST[state] or 0) > (BEST[best] or 0) then
        best = state
      end
    end
  end
  return best
end

-- The numbers an approver reads next to the evidence.
local function summaryOf(result)
  local summary = { unknown = result.unknown }
  for _, bar in ipairs(result.bars) do
    if bar.label == "Classes" then
      summary.classes, summary.classesTotal = bar.done, bar.total
    elseif bar.label == "Races" then
      summary.races, summary.racesTotal = bar.done, bar.total
    else
      summary.done, summary.total = bar.done, bar.total
    end
  end
  return summary
end

-- Claims the current period of `missionId`. Returns the claim and whether it went out (false: saved here, not sent
-- yet), or nil plus the reason: "unknown_mission", "no_season", "inactive", "limit", "not_complete", or one of
-- PvPSeasonService:SubmitClaim (for example "invalid:note" for a manual mission without a note).
function PvPMissionService:Claim(missionId, note)
  local mission, season, reason = self:Resolve(missionId)
  if not mission then
    return nil, reason
  end
  if not mission.active then
    return nil, "inactive"
  end
  local result = self:Progress(missionId)
  if result.nextN > (mission.perPlayer or 1) then
    return nil, "limit"
  end
  if not result.claimable then
    return nil, "not_complete"
  end
  local claim, queued = self.deps.season:SubmitClaim({
    missionId = missionId,
    at = self.deps.now(),
    n = result.nextN,
    summary = summaryOf(result),
    evidence = result.evidence,
    note = note ~= "" and note or nil,
  })
  if not claim then
    return nil, queued
  end
  local log = self:WriteLog(season)
  if log then
    log.claims[claim.id] = { claim = claim, state = "pending" }
  end
  self:KeepAnnouncing()
  self:Changed()
  return claim, queued
end

-- Are there local claims of the active season still waiting for a decision (and still worth announcing)?
function PvPMissionService:HasPending()
  local season = self.deps.season:ActiveSeason()
  if not season then
    return false
  end
  for id, entry in pairs(self:ReadLog(season).claims) do
    if self:EntryState(entry) == "pending" and not self.refused[id] then
      return true
    end
  end
  return false
end

-- Reasons SubmitClaim gives that no retry will change: the mission was paused, the season is over or the limit of the
-- mission is reached. A claim refused like that stops being announced.
local PERMANENT_REFUSAL = {
  inactive = true,
  out_of_season = true,
  no_season = true,
  unknown_mission = true,
  limit = true,
}

-- Sends the pending claims again (the same claim is the same id, so a receiver that has it ignores the repeat).
-- Returns how many went out and how many were refused for good (those are not announced again this session).
function PvPMissionService:Reannounce()
  local season = self.deps.season:ActiveSeason()
  if not season then
    return 0, 0
  end
  local claims = self:ReadLog(season).claims
  local ids = {}
  for id in pairs(claims) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local sent, dead = 0, 0
  for _, id in ipairs(ids) do
    local entry = claims[id]
    local claim = entry.claim
    local parts = ns.PvPSeasonModel.ParseClaimId(id)
    if
      claim
      and parts
      and not self.refused[id]
      and self:EntryState(entry) == "pending"
      and claim.seasonId == season.id
    then
      local again, why = self.deps.season:SubmitClaim({
        missionId = claim.missionId,
        at = claim.at,
        n = parts.n,
        summary = claim.summary,
        evidence = claim.evidence,
        note = claim.note,
      })
      if again then
        sent = sent + 1
      elseif PERMANENT_REFUSAL[why] then
        dead = dead + 1
        self.refused[id] = true
      end
    end
  end
  return sent, dead
end

function PvPMissionService:Tick()
  if not self.deps.isActive() then
    self.looping = false
    return
  end
  self:Reannounce()
  if self:HasPending() then
    self.deps.schedule(ns.Constants.PVP_CLAIM_REANNOUNCE_SECONDS, function()
      self:Tick()
    end)
  else
    self.looping = false
  end
end

-- Announces the pending claims again after the login send delay, and then every PVP_CLAIM_REANNOUNCE_SECONDS while
-- any is pending.
function PvPMissionService:StartAnnouncing()
  if self.looping then
    return
  end
  self.looping = true
  local constants = ns.Constants
  self.deps.schedule(
    self.deps.random(constants.PVP_LOGIN_SEND_DELAY_MIN, constants.PVP_LOGIN_SEND_DELAY_MAX),
    function()
      self:Tick()
    end
  )
end

-- A claim was just made: the repetition starts if it is not running (the claim itself has just been sent).
function PvPMissionService:KeepAnnouncing()
  if self.looping then
    return
  end
  self.looping = true
  self.deps.schedule(ns.Constants.PVP_CLAIM_REANNOUNCE_SECONDS, function()
    self:Tick()
  end)
end

ns.PvPMissionService = PvPMissionService
