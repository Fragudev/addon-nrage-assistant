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

local function validatePvPReset(payload)
  if not (ns.EventModel.IsCharacterKey(payload.target) and isInt(payload.rev, 1, MAX_REV)) then
    return nil
  end
  return { target = payload.target, rev = payload.rev }
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
  SYNC_REQ = validateSyncReq,
  SYNC_DATA = validateSyncData,
  EVENT_UPSERT = validateEventUpsert,
  ATTENDANCE_UPSERT = validateAttendanceUpsert,
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
