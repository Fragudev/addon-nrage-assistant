local _, ns = ...

-- Local raid events, attendance and assignments. Every change checks the actor's role first and
-- bumps a per-record `rev`, so later sync can order edits. Deleting leaves a tombstone.
--
-- ctx = {
--   events     = db.global.events,             tombstones = db.global.sync.tombstones,
--   role       = a rank role,                  actor      = "Name-Realm",
--   now        = function() -> server time,    newId      = function() -> unique id,
--   rosterId   = the roster of the actor (nil: none),
-- }
-- A raid leader works on the events of their own roster only (RosterService.MayAct); the guild master on any.
-- Every operation returns its result, or nil/false plus a reason:
--   "forbidden" | "other_roster" | "not_found" | "limit" | "invalid:<field>" | "invalid_state" | "closed".
local EventService = {}

local Can = function(role, action)
  return ns.PermissionService.Can(role, action)
end

-- nil when the actor may manage `event`, else "other_roster".
local function rosterGuard(ctx, event)
  if ns.RosterService.MayAct(ctx.role, ctx.rosterId, event.rosterId) then
    return nil
  end
  return "other_roster"
end

local function stamp(ctx, record)
  record.rev = (record.rev or 0) + 1
  record.updatedAt = ctx.now()
  record.updatedBy = ctx.actor
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function addTombstone(ctx, key, rev)
  local tombstones = ctx.tombstones
  if not tombstones[key] and countKeys(tombstones) >= ns.Constants.TOMBSTONE_MAX then
    -- Full: drop one rather than refuse a deletion. An assignment tombstone ("A:") goes first (the least costly one
    -- to lose: its event is usually gone or its roster is rebuilt), the oldest of its kind; the others ("E:", "B:",
    -- "R:", "M:") only when there is no assignment one.
    local oldestKey, oldestAt, oldestIsA
    for existing, entry in pairs(tombstones) do
      local isA = existing:sub(1, 2) == "A:"
      if not oldestAt or (isA and not oldestIsA) or (isA == oldestIsA and entry.at < oldestAt) then
        oldestKey, oldestAt, oldestIsA = existing, entry.at, isA
      end
    end
    tombstones[oldestKey] = nil
  end
  tombstones[key] = { at = ctx.now(), rev = rev }
end

-- Also used when applying a received DELETE, so both paths share the same bounded list.
EventService.AddTombstone = addTombstone

function EventService.Create(ctx, fields)
  if not Can(ctx.role, "raid_manage") then
    return nil, "forbidden"
  end
  local clean, reason = ns.EventModel.ValidateEvent(fields)
  if not clean then
    return nil, reason
  end
  -- A raid leader's new event belongs to their roster; the guild master chooses (or leaves it with none).
  if not ns.PermissionService.IsGlobal(ctx.role) then
    if ctx.rosterId == nil or (clean.rosterId ~= nil and clean.rosterId ~= ctx.rosterId) then
      return nil, "other_roster"
    end
    clean.rosterId = ctx.rosterId
  end
  if countKeys(ctx.events) >= ns.Constants.EVENT_MAX then
    return nil, "limit"
  end

  local event = {
    eventId = ctx.newId(),
    title = clean.title,
    instance = clean.instance,
    startAt = clean.startAt,
    status = clean.status or "planned",
    rosterId = clean.rosterId,
    source = "declared",
    attendance = {},
    signups = {},
    assignments = {},
    loot = {},
  }
  stamp(ctx, event)
  ctx.events[event.eventId] = event
  return event
end

function EventService.Update(ctx, eventId, fields)
  if not Can(ctx.role, "raid_manage") then
    return nil, "forbidden"
  end
  local event = ctx.events[eventId]
  if not event then
    return nil, "not_found"
  end
  local clean, reason = ns.EventModel.ValidateEvent(fields, true)
  if not clean then
    return nil, reason
  end
  local denied = rosterGuard(ctx, event)
  if denied then
    return nil, denied
  end
  -- Moving an event to another roster, or giving a legacy one a roster, is the guild master's.
  if clean.rosterId ~= nil and not ns.PermissionService.IsGlobal(ctx.role) then
    return nil, "forbidden"
  end

  for key, value in pairs(clean) do
    event[key] = value
  end
  stamp(ctx, event)
  return event
end

function EventService.Delete(ctx, eventId)
  if not Can(ctx.role, "raid_manage") then
    return false, "forbidden"
  end
  local event = ctx.events[eventId]
  if not event then
    return false, "not_found"
  end
  local denied = rosterGuard(ctx, event)
  if denied then
    return false, denied
  end
  ctx.events[eventId] = nil
  addTombstone(ctx, "E:" .. eventId, event.rev + 1)
  return true
end

-- Records a member's attendance state. Nothing here ever infers "absent" from a disconnect:
-- only an explicit call by someone allowed to record attendance changes a state.
function EventService.SetAttendance(ctx, eventId, characterKey, state)
  if not Can(ctx.role, "raid_manage") then
    return nil, "forbidden"
  end
  local event = ctx.events[eventId]
  if not event then
    return nil, "not_found"
  end
  local denied = rosterGuard(ctx, event)
  if denied then
    return nil, denied
  end
  if not ns.EventModel.IsCharacterKey(characterKey) then
    return nil, "invalid:characterKey"
  end
  if not ns.EventModel.IsAttendanceState(state) then
    return nil, "invalid_state"
  end

  local record = event.attendance[characterKey]
  if not record and countKeys(event.attendance) >= ns.Constants.EVENT_ATTENDANCE_MAX then
    return nil, "limit"
  end

  record = record or {}
  record.state = state
  record.source = "declared"
  record.recordedBy = ctx.actor
  stamp(ctx, record)
  event.attendance[characterKey] = record
  return record
end

-- Can the players of the event still change their sign-up? Only while it is planned or open and has not started.
function EventService.SignupOpen(event, now)
  if event.status ~= "planned" and event.status ~= "open" then
    return false
  end
  return event.startAt == nil or event.startAt > now
end

-- The actor signs up their own character: "yes" (going) or "no" (not going). There is no character argument, so
-- nobody can answer for somebody else; the leader's record of what happened stays in `attendance`.
function EventService.SetSignup(ctx, eventId, status)
  if ns.PermissionService.Scope(ctx.role, "event_signup", ctx.rosterId) == "none" then
    return nil, "forbidden"
  end
  local event = ctx.events[eventId]
  if not event then
    return nil, "not_found"
  end
  if not ns.RosterService.MayAct(ctx.role, ctx.rosterId, event.rosterId) then
    return nil, "other_roster"
  end
  if not ns.EventModel.IsSignupStatus(status) then
    return nil, "invalid:status"
  end
  if not EventService.SignupOpen(event, ctx.now()) then
    return nil, "closed"
  end

  event.signups = event.signups or {}
  local record = event.signups[ctx.actor]
  if not record and countKeys(event.signups) >= ns.Constants.EVENT_ATTENDANCE_MAX then
    return nil, "limit"
  end

  record = record or {}
  record.status = status
  record.rev = (record.rev or 0) + 1
  record.updatedAt = ctx.now()
  record.updatedBy = ctx.actor
  event.signups[ctx.actor] = record
  return record
end

function EventService.AddAssignment(ctx, eventId, fields)
  if not Can(ctx.role, "raid_manage") then
    return nil, "forbidden"
  end
  local event = ctx.events[eventId]
  if not event then
    return nil, "not_found"
  end
  local denied = rosterGuard(ctx, event)
  if denied then
    return nil, denied
  end
  local clean, reason = ns.EventModel.ValidateAssignment(fields)
  if not clean then
    return nil, reason
  end
  if countKeys(event.assignments) >= ns.Constants.EVENT_ASSIGNMENTS_MAX then
    return nil, "limit"
  end

  local assignment = {
    assignmentId = ctx.newId(),
    encounter = clean.encounter,
    characterKey = clean.characterKey,
    group = clean.group,
    task = clean.task,
    note = clean.note,
    source = "declared",
  }
  stamp(ctx, assignment)
  event.assignments[assignment.assignmentId] = assignment
  return assignment
end

function EventService.RemoveAssignment(ctx, eventId, assignmentId)
  if not Can(ctx.role, "raid_manage") then
    return false, "forbidden"
  end
  local event = ctx.events[eventId]
  local assignment = event and event.assignments[assignmentId]
  if not assignment then
    return false, "not_found"
  end
  local denied = rosterGuard(ctx, event)
  if denied then
    return false, denied
  end
  event.assignments[assignmentId] = nil
  addTombstone(ctx, ("A:%s:%s"):format(eventId, assignmentId), assignment.rev + 1)
  return true
end

-- Events sorted by start time (undated last), then title.
function EventService.List(ctx)
  local list = {}
  for _, event in pairs(ctx.events) do
    list[#list + 1] = event
  end
  table.sort(list, function(a, b)
    local left, right = a.startAt or math.huge, b.startAt or math.huge
    if left ~= right then
      return left < right
    end
    if a.title ~= b.title then
      return a.title < b.title
    end
    return a.eventId < b.eventId
  end)
  return list
end

-- Local housekeeping: removes events past their retention and expired tombstones.
-- Returns the number of events removed.
function EventService.Purge(ctx)
  local constants = ns.Constants
  local now = ctx.now()
  local removed = 0

  for eventId, event in pairs(ctx.events) do
    local reference = event.startAt or event.updatedAt or 0
    if now - reference > constants.EVENT_RETENTION_SECONDS then
      ctx.events[eventId] = nil
      removed = removed + 1
    end
  end
  for key, entry in pairs(ctx.tombstones) do
    if now - entry.at > constants.TOMBSTONE_TTL_SECONDS then
      ctx.tombstones[key] = nil
    end
  end
  return removed
end

ns.EventService = EventService
