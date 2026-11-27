local _, ns = ...

-- The detection side of the PvP missions (docs/PVP_MISSIONS_PLAN.md, sections 2 and 10): the PvP log of this
-- character, the battleground results, the progress of each mission and the claims. Nothing here touches the client:
-- the readers, the clock, the timers and the season service are injected, so the rules are tested with fakes.
--
--   * An honour kill of the feed (and a battleground result) is logged in `char.pvpLog.events` whatever the season: a
--     client that has not received the season yet, or whose season just changed, loses nothing, and the progress of a
--     mission is computed from the same log when the season is known. The class and race of the victim come from the
--     unit cache when it has seen the victim, otherwise they stay unknown. Rows older than PVP_LOG_RETENTION_DAYS
--     days, and the oldest ones beyond PVP_LOG_EVENTS_MAX, are dropped.
--   * Progress is the pure PvPMissionTracker over that log.
--   * A claim is built from the progress (summary and evidence), submitted with PvPSeasonService:SubmitClaim and
--     kept in `char.pvpClaims[seasonId]` as `{ claim, state }`. Its state follows the ledger (approved, rejected) and
--     is "pending" until then. Pending claims are announced again a while after login and then every
--     PVP_CLAIM_REANNOUNCE_SECONDS while any is pending, so an approver who logs in later still gets them.
--
-- deps = { season = PvPSeasonService, log = function() -> char.pvpLog, claims = function() -> char.pvpClaims,
--          cache = PvPUnitCache, now = function() -> server time, platform = { GetPlayerMapId, GetEnemyPlayerInfo,
--          GetBattlegroundWinner, GetPlayerFaction, IsInBattleground, HasBattlegroundWinner },
--          killsAvailable = function() -> boolean, schedule = function(delay, fn), random = function(min, max),
--          isActive = function() -> boolean, onChange = function() (optional), isGuildKos = function(name) -> boolean
--          (optional: is the victim on the guild Kill On Sight list right now), guildInGroup = function() -> number
--          (optional: the guild members in the group of the player now, the player excluded), onAutoClaim =
--          function(mission, claim) (optional: a mission with `autoClaim` was claimed) }
-- The wiring sets `unitSource`, `winSource` and `duelSource` to true when the events behind them could be registered.
-- (`platform` also gives ParseDuelResult, GetPlayerName and HasDuelResult for the duel wins.)
local PvPMissionService = {}
PvPMissionService.__index = PvPMissionService

function PvPMissionService.New(deps)
  return setmetatable({
    deps = deps,
    units = ns.EnemyPlayerUnits(),
    unitSource = false,
    winSource = false,
    duelSource = false,
    looping = false,
    scoring = false,
    refused = {},
  }, PvPMissionService)
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

-- The rows of the PvP log of this character (empty when it has none saved).
function PvPMissionService:Events()
  local log = self.deps.log()
  if type(log) == "table" and type(log.events) == "table" then
    return log.events
  end
  return {}
end

-- The saved log, to write: nil when the character has none.
function PvPMissionService:WriteLog()
  local log = self.deps.log()
  if type(log) ~= "table" then
    return nil
  end
  log.events = log.events or {}
  return log
end

-- The claims of this character for `season`, to read.
function PvPMissionService:ReadClaims(season)
  local claims = self.deps.claims()
  if type(claims) == "table" and type(claims[season.id]) == "table" then
    return claims[season.id]
  end
  return {}
end

-- The claims of this character for `season`, to write: nil when the character has no claims table.
function PvPMissionService:WriteClaims(season)
  local claims = self.deps.claims()
  if type(claims) ~= "table" then
    return nil
  end
  claims[season.id] = claims[season.id] or {}
  return claims[season.id]
end

-- Adds `row` to the log, dropping the rows past the retention.
function PvPMissionService:Append(log, row)
  local events = log.events
  events[#events + 1] = row
  local cutoff = self.deps.now() - ns.Constants.PVP_LOG_RETENTION_DAYS * 86400
  local kept = {}
  for _, event in ipairs(events) do
    if type(event.at) == "number" and event.at >= cutoff then
      kept[#kept + 1] = event
    end
  end
  if #kept ~= #events then
    for index = #events, 1, -1 do
      events[index] = kept[index]
    end
  end
  while #events > ns.Constants.PVP_LOG_EVENTS_MAX do
    table.remove(events, 1)
  end
end

-- Capture filters at observation time: a delayed attribution must not inherit a later map, group or KOS change.
function PvPMissionService:KillContext(victim)
  -- A bounty counts a kill by what the guild KOS said at this moment: the flag is saved with the kill and later list
  -- changes do not touch it.
  local isKos = self.deps.isGuildKos
  -- The guild members in the group at this moment, for the missions that ask for a group (saved only when there are
  -- some, a row without it counts as none).
  local inGroup
  if self.deps.guildInGroup then
    local readable, count = pcall(self.deps.guildInGroup)
    if readable and type(count) == "number" and count > 0 then
      inGroup = math.floor(count)
    end
  end
  return {
    mapId = self.deps.platform.GetPlayerMapId(),
    kos = isKos and isKos(victim) == true or nil,
    guildInGroup = inGroup,
  }
end

-- An own honour kill. A world lifetime-HK credit ID is stable across duplicate events and reloads.
function PvPMissionService:OnHonorKill(entry)
  if not (entry and entry.victim and entry.time) then
    return false
  end
  local log = self:WriteLog()
  if not log then
    return false
  end
  if entry.creditId then
    for _, row in ipairs(log.events) do
      if row.creditId == entry.creditId then
        return false
      end
    end
  end
  local class, race = self.deps.cache:Lookup(entry.victim)
  local context = entry.context or self:KillContext(entry.victim)
  self:Append(log, {
    kind = "kill",
    honor = true,
    kos = context.kos,
    at = entry.time,
    victim = entry.victim,
    mapId = context.mapId,
    place = entry.where,
    class = entry.class or class,
    race = entry.race or race,
    guildInGroup = context.guildInGroup,
    guid = entry.guid,
    creditId = entry.creditId,
  })
  self:Changed()
  self:AutoClaim()
  return true
end

-- Is `name` this character? On Forever a name can have several words and UnitName gives only the first one, so the
-- full roster name (the identity key without the own realm) is tried first, then the UnitName one. Case-insensitive.
function PvPMissionService:IsOwnName(name)
  local platform = self.deps.platform
  local wanted = name:lower()
  if platform.GetIdentityKey and platform.NormalizeName then
    local ok, key = pcall(platform.GetIdentityKey)
    if ok and type(key) == "string" then
      local normalized, full = pcall(platform.NormalizeName, key)
      if normalized and type(full) == "string" and full ~= "" and full:lower() == wanted then
        return true
      end
    end
  end
  local read, own = pcall(platform.GetPlayerName)
  return read and type(own) == "string" and own ~= "" and own:lower() == wanted
end

-- A system message (CHAT_MSG_SYSTEM). The client prints the result of every duel nearby, so only the own win is
-- logged, as `{ kind = "duel", at, victim, mapId }` (a loss, another player's duel and any other text log nothing). The
-- winner is compared with the name the client gives for the player; a name that cannot be read logs nothing. Returns
-- true when a row was logged.
function PvPMissionService:OnSystemMessage(message)
  local platform = self.deps.platform
  if not (platform.ParseDuelResult and platform.GetPlayerName) then
    return false
  end
  local parsed, winner, loser = pcall(platform.ParseDuelResult, message)
  if not (parsed and type(winner) == "string" and type(loser) == "string") then
    return false
  end
  if not self:IsOwnName(winner) then
    return false
  end
  local log = self:WriteLog()
  if not log then
    return false
  end
  self:Append(log, {
    kind = "duel",
    at = self.deps.now(),
    victim = loser,
    mapId = platform.GetPlayerMapId(),
  })
  self:Changed()
  self:AutoClaim()
  return true
end

-- A unit the player can see ("target", "mouseover", "nameplate4"): an enemy player is remembered with its class and
-- race, so a kill logged later (also one logged before the season is known) carries them.
function PvPMissionService:OnUnit(unit)
  local info = self.deps.platform.GetEnemyPlayerInfo(unit)
  if info and self.deps.onEnemy then
    self.deps.onEnemy(info, unit)
  end
  return info ~= nil and self.deps.cache:Remember(info.name, info.class, info.race)
end

-- Retry visible units whose data was not ready at NAME_PLATE_UNIT_ADDED. Independent of the Intel module.
function PvPMissionService:RescanUnits()
  local count = 0
  for _, unit in ipairs(self.units) do
    local ok, remembered = pcall(self.OnUnit, self, unit)
    if ok and remembered then
      count = count + 1
    end
  end
  return count
end

-- The battleground result (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, C.4). Three sources, the first that gives a winner
-- wins and the result is logged once per battleground instance: UPDATE_BATTLEFIELD_STATUS, UPDATE_BATTLEFIELD_SCORE
-- (asked for with RequestBattlefieldScoreData when combat ends and every PVP_BG_SCORE_POLL_SECONDS inside the
-- battleground) and, if a winner was seen but never logged, the moment the player leaves the instance. An instance is
-- the battleground map id plus the time the player entered it, kept in `char.pvpLog.bg` so a reload does not log the
-- result again:
--   log.bg = { id = map id, bg = "wsg" | "ab" | "av" | nil, startedAt, winner = "Alliance" | "Horde" | nil, logged }
function PvPMissionService:BgInstance()
  local read = self.deps.platform.GetBattlegroundInstance
  return read and read() or nil
end

-- The record of the battleground the player is in now: the saved one when it is the same instance, otherwise a new one
-- (the one saved is settled first). Nil when the character has no saved log.
function PvPMissionService:BgRecord()
  local log = self:WriteLog()
  if not log then
    return nil
  end
  local id = self:BgInstance()
  if type(log.bg) == "table" and log.bg.id == id then
    return log.bg
  end
  self:SettleBg()
  log.bg = { id = id, bg = id and ns.Constants.PVP_BG_BY_MAP[id] or nil, startedAt = self.deps.now() }
  return log.bg
end

-- Logs the result of `record` (win or loss of the player's side) once. Returns true when a row was logged.
function PvPMissionService:LogBgResult(record, winner)
  local faction = self.deps.platform.GetPlayerFaction()
  if record.logged or not winner or not faction then
    return false
  end
  local log = self:WriteLog()
  if not log then
    return false
  end
  record.logged = true
  self:Append(log, {
    kind = "bg",
    result = winner == faction and "win" or "loss",
    bg = record.bg,
    at = self.deps.now(),
    mapId = self.deps.platform.GetPlayerMapId(),
  })
  self:Changed()
  self:AutoClaim()
  return true
end

-- The player left the battleground: a winner that was seen but never logged is logged now, and the record goes.
function PvPMissionService:SettleBg()
  local log = self:WriteLog()
  if not log or type(log.bg) ~= "table" then
    return false
  end
  local record = log.bg
  log.bg = nil
  return self:LogBgResult(record, record.winner)
end

-- A battleground status or score update arrived: when the battleground has a winner it is remembered, and logged if no
-- earlier source did. Returns true when a result was logged.
function PvPMissionService:OnBattlegroundStatus()
  local platform = self.deps.platform
  if platform.IsInBattleground() ~= true then
    return false
  end
  local winner = platform.GetBattlegroundWinner()
  if not winner then
    return false
  end
  local record = self:BgRecord()
  if not record then
    return false
  end
  record.winner = winner
  return self:LogBgResult(record, winner)
end

-- UPDATE_BATTLEFIELD_SCORE carries the same information as the status.
PvPMissionService.OnBattlegroundScore = PvPMissionService.OnBattlegroundStatus

-- Asks the client for the score data (so the winner arrives) while the player is in a battleground whose result is not
-- logged yet. Returns true when the request was made.
function PvPMissionService:RequestScore()
  local platform = self.deps.platform
  if not platform.RequestBattlegroundScore or platform.IsInBattleground() ~= true then
    return false
  end
  local log = self.deps.log()
  if type(log) == "table" and type(log.bg) == "table" and log.bg.logged and log.bg.id == self:BgInstance() then
    return false
  end
  return platform.RequestBattlegroundScore() == true
end

-- PLAYER_REGEN_ENABLED: the fight is over, a good moment to ask for the score.
function PvPMissionService:OnCombatEnded()
  return self:RequestScore()
end

-- Requests the score every PVP_BG_SCORE_POLL_SECONDS while the player is in a battleground (and the addon is active).
function PvPMissionService:ScoreTick()
  if not self.deps.isActive() or self.deps.platform.IsInBattleground() ~= true then
    self.scoring = false
    return
  end
  self:RequestScore()
  self.deps.schedule(ns.Constants.PVP_BG_SCORE_POLL_SECONDS, function()
    self:ScoreTick()
  end)
end

function PvPMissionService:StartScoring()
  if self.scoring then
    return
  end
  self.scoring = true
  self:ScoreTick()
end

-- PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi). A loading screen into another world settles the battleground
-- the player left (a result seen but not logged is logged now) and starts the record of the one they entered. A
-- /reload or a login keeps the saved record while the player is still in the same battleground (a login into another
-- place settles it). Without arguments it counts as a new world.
function PvPMissionService:OnWorldEntered(isInitialLogin, isReloadingUi)
  local inBg = self.deps.platform.IsInBattleground() == true
  local log = self:WriteLog()
  if log then
    local record = type(log.bg) == "table" and log.bg or nil
    local sameInstance = inBg and record ~= nil and record.id == self:BgInstance()
    if not ((isInitialLogin or isReloadingUi) and sameInstance) then
      self:SettleBg()
    end
    if inBg then
      self:BgRecord()
    end
  end
  if inBg then
    self:StartScoring()
  end
end

-- Which sources of data this client has: kills (the feed has a victim name), zones (the map id is readable), class
-- and race (the unit events could be registered), battleground wins (the winner can be read and the event could be
-- registered) and duels (the system message could be registered and the client defines both duel texts). A mission
-- whose source is missing shows "Not available on this client".
function PvPMissionService:Availability()
  local kills = self.deps.killsAvailable() == true
  return {
    kills = kills,
    zones = kills and self.deps.platform.GetPlayerMapId() ~= nil,
    classRace = self.unitSource == true,
    bgWins = self.winSource == true and self.deps.platform.HasBattlegroundWinner() == true,
    duels = self.duelSource == true
      and self.deps.platform.HasDuelResult ~= nil
      and self.deps.platform.HasDuelResult() == true,
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
  return ns.PvPMissionTracker.Progress(
    mission,
    self:Events(),
    self.deps.now(),
    self:ReadClaims(season),
    season,
    self.deps.platform.GetPlayerFaction()
  )
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
  for _, entry in pairs(self:ReadClaims(season)) do
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
  if result.nextN > (mission.perPlayer or 1) or result.maxedOut then
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
  local claims = self:WriteClaims(season)
  if claims then
    claims[claim.id] = { claim = claim, state = "pending" }
  end
  self:KeepAnnouncing()
  self:Changed()
  return claim, queued
end

-- The missions of the active season whose goal asks for an automatic claim are claimed as soon as the log completes
-- them (and only the first claim of a period: later ones are the member's choice). A manual mission never is (it needs
-- a note). Returns how many claims went out.
function PvPMissionService:AutoClaim()
  local season = self.deps.season:ActiveSeason()
  if not (season and season.state == "active") then
    return 0
  end
  local sent = 0
  for _, mission in ipairs(self.deps.season:Missions(season.id)) do
    local goal = mission.goal
    if goal.autoClaim == true and goal.kind ~= "manual" then
      local result = self:Progress(mission.id)
      if result and result.complete and result.claimable and result.nextN == 1 then
        local claim = self:Claim(mission.id)
        if claim then
          sent = sent + 1
          if self.deps.onAutoClaim then
            pcall(self.deps.onAutoClaim, mission, claim)
          end
        end
      end
    end
  end
  return sent
end

-- Are there local claims of the active season still waiting for a decision (and still worth announcing)?
function PvPMissionService:HasPending()
  local season = self.deps.season:ActiveSeason()
  if not season then
    return false
  end
  for id, entry in pairs(self:ReadClaims(season)) do
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
  local claims = self:ReadClaims(season)
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

-- A gm or cogm is online (their HELLO arrived): the pending claims go out again, after the delay a login uses so the
-- approver has time to load, and at most once per PVP_CLAIM_HELLO_COOLDOWN_SECONDS. Returns true when it was planned.
function PvPMissionService:OnApproverSeen()
  if not self.deps.isActive() or not self:HasPending() then
    return false
  end
  local now = self.deps.now()
  if self.lastResendAt and now - self.lastResendAt < ns.Constants.PVP_CLAIM_HELLO_COOLDOWN_SECONDS then
    return false
  end
  self.lastResendAt = now
  local constants = ns.Constants
  self.deps.schedule(
    self.deps.random(constants.PVP_LOGIN_SEND_DELAY_MIN, constants.PVP_LOGIN_SEND_DELAY_MAX),
    function()
      if self.deps.isActive() then
        self:Reannounce()
      end
    end
  )
  return true
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
