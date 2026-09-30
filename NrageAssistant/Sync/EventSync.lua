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
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "unknown_event" | "stale" | "tombstoned" | "limit" | "unsupported"
local EventSync = {}

local MAX_FUTURE_SKEW_SECONDS = 300

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- nil when allowed, otherwise the reason. A sender the roster does not know gets nothing.
local function authorize(role, action)
  if role == nil then
    return "unknown_sender"
  end
  if not ns.PermissionService.Can(role, action) then
    return "forbidden"
  end
  return nil
end

local function clampTimestamp(ctx, updatedAt)
  return math.min(updatedAt, ctx.now() + MAX_FUTURE_SKEW_SECONDS)
end

local function wins(rev, updatedAt, sender, current)
  if rev ~= current.rev then
    return rev > current.rev
  end
  if updatedAt ~= current.updatedAt then
    return updatedAt > current.updatedAt
  end
  return sender > (current.updatedBy or "")
end

-- Returns true if the tombstone blocks an upsert with this revision.
local function blockedByTombstone(ctx, key, rev)
  local tombstone = ctx.tombstones[key]
  return tombstone ~= nil and rev <= tombstone.rev
end

local function applyEventUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "manage_events")
  if denied then
    return false, denied
  end

  local key = "E:" .. payload.eventId
  if blockedByTombstone(ctx, key, payload.rev) then
    return false, "tombstoned"
  end

  local event = ctx.events[payload.eventId]
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  if event then
    if not wins(payload.rev, updatedAt, sender, event) then
      return false, "stale"
    end
  else
    if countKeys(ctx.events) >= ns.Constants.EVENT_MAX then
      return false, "limit"
    end
    event = { eventId = payload.eventId, attendance = {}, assignments = {} }
    ctx.events[payload.eventId] = event
  end

  -- An upsert carries the whole event: fields it omits are cleared.
  event.title = payload.title
  event.instance = payload.instance
  event.startAt = payload.startAt
  event.status = payload.status or "planned"
  event.rev = payload.rev
  event.updatedAt = updatedAt
  event.updatedBy = sender
  event.source = "received"
  ctx.tombstones[key] = nil
  return true
end

local function applyAttendanceUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "record_attendance")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
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

local function applyAssignUpsert(ctx, payload, sender, role)
  local denied = authorize(role, "manage_assignments")
  if denied then
    return false, denied
  end
  local event = ctx.events[payload.eventId]
  if not event then
    return false, "unknown_event"
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
  local denied = authorize(role, isEvent and "manage_events" or "manage_assignments")
  if denied then
    return false, denied
  end

  local event = ctx.events[payload.eventId]
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
