local _, ns = ...

-- The local side of the PvP seasons (docs/PVP_MISSIONS_PLAN.md): what this client does, with the permission check the
-- receivers will repeat, and what the interface reads. Every change is validated, applied to the own ledger through
-- the same rules a received message goes through (own messages are never received), and then sent to the guild.
-- Nothing here touches the client API: it is all injected, so it is tested without one.
--
--   PvPSeasonService.New(deps) -> service
--   deps = {
--     ledger = db.global.pvpSeason,
--     now = function() -> server time,         newId = function() -> unique id,
--     ownName = function() -> own character name,   ownRole = function() -> role or nil,
--     roleOf = function(name) -> role or nil (the guild roster),
--     send = function(messageType, payload, key) -> queued (true), or false plus a reason,
--     onChange = function(messageType) (optional: the interface redraws),
--     onSeasonClosed = function(seasonId) (optional: the per-character mission log of that season is dropped),
--     fits = function(messageType, payload) -> boolean (optional: does it encode under the guild message limit?),
--   }
--
-- Every action returns the record it made and whether it was queued for the guild (`false` means it was saved here
-- but not sent: the lockdown, or a full queue); or nil plus the reason. Reasons: "forbidden", "invalid:<field>",
-- "no_season", "closed", "not_found", "decided", "unknown_mission", "unknown_player" and
-- the ones of PvPSeasonSync.Apply ("limit", "active_exists", "stale", ...).
local PvPSeasonService = {}
PvPSeasonService.__index = PvPSeasonService

local Model = ns.PvPSeasonModel

-- Loaded after this file (the Sync files come after the Domain ones in the TOC), so it is looked up when it is used.
local function Sync()
  return ns.PvPSeasonSync
end

function PvPSeasonService.New(deps)
  return setmetatable({
    ledger = deps.ledger,
    now = deps.now,
    newId = deps.newId,
    ownName = deps.ownName,
    ownRole = deps.ownRole,
    guildRoleOf = deps.roleOf,
    send = deps.send,
    onChange = deps.onChange,
    onSeasonClosed = deps.onSeasonClosed,
    fits = deps.fits,
  }, PvPSeasonService)
end

---------------------------------------------------------------------------------------------------------------------
-- Who am I
---------------------------------------------------------------------------------------------------------------------

-- May the local player do `action` (a PermissionService action name, section 3 of the plan)?
function PvPSeasonService:CanPvP(action)
  return ns.PermissionService.Can(self.ownRole(), action)
end

-- Does this client approve claims (gm or cogm)?
function PvPSeasonService:IsApprover()
  return self:CanPvP("pvp_claim_decide")
end

-- The rules a record goes through: the roster for roles, the own role for the own name.
function PvPSeasonService:Context()
  return {
    ledger = self.ledger,
    now = self.now,
    roleOf = function(name)
      if name == self.ownName() then
        return self.ownRole()
      end
      return self.guildRoleOf(name)
    end,
    isApprover = function()
      return self:IsApprover()
    end,
    onSeasonClosed = self.onSeasonClosed,
  }
end

---------------------------------------------------------------------------------------------------------------------
-- Reading: what the interface shows
---------------------------------------------------------------------------------------------------------------------

local function sortedValues(map, before)
  local list = {}
  for _, value in pairs(map) do
    list[#list + 1] = value
  end
  table.sort(list, before)
  return list
end

-- The season that is running (state "active"), or nil.
function PvPSeasonService:ActiveSeason()
  local id = self.ledger.activeId
  return id and self.ledger.seasons[id] or nil
end

function PvPSeasonService:Season(seasonId)
  return self.ledger.seasons[seasonId]
end

-- Every season held, newest first.
function PvPSeasonService:Seasons()
  return sortedValues(self.ledger.seasons, function(a, b)
    if a.startsAt ~= b.startsAt then
      return a.startsAt > b.startsAt
    end
    return a.id < b.id
  end)
end

function PvPSeasonService:Mission(missionId)
  return self.ledger.missions[missionId]
end

-- The missions of a season by title. Paused ones (`active = false`) only with `includePaused`: members never see them.
function PvPSeasonService:Missions(seasonId, includePaused)
  local list = {}
  for _, mission in pairs(self.ledger.missions) do
    if mission.seasonId == seasonId and (includePaused or mission.active) then
      list[#list + 1] = mission
    end
  end
  table.sort(list, function(a, b)
    local left, right = a.title:lower(), b.title:lower()
    if left ~= right then
      return left < right
    end
    return a.id < b.id
  end)
  return list
end

-- The prizes of a season: `{ seasonId, tiers, ... }`. Once the season is closed they are the ones frozen in its final.
function PvPSeasonService:Prizes(seasonId)
  local final = self.ledger.finals[seasonId]
  if final then
    return { seasonId = seasonId, tiers = final.prizes, closed = true }
  end
  return self.ledger.prizes[seasonId]
end

-- The ranking of a season (default: the active one), best first: `{ pos, player, points, lastAt, tier }`. A season that
-- is closed answers with its final standing; an open one is derived from the grants this client holds.
function PvPSeasonService:Standings(seasonId)
  seasonId = seasonId or self.ledger.activeId
  if not seasonId then
    return {}
  end
  local final = self.ledger.finals[seasonId]
  if final then
    local rows = {}
    for index, standing in ipairs(final.standings) do
      rows[index] = {
        pos = standing.pos,
        player = standing.player,
        points = standing.points,
        lastAt = standing.lastAt,
        tier = Model.TierOf(standing.pos),
      }
    end
    return rows
  end
  local ctx = self:Context()
  return Model.Standings(self.ledger.grants[seasonId] or {}, self.ledger.voids, nil, ctx.roleOf, seasonId)
end

-- The row of a player (default: the local one) in the ranking of a season, or nil when they have no points.
function PvPSeasonService:StandingOf(player, seasonId)
  player = player or self.ownName()
  for _, row in ipairs(self:Standings(seasonId)) do
    if row.player == player then
      return row
    end
  end
  return nil
end

-- The grants of an open season, newest first, each with `voided` (an admin voided it) and the mission title.
function PvPSeasonService:Grants(seasonId)
  seasonId = seasonId or self.ledger.activeId
  local ctx = self:Context()
  local list = {}
  for _, grant in pairs(self.ledger.grants[seasonId] or {}) do
    local void = self.ledger.voids[grant.id]
    local mission = self.ledger.missions[grant.missionId]
    list[#list + 1] = {
      id = grant.id,
      seasonId = grant.seasonId,
      player = grant.player,
      missionId = grant.missionId,
      missionTitle = mission and mission.title or nil,
      points = grant.points,
      at = grant.at,
      by = grant.by,
      counts = Model.GrantCounts(grant, ctx.roleOf),
      voided = void ~= nil and Model.VoidCounts(void, ctx.roleOf),
    }
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.id < b.id
  end)
  return list
end

-- The claims waiting for a decision, oldest first. A claim that was granted or rejected is not in the list.
function PvPSeasonService:Queue()
  local list = {}
  for _, claim in pairs(self.ledger.queue) do
    local held = self.ledger.grants[claim.seasonId]
    if not (held and held[claim.id]) and not self.ledger.rejects[claim.id] then
      list[#list + 1] = claim
    end
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    return a.id < b.id
  end)
  return list
end

-- The claims an approver rejected and could still approve: each claim with `rejectedBy`, `rejectedAt` and `reason`.
function PvPSeasonService:Rejected()
  local list = {}
  for claimId, reject in pairs(self.ledger.rejects) do
    local claim = self.ledger.queue[claimId]
    local held = claim and self.ledger.grants[claim.seasonId]
    if claim and not (held and held[claimId]) then
      local row = {}
      for key, value in pairs(claim) do
        row[key] = value
      end
      row.rejectedBy, row.rejectedAt, row.reason = reject.by, reject.at, reject.reason
      list[#list + 1] = row
    end
  end
  table.sort(list, function(a, b)
    if a.rejectedAt ~= b.rejectedAt then
      return a.rejectedAt > b.rejectedAt
    end
    return a.id < b.id
  end)
  return list
end

-- "approved" | "rejected" | "pending" | nil (unknown) for a claim id, as this client knows it. An approval beats a
-- rejection.
function PvPSeasonService:ClaimState(claimId)
  for _, held in pairs(self.ledger.grants) do
    if held[claimId] then
      return "approved"
    end
  end
  if self.ledger.rejects[claimId] then
    return "rejected"
  end
  if self.ledger.queue[claimId] then
    return "pending"
  end
  return nil
end

function PvPSeasonService:Final(seasonId)
  return self.ledger.finals[seasonId]
end

-- The final standings of every closed season, newest first.
function PvPSeasonService:Finals()
  return sortedValues(self.ledger.finals, function(a, b)
    if a.closedAt ~= b.closedAt then
      return a.closedAt > b.closedAt
    end
    return a.seasonId < b.seasonId
  end)
end

-- The delivery list of a closed season by position: `{ pos, player, tier, rewards, delivered, updatedBy, updatedAt }`.
function PvPSeasonService:Deliveries(seasonId)
  local final = self.ledger.finals[seasonId]
  local held = self.ledger.deliveries[seasonId]
  if not (final and held) then
    return {}
  end
  local rows = {}
  for _, standing in ipairs(final.standings) do
    local delivery = held[standing.player]
    if delivery then
      rows[#rows + 1] = {
        pos = standing.pos,
        player = standing.player,
        tier = delivery.tier,
        rewards = final.prizes[delivery.tier] or {},
        delivered = delivery.delivered,
        updatedBy = delivery.rev >= 1 and delivery.updatedBy or nil,
        updatedAt = delivery.rev >= 1 and delivery.updatedAt or nil,
      }
    end
  end
  return rows
end

-- The all-time ranking over every final: `{ pos, player, points, seasons, podiums }`.
function PvPSeasonService:Cumulative()
  return Model.Cumulative(self.ledger.finals)
end

---------------------------------------------------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------------------------------------------------

-- Validates, applies to the own ledger like a received message, tells the UI and sends. Returns the payload that went
-- out and whether it was queued; or nil plus the reason.
function PvPSeasonService:Commit(messageType, payload, key)
  local message = ns.Protocol.Validate(ns.Protocol.Build(messageType, payload, "local"))
  if not message then
    return nil, "invalid:payload"
  end
  local ok, reason = Sync().Apply(self:Context(), message, self.ownName())
  if not ok then
    return nil, reason
  end
  if self.onChange then
    self.onChange(messageType)
  end
  local queued = self.send(messageType, message.p, key)
  return message.p, queued == true
end

local function forbidden(self, action)
  if not self:CanPvP(action) then
    return "forbidden"
  end
  return nil
end

local function stamp(self, record, previous)
  record.rev = previous and previous.rev + 1 or 1
  record.updatedAt = self.now()
  return record
end

-- A new season, starting now unless `startsAt` says otherwise. `fields` = { name, startsAt?, endsAt }.
function PvPSeasonService:CreateSeason(fields)
  local denied = forbidden(self, "pvp_season_manage")
  if denied then
    return nil, denied
  end
  if self:ActiveSeason() then
    return nil, "active_exists"
  end
  local record = stamp(self, {
    id = self.newId(),
    name = Model.CleanText(fields.name),
    startsAt = fields.startsAt or self.now(),
    endsAt = fields.endsAt,
    state = "active",
  })
  local clean, reason = Model.ValidateSeason(record)
  if not clean then
    return nil, reason
  end
  local payload, queued = self:Commit("PVP_SEASON", clean, "PS:" .. clean.id)
  if not payload then
    return nil, queued
  end
  return self.ledger.seasons[clean.id], queued
end

-- Changes the name or the dates of an open season. `fields` = { name?, startsAt?, endsAt? }.
function PvPSeasonService:EditSeason(seasonId, fields)
  local denied = forbidden(self, "pvp_season_manage")
  if denied then
    return nil, denied
  end
  local season = self.ledger.seasons[seasonId]
  if not season then
    return nil, "not_found"
  end
  if season.state ~= "active" then
    return nil, "closed"
  end
  local record = stamp(self, {
    id = season.id,
    name = fields.name ~= nil and Model.CleanText(fields.name) or season.name,
    startsAt = fields.startsAt or season.startsAt,
    endsAt = fields.endsAt or season.endsAt,
    state = "active",
  }, season)
  local clean, reason = Model.ValidateSeason(record)
  if not clean then
    return nil, reason
  end
  local payload, queued = self:Commit("PVP_SEASON", clean, "PS:" .. seasonId)
  if not payload then
    return nil, queued
  end
  return self.ledger.seasons[seasonId], queued
end

local function standingRows(rows)
  local standings = {}
  for index, row in ipairs(rows) do
    if index > ns.Constants.PVP_FINAL_STANDINGS_MAX then
      break
    end
    standings[index] = { pos = index, player = row.player, points = row.points, lastAt = row.lastAt }
  end
  return standings
end

-- Closes a season (default: the active one): freezes the standing from the grants this client holds, copies the
-- prizes into it, sends it as the final of the season and lets everybody drop the detail (grants, voids, rejections,
-- the claims that were waiting). Returns the final, the number of claims that expired and whether the final was queued.
-- A standing too long for one guild message is cut from the tail (never below the ten that win a prize).
function PvPSeasonService:CloseSeason(seasonId)
  local denied = forbidden(self, "pvp_season_manage")
  if denied then
    return nil, denied
  end
  seasonId = seasonId or self.ledger.activeId
  local season = seasonId and self.ledger.seasons[seasonId]
  if not season then
    return nil, "no_season"
  end
  if season.state ~= "active" or self.ledger.finals[seasonId] then
    return nil, "closed"
  end

  local prizes = self.ledger.prizes[seasonId]
  local final = {
    seasonId = seasonId,
    name = season.name,
    startsAt = season.startsAt,
    endsAt = season.endsAt,
    closedAt = self.now(),
    standings = standingRows(self:Standings(seasonId)),
    prizes = prizes and prizes.tiers or {},
  }
  local clean, reason = Model.ValidateFinal(final)
  if not clean then
    return nil, reason
  end
  if self.fits then
    clean = Model.FitFinal(clean, function(candidate)
      return self.fits("PVP_FINAL", candidate)
    end)
  end

  local expired = 0
  for _, claim in pairs(self.ledger.queue) do
    if claim.seasonId == seasonId then
      expired = expired + 1
    end
  end
  local payload, queued = self:Commit("PVP_FINAL", clean, "PF:" .. seasonId)
  if not payload then
    return nil, queued
  end
  -- The season record follows, so every client agrees on its revision too.
  local record = stamp(self, {
    id = season.id,
    name = season.name,
    startsAt = season.startsAt,
    endsAt = season.endsAt,
    state = "closed",
  }, season)
  self:Commit("PVP_SEASON", record, "PS:" .. seasonId)
  return self.ledger.finals[seasonId], expired, queued
end

-- Creates or changes a mission of the active season. `fields` = { id?, title, desc?, points, goal = { kind, count?,
-- zones?, place?, distinct? }, repeatKind, perPlayer?, active? }. With an `id` of a mission held, the fields given
-- replace the stored ones and the rest stay. A mission is never deleted, only paused (`active = false`).
function PvPSeasonService:UpsertMission(fields)
  local denied = forbidden(self, "pvp_mission_manage")
  if denied then
    return nil, denied
  end
  local existing = fields.id and self.ledger.missions[fields.id] or nil
  if fields.id and not existing and not ns.Validate.Id(fields.id) then
    return nil, "invalid:id"
  end
  local season = existing and self.ledger.seasons[existing.seasonId] or self:ActiveSeason()
  if not season then
    return nil, "no_season"
  end
  if season.state ~= "active" then
    return nil, "closed"
  end

  local base = existing or {}
  local function pick(name)
    if fields[name] ~= nil then
      return fields[name]
    end
    return base[name]
  end
  local record = stamp(self, {
    id = existing and existing.id or fields.id or self.newId(),
    seasonId = season.id,
    title = fields.title ~= nil and Model.CleanText(fields.title) or base.title,
    desc = fields.desc ~= nil and Model.CleanText(fields.desc) or base.desc,
    points = pick("points"),
    goal = pick("goal"),
    repeatKind = pick("repeatKind"),
    perPlayer = pick("perPlayer"),
    active = pick("active"),
  }, existing)
  local clean, reason = Model.ValidateMission(record)
  if not clean then
    return nil, reason
  end
  local payload, queued = self:Commit("PVP_MISSION", clean, "PM:" .. clean.id)
  if not payload then
    return nil, queued
  end
  return self.ledger.missions[clean.id], queued
end

-- Pauses or resumes a mission.
function PvPSeasonService:SetMissionActive(missionId, active)
  local denied = forbidden(self, "pvp_mission_manage")
  if denied then
    return nil, denied
  end
  if not self.ledger.missions[missionId] then
    return nil, "not_found"
  end
  return self:UpsertMission({ id = missionId, active = active == true })
end

-- Replaces the prizes of an open season. `tiers` = { ["1"] = rewards, ["2"] = ..., ["3"], ["4-6"], ["7-10"] }, each a
-- list of at most five { kind = "gold", amount } | { kind = "item", itemId, name, count }.
function PvPSeasonService:SetPrizes(seasonId, tiers)
  local denied = forbidden(self, "pvp_prize_manage")
  if denied then
    return nil, denied
  end
  local season = self.ledger.seasons[seasonId]
  if not season then
    return nil, "not_found"
  end
  if season.state ~= "active" then
    return nil, "closed"
  end
  local record = stamp(self, { seasonId = seasonId, tiers = tiers }, self.ledger.prizes[seasonId])
  local clean, reason = Model.ValidatePrizes(record)
  if not clean then
    return nil, reason
  end
  local payload, queued = self:Commit("PVP_PRIZES", clean, "PP:" .. seasonId)
  if not payload then
    return nil, queued
  end
  return self.ledger.prizes[seasonId], queued
end

-- Builds the claim of the local player for a mission and sends it to the guild. `fields` = { missionId, at? (default
-- now), n? (1..perPlayer, default 1), summary?, evidence?, note? }. The player is always the local one and the period
-- key comes from the mission, so the claim id is the same for the same claim (a claim sent twice is one). An admin
-- also keeps it in their own queue. Returns the claim and whether it was queued.
function PvPSeasonService:SubmitClaim(fields)
  local denied = forbidden(self, "pvp_claim")
  if denied then
    return nil, denied
  end
  local mission = self.ledger.missions[fields.missionId]
  if not mission then
    return nil, "unknown_mission"
  end
  local season = self.ledger.seasons[mission.seasonId]
  if not season or season.state ~= "active" or self.ledger.activeId ~= season.id then
    return nil, "no_season"
  end
  if not mission.active then
    return nil, "inactive"
  end
  local at = fields.at or self.now()
  if not Model.Contains(season, at) then
    return nil, "out_of_season"
  end
  if mission.goal.kind == "manual" and not (fields.note and fields.note ~= "") then
    return nil, "invalid:note"
  end
  local player = self.ownName()
  local periodKey = Model.PeriodKey(mission.repeatKind, at)
  local claim = {
    id = Model.ClaimId(player, mission.id, periodKey, fields.n or 1),
    missionId = mission.id,
    seasonId = season.id,
    periodKey = periodKey,
    player = player,
    at = at,
    summary = fields.summary,
    evidence = fields.evidence,
    note = fields.note,
  }
  local clean, reason = Model.ValidateClaim(claim)
  if not clean then
    return nil, reason
  end
  if Model.ParseClaimId(clean.id).n > mission.perPlayer then
    return nil, "limit"
  end
  local message = ns.Protocol.Validate(ns.Protocol.Build("PVP_CLAIM", clean, "local"))
  if not message then
    return nil, "invalid:claim"
  end
  -- An admin sees the claims of everybody, their own included; for anybody else the others' clients keep it.
  if self:IsApprover() then
    Sync().Apply(self:Context(), message, player)
    if self.onChange then
      self.onChange("PVP_CLAIM")
    end
  end
  local queued = self.send("PVP_CLAIM", message.p, "PC:" .. clean.id)
  return clean, queued == true
end

-- Stores a claim received from `sender` in the approver queue (the same path Comm takes for a PVP_CLAIM). Returns true,
-- or false plus the reason ("not_approver" for a client that does not approve claims).
function PvPSeasonService:ReceiveClaim(payload, sender)
  local message = ns.Protocol.Validate(ns.Protocol.Build("PVP_CLAIM", payload, "local"))
  if not message then
    return false, "invalid:claim"
  end
  local ok, reason = Sync().Apply(self:Context(), message, sender)
  if ok and self.onChange then
    self.onChange("PVP_CLAIM")
  end
  return ok, reason
end

-- Approves a claim of the queue: a grant whose id is the claim id, with the points of the mission as they are now.
-- Two approvers approving the same claim make the same grant, so the second changes nothing.
function PvPSeasonService:Approve(claimId)
  local denied = forbidden(self, "pvp_claim_decide")
  if denied then
    return nil, denied
  end
  local claim = self.ledger.queue[claimId]
  if not claim then
    return nil, self:ClaimState(claimId) == "approved" and "decided" or "not_found"
  end
  local season = self.ledger.seasons[claim.seasonId]
  if not season or season.state ~= "active" then
    return nil, "closed"
  end
  local mission = self.ledger.missions[claim.missionId]
  if not mission then
    return nil, "unknown_mission"
  end
  local payload, queued = self:Commit("PVP_GRANT", {
    id = claim.id,
    seasonId = claim.seasonId,
    player = claim.player,
    missionId = claim.missionId,
    points = mission.points,
    at = self.now(),
  }, "PG:" .. claim.id)
  if not payload then
    return nil, queued
  end
  return self.ledger.grants[claim.seasonId][claim.id], queued
end

-- Rejects a claim, with a reason of up to 100 characters (optional). It moves from the queue to the rejected list, and
-- an approver can still approve it afterwards (a grant beats a rejection).
function PvPSeasonService:Reject(claimId, reason)
  local denied = forbidden(self, "pvp_claim_decide")
  if denied then
    return nil, denied
  end
  local claim = self.ledger.queue[claimId]
  if not claim then
    return nil, self:ClaimState(claimId) == "approved" and "decided" or "not_found"
  end
  local payload, queued = self:Commit("PVP_REJECT", {
    claimId = claimId,
    seasonId = claim.seasonId,
    reason = reason ~= nil and Model.CleanText(reason) or nil,
    at = self.now(),
  }, "PR:" .. claimId)
  if not payload then
    return nil, queued
  end
  return self.ledger.rejects[claimId], queued
end

-- Gives points to a player without a claim (a manual mission, a correction). Admin only. `points` defaults to the
-- points of the mission.
function PvPSeasonService:DirectGrant(player, missionId, points)
  local denied = forbidden(self, "pvp_grant_direct")
  if denied then
    return nil, denied
  end
  local mission = self.ledger.missions[missionId]
  if not mission then
    return nil, "unknown_mission"
  end
  local season = self.ledger.seasons[mission.seasonId]
  if not season or season.state ~= "active" then
    return nil, "no_season"
  end
  local grant = {
    id = self.newId(),
    seasonId = season.id,
    player = player,
    missionId = missionId,
    points = points or mission.points,
    at = self.now(),
  }
  local clean, reason = Model.ValidateGrant(grant)
  if not clean then
    return nil, reason
  end
  local payload, queued = self:Commit("PVP_GRANT", clean, "PG:" .. clean.id)
  if not payload then
    return nil, queued
  end
  return self.ledger.grants[season.id][clean.id], queued
end

-- Takes a grant out of the standings (an abusive one). Admin only. The grant stays on record, marked voided.
function PvPSeasonService:Void(grantId, reason)
  local denied = forbidden(self, "pvp_grant_void")
  if denied then
    return nil, denied
  end
  local grant
  for _, held in pairs(self.ledger.grants) do
    grant = grant or held[grantId]
  end
  if not grant then
    return nil, "not_found"
  end
  if self.ledger.voids[grantId] then
    return nil, "decided"
  end
  local payload, queued = self:Commit("PVP_VOID", {
    grantId = grantId,
    seasonId = grant.seasonId,
    reason = reason ~= nil and Model.CleanText(reason) or nil,
    at = self.now(),
  }, "PV:" .. grantId)
  if not payload then
    return nil, queued
  end
  return self.ledger.voids[grantId], queued
end

-- Marks the prize of a player as handed over (or not yet). The prize is given in game; this only records it.
function PvPSeasonService:MarkDelivery(seasonId, player, delivered)
  local denied = forbidden(self, "pvp_delivery_mark")
  if denied then
    return nil, denied
  end
  local held = self.ledger.deliveries[seasonId]
  local current = held and held[player]
  if not (self.ledger.finals[seasonId] and current) then
    return nil, "not_found"
  end
  local payload, queued = self:Commit("PVP_DELIVERY", {
    seasonId = seasonId,
    player = player,
    tier = current.tier,
    delivered = delivered == true,
    rev = current.rev + 1,
    updatedAt = self.now(),
  }, ("PD:%s:%s"):format(seasonId, player))
  if not payload then
    return nil, queued
  end
  return self.ledger.deliveries[seasonId][player], queued
end

-- Forgets the mission log of a season that closed, in the saved data of the local character (`missions` =
-- char.pvpMissions: the kills and the claims of the season). Returns true when something was dropped.
function PvPSeasonService.ClearMissionLog(missions, seasonId)
  if type(missions) ~= "table" or missions.seasonId ~= seasonId then
    return false
  end
  missions.seasonId = nil
  missions.kills = {}
  missions.claims = {}
  return true
end

ns.PvPSeasonService = PvPSeasonService
