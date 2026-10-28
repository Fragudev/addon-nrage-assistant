local _, ns = ...

-- Applies received raid operations to local data, and builds the payloads for local changes.
--
-- Authority: the sender's role comes from the receiver's own guild roster (`role`), never from the
-- message. `updatedBy`/`recordedBy` are always the message sender.
--
-- Conflicts: for the same record the higher `rev` wins; on equal `rev` the later `updatedAt`
-- (server time, clamped so a sender cannot date an edit in the future to always win); on a tie the
-- lexicographically larger sender. An identical record is a no-op. A DELETE leaves a tombstone,
-- and any upsert whose `rev` does not exceed the tombstone's is dropped, so a stale edit cannot
-- resurrect deleted data (on a tie the delete wins).
--
-- ctx = { events = db.global.events, tombstones = db.global.sync.tombstones, now = function() }
-- Rosters: a raid leader only changes the events of their own roster, and the receiver checks it with the roster it
-- holds for the sender (`ctx.members` and `ctx.rosters`, or `ctx.rosterOf(sender)`); the guild master changes any.
-- An event without a roster (legacy, or from a client that does not know rosters) stays open to the members who have a
-- roster until the guild master gives it one.
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "other_roster" | "unknown_event" | "stale" | "tombstoned" | "limit" |
--   "unsupported"
local EventSync = {}

local Rules = ns.SyncRules
local countKeys, authorize, clampTimestamp = Rules.CountKeys, Rules.Authorize, Rules.ClampTimestamp
local wins, blockedByTombstone = Rules.Wins, Rules.BlockedByTombstone

-- nil when `sender` (with `role`) may manage an event of `eventRosterId`, else "other_roster".
local function rosterGuard(ctx, sender, role, eventRosterId)
  local senderRoster = ns.RosterService.SenderRoster(ctx, sender)
  if ns.RosterService.MayAct(role, senderRoster, eventRosterId) then
    return nil
  end
  return "other_roster"
end
EventSync.RosterGuard = rosterGuard

local function applyEventUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "raid_manage")
  if denied then
    return false, denied
  end

  local key = "E:" .. payload.eventId
  if blockedByTombstone(ctx, key, payload.rev) then
    return false, "tombstoned"
  end

  local event = ctx.events[payload.eventId]
  -- The event as it stands, and the event as the message would leave it, both have to be of the sender's roster.
  if event then
    local blocked = rosterGuard(ctx, sender, role, event.rosterId)
    if blocked then
      return false, blocked
    end
  end
  -- What the message says about the roster has to be the sender's own: a raid leader cannot move an event to another
  -- roster, and a new event has to say it is of theirs. A message with no roster is only fine for an event that already
  -- has one (an older client editing it).
  if not ns.PermissionService.IsGlobal(role) then
    local senderRoster = ns.RosterService.SenderRoster(ctx, sender)
    if (payload.rosterId ~= nil and payload.rosterId ~= senderRoster) or (payload.rosterId == nil and not event) then
      return false, "other_roster"
    end
  end
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if event then
    if not wins(payload.rev, updatedAt, sender, event) then
      return false, "stale"
    end
  else
    if countKeys(ctx.events) >= ns.Constants.EVENT_MAX then
      return false, "limit"
    end
    event = { eventId = payload.eventId, attendance = {}, signups = {}, assignments = {}, loot = {} }
    ctx.events[payload.eventId] = event
  end

  -- An upsert carries the whole event: fields it omits are cleared.
  event.title = payload.title
  event.instance = payload.instance
  event.startAt = payload.startAt
  event.status = payload.status or "planned"
  -- A message that leaves the roster out (a client that does not know rosters) keeps the one the event has.
  event.rosterId = payload.rosterId or event.rosterId
  event.rev = payload.rev
  event.updatedAt = updatedAt
  event.updatedBy = sender
  event.source = "received"
  ctx.tombstones[key] = nil
  return true
end

local function applyAttendanceUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "raid_manage")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
  end
  local blocked = rosterGuard(ctx, sender, role, event.rosterId)
  if blocked then
    return false, blocked
  end

  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local record = event.attendance[payload.characterKey]
  if record then
    if not wins(payload.rev, updatedAt, sender, record) then
      return false, "stale"
    end
  else
    if countKeys(event.attendance) >= ns.Constants.EVENT_ATTENDANCE_MAX then
      return false, "limit"
    end
    record = {}
    event.attendance[payload.characterKey] = record
  end

  record.state = payload.state
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  record.recordedBy = sender
  record.source = "received"
  return true
end

-- A player's own sign-up. The character is the sender: nobody answers for somebody else. The one exception is an item
-- of a snapshot (`ctx.relay`, set by Transfer.ApplyItems and never by a live message): a leader (raid_manage) passes it
-- on, and then the character's own rank and roster are the ones read from this client's records (`ctx.roleOf`).
-- The time lock of the sign-up is not enforced here: a received answer may be old (a snapshot, a queued message) and
-- clocks differ, while the answer can only come from its own character and is bounded by Wins and ClampTimestamp.
local function applySignupUpsert(ctx, payload, sender, role)
  local character, characterRole = sender, role
  if ctx.relay then
    local denied = authorize(role, "raid_manage")
    if denied then
      return false, denied
    end
    character = payload.characterKey
    characterRole = ctx.roleOf and ctx.roleOf(character)
  elseif payload.characterKey ~= sender then
    return false, "forbidden"
  end
  local characterRoster = ns.RosterService.SenderRoster(ctx, character)
  if ns.PermissionService.Scope(characterRole, "event_signup", characterRoster) == "none" then
    return false, characterRole == nil and "unknown_sender" or "forbidden"
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
  end
  if not ns.RosterService.MayAct(characterRole, characterRoster, event.rosterId) then
    return false, "other_roster"
  end

  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  event.signups = event.signups or {}
  local record = event.signups[payload.characterKey]
  if record then
    if not wins(payload.rev, updatedAt, sender, record) then
      return false, "stale"
    end
  else
    if countKeys(event.signups) >= ns.Constants.EVENT_ATTENDANCE_MAX then
      return false, "limit"
    end
    record = {}
    event.signups[payload.characterKey] = record
  end

  record.status = payload.status
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  return true
end

local function applyAssignUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "raid_manage")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
  end

  local blocked = rosterGuard(ctx, sender, role, event.rosterId)
  if blocked then
    return false, blocked
  end

  local key = ("A:%s:%s"):format(payload.eventId, payload.assignmentId)
  if blockedByTombstone(ctx, key, payload.rev) then
    return false, "tombstoned"
  end

  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local assignment = event.assignments[payload.assignmentId]
  if assignment then
    if not wins(payload.rev, updatedAt, sender, assignment) then
      return false, "stale"
    end
  else
    if countKeys(event.assignments) >= ns.Constants.EVENT_ASSIGNMENTS_MAX then
      return false, "limit"
    end
    assignment = { assignmentId = payload.assignmentId }
    event.assignments[payload.assignmentId] = assignment
  end

  assignment.encounter = payload.encounter
  assignment.characterKey = payload.characterKey
  assignment.group = payload.group
  assignment.task = payload.task
  assignment.note = payload.note
  assignment.rev = payload.rev
  assignment.updatedAt = updatedAt
  assignment.updatedBy = sender
  assignment.source = "received"
  ctx.tombstones[key] = nil
  return true
end

local function applyDelete(ctx, payload, sender, role)
  local isEvent = payload.kind == "event"
  local denied = authorize(role, "raid_manage")
  if denied then
    return false, denied
  end

  local event = ctx.events[payload.eventId]
  -- Only the guild master can delete something of an event this client does not know: a raid leader cannot know it
  -- is one of their roster's.
  if event then
    local blocked = rosterGuard(ctx, sender, role, event.rosterId)
    if blocked then
      return false, blocked
    end
  elseif not ns.PermissionService.IsGlobal(role) then
    return false, "unknown_event"
  end
  local key
  if isEvent then
    key = "E:" .. payload.eventId
    if event and event.rev >= payload.rev then
      return false, "stale"
    end
    ctx.events[payload.eventId] = nil
  else
    key = ("A:%s:%s"):format(payload.eventId, payload.assignmentId)
    local assignment = event and event.assignments[payload.assignmentId]
    if assignment and assignment.rev >= payload.rev then
      return false, "stale"
    end
    if assignment then
      event.assignments[payload.assignmentId] = nil
    end
  end

  -- Remembered even when the record is unknown here, so a late stale upsert is still dropped.
  local tombstone = ctx.tombstones[key]
  if not tombstone or tombstone.rev < payload.rev then
    ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, key, payload.rev)
  end
  return true
end

local APPLIERS = {
  EVENT_UPSERT = applyEventUpsert,
  ATTENDANCE_UPSERT = applyAttendanceUpsert,
  SIGNUP_UPSERT = applySignupUpsert,
  ASSIGN_UPSERT = applyAssignUpsert,
  DELETE = applyDelete,
}

-- `message` must already be validated by Protocol. `sender` and `role` come from the client.
function EventSync.Apply(ctx, message, sender, role)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role)
end

function EventSync.IsRaidMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- Lets another module (loot council) add the messages it knows how to apply. Only meant to be
-- called while the addon files load.
function EventSync.RegisterApplier(messageType, applier)
  APPLIERS[messageType] = applier
end

-- Payload builders: what a local change looks like on the wire.

function EventSync.EventPayload(event)
  return {
    eventId = event.eventId,
    rev = event.rev,
    updatedAt = event.updatedAt,
    title = event.title,
    instance = event.instance,
    startAt = event.startAt,
    status = event.status,
    rosterId = event.rosterId,
  }
end

function EventSync.AttendancePayload(eventId, characterKey, record)
  return {
    eventId = eventId,
    characterKey = characterKey,
    state = record.state,
    rev = record.rev,
    updatedAt = record.updatedAt,
  }
end

function EventSync.SignupPayload(eventId, characterKey, record)
  return {
    eventId = eventId,
    characterKey = characterKey,
    status = record.status,
    rev = record.rev,
    updatedAt = record.updatedAt,
  }
end

function EventSync.AssignPayload(eventId, assignment)
  return {
    eventId = eventId,
    assignmentId = assignment.assignmentId,
    rev = assignment.rev,
    updatedAt = assignment.updatedAt,
    encounter = assignment.encounter,
    characterKey = assignment.characterKey,
    group = assignment.group,
    task = assignment.task,
    note = assignment.note,
  }
end

-- Delete payloads reuse the revision stored in the tombstone the local delete left behind.
function EventSync.DeleteEventPayload(tombstones, eventId)
  local tombstone = tombstones["E:" .. eventId]
  if not tombstone then
    return nil
  end
  return { kind = "event", eventId = eventId, rev = tombstone.rev }
end

function EventSync.DeleteAssignmentPayload(tombstones, eventId, assignmentId)
  local tombstone = tombstones[("A:%s:%s"):format(eventId, assignmentId)]
  if not tombstone then
    return nil
  end
  return { kind = "assignment", eventId = eventId, assignmentId = assignmentId, rev = tombstone.rev }
end

ns.EventSync = EventSync
