local _, ns = ...

-- Applies received PvP season records to the ledger, and builds what a ledger catch-up sends
-- (docs/PVP_MISSIONS_PLAN.md, sections 1 and 4).
--
-- "admin" below means gm or cogm: the PvP officer flag no longer gives any power (the PVP_OFFICER records are still
-- accepted from an admin and kept, but nothing reads them).
--   PVP_SEASON   season        admin       conflicts: SyncRules.Wins by rev; of several active seasons the one that
--                                          outranks the others is the active one (rev, updatedAt, author, id)
--   PVP_MISSION  mission       admin       SyncRules.Wins
--   PVP_PRIZES   prizes        admin       SyncRules.Wins, the whole record replaces the previous one
--   PVP_OFFICER  officer       admin       SyncRules.Wins
--   PVP_CLAIM    claim         anyone      the player is the sender; the same id keeps the first, replays are no-ops
--   PVP_REJECT   reject        admin       the latest `at` wins; a grant beats it
--   PVP_GRANT    grant         admin       append-only by id
--   PVP_VOID     void          admin       append-only by grant id
--   PVP_DELIVERY delivery      admin       SyncRules.Wins per (season, player)
--   PVP_FINAL    final         admin       the first one of a season wins and is authoritative
--
-- Authority is never in the message. `by`, the author, is the sender of a guild message, or, inside the ledger
-- catch-up of a relay (a leader, checked by Comm before anything is decoded) that is a gm or cogm, the author the item
-- names: the one documented exception to "the author is the sender". A relay that is not a gm or cogm only carries
-- what it authored itself (item author == relay), so an officer cannot put words in the guild master's mouth. An
-- author's role comes from the receiver's own guild roster (`ctx.roleOf`). A record whose author may not write it is
-- refused.
--
-- ctx = { ledger = db.global.pvpSeason, now = function(), roleOf = function(name) -> role or nil,
--         isApprover = function() -> boolean (this client approves claims), onSeasonClosed = function(seasonId) }
-- Every Apply returns true, or false plus:
--   "unknown_sender" | "forbidden" | "stale" | "duplicate" | "limit" | "closed" | "unknown_season" |
--   "unknown_mission" | "inactive" | "bad_period" | "out_of_season" | "future" | "decided" | "not_approver" |
--   "bad_player" | "invalid" | "unsupported"
local PvPSeasonSync = {}

local Rules = ns.SyncRules
local Model = ns.PvPSeasonModel
local countKeys, clampTimestamp = Rules.CountKeys, Rules.ClampTimestamp

local TABLES =
  { "seasons", "missions", "prizes", "officers", "grants", "voids", "rejects", "queue", "finals", "deliveries" }

-- An empty ledger: what db.global.pvpSeason holds before anything arrives (Store migration 12 makes the same).
function PvPSeasonSync.NewLedger()
  local ledger = {}
  for _, name in ipairs(TABLES) do
    ledger[name] = {}
  end
  return ledger
end

local function ledgerOf(ctx)
  local ledger = ctx.ledger
  for _, name in ipairs(TABLES) do
    if type(ledger[name]) ~= "table" then
      ledger[name] = {}
    end
  end
  return ledger
end

local function roleOf(ctx, name)
  return ctx.roleOf and ctx.roleOf(name) or nil
end

local function adminOnly(ctx, by, action)
  return Rules.Authorize(roleOf(ctx, by), action)
end

local function tooFarAhead(ctx, at)
  return at > ctx.now() + Rules.MAX_FUTURE_SKEW_SECONDS
end

local function copyList(list)
  local out = {}
  for index, value in ipairs(list) do
    out[index] = value
  end
  return out
end

-- Which season is the active one? Several can hold state "active" (two admins started one each, or a catch-up brought
-- one); the one that outranks the others wins on every client, whatever order they arrived in: higher `rev`, then later
-- `updatedAt`, then the larger author, then the larger id.
local function outranks(a, b)
  if a.rev ~= b.rev then
    return a.rev > b.rev
  end
  if a.updatedAt ~= b.updatedAt then
    return a.updatedAt > b.updatedAt
  end
  if (a.updatedBy or "") ~= (b.updatedBy or "") then
    return (a.updatedBy or "") > (b.updatedBy or "")
  end
  return a.id > b.id
end

local function electActive(ledger)
  local best
  for _, season in pairs(ledger.seasons) do
    if
      type(season) == "table"
      and season.state == "active"
      and type(season.rev) == "number"
      and type(season.updatedAt) == "number"
      and (not best or outranks(season, best))
    then
      best = season
    end
  end
  ledger.activeId = best and best.id or nil
end

---------------------------------------------------------------------------------------------------------------------
-- Closing a season: the final standing is authoritative, and the detail of the season goes away.
---------------------------------------------------------------------------------------------------------------------

-- Forgets the detail of a closed season: its grants, voids, rejections and the claims still waiting.
local function cleanup(ledger, seasonId)
  ledger.grants[seasonId] = nil
  for grantId, void in pairs(ledger.voids) do
    if void.seasonId == seasonId then
      ledger.voids[grantId] = nil
    end
  end
  for claimId, reject in pairs(ledger.rejects) do
    if reject.seasonId == seasonId then
      ledger.rejects[claimId] = nil
    end
  end
  for claimId, claim in pairs(ledger.queue) do
    if claim.seasonId == seasonId then
      ledger.queue[claimId] = nil
    end
  end
end

-- One delivery per player in the tiers (positions 1 to 10). What was already marked is kept; a player who is not in the
-- final loses their entry (it can only have come from a delivery that reached us before the final did).
local function rebuildDeliveries(ledger, final, by)
  local held = ledger.deliveries[final.seasonId] or {}
  local rebuilt = {}
  for _, standing in ipairs(final.standings) do
    local tier = Model.TierOf(standing.pos)
    if tier then
      local delivery = held[standing.player]
      if delivery then
        delivery.tier = tier
      else
        delivery = {
          seasonId = final.seasonId,
          player = standing.player,
          tier = tier,
          delivered = false,
          rev = 0,
          updatedAt = final.closedAt,
          updatedBy = by,
        }
      end
      rebuilt[standing.player] = delivery
    end
  end
  ledger.deliveries[final.seasonId] = rebuilt
end

---------------------------------------------------------------------------------------------------------------------
-- Appliers: (ctx, payload, by) -> true | false, reason
---------------------------------------------------------------------------------------------------------------------

local function applySeason(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_season_manage")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  if ledger.finals[payload.id] and payload.state == "active" then
    return false, "closed"
  end
  local season = ledger.seasons[payload.id]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if season then
    if not Rules.Wins(payload.rev, updatedAt, by, season) then
      return false, "stale"
    end
  elseif countKeys(ledger.seasons) >= ns.Constants.PVP_SEASONS_MAX then
    return false, "limit"
  end

  season = season or { id = payload.id }
  season.name, season.startsAt, season.endsAt, season.state =
    payload.name, payload.startsAt, payload.endsAt, payload.state
  season.rev, season.updatedAt, season.updatedBy = payload.rev, updatedAt, by
  ledger.seasons[payload.id] = season
  electActive(ledger)
  return true
end

local function applyMission(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_mission_manage")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  local mission = ledger.missions[payload.id]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if mission then
    -- A mission belongs to one season for good: grants keep pointing to it.
    if mission.seasonId ~= payload.seasonId then
      return false, "invalid"
    end
    if not Rules.Wins(payload.rev, updatedAt, by, mission) then
      return false, "stale"
    end
  else
    local inSeason = 0
    for _, other in pairs(ledger.missions) do
      if other.seasonId == payload.seasonId then
        inSeason = inSeason + 1
      end
    end
    if inSeason >= ns.Constants.PVP_MISSIONS_MAX then
      return false, "limit"
    end
  end
  ledger.missions[payload.id] = {
    id = payload.id,
    seasonId = payload.seasonId,
    title = payload.title,
    desc = payload.desc,
    points = payload.points,
    goal = payload.goal,
    repeatKind = payload.repeatKind,
    perPlayer = payload.perPlayer,
    active = payload.active,
    rev = payload.rev,
    updatedAt = updatedAt,
    updatedBy = by,
  }
  return true
end

local function applyPrizes(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_prize_manage")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  local prizes = ledger.prizes[payload.seasonId]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if prizes then
    if not Rules.Wins(payload.rev, updatedAt, by, prizes) then
      return false, "stale"
    end
  elseif countKeys(ledger.prizes) >= ns.Constants.PVP_SEASONS_MAX then
    return false, "limit"
  end
  ledger.prizes[payload.seasonId] =
    { seasonId = payload.seasonId, tiers = payload.tiers, rev = payload.rev, updatedAt = updatedAt, updatedBy = by }
  return true
end

local function applyOfficer(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_admin")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  local officer = ledger.officers[payload.player]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if officer then
    if not Rules.Wins(payload.rev, updatedAt, by, officer) then
      return false, "stale"
    end
  elseif countKeys(ledger.officers) >= ns.Constants.PVP_OFFICERS_MAX then
    return false, "limit"
  end
  ledger.officers[payload.player] = {
    player = payload.player,
    intervals = payload.intervals,
    rev = payload.rev,
    updatedAt = updatedAt,
    updatedBy = by,
  }
  return true
end

-- How many claims wait in the queue, and how many of them are `player`'s.
local function countQueue(ledger, player)
  local total, own = 0, 0
  for _, queued in pairs(ledger.queue) do
    total = total + 1
    if queued.player == player then
      own = own + 1
    end
  end
  return total, own
end

-- A claim. It is only kept by a client that approves claims, and only when it fits the active season and a mission the
-- client knows; a claim it cannot place yet is refused, and the claimant announces it again later.
local function applyClaim(ctx, payload, by)
  local constants = ns.Constants
  local role = roleOf(ctx, by)
  if role == nil then
    return false, "unknown_sender"
  end
  local denied = Rules.Authorize(role, "pvp_claim")
  if denied then
    return false, denied
  end
  if payload.player ~= by then
    return false, "bad_player"
  end
  if not (ctx.isApprover and ctx.isApprover()) then
    return false, "not_approver"
  end
  if tooFarAhead(ctx, payload.at) then
    return false, "future"
  end

  local ledger = ledgerOf(ctx)
  local season = ledger.seasons[payload.seasonId]
  if not season then
    return false, "unknown_season"
  end
  if season.state ~= "active" or ledger.activeId ~= season.id then
    return false, "closed"
  end
  if not Model.Contains(season, payload.at) then
    return false, "out_of_season"
  end
  for _, row in ipairs(payload.evidence) do
    if not Model.Contains(season, row.at) then
      return false, "out_of_season"
    end
  end

  local mission = ledger.missions[payload.missionId]
  if not mission or mission.seasonId ~= payload.seasonId then
    return false, "unknown_mission"
  end
  if not mission.active then
    return false, "inactive"
  end
  if Model.ParseClaimId(payload.id).n > mission.perPlayer then
    return false, "limit"
  end
  if payload.periodKey ~= Model.PeriodKey(mission.repeatKind, payload.at) then
    return false, "bad_period"
  end

  local grants = ledger.grants[payload.seasonId]
  if (grants and grants[payload.id]) or ledger.rejects[payload.id] then
    return false, "decided"
  end
  if ledger.queue[payload.id] then
    return false, "duplicate"
  end
  local total, own = countQueue(ledger, payload.player)
  if total >= constants.PVP_QUEUE_MAX then
    -- A rejected claim only waits for an approver to change their mind: it makes room before a new claim is refused.
    for claimId in pairs(ledger.queue) do
      if ledger.rejects[claimId] then
        ledger.queue[claimId] = nil
      end
    end
    total, own = countQueue(ledger, payload.player)
  end
  if total >= constants.PVP_QUEUE_MAX or own >= constants.PVP_QUEUE_PER_PLAYER_MAX then
    return false, "limit"
  end

  ledger.queue[payload.id] = {
    id = payload.id,
    missionId = payload.missionId,
    seasonId = payload.seasonId,
    periodKey = payload.periodKey,
    player = payload.player,
    at = payload.at,
    summary = payload.summary,
    evidence = payload.evidence,
    note = payload.note,
    receivedAt = ctx.now(),
  }
  return true
end

local function applyReject(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_claim_decide")
  if denied then
    return false, denied
  end
  if tooFarAhead(ctx, payload.at) then
    return false, "future"
  end
  local ledger = ledgerOf(ctx)
  if ledger.finals[payload.seasonId] then
    return false, "closed"
  end
  local held = ledger.rejects[payload.claimId]
  if held then
    -- The latest decision wins; at the same instant the larger author does, so every client picks the same one.
    if payload.at < held.at or (payload.at == held.at and by <= held.by) then
      return false, payload.at == held.at and by == held.by and "duplicate" or "stale"
    end
  elseif countKeys(ledger.rejects) >= ns.Constants.PVP_REJECTS_MAX then
    return false, "limit"
  end
  -- The claim stays in the queue, marked rejected by this record: an approver can still change their mind.
  ledger.rejects[payload.claimId] =
    { claimId = payload.claimId, seasonId = payload.seasonId, reason = payload.reason, at = payload.at, by = by }
  return true
end

local function applyGrant(ctx, payload, by)
  local ledger = ledgerOf(ctx)
  local grant = {
    id = payload.id,
    seasonId = payload.seasonId,
    player = payload.player,
    missionId = payload.missionId,
    points = payload.points,
    at = payload.at,
    by = by,
  }
  if not Model.GrantCounts(grant, ctx.roleOf) then
    return false, roleOf(ctx, by) ~= nil and "forbidden" or "unknown_sender"
  end
  if tooFarAhead(ctx, payload.at) then
    return false, "future"
  end
  if ledger.finals[payload.seasonId] then
    return false, "closed"
  end
  local held = ledger.grants[payload.seasonId]
  if held and held[payload.id] then
    return false, "duplicate"
  end
  if held then
    if countKeys(held) >= ns.Constants.PVP_GRANTS_MAX then
      return false, "limit"
    end
  elseif countKeys(ledger.grants) >= ns.Constants.PVP_SEASONS_MAX then
    return false, "limit"
  else
    held = {}
    ledger.grants[payload.seasonId] = held
  end
  held[payload.id] = grant
  ledger.queue[payload.id] = nil
  return true
end

local function applyVoid(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_grant_void")
  if denied then
    return false, denied
  end
  if tooFarAhead(ctx, payload.at) then
    return false, "future"
  end
  local ledger = ledgerOf(ctx)
  if ledger.finals[payload.seasonId] then
    return false, "closed"
  end
  if ledger.voids[payload.grantId] then
    return false, "duplicate"
  end
  if countKeys(ledger.voids) >= ns.Constants.PVP_VOIDS_MAX then
    return false, "limit"
  end
  ledger.voids[payload.grantId] =
    { grantId = payload.grantId, seasonId = payload.seasonId, reason = payload.reason, at = payload.at, by = by }
  return true
end

local function applyDelivery(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_delivery_mark")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  local final = ledger.finals[payload.seasonId]
  if final then
    -- Once the final is known, only a player it ranks in a prize tier has a delivery, and in that tier.
    local standing
    for _, row in ipairs(final.standings) do
      if row.player == payload.player then
        standing = row
        break
      end
    end
    if not standing or Model.TierOf(standing.pos) ~= payload.tier then
      return false, "invalid"
    end
  end
  local held = ledger.deliveries[payload.seasonId]
  local current = held and held[payload.player]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if current then
    if not Rules.Wins(payload.rev, updatedAt, by, current) then
      return false, "stale"
    end
  elseif held and countKeys(held) >= ns.Constants.PVP_DELIVERIES_MAX then
    return false, "limit"
  elseif not held and countKeys(ledger.deliveries) >= ns.Constants.PVP_SEASONS_MAX then
    return false, "limit"
  end
  if not held then
    held = {}
    ledger.deliveries[payload.seasonId] = held
  end
  held[payload.player] = {
    seasonId = payload.seasonId,
    player = payload.player,
    tier = payload.tier,
    delivered = payload.delivered,
    rev = payload.rev,
    updatedAt = updatedAt,
    updatedBy = by,
  }
  return true
end

local function applyFinal(ctx, payload, by)
  local denied = adminOnly(ctx, by, "pvp_season_manage")
  if denied then
    return false, denied
  end
  local ledger = ledgerOf(ctx)
  if ledger.finals[payload.seasonId] then
    return false, "duplicate"
  end
  if countKeys(ledger.finals) >= ns.Constants.PVP_FINALS_MAX then
    return false, "limit"
  end
  local final = {
    seasonId = payload.seasonId,
    name = payload.name,
    startsAt = payload.startsAt,
    endsAt = payload.endsAt,
    closedAt = payload.closedAt,
    standings = payload.standings,
    prizes = payload.prizes,
    closedBy = by,
  }
  ledger.finals[payload.seasonId] = final

  local season = ledger.seasons[payload.seasonId]
  if season then
    season.state = "closed"
  elseif countKeys(ledger.seasons) < ns.Constants.PVP_SEASONS_MAX then
    -- A season this client never saw is still part of the history.
    ledger.seasons[payload.seasonId] = {
      id = payload.seasonId,
      name = payload.name,
      startsAt = payload.startsAt,
      endsAt = payload.endsAt,
      state = "closed",
      rev = 0,
      updatedAt = payload.closedAt,
      updatedBy = by,
    }
  end
  if ledger.activeId == payload.seasonId then
    -- Another season that was started at the same time may take its place.
    electActive(ledger)
  end
  cleanup(ledger, payload.seasonId)
  rebuildDeliveries(ledger, final, by)
  if ctx.onSeasonClosed then
    ctx.onSeasonClosed(payload.seasonId)
  end
  return true
end

local APPLIERS = {
  PVP_SEASON = applySeason,
  PVP_MISSION = applyMission,
  PVP_PRIZES = applyPrizes,
  PVP_OFFICER = applyOfficer,
  PVP_CLAIM = applyClaim,
  PVP_REJECT = applyReject,
  PVP_GRANT = applyGrant,
  PVP_VOID = applyVoid,
  PVP_DELIVERY = applyDelivery,
  PVP_FINAL = applyFinal,
}

-- The messages that change the ledger or the claim queue (not the catch-up pair).
function PvPSeasonSync.IsRecordMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- Every message of this feature that is allowed on the guild channel: the records and the ledger request.
function PvPSeasonSync.IsSeasonMessage(messageType)
  return APPLIERS[messageType] ~= nil or messageType == "PVP_LEDGER_REQ"
end

-- `message` must already be validated by Protocol. `by` is the sender of a guild message; for an item of a ledger
-- catch-up it is the author the item names (see ApplyItems).
function PvPSeasonSync.Apply(ctx, message, by)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, by)
end

-- The items of one page of a ledger catch-up, each applied as if its author had sent it. `relay` = { sender = the
-- whisperer, global = whether they are a gm or cogm }: only a global relay may name other authors; any other relay is
-- believed about its own records alone (item author == relay). An item that does not validate, is not a record of
-- this feature, names no author or an author the relay may not name is skipped. Returns { applied, total, forged
-- (how many were skipped for the author) }.
function PvPSeasonSync.ApplyItems(ctx, items, relay)
  local summary = { applied = 0, total = #items, forged = 0 }
  for _, entry in ipairs(items) do
    if type(entry) == "table" and PvPSeasonSync.IsRecordMessage(entry.t) and entry.t ~= "PVP_CLAIM" then
      local message = ns.Protocol.Validate(ns.Protocol.Build(entry.t, entry.p, "ledger"))
      if message and Model.IsPlayer(entry.by) then
        if not (relay and (relay.global or entry.by == relay.sender)) then
          summary.forged = summary.forged + 1
        elseif PvPSeasonSync.Apply(ctx, message, entry.by) then
          summary.applied = summary.applied + 1
        end
      end
    end
  end
  return summary
end

---------------------------------------------------------------------------------------------------------------------
-- Ledger catch-up
---------------------------------------------------------------------------------------------------------------------

-- Everything the ledger holds about a season, as small strings: two clients with the same tokens hold the same ledger.
-- The officers, the seasons, the finals and the deliveries are global; the rest belongs to `seasonId` (nil: nothing of
-- any season).
function PvPSeasonSync.Tokens(ledger, seasonId)
  local tokens = {}
  local function add(text)
    tokens[#tokens + 1] = text
  end
  for player, officer in pairs(ledger.officers) do
    add(("o:%s:%d"):format(player, officer.rev))
  end
  for id, season in pairs(ledger.seasons) do
    add(("s:%s:%d:%s"):format(id, season.rev, season.state))
  end
  for id in pairs(ledger.finals) do
    add("f:" .. id)
  end
  -- Who got their prize is history too: the deliveries of every season are part of it.
  for id, held in pairs(ledger.deliveries) do
    for player, delivery in pairs(held) do
      add(("d:%s:%s:%d:%d"):format(id, player, delivery.rev, delivery.delivered and 1 or 0))
    end
  end
  if seasonId then
    for id, mission in pairs(ledger.missions) do
      if mission.seasonId == seasonId then
        add(("m:%s:%d"):format(id, mission.rev))
      end
    end
    local prizes = ledger.prizes[seasonId]
    if prizes then
      add(("p:%s:%d"):format(seasonId, prizes.rev))
    end
    for id in pairs(ledger.grants[seasonId] or {}) do
      add("g:" .. id)
    end
    for id, void in pairs(ledger.voids) do
      if void.seasonId == seasonId then
        add("v:" .. id)
      end
    end
    for id, reject in pairs(ledger.rejects) do
      if reject.seasonId == seasonId then
        add(("r:%s:%d:%s"):format(id, reject.at, reject.by))
      end
    end
  end
  return tokens
end

-- { count, digest } of the ledger for a season, the pair a PVP_LEDGER_REQ carries.
function PvPSeasonSync.Summary(ledger, seasonId)
  local tokens = PvPSeasonSync.Tokens(ledger, seasonId)
  return { count = #tokens, digest = Model.Digest(tokens) }
end

-- The payload of a request for the catch-up of `seasonId` (nil: the client knows no season yet).
function PvPSeasonSync.RequestPayload(ledger, seasonId)
  local summary = PvPSeasonSync.Summary(ledger, seasonId)
  return { seasonId = seasonId, count = summary.count, digest = summary.digest }
end

-- Does this ledger differ from the one the request describes?
function PvPSeasonSync.Differs(ledger, request)
  local summary = PvPSeasonSync.Summary(ledger, request.seasonId)
  return summary.count ~= request.count or summary.digest ~= request.digest
end

local function item(messageType, payload, by)
  if type(by) ~= "string" then
    return nil
  end
  local message = ns.Protocol.Validate(ns.Protocol.Build(messageType, payload, "ledger"))
  return message and { t = messageType, p = message.p, by = by } or nil
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- The ledger as a list of { t, p, by } items in the order a receiver needs them: officers first (they decide who may
-- author what), then seasons, missions, prizes and finals, then the grants, voids, rejections and deliveries of the
-- seasons in `seasonIds` that are still open. What does not validate is left out.
function PvPSeasonSync.LedgerItems(ledger, seasonIds)
  local items = {}
  local function add(entry)
    -- An item that does not validate is nil: it is left out.
    if entry then
      items[#items + 1] = entry
    end
  end
  local wanted = {}
  for _, id in ipairs(seasonIds) do
    wanted[id] = true
  end

  for _, player in ipairs(sortedKeys(ledger.officers)) do
    local officer = ledger.officers[player]
    add(item("PVP_OFFICER", {
      player = player,
      intervals = officer.intervals,
      rev = officer.rev,
      updatedAt = officer.updatedAt,
    }, officer.updatedBy))
  end
  for _, id in ipairs(sortedKeys(ledger.seasons)) do
    local season = ledger.seasons[id]
    -- A season that only exists as the stub of a final (revision 0) is carried by the final.
    if season.rev >= 1 then
      add(item("PVP_SEASON", {
        id = id,
        name = season.name,
        startsAt = season.startsAt,
        endsAt = season.endsAt,
        state = season.state,
        rev = season.rev,
        updatedAt = season.updatedAt,
      }, season.updatedBy))
    end
  end
  for _, id in ipairs(sortedKeys(ledger.missions)) do
    local m = ledger.missions[id]
    if wanted[m.seasonId] then
      add(item("PVP_MISSION", {
        id = id,
        seasonId = m.seasonId,
        title = m.title,
        desc = m.desc,
        points = m.points,
        goal = m.goal,
        repeatKind = m.repeatKind,
        perPlayer = m.perPlayer,
        active = m.active,
        rev = m.rev,
        updatedAt = m.updatedAt,
      }, m.updatedBy))
    end
  end
  for _, id in ipairs(sortedKeys(ledger.prizes)) do
    local prizes = ledger.prizes[id]
    if wanted[id] then
      add(item("PVP_PRIZES", {
        seasonId = id,
        tiers = prizes.tiers,
        rev = prizes.rev,
        updatedAt = prizes.updatedAt,
      }, prizes.updatedBy))
    end
  end
  for _, id in ipairs(sortedKeys(ledger.finals)) do
    local final = ledger.finals[id]
    add(item("PVP_FINAL", {
      seasonId = id,
      name = final.name,
      startsAt = final.startsAt,
      endsAt = final.endsAt,
      closedAt = final.closedAt,
      standings = final.standings,
      prizes = final.prizes,
    }, final.closedBy))
  end
  for _, id in ipairs(sortedKeys(ledger.grants)) do
    if wanted[id] and not ledger.finals[id] then
      for _, grantId in ipairs(sortedKeys(ledger.grants[id])) do
        local grant = ledger.grants[id][grantId]
        add(item("PVP_GRANT", {
          id = grant.id,
          seasonId = grant.seasonId,
          player = grant.player,
          missionId = grant.missionId,
          points = grant.points,
          at = grant.at,
        }, grant.by))
      end
    end
  end
  for _, grantId in ipairs(sortedKeys(ledger.voids)) do
    local void = ledger.voids[grantId]
    if wanted[void.seasonId] and not ledger.finals[void.seasonId] then
      add(
        item("PVP_VOID", { grantId = grantId, seasonId = void.seasonId, reason = void.reason, at = void.at }, void.by)
      )
    end
  end
  for _, claimId in ipairs(sortedKeys(ledger.rejects)) do
    local reject = ledger.rejects[claimId]
    if wanted[reject.seasonId] and not ledger.finals[reject.seasonId] then
      add(item("PVP_REJECT", {
        claimId = claimId,
        seasonId = reject.seasonId,
        reason = reject.reason,
        at = reject.at,
      }, reject.by))
    end
  end
  for _, id in ipairs(sortedKeys(ledger.deliveries)) do
    -- The deliveries of every season: who got their prize is history too.
    for _, player in ipairs(sortedKeys(ledger.deliveries[id])) do
      local d = ledger.deliveries[id][player]
      if d.rev >= 1 then
        add(item("PVP_DELIVERY", {
          seasonId = id,
          player = player,
          tier = d.tier,
          delivered = d.delivered,
          rev = d.rev,
          updatedAt = d.updatedAt,
        }, d.updatedBy))
      end
    end
  end
  return items
end

-- The seasons a catch-up answer carries the detail of: the one asked for (if the relay has it) and the relay's active
-- one.
function PvPSeasonSync.ScopeFor(ledger, request)
  local ids = {}
  if request.seasonId and ledger.seasons[request.seasonId] then
    ids[#ids + 1] = request.seasonId
  end
  if ledger.activeId and ledger.activeId ~= request.seasonId then
    ids[#ids + 1] = ledger.activeId
  end
  return ids
end

-- Splits `items` into pages that each satisfy `fits(page)` (a function that encodes a page and says whether it is small
-- enough) and hold at most `maxItems`. An item that does not fit alone is left out. Returns a list of pages.
function PvPSeasonSync.Paginate(items, fits, maxItems)
  local pages = {}
  local index = 1
  while index <= #items do
    local size = math.min(maxItems, #items - index + 1)
    local page = {}
    while size >= 1 do
      page = {}
      for offset = 0, size - 1 do
        page[#page + 1] = items[index + offset]
      end
      if fits(page) then
        break
      end
      if size == 1 then
        page = nil
        break
      end
      size = math.floor(size / 2)
    end
    if page then
      pages[#pages + 1] = copyList(page)
      index = index + size
    else
      index = index + 1
    end
  end
  return pages
end

ns.PvPSeasonSync = PvPSeasonSync
