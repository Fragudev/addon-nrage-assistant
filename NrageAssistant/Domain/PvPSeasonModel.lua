local _, ns = ...

-- Shape, validation and the pure rules of the PvP season system (docs/PVP_MISSIONS_PLAN.md, section 1). No client API,
-- no storage: plain tables in, plain tables out, so everything here is tested without a client.
--
-- Records (all ids are `[A-Za-z0-9_-]{1,40}`; times are server time; a name is a character name as the guild roster
-- writes it, possibly several words):
--   season   { id, name, startsAt, endsAt, state = "active" | "closed", rev, updatedAt }
--   mission  { id, seasonId, title, desc, points, goal = { kind, count, zones, place, distinct, target?, bgs?,
--              victimClasses?, victimRaces?, victimCapPerDay?, minGuildInGroup?, window?, maxCompletions?,
--              autoClaim? }, repeatKind, perPlayer, active, rev, updatedAt }
--   claim    { id, missionId, seasonId, periodKey, player, at, summary, evidence, note }
--   grant    { id, seasonId, player, missionId, points, at }          (+ `by`, who authored it)
--   void     { grantId, seasonId, reason, at }                        (+ `by`)
--   reject   { claimId, seasonId, reason, at }                        (+ `by`)
--   progress { seasonId, rows = { { missionId, count, goal } } }   (what a member says they have counted; display only)
--   prizes   { seasonId, tiers = { ["1"] = rewards, ... }, rev, updatedAt }
--   officer  { player, intervals = { { from, to? } ... }, rev, updatedAt }
--   delivery { seasonId, player, tier, delivered, rev, updatedAt }
--   final    { seasonId, name, startsAt, endsAt, closedAt, standings, prizes = tiers }   (+ `closedBy`)
-- `by`, `updatedBy` and `closedBy` are never part of a validated payload: they come from the sender of a message, or
-- (inside a ledger catch-up from a trusted relay) from the item. Every Validate* function returns the clean record
-- (unknown fields dropped) or nil plus "invalid:<field>".
local PvPSeasonModel = {}

local V = ns.Validate
local isInt, isText, isId = V.Int, V.Text, V.Id

local MAX_REV = 2147483647
local MAX_TIMESTAMP = 4102444800 -- 2100-01-01
local MAX_NAME = 64
local MAX_MAP_ID = 999999
local MAX_ITEM_ID = 10000000
local MAX_TOKEN = 20

PvPSeasonModel.STATES = { active = true, closed = true }
PvPSeasonModel.GOAL_KINDS = { kills = true, kos = true, bg_wins = true, manual = true, bg_played = true }
-- The battleground tokens a `bgs` filter may hold (the values of PVP_BG_BY_MAP).
PvPSeasonModel.BATTLEGROUNDS = { wsg = true, ab = true, av = true }
PvPSeasonModel.PLACES = { any = true, world = true, bg = true }
PvPSeasonModel.DISTINCT = { none = true, name = true, class = true, race = true, class_race = true }
PvPSeasonModel.REPEAT_KINDS = { once = true, daily = true, weekly = true }

-- The keys of a claim summary (what the claimant's client counted); the approver reads them next to the evidence.
local SUMMARY_KEYS = { "done", "total", "classes", "classesTotal", "races", "racesTotal", "unknown" }

local function bad(field)
  return nil, "invalid:" .. field
end

local function isTime(value)
  return isInt(value, 0, MAX_TIMESTAMP)
end

local function isRev(value)
  return isInt(value, 1, MAX_REV)
end

-- A character name: plain text, no ":" (it is part of the claim id).
function PvPSeasonModel.IsPlayer(name)
  return isText(name, MAX_NAME) and not name:find(":", 1, true)
end

-- Plain text with the spaces tidied: the form a name is stored and sent in.
function PvPSeasonModel.CleanText(text)
  if type(text) ~= "string" then
    return nil
  end
  return (text:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function isCleanText(text, max)
  return isText(text, max) and PvPSeasonModel.CleanText(text) == text
end

-- An upper-case token (`^%u+$`, the rule PROFILE applies to a class): the class or race file token of a victim.
local function isToken(value)
  return isText(value, MAX_TOKEN) and value:find("^%u+$") ~= nil
end

local function isOptionalText(value, max)
  return value == nil or value == "" or isText(value, max)
end

---------------------------------------------------------------------------------------------------------------------
-- Dates: period keys, computed by hand so the model needs no clock and no `os`.
---------------------------------------------------------------------------------------------------------------------

local SECONDS_PER_DAY = 86400

-- Days since 1970-01-01 -> year, month, day (proleptic Gregorian, UTC).
local function civilFromDays(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local year = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * mp + 2) / 5) + 1
  local month = mp < 10 and mp + 3 or mp - 9
  if month <= 2 then
    year = year + 1
  end
  return year, month, day
end

local function daysFromCivil(year, month, day)
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local mp = month > 2 and month - 3 or month + 9
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- "YYYYMMDD" of the server day (UTC) a timestamp falls on.
function PvPSeasonModel.DayKey(at)
  local year, month, day = civilFromDays(math.floor(at / SECONDS_PER_DAY))
  return ("%04d%02d%02d"):format(year, month, day)
end

-- "YYYYWww": the ISO 8601 week (weeks start on Monday) of the timestamp, UTC. The year is the ISO year, which is the
-- year of the Thursday of that week.
function PvPSeasonModel.WeekKey(at)
  local days = math.floor(at / SECONDS_PER_DAY)
  local weekday = (days + 3) % 7 -- 1970-01-01 was a Thursday; Monday = 0
  local thursday = days - weekday + 3
  local year = civilFromDays(thursday)
  local week = math.floor((thursday - daysFromCivil(year, 1, 1)) / 7) + 1
  return ("%04dW%02d"):format(year, week)
end

-- The period a mission counts in at time `at`: "all" for `once`, the day for `daily`, the ISO week for `weekly`.
function PvPSeasonModel.PeriodKey(repeatKind, at)
  if repeatKind == "daily" then
    return PvPSeasonModel.DayKey(at)
  elseif repeatKind == "weekly" then
    return PvPSeasonModel.WeekKey(at)
  elseif repeatKind == "once" then
    return "all"
  end
  return nil
end

function PvPSeasonModel.IsPeriodKey(key)
  if type(key) ~= "string" then
    return false
  end
  if key == "all" then
    return true
  end
  local month, day = key:match("^%d%d%d%d(%d%d)(%d%d)$")
  if month then
    return tonumber(month) >= 1 and tonumber(month) <= 12 and tonumber(day) >= 1 and tonumber(day) <= 31
  end
  local week = key:match("^%d%d%d%dW(%d%d)$")
  return week ~= nil and tonumber(week) >= 1 and tonumber(week) <= 53
end

-- Is `at` inside the dates of the season (both ends included)?
function PvPSeasonModel.Contains(season, at)
  return type(season) == "table" and type(at) == "number" and at >= season.startsAt and at <= season.endsAt
end

---------------------------------------------------------------------------------------------------------------------
-- Claim ids: "<player>:<missionId>:<periodKey>:<n>". A grant with that id approves that claim.
---------------------------------------------------------------------------------------------------------------------

function PvPSeasonModel.ClaimId(player, missionId, periodKey, n)
  return ("%s:%s:%s:%d"):format(player, missionId, periodKey, n)
end

-- { player, missionId, periodKey, n } or nil when `id` is not a claim id.
function PvPSeasonModel.ParseClaimId(id)
  if type(id) ~= "string" or #id > MAX_NAME + 40 + 8 + 2 + 3 then
    return nil
  end
  local player, missionId, periodKey, n = id:match("^(.+):([^:]+):([^:]+):(%d+)$")
  if not player then
    return nil
  end
  n = tonumber(n)
  if
    not (
      PvPSeasonModel.IsPlayer(player)
      and isId(missionId)
      and PvPSeasonModel.IsPeriodKey(periodKey)
      and isInt(n, 1, ns.Constants.PVP_MISSION_PER_PLAYER_MAX)
    )
  then
    return nil
  end
  return { player = player, missionId = missionId, periodKey = periodKey, n = n }
end

function PvPSeasonModel.IsClaimId(id)
  return PvPSeasonModel.ParseClaimId(id) ~= nil
end

-- Either a claim id (the approval of a claim) or a plain id (a direct grant).
local function isGrantId(id)
  return isId(id) or PvPSeasonModel.IsClaimId(id)
end

---------------------------------------------------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------------------------------------------------

function PvPSeasonModel.ValidateSeason(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not isId(fields.id) then
    return bad("id")
  end
  if not isCleanText(fields.name, constants.PVP_SEASON_NAME_MAX) then
    return bad("name")
  end
  if not (isTime(fields.startsAt) and isTime(fields.endsAt) and fields.endsAt > fields.startsAt) then
    return bad("dates")
  end
  if not (type(fields.state) == "string" and PvPSeasonModel.STATES[fields.state]) then
    return bad("state")
  end
  if not (isRev(fields.rev) and isTime(fields.updatedAt)) then
    return bad("rev")
  end
  return {
    id = fields.id,
    name = fields.name,
    startsAt = fields.startsAt,
    endsAt = fields.endsAt,
    state = fields.state,
    rev = fields.rev,
    updatedAt = fields.updatedAt,
  }
end

-- A list of up to `max` distinct values that satisfy `valid`, or nil when anything is wrong. An empty list is valid
-- (no filter).
local function cleanList(list, max, valid)
  if type(list) ~= "table" or #list > max then
    return nil
  end
  local clean, seen = {}, {}
  for index, value in ipairs(list) do
    if not valid(value) or seen[value] then
      return nil
    end
    seen[value] = true
    clean[index] = value
  end
  return clean
end

local function isBattleground(value)
  return type(value) == "string" and PvPSeasonModel.BATTLEGROUNDS[value] == true
end

-- The optional fields of a goal that narrow what counts or change how it is claimed (they travel inside `goal`, so an
-- older client that does not know them drops them). Returns false when one is present and invalid. A field that does
-- not apply to the kind is dropped. Only fields that differ from their default are written.
local function addOptionalGoal(goal, clean)
  local constants = ns.Constants
  local kind = goal.kind
  local kills = kind == "kills" or kind == "kos"
  local battlegrounds = kind == "bg_wins" or kind == "bg_played"
  if battlegrounds and goal.bgs ~= nil then
    local bgs = cleanList(goal.bgs, 3, isBattleground)
    if not bgs then
      return false
    end
    clean.bgs = #bgs > 0 and bgs or nil
  end
  if kills then
    for _, field in ipairs({ "victimClasses", "victimRaces" }) do
      if goal[field] ~= nil then
        local list = cleanList(goal[field], constants.PVP_MISSION_FILTER_MAX, isToken)
        if not list then
          return false
        end
        clean[field] = #list > 0 and list or nil
      end
    end
    if goal.victimCapPerDay ~= nil then
      if not isInt(goal.victimCapPerDay, 0, constants.PVP_MISSION_VICTIM_CAP_MAX) then
        return false
      end
      clean.victimCapPerDay = goal.victimCapPerDay
    end
    if goal.minGuildInGroup ~= nil then
      if not isInt(goal.minGuildInGroup, 0, constants.PVP_MISSION_GUILD_GROUP_MAX) then
        return false
      end
      clean.minGuildInGroup = goal.minGuildInGroup > 0 and goal.minGuildInGroup or nil
    end
  end
  if kind ~= "manual" and goal.window ~= nil then
    local window = goal.window
    if
      type(window) ~= "table"
      or not (isTime(window.startsAt) and isTime(window.endsAt))
      or window.startsAt >= window.endsAt
    then
      return false
    end
    clean.window = { startsAt = window.startsAt, endsAt = window.endsAt }
  end
  if goal.maxCompletions ~= nil then
    if not isInt(goal.maxCompletions, 0, constants.PVP_MISSION_COMPLETIONS_MAX) then
      return false
    end
    clean.maxCompletions = goal.maxCompletions > 0 and goal.maxCompletions or nil
  end
  if goal.autoClaim ~= nil then
    if type(goal.autoClaim) ~= "boolean" then
      return false
    end
    clean.autoClaim = goal.autoClaim or nil
  end
  return true
end

local function validateGoal(goal)
  local constants = ns.Constants
  if type(goal) ~= "table" then
    return nil
  end
  if not (type(goal.kind) == "string" and PvPSeasonModel.GOAL_KINDS[goal.kind]) then
    return nil
  end
  local place = goal.place == nil and "any" or goal.place
  local distinct = goal.distinct == nil and "none" or goal.distinct
  if not (type(place) == "string" and PvPSeasonModel.PLACES[place]) then
    return nil
  end
  if not (type(distinct) == "string" and PvPSeasonModel.DISTINCT[distinct]) then
    return nil
  end
  -- The count is ignored for a manual mission and derived for a class or race one; a valid number is still required
  -- so the form always writes one.
  local count = goal.count == nil and 1 or goal.count
  if not isInt(count, 1, constants.PVP_MISSION_COUNT_MAX) then
    return nil
  end
  local zones = {}
  if goal.zones ~= nil then
    if type(goal.zones) ~= "table" or #goal.zones > constants.PVP_MISSION_ZONES_MAX then
      return nil
    end
    local seen = {}
    for index, mapId in ipairs(goal.zones) do
      if not isInt(mapId, 1, MAX_MAP_ID) or seen[mapId] then
        return nil
      end
      seen[mapId] = true
      zones[index] = mapId
    end
  end
  local clean = { kind = goal.kind, count = count, zones = zones, place = place, distinct = distinct }
  -- A bounty ("kos") may name one victim. The name is cleaned with IntelModel (loaded after this file, so it is looked
  -- up at call time; a client without it refuses a target rather than keep one unchecked). Any other kind drops it.
  if goal.kind == "kos" and goal.target ~= nil then
    local target = ns.IntelModel and ns.IntelModel.CleanName(goal.target) or nil
    if not target then
      return nil
    end
    clean.target = target
  end
  if not addOptionalGoal(goal, clean) then
    return nil
  end
  return clean
end

-- Does this mission need a client that knows the optional goal fields or the battleground-played kind (protocol minor
-- 13)? An older client drops the fields (and so counts more than the officer asked for) and refuses the kind.
-- The zone ids an older client would misread (docs/PVP_DUELS_ZONES_PLAN.md, 1.4): the continents of the zone tree and
-- the zones that have cities inside them. Built once on first use.
local newZoneIds

local function getNewZoneIds()
  if not newZoneIds then
    newZoneIds = {}
    for _, region in ipairs(ns.Constants.PVP_MISSION_REGIONS) do
      newZoneIds[region.mapId] = true
      for _, zone in ipairs(region.zones) do
        if zone.includes then
          newZoneIds[zone.mapId] = true
        end
      end
    end
  end
  return newZoneIds
end

function PvPSeasonModel.UsesNewGoalFeatures(goal)
  if type(goal) ~= "table" then
    return false
  end
  if goal.kind == "bg_played" then
    return true
  end
  for _, mapId in ipairs(type(goal.zones) == "table" and goal.zones or {}) do
    if getNewZoneIds()[mapId] then
      return true
    end
  end
  for _, field in ipairs({
    "bgs",
    "victimClasses",
    "victimRaces",
    "victimCapPerDay",
    "minGuildInGroup",
    "window",
    "maxCompletions",
    "autoClaim",
  }) do
    if goal[field] ~= nil then
      return true
    end
  end
  return false
end

function PvPSeasonModel.ValidateMission(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not (isId(fields.id) and isId(fields.seasonId)) then
    return bad("id")
  end
  if not isCleanText(fields.title, constants.PVP_MISSION_TITLE_MAX) then
    return bad("title")
  end
  if not isOptionalText(fields.desc, constants.PVP_MISSION_DESC_MAX) then
    return bad("desc")
  end
  if not isInt(fields.points, 1, constants.PVP_MISSION_POINTS_MAX) then
    return bad("points")
  end
  local goal = validateGoal(fields.goal)
  if not goal then
    return bad("goal")
  end
  if not (type(fields.repeatKind) == "string" and PvPSeasonModel.REPEAT_KINDS[fields.repeatKind]) then
    return bad("repeatKind")
  end
  local perPlayer = fields.perPlayer == nil and 1 or fields.perPlayer
  if not isInt(perPlayer, 1, constants.PVP_MISSION_PER_PLAYER_MAX) then
    return bad("perPlayer")
  end
  local active = fields.active == nil and true or fields.active
  if type(active) ~= "boolean" then
    return bad("active")
  end
  if not (isRev(fields.rev) and isTime(fields.updatedAt)) then
    return bad("rev")
  end
  return {
    id = fields.id,
    seasonId = fields.seasonId,
    title = fields.title,
    desc = fields.desc or "",
    points = fields.points,
    goal = goal,
    repeatKind = fields.repeatKind,
    perPlayer = perPlayer,
    active = active,
    rev = fields.rev,
    updatedAt = fields.updatedAt,
  }
end

-- A progress summary: how far the sender is in some missions of a season. Display only, nothing is granted by it.
function PvPSeasonModel.ValidateProgress(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not isId(fields.seasonId) then
    return bad("seasonId")
  end
  if type(fields.rows) ~= "table" or #fields.rows > constants.PVP_MISSIONS_MAX then
    return bad("rows")
  end
  local rows, seen = {}, {}
  for index, row in ipairs(fields.rows) do
    if
      type(row) ~= "table"
      or not isId(row.missionId)
      or seen[row.missionId]
      or not isInt(row.goal, 1, constants.PVP_MISSION_COUNT_MAX)
      or not isInt(row.count, 0, row.goal)
    then
      return bad("rows")
    end
    seen[row.missionId] = true
    rows[index] = { missionId = row.missionId, count = row.count, goal = row.goal }
  end
  return { seasonId = fields.seasonId, rows = rows }
end

local function validateSummary(summary)
  if summary == nil then
    return {}
  end
  if type(summary) ~= "table" then
    return nil
  end
  local clean = {}
  for _, key in ipairs(SUMMARY_KEYS) do
    local value = summary[key]
    if value ~= nil then
      if not isInt(value, 0, 100000) then
        return nil
      end
      clean[key] = value
    end
  end
  return clean
end

local function validateEvidenceRow(row)
  if type(row) ~= "table" or not isTime(row.at) then
    return nil
  end
  local mapId = row.mapId
  if mapId ~= nil and not isInt(mapId, 0, MAX_MAP_ID) then
    return nil
  end
  if row.bgWin ~= nil then
    -- `bgWin = false` is a battleground that was lost (the "played" goal counts those too); `bg` says which one.
    if type(row.bgWin) ~= "boolean" or row.victim ~= nil then
      return nil
    end
    if row.bg ~= nil and not isBattleground(row.bg) then
      return nil
    end
    return { at = row.at, bgWin = row.bgWin, mapId = mapId, bg = row.bg }
  end
  if row.kos ~= nil and row.kos ~= true then
    return nil
  end
  if not (isText(row.victim, ns.Constants.PVP_FEED_VICTIM_MAX) and type(row.place) == "string") then
    return nil
  end
  if row.place ~= "world" and row.place ~= "bg" then
    return nil
  end
  local clean = { at = row.at, victim = row.victim, mapId = mapId, place = row.place, kos = row.kos }
  if row.guild ~= nil then
    if not isInt(row.guild, 0, ns.Constants.PVP_MISSION_GUILD_GROUP_MAX) then
      return nil
    end
    clean.guild = row.guild
  end
  if row.class ~= nil then
    if not isToken(row.class) then
      return nil
    end
    clean.class = row.class
  end
  if row.race ~= nil then
    if not isToken(row.race) then
      return nil
    end
    clean.race = row.race
  end
  return clean
end

-- A claim. `id`, `missionId`, `periodKey` and `player` have to agree with each other: the id is built from them.
function PvPSeasonModel.ValidateClaim(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  local parts = PvPSeasonModel.ParseClaimId(fields.id)
  if not parts then
    return bad("id")
  end
  if
    not (
      fields.player == parts.player
      and fields.missionId == parts.missionId
      and fields.periodKey == parts.periodKey
      and isId(fields.seasonId)
    )
  then
    return bad("id")
  end
  if not isTime(fields.at) then
    return bad("at")
  end
  local summary = validateSummary(fields.summary)
  if not summary then
    return bad("summary")
  end
  local evidence = {}
  if fields.evidence ~= nil then
    if type(fields.evidence) ~= "table" or #fields.evidence > constants.PVP_CLAIM_EVIDENCE_MAX then
      return bad("evidence")
    end
    for index, row in ipairs(fields.evidence) do
      evidence[index] = validateEvidenceRow(row)
      if not evidence[index] then
        return bad("evidence")
      end
    end
  end
  if not isOptionalText(fields.note, constants.PVP_NOTE_MAX) then
    return bad("note")
  end
  return {
    id = fields.id,
    missionId = fields.missionId,
    seasonId = fields.seasonId,
    periodKey = fields.periodKey,
    player = fields.player,
    at = fields.at,
    summary = summary,
    evidence = evidence,
    note = (fields.note ~= nil and fields.note ~= "") and fields.note or nil,
  }
end

function PvPSeasonModel.ValidateGrant(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not isGrantId(fields.id) then
    return bad("id")
  end
  if not (isId(fields.seasonId) and isId(fields.missionId) and PvPSeasonModel.IsPlayer(fields.player)) then
    return bad("ref")
  end
  -- The id of an approval names the claim: it has to name this player and mission.
  local parts = PvPSeasonModel.ParseClaimId(fields.id)
  if parts and not (parts.player == fields.player and parts.missionId == fields.missionId) then
    return bad("id")
  end
  if not isInt(fields.points, 1, constants.PVP_MISSION_POINTS_MAX) then
    return bad("points")
  end
  if not isTime(fields.at) then
    return bad("at")
  end
  return {
    id = fields.id,
    seasonId = fields.seasonId,
    player = fields.player,
    missionId = fields.missionId,
    points = fields.points,
    at = fields.at,
  }
end

function PvPSeasonModel.ValidateVoid(fields)
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not (isGrantId(fields.grantId) and isId(fields.seasonId)) then
    return bad("ref")
  end
  if not isOptionalText(fields.reason, ns.Constants.PVP_REASON_MAX) then
    return bad("reason")
  end
  if not isTime(fields.at) then
    return bad("at")
  end
  return {
    grantId = fields.grantId,
    seasonId = fields.seasonId,
    reason = (fields.reason ~= nil and fields.reason ~= "") and fields.reason or nil,
    at = fields.at,
  }
end

function PvPSeasonModel.ValidateReject(fields)
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not (PvPSeasonModel.IsClaimId(fields.claimId) and isId(fields.seasonId)) then
    return bad("ref")
  end
  if not isOptionalText(fields.reason, ns.Constants.PVP_REASON_MAX) then
    return bad("reason")
  end
  if not isTime(fields.at) then
    return bad("at")
  end
  return {
    claimId = fields.claimId,
    seasonId = fields.seasonId,
    reason = (fields.reason ~= nil and fields.reason ~= "") and fields.reason or nil,
    at = fields.at,
  }
end

local function validateReward(reward)
  local constants = ns.Constants
  if type(reward) ~= "table" then
    return nil
  end
  if reward.kind == "gold" then
    if not isInt(reward.amount, 1, constants.PVP_PRIZE_GOLD_MAX) then
      return nil
    end
    return { kind = "gold", amount = reward.amount }
  elseif reward.kind == "item" then
    if
      not (
        isInt(reward.itemId, 1, MAX_ITEM_ID)
        and isText(reward.name, constants.PVP_PRIZE_ITEM_NAME_MAX)
        and isInt(reward.count, 1, constants.PVP_PRIZE_ITEM_COUNT_MAX)
      )
    then
      return nil
    end
    return { kind = "item", itemId = reward.itemId, name = reward.name, count = reward.count }
  end
  return nil
end

-- A `tiers` map: only the five known tiers are kept, each a list of at most PVP_PRIZE_ENTRIES_MAX rewards.
function PvPSeasonModel.ValidateTiers(tiers)
  if type(tiers) ~= "table" then
    return bad("tiers")
  end
  local clean = {}
  for _, tier in ipairs(ns.Constants.PVP_PRIZE_TIERS) do
    local rewards = tiers[tier]
    if rewards ~= nil then
      if type(rewards) ~= "table" or #rewards > ns.Constants.PVP_PRIZE_ENTRIES_MAX then
        return bad("tiers")
      end
      clean[tier] = {}
      for index, reward in ipairs(rewards) do
        clean[tier][index] = validateReward(reward)
        if not clean[tier][index] then
          return bad("tiers")
        end
      end
    end
  end
  return clean
end

function PvPSeasonModel.ValidatePrizes(fields)
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not isId(fields.seasonId) then
    return bad("id")
  end
  local tiers, reason = PvPSeasonModel.ValidateTiers(fields.tiers)
  if not tiers then
    return nil, reason
  end
  if not (isRev(fields.rev) and isTime(fields.updatedAt)) then
    return bad("rev")
  end
  return { seasonId = fields.seasonId, tiers = tiers, rev = fields.rev, updatedAt = fields.updatedAt }
end

function PvPSeasonModel.ValidateOfficer(fields)
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not PvPSeasonModel.IsPlayer(fields.player) then
    return bad("player")
  end
  if type(fields.intervals) ~= "table" or #fields.intervals > ns.Constants.PVP_OFFICER_INTERVALS_MAX then
    return bad("intervals")
  end
  local intervals = {}
  local previousEnd = 0
  for index, interval in ipairs(fields.intervals) do
    if type(interval) ~= "table" or not isTime(interval.from) or interval.from < previousEnd then
      return bad("intervals")
    end
    if interval.to == nil then
      -- Only the last interval can still be open.
      if index ~= #fields.intervals then
        return bad("intervals")
      end
      intervals[index] = { from = interval.from }
    else
      if not (isTime(interval.to) and interval.to >= interval.from) then
        return bad("intervals")
      end
      intervals[index] = { from = interval.from, to = interval.to }
      previousEnd = interval.to
    end
  end
  if not (isRev(fields.rev) and isTime(fields.updatedAt)) then
    return bad("rev")
  end
  return { player = fields.player, intervals = intervals, rev = fields.rev, updatedAt = fields.updatedAt }
end

-- The tier a prize of the delivery list belongs to.
function PvPSeasonModel.IsTier(tier)
  for _, known in ipairs(ns.Constants.PVP_PRIZE_TIERS) do
    if tier == known then
      return true
    end
  end
  return false
end

function PvPSeasonModel.ValidateDelivery(fields)
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not (isId(fields.seasonId) and PvPSeasonModel.IsPlayer(fields.player)) then
    return bad("ref")
  end
  if not PvPSeasonModel.IsTier(fields.tier) then
    return bad("tier")
  end
  if type(fields.delivered) ~= "boolean" then
    return bad("delivered")
  end
  if not (isRev(fields.rev) and isTime(fields.updatedAt)) then
    return bad("rev")
  end
  return {
    seasonId = fields.seasonId,
    player = fields.player,
    tier = fields.tier,
    delivered = fields.delivered,
    rev = fields.rev,
    updatedAt = fields.updatedAt,
  }
end

function PvPSeasonModel.ValidateFinal(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return bad("fields")
  end
  if not isId(fields.seasonId) then
    return bad("id")
  end
  if not isCleanText(fields.name, constants.PVP_SEASON_NAME_MAX) then
    return bad("name")
  end
  if
    not (
      isTime(fields.startsAt)
      and isTime(fields.endsAt)
      and fields.endsAt > fields.startsAt
      and isTime(fields.closedAt)
    )
  then
    return bad("dates")
  end
  if type(fields.standings) ~= "table" or #fields.standings > constants.PVP_FINAL_STANDINGS_MAX then
    return bad("standings")
  end
  local standings, seen = {}, {}
  local highest = constants.PVP_GRANTS_MAX * constants.PVP_MISSION_POINTS_MAX
  for index, row in ipairs(fields.standings) do
    if
      not (
        type(row) == "table"
        and row.pos == index
        and PvPSeasonModel.IsPlayer(row.player)
        and not seen[row.player]
        and isInt(row.points, constants.PVP_MIN_POINTS, highest)
        and isTime(row.lastAt)
      )
    then
      return bad("standings")
    end
    seen[row.player] = true
    standings[index] = { pos = index, player = row.player, points = row.points, lastAt = row.lastAt }
  end
  local prizes, reason = PvPSeasonModel.ValidateTiers(fields.prizes == nil and {} or fields.prizes)
  if not prizes then
    return nil, reason
  end
  return {
    seasonId = fields.seasonId,
    name = fields.name,
    startsAt = fields.startsAt,
    endsAt = fields.endsAt,
    closedAt = fields.closedAt,
    standings = standings,
    prizes = prizes,
  }
end

---------------------------------------------------------------------------------------------------------------------
-- Officers
---------------------------------------------------------------------------------------------------------------------

-- Is `officer` (a record, or nil) an officer at time `at`? Both ends of an interval count: a grant stamped at the
-- very moment the flag was taken away still stands.
function PvPSeasonModel.IsOfficerAt(officer, at)
  if type(officer) ~= "table" or type(officer.intervals) ~= "table" or type(at) ~= "number" then
    return false
  end
  for _, interval in ipairs(officer.intervals) do
    if at >= interval.from and (interval.to == nil or at <= interval.to) then
      return true
    end
  end
  return false
end

-- An open interval: the flag is on right now.
function PvPSeasonModel.IsOfficer(officer)
  if type(officer) ~= "table" or type(officer.intervals) ~= "table" then
    return false
  end
  local last = officer.intervals[#officer.intervals]
  return last ~= nil and last.to == nil
end

-- The intervals after switching the flag on or off at `now`, or nil plus "unchanged" (it was in that state already)
-- or "limit" (no room for another interval). Closed intervals that ended before `keepFrom` (the start of the active
-- season: no grant of it can fall there) are dropped first to make room.
function PvPSeasonModel.ToggleIntervals(intervals, on, now, keepFrom)
  local open = #intervals > 0 and intervals[#intervals].to == nil
  if on == open then
    return nil, "unchanged"
  end
  local result = {}
  for _, interval in ipairs(intervals) do
    if interval.to == nil or interval.to >= (keepFrom or 0) then
      result[#result + 1] = { from = interval.from, to = interval.to }
    end
  end
  if on then
    if #result >= ns.Constants.PVP_OFFICER_INTERVALS_MAX then
      return nil, "limit"
    end
    result[#result + 1] = { from = now }
  else
    result[#result].to = now
  end
  return result
end

---------------------------------------------------------------------------------------------------------------------
-- Ranking
---------------------------------------------------------------------------------------------------------------------

-- The tier of a position (1..10), or nil: 1, 2, 3, "4-6", "7-10".
function PvPSeasonModel.TierOf(position)
  if type(position) ~= "number" or position < 1 or position > 10 or position % 1 ~= 0 then
    return nil
  end
  if position <= 3 then
    return tostring(position)
  elseif position <= 6 then
    return "4-6"
  end
  return "7-10"
end

-- The positions a tier covers: first, last.
function PvPSeasonModel.TierRange(tier)
  if tier == "4-6" then
    return 4, 6
  elseif tier == "7-10" then
    return 7, 10
  end
  local position = tonumber(tier)
  if position and position >= 1 and position <= 3 then
    return position, position
  end
  return nil
end

-- Does the author of a grant count? Only gm and cogm: the PvP officer flag gives no power any more.
function PvPSeasonModel.GrantCounts(grant, roleOf)
  local by = grant.by
  if type(by) ~= "string" or roleOf == nil then
    return false
  end
  return ns.PermissionService.IsGlobal(roleOf(by))
end

-- A void counts when gm or cogm wrote it.
function PvPSeasonModel.VoidCounts(void, roleOf)
  return type(void) == "table"
    and type(void.by) == "string"
    and roleOf ~= nil
    and ns.PermissionService.IsGlobal(roleOf(void.by))
end

local function compareRows(a, b)
  if a.points ~= b.points then
    return a.points > b.points
  end
  if a.lastAt ~= b.lastAt then
    return a.lastAt < b.lastAt
  end
  local left, right = a.player:lower(), b.player:lower()
  if left ~= right then
    return left < right
  end
  return a.player < b.player
end

-- The ranking of a season, derived from its grants (plan 1.8). `grants` and `voids` are maps or lists of the records
-- stored by PvPSeasonSync (each grant with its `by`), `_officers` unused (the PvP officer flag gives no power any
-- more), `roleOf(name)` the role of an author according to the guild roster. With `seasonId` only the grants of that
-- season are read.
-- Returns a list of { pos, player, points, lastAt, tier } best first; a player with no points is not ranked, and
-- `tier` is nil past position 10. Ties on points go to whoever reached the total first (earlier `lastAt`), then name.
function PvPSeasonModel.Standings(grants, voids, _officers, roleOf, seasonId)
  local totals, rows = {}, {}
  for _, grant in pairs(grants or {}) do
    local voided = voids and voids[grant.id]
    if
      (seasonId == nil or grant.seasonId == seasonId)
      and PvPSeasonModel.GrantCounts(grant, roleOf)
      and not (voided and PvPSeasonModel.VoidCounts(voided, roleOf))
    then
      local row = totals[grant.player]
      if not row then
        row = { player = grant.player, points = 0, lastAt = 0 }
        totals[grant.player] = row
        rows[#rows + 1] = row
      end
      row.points = row.points + grant.points
      if grant.at > row.lastAt then
        row.lastAt = grant.at
      end
    end
  end
  local ranked = {}
  for _, row in ipairs(rows) do
    if row.points >= ns.Constants.PVP_MIN_POINTS then
      ranked[#ranked + 1] = row
    end
  end
  table.sort(ranked, compareRows)
  for position, row in ipairs(ranked) do
    row.pos = position
    row.tier = PvPSeasonModel.TierOf(position)
  end
  return ranked
end

-- The all-time ranking from the final standings (`finals` = map or list of final records): points, seasons played and
-- podiums (positions 1 to 3) per player, most points first, then most podiums, then name.
function PvPSeasonModel.Cumulative(finals)
  local byPlayer, rows = {}, {}
  for _, final in pairs(finals or {}) do
    for _, standing in ipairs(final.standings or {}) do
      local row = byPlayer[standing.player]
      if not row then
        row = { player = standing.player, points = 0, seasons = 0, podiums = 0 }
        byPlayer[standing.player] = row
        rows[#rows + 1] = row
      end
      row.points = row.points + standing.points
      row.seasons = row.seasons + 1
      if standing.pos <= 3 then
        row.podiums = row.podiums + 1
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.points ~= b.points then
      return a.points > b.points
    end
    if a.podiums ~= b.podiums then
      return a.podiums > b.podiums
    end
    return a.player:lower() < b.player:lower() or (a.player:lower() == b.player:lower() and a.player < b.player)
  end)
  for position, row in ipairs(rows) do
    row.pos = position
  end
  return rows
end

-- The final standing as one guild message can carry it: the same record with its standings cut from the tail, ten rows
-- at a time and never below the ten that win a prize, until `fits(final)` (a function that encodes it and says whether
-- it is small enough) is true. Returns the record and whether all the rows were kept; the input is not changed.
function PvPSeasonModel.FitFinal(final, fits)
  local count = #final.standings
  while true do
    local rows = {}
    for index = 1, count do
      rows[index] = final.standings[index]
    end
    local candidate = {}
    for key, value in pairs(final) do
      candidate[key] = value
    end
    candidate.standings = rows
    if count <= 10 or fits(candidate) then
      return candidate, count == #final.standings
    end
    count = math.max(10, count - 10)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Digest
---------------------------------------------------------------------------------------------------------------------

-- Adler-32 of the sorted `tokens` (a list of strings) joined with newlines, as 8 hex digits. Two clients holding the
-- same tokens get the same digest whatever order they hold them in. Plain arithmetic, so no `bit` library is needed.
function PvPSeasonModel.Digest(tokens)
  local sorted = {}
  for index, token in ipairs(tokens) do
    sorted[index] = token
  end
  table.sort(sorted)
  local a, b = 1, 0
  for _, token in ipairs(sorted) do
    local text = token .. "\n"
    for index = 1, #text do
      a = (a + text:byte(index)) % 65521
      b = (b + a) % 65521
    end
  end
  return ("%04x%04x"):format(b, a)
end

ns.PvPSeasonModel = PvPSeasonModel
