local _, ns = ...

-- Message envelope and payload validation.
--   { v = major, m = minor, t = type, id = messageId, p = payload }
-- Everything received is hostile input: only whitelisted types and fields survive, values are
-- bounds-checked, unknown fields are dropped, and strings carrying escape sequences are rejected
-- (so a message can never smuggle colour codes or links into the UI).
-- HELLO and PROFILE are the phase 1 messages; the raid operations and the PvP counters follow below.
local Protocol = {}

local MAX_VERSION_LENGTH = 32
local MAX_CLASS_LENGTH = 20
local MAX_PROFESSIONS = 8
local MAX_PROFESSION_NAME = 40
local MAX_REV = 2147483647

local isInt, isText, isId = ns.Validate.Int, ns.Validate.Text, ns.Validate.Id

local function validateHello(payload)
  if not isText(payload.version, MAX_VERSION_LENGTH) then
    return nil
  end
  return { version = payload.version }
end

local function validateProfessions(list)
  if type(list) ~= "table" or #list > MAX_PROFESSIONS then
    return nil
  end
  local clean = {}
  for index, entry in ipairs(list) do
    if type(entry) ~= "table" or not isText(entry.name, MAX_PROFESSION_NAME) or not isInt(entry.skill, 0, 1000) then
      return nil
    end
    local profession = { name = entry.name, skill = entry.skill }
    if entry.max ~= nil then
      if not isInt(entry.max, 0, 1000) then
        return nil
      end
      profession.max = entry.max
    end
    -- Protocol 1.5: secondary professions (cooking, fishing, archaeology) say so. An older client leaves it out.
    if entry.secondary ~= nil then
      if entry.secondary ~= true then
        return nil
      end
      profession.secondary = true
    end
    clean[index] = profession
  end
  return clean
end

local function validateFields(fields)
  if type(fields) ~= "table" then
    return nil
  end
  local clean = {}
  for key in pairs(ns.Constants.MANUAL_FIELDS) do
    local value = fields[key]
    if value ~= nil then
      if not isText(value, ns.Constants.MAX_FIELD_LENGTH) then
        return nil
      end
      clean[key] = value
    end
  end
  return clean
end

local function validateProfile(payload)
  if not isInt(payload.rev, 0, MAX_REV) then
    return nil
  end
  if not (isText(payload.class, MAX_CLASS_LENGTH) and payload.class:find("^%u+$")) then
    return nil
  end
  if not isInt(payload.level, 1, 999) then
    return nil
  end

  local clean = { rev = payload.rev, class = payload.class, level = payload.level }

  if payload.ilvl ~= nil then
    if not isInt(payload.ilvl, 0, 2000) then
      return nil
    end
    clean.ilvl = payload.ilvl
  end
  if payload.professions ~= nil then
    clean.professions = validateProfessions(payload.professions)
    if not clean.professions then
      return nil
    end
  end
  if payload.fields ~= nil then
    clean.fields = validateFields(payload.fields)
    if not clean.fields then
      return nil
    end
  end
  return clean
end

-- Raid operations (phase 2). Editing authority is NOT decided here: the receiver checks the
-- sender's role from its own guild roster. `recordedBy`/`updatedBy` are never taken from the
-- payload either; they come from the sender of the message.
local MAX_TIMESTAMP = 4102444800 -- 2100-01-01

local function validateRevision(payload)
  return isInt(payload.rev, 1, MAX_REV) and isInt(payload.updatedAt, 0, MAX_TIMESTAMP)
end

local function validateEventUpsert(payload)
  if not (isId(payload.eventId) and validateRevision(payload)) then
    return nil
  end
  local fields = ns.EventModel.ValidateEvent(payload)
  if not fields then
    return nil
  end
  fields.eventId, fields.rev, fields.updatedAt = payload.eventId, payload.rev, payload.updatedAt
  return fields
end

local function validateAttendanceUpsert(payload)
  if not (isId(payload.eventId) and validateRevision(payload)) then
    return nil
  end
  if not (ns.EventModel.IsCharacterKey(payload.characterKey) and ns.EventModel.IsAttendanceState(payload.state)) then
    return nil
  end
  return {
    eventId = payload.eventId,
    characterKey = payload.characterKey,
    state = payload.state,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
  }
end

local function validateSignupUpsert(payload)
  if not (isId(payload.eventId) and validateRevision(payload)) then
    return nil
  end
  if not (ns.EventModel.IsCharacterKey(payload.characterKey) and ns.EventModel.IsSignupStatus(payload.status)) then
    return nil
  end
  return {
    eventId = payload.eventId,
    characterKey = payload.characterKey,
    status = payload.status,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
  }
end

local function validateAssignUpsert(payload)
  if not (isId(payload.eventId) and isId(payload.assignmentId) and validateRevision(payload)) then
    return nil
  end
  local fields = ns.EventModel.ValidateAssignment(payload)
  if not fields then
    return nil
  end
  fields.eventId, fields.assignmentId = payload.eventId, payload.assignmentId
  fields.rev, fields.updatedAt = payload.rev, payload.updatedAt
  return fields
end

local DELETE_KINDS = { event = true, assignment = true }

local function validateDelete(payload)
  if not (type(payload.kind) == "string" and DELETE_KINDS[payload.kind]) then
    return nil
  end
  if not (isId(payload.eventId) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  local clean = { kind = payload.kind, eventId = payload.eventId, rev = payload.rev }
  if payload.kind == "assignment" then
    if not isId(payload.assignmentId) then
      return nil
    end
    clean.assignmentId = payload.assignmentId
  end
  return clean
end

-- Loot council. As with the raid operations, authority is not in the payload and neither is the
-- author: a candidate or a voter is always the sender.
local function validateLootSession(payload)
  if not (isId(payload.eventId) and isId(payload.sessionId) and validateRevision(payload)) then
    return nil
  end
  local item = ns.LootModel.ValidateItem(payload)
  if not item or not (payload.status == "open" or payload.status == "closed") then
    return nil
  end
  return {
    eventId = payload.eventId,
    sessionId = payload.sessionId,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
    itemId = item.itemId,
    itemName = item.itemName,
    status = payload.status,
  }
end

local function validateLootAward(payload)
  if not (isId(payload.eventId) and isId(payload.sessionId) and validateRevision(payload)) then
    return nil
  end
  local item = ns.LootModel.ValidateItem(payload)
  if not (item and ns.LootModel.IsCharacterKey(payload.characterKey) and ns.LootModel.IsReason(payload.reason)) then
    return nil
  end
  return {
    eventId = payload.eventId,
    sessionId = payload.sessionId,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
    itemId = item.itemId,
    itemName = item.itemName,
    characterKey = payload.characterKey,
    reason = payload.reason,
  }
end

local function validateLootCandidate(payload)
  if not (isId(payload.eventId) and isId(payload.sessionId) and validateRevision(payload)) then
    return nil
  end
  local candidate = ns.LootModel.ValidateCandidate(payload)
  if not candidate then
    return nil
  end
  return {
    eventId = payload.eventId,
    sessionId = payload.sessionId,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
    spec = candidate.spec,
    need = candidate.need,
    upgrade = candidate.upgrade,
  }
end

local function validateLootVote(payload)
  if not (isId(payload.eventId) and isId(payload.sessionId) and validateRevision(payload)) then
    return nil
  end
  if not ns.LootModel.IsCharacterKey(payload.target) then
    return nil
  end
  return {
    eventId = payload.eventId,
    sessionId = payload.sessionId,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
    target = payload.target,
  }
end

-- PvP counters. As with PROFILE, the record belongs to the sender: there is no name in PVP_STATS, and a member
-- can only ever publish their own. A reset names its target but is accepted from an admin only.
local function validatePair(pair)
  if type(pair) ~= "table" then
    return nil
  end
  local high = ns.Constants.PVP_MAX_KILLS
  if not (isInt(pair.world, 0, high) and isInt(pair.bg, 0, high)) then
    return nil
  end
  return { world = pair.world, bg = pair.bg }
end

local function validateDay(day)
  if type(day) ~= "string" then
    return false
  end
  local year, month, date = day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false
  end
  year, month, date = tonumber(year), tonumber(month), tonumber(date)
  return year >= 2000 and year <= 2100 and month >= 1 and month <= 12 and date >= 1 and date <= 31
end

local function validatePvPStats(payload)
  if not validateRevision(payload) then
    return nil
  end
  local clean = { rev = payload.rev, updatedAt = payload.updatedAt, honor = validatePair(payload.honor) }
  if not clean.honor then
    return nil
  end
  -- Killing blows are left out by a client that cannot read the combat log.
  if payload.blows ~= nil then
    clean.blows = validatePair(payload.blows)
    if not clean.blows then
      return nil
    end
  end

  local today = payload.today
  if type(today) ~= "table" or not validateDay(today.day) then
    return nil
  end
  clean.today = { day = today.day, honor = validatePair(today.honor) }
  if not clean.today.honor then
    return nil
  end
  if today.blows ~= nil then
    clean.today.blows = validatePair(today.blows)
    if not clean.today.blows then
      return nil
    end
  end
  return clean
end

-- A kill for the guild feed. The killer is the sender of the message; the payload names only the victim. The
-- victim is plain text like any other name (no escapes), `where` one of two places and `blow` a real boolean.
local function validatePvPKill(payload)
  if not isText(payload.victim, ns.Constants.PVP_FEED_VICTIM_MAX) then
    return nil
  end
  if payload.where ~= "world" and payload.where ~= "bg" then
    return nil
  end
  if type(payload.blow) ~= "boolean" then
    return nil
  end
  return { victim = payload.victim, where = payload.where, blow = payload.blow }
end

-- Guild blacklist. The author is the sender, so the payload has no field for it. A name has to be the one the
-- blacklist would keep (BlacklistService.Validate: no realm suffix, trimmed, no escapes), and the key is only
-- bounded here: the receiver works it out again from the name (BlacklistSync).
local function validateBlacklistKey(key)
  return isText(key, ns.Constants.BLACKLIST_NAME_MAX) and not key:find(":", 1, true)
end

local function validateBlacklistUpsert(payload)
  if not (validateBlacklistKey(payload.key) and validateRevision(payload)) then
    return nil
  end
  local clean = ns.BlacklistService.Validate(payload.name, payload.reason)
  if not (clean and clean.name == payload.name and clean.reason == payload.reason) then
    return nil
  end
  return {
    key = payload.key,
    name = clean.name,
    reason = clean.reason,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
  }
end

local function validateBlacklistDelete(payload)
  if not (validateBlacklistKey(payload.key) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { key = payload.key, rev = payload.rev }
end

-- Guild Kill On Sight list. Like the blacklist, the author is the sender, so the payload has no field for it, and the
-- key is only bounded here: the receiver works it out again from the name (GuildKosSync). The name, category and
-- reason have to be what IntelModel.ValidateKos would keep; the reason is optional.
local function validateKosKey(key)
  return isText(key, ns.Constants.INTEL_NAME_MAX) and not key:find(":", 1, true)
end

local function validateKosUpsert(payload)
  if not (validateKosKey(payload.key) and validateRevision(payload)) then
    return nil
  end
  local clean = ns.IntelModel.ValidateKos({ name = payload.name, category = payload.category, reason = payload.reason })
  if
    not (clean and clean.name == payload.name and payload.category == clean.category and clean.reason == payload.reason)
  then
    return nil
  end
  return {
    key = payload.key,
    name = clean.name,
    category = clean.category,
    reason = clean.reason,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
  }
end

local function validateKosDelete(payload)
  if not (validateKosKey(payload.key) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { key = payload.key, rev = payload.rev }
end

local function validatePvPReset(payload)
  if not (ns.EventModel.IsCharacterKey(payload.target) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { target = payload.target, rev = payload.rev }
end

-- Layers. LAYER_STATE is the sender's own layer (`layer = 0` means "forget me"); LAYER_SWAP is one step of a swap.
-- Neither names who acts: the actor is always the sender. Only the helper of an `assign` is named, and it is
-- plain text like any character name.
local SWAP_STEPS = { request = true, offer = true, assign = true, close = true }
local SWAP_OUTCOMES = { done = true, expired = true, cancelled = true, declined = true, unconfirmed = true }

local function validateLayerState(payload)
  local constants = ns.Constants
  if not (isInt(payload.map, 0, constants.LAYER_MAP_MAX) and isInt(payload.layer, 0, constants.LAYER_ID_MAX)) then
    return nil
  end
  return { map = payload.map, layer = payload.layer }
end

local function validateLayerSwap(payload)
  local constants = ns.Constants
  local step = payload.s
  if not (isId(payload.rid) and type(step) == "string" and SWAP_STEPS[step]) then
    return nil
  end
  local clean = { rid = payload.rid, s = step }
  if step == "request" then
    if not (isInt(payload.map, 0, constants.LAYER_MAP_MAX) and isInt(payload.layer, 1, constants.LAYER_ID_MAX)) then
      return nil
    end
    clean.map, clean.layer = payload.map, payload.layer
  elseif step == "assign" then
    if not ns.EventModel.IsCharacterKey(payload.helper) then
      return nil
    end
    clean.helper = payload.helper
  elseif step == "close" then
    if not (type(payload.o) == "string" and SWAP_OUTCOMES[payload.o]) then
      return nil
    end
    clean.o = payload.o
  end
  return clean
end

-- The readiness rules of one roster: the whole set, validated rule by rule (ReadinessRules.Validate).
local function validateRosterRules(payload)
  if not (isId(payload.rosterId) and validateRevision(payload)) then
    return nil
  end
  local rules = ns.ReadinessRules.Validate(payload.rules)
  if not rules then
    return nil
  end
  return { rosterId = payload.rosterId, rev = payload.rev, updatedAt = payload.updatedAt, rules = rules }
end

-- Raid rosters and the roster assignments (protocol 1.5). Who may send them is decided by the receiver from its own
-- guild roster (RosterSync).
local function validateRosterUpsert(payload)
  if not (isId(payload.rosterId) and validateRevision(payload)) then
    return nil
  end
  local name = ns.RosterService.CleanName(payload.name)
  if not (name and name == payload.name) then
    return nil
  end
  return { rosterId = payload.rosterId, name = name, rev = payload.rev, updatedAt = payload.updatedAt }
end

local function validateRosterDelete(payload)
  if not (isId(payload.rosterId) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { rosterId = payload.rosterId, rev = payload.rev }
end

local function validateMemberUpsert(payload)
  if not (ns.RosterService.IsMemberKey(payload.key) and validateRevision(payload)) then
    return nil
  end
  -- Older clients also sent the addon role they assigned. The role is the guild rank now: it is tolerated, not kept.
  if payload.role ~= nil and not ns.Validate.Text(payload.role, 16) then
    return nil
  end
  local clean = { key = payload.key, rev = payload.rev, updatedAt = payload.updatedAt }
  if payload.rosterId ~= nil then
    if not isId(payload.rosterId) then
      return nil
    end
    clean.rosterId = payload.rosterId
  end
  return clean
end

local function validateMemberDelete(payload)
  if not (ns.RosterService.IsMemberKey(payload.key) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { key = payload.key, rev = payload.rev }
end

-- The recipes of a member (protocol 1.5): one profession list in `parts` messages. The record belongs to the sender, so
-- there is no name of a member in it. Every id is a whole number in range and appears once in the message.
local function validateRecipes(payload)
  local constants = ns.Constants
  if not (isInt(payload.prof, 1, constants.RECIPE_PROFESSION_ID_MAX) and validateRevision(payload)) then
    return nil
  end
  if not isInt(payload.parts, 1, constants.RECIPE_PARTS_MAX) or not isInt(payload.part, 1, payload.parts) then
    return nil
  end
  if type(payload.ids) ~= "table" or #payload.ids > constants.RECIPE_CHUNK then
    return nil
  end
  local ids, seen = {}, {}
  for index, id in ipairs(payload.ids) do
    if not isInt(id, 1, constants.RECIPE_ID_MAX) or seen[id] then
      return nil
    end
    seen[id] = true
    ids[index] = id
  end
  local clean = {
    prof = payload.prof,
    rev = payload.rev,
    updatedAt = payload.updatedAt,
    part = payload.part,
    parts = payload.parts,
    ids = ids,
  }
  if payload.name ~= nil then
    if not isText(payload.name, MAX_PROFESSION_NAME) then
      return nil
    end
    clean.name = payload.name
  end
  if payload.total ~= nil then
    if not isInt(payload.total, 0, constants.RECIPES_MAX_PER_PROFESSION) then
      return nil
    end
    clean.total = payload.total
  end
  return clean
end

-- PvP seasons (protocol 1.7). Every record is validated by PvPSeasonModel; who may author it is decided by the receiver
-- (PvPSeasonSync) from its own guild roster and officer records. `by` never travels in a payload: it is the sender, or
-- the author named by the item of a ledger catch-up from a trusted relay.
local function seasonValidator(name)
  return function(payload)
    return (ns.PvPSeasonModel[name](payload))
  end
end

-- The ledger request: how many ledger records the requester holds for a season and their digest.
local function validateLedgerReq(payload)
  if payload.seasonId ~= nil and not isId(payload.seasonId) then
    return nil
  end
  if
    not (
      isInt(payload.count, 0, 1000000)
      and type(payload.digest) == "string"
      and payload.digest:find("^%x%x%x%x%x%x%x%x$")
    )
  then
    return nil
  end
  return { seasonId = payload.seasonId, count = payload.count, digest = payload.digest }
end

-- One page of a ledger catch-up. As with SYNC_DATA only the size is checked here: each item is validated by its own
-- validator when it is applied.
local function validateLedgerData(payload)
  local constants = ns.Constants
  if payload.seasonId ~= nil and not isId(payload.seasonId) then
    return nil
  end
  if not (isInt(payload.pages, 1, constants.PVP_LEDGER_PAGES_MAX) and isInt(payload.page, 1, payload.pages)) then
    return nil
  end
  if type(payload.items) ~= "table" or #payload.items > constants.PVP_LEDGER_PAGE_ITEMS then
    return nil
  end
  return { seasonId = payload.seasonId, page = payload.page, pages = payload.pages, items = payload.items }
end

-- Snapshot for late joiners. SYNC_REQ carries nothing. SYNC_DATA carries a list of raid messages
-- ({ t, p } items); only its size is checked here, because each item is validated on its own, by
-- its own validator, when it is applied.
local function validateSyncReq()
  return {}
end

local function validateSyncData(payload)
  if type(payload.items) ~= "table" or #payload.items > ns.Constants.IMPORT_MAX_ITEMS then
    return nil
  end
  return { items = payload.items }
end

local VALIDATORS = {
  HELLO = validateHello,
  PROFILE = validateProfile,
  LOOT_SESSION = validateLootSession,
  LOOT_AWARD = validateLootAward,
  LOOT_CANDIDATE = validateLootCandidate,
  LOOT_VOTE = validateLootVote,
  PVP_STATS = validatePvPStats,
  PVP_RESET = validatePvPReset,
  PVP_KILL = validatePvPKill,
  BLACKLIST_UPSERT = validateBlacklistUpsert,
  BLACKLIST_DELETE = validateBlacklistDelete,
  KOS_UPSERT = validateKosUpsert,
  KOS_DELETE = validateKosDelete,
  ROSTER_RULES = validateRosterRules,
  LAYER_STATE = validateLayerState,
  LAYER_SWAP = validateLayerSwap,
  RECIPES = validateRecipes,
  PVP_SEASON = seasonValidator("ValidateSeason"),
  PVP_MISSION = seasonValidator("ValidateMission"),
  PVP_PRIZES = seasonValidator("ValidatePrizes"),
  PVP_OFFICER = seasonValidator("ValidateOfficer"),
  PVP_CLAIM = seasonValidator("ValidateClaim"),
  PVP_REJECT = seasonValidator("ValidateReject"),
  PVP_GRANT = seasonValidator("ValidateGrant"),
  PVP_VOID = seasonValidator("ValidateVoid"),
  PVP_DELIVERY = seasonValidator("ValidateDelivery"),
  PVP_FINAL = seasonValidator("ValidateFinal"),
  PVP_LEDGER_REQ = validateLedgerReq,
  PVP_LEDGER_DATA = validateLedgerData,
  ROSTER_UPSERT = validateRosterUpsert,
  ROSTER_DELETE = validateRosterDelete,
  MEMBER_UPSERT = validateMemberUpsert,
  MEMBER_DELETE = validateMemberDelete,
  SYNC_REQ = validateSyncReq,
  SYNC_DATA = validateSyncData,
  EVENT_UPSERT = validateEventUpsert,
  ATTENDANCE_UPSERT = validateAttendanceUpsert,
  SIGNUP_UPSERT = validateSignupUpsert,
  ASSIGN_UPSERT = validateAssignUpsert,
  DELETE = validateDelete,
}

function Protocol.Build(messageType, payload, id)
  local constants = ns.Constants
  return {
    v = constants.PROTOCOL_MAJOR,
    m = constants.PROTOCOL_MINOR,
    t = messageType,
    id = id,
    p = payload,
  }
end

-- Returns a clean message { v, m, t, id, p }, or nil plus a reason:
-- "not_table" | "bad_version" | "incompatible_version" | "unknown_type" | "bad_id" | "bad_payload".
function Protocol.Validate(message)
  if type(message) ~= "table" then
    return nil, "not_table"
  end
  if not (isInt(message.v, 1, 255) and isInt(message.m, 0, 255)) then
    return nil, "bad_version"
  end
  if message.v ~= ns.Constants.PROTOCOL_MAJOR then
    return nil, "incompatible_version"
  end

  local validator = type(message.t) == "string" and VALIDATORS[message.t]
  if not validator then
    return nil, "unknown_type"
  end
  if not isId(message.id) then
    return nil, "bad_id"
  end
  if type(message.p) ~= "table" then
    return nil, "bad_payload"
  end

  local payload = validator(message.p)
  if not payload then
    return nil, "bad_payload"
  end
  return { v = message.v, m = message.m, t = message.t, id = message.id, p = payload }
end

ns.Protocol = Protocol
