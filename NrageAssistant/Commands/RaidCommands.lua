local _, ns = ...

-- The raid operations the window calls for events, attendance and assignments. Each method returns the lines
-- to show, so the whole thing is testable without a client.
-- Every change is applied locally through EventService (which checks the rank-derived role) and then
-- sent to the guild through Comm.
--   deps: events, tombstones, platform, comm
local RaidCommands = {}
RaidCommands.__index = RaidCommands

local L = ns.L

function RaidCommands.New(deps)
  return setmetatable({
    events = deps.events,
    tombstones = deps.tombstones,
    platform = deps.platform,
    comm = deps.comm,
    rosters = deps.rosters,
    members = deps.members,
  }, RaidCommands)
end

function RaidCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    tombstones = self.tombstones,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    rosterId = ns.RosterService.RosterOf(self.members or {}, self.rosters or {}, platform.GetIdentityKey()),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
  }
end

local function fail(ctx, reason)
  if reason == "forbidden" then
    return L("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  local field = tostring(reason):match("^invalid:(.+)$")
  if field then
    return L("invalid %s."):format(field)
  end
  local messages = {
    other_roster = L("that event belongs to another roster."),
    not_found = L("not found."),
    limit = L("limit reached."),
    invalid_state = L("unknown state. Use invited, confirmed, present, late, leftEarly, absent, excused or unknown."),
  }
  return messages[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason, detail)
  if ok then
    return nil
  end
  local why = detail and ("%s: %s"):format(tostring(reason), detail) or tostring(reason)
  return L("saved here, but not sent to the guild (%s)."):format(why)
end

function RaidCommands:CreateEvent(title)
  local ctx = self:Context()
  local event, reason = ns.EventService.Create(ctx, { title = title })
  if not event then
    return { fail(ctx, reason) }
  end
  return { L("created event '%s'."):format(event.title), sentNote(self.comm:SendEvent(event)) }
end

function RaidCommands:DeleteEvent(event)
  local ctx = self:Context()
  local ok, reason = ns.EventService.Delete(ctx, event.eventId)
  if not ok then
    return { fail(ctx, reason) }
  end
  return { L("deleted '%s'."):format(event.title), sentNote(self.comm:SendDeleteEvent(event.eventId)) }
end

function RaidCommands:UpdateEvent(event, fields)
  local ctx = self:Context()
  local updated, reason = ns.EventService.Update(ctx, event.eventId, fields)
  if not updated then
    if reason == "invalid:status" then
      return { L("status must be planned, open, closed or cancelled.") }
    end
    return { fail(ctx, reason) }
  end
  return { L("updated '%s' [%s]."):format(updated.title, updated.status), sentNote(self.comm:SendEvent(updated)) }
end

function RaidCommands:RenameEvent(event, title)
  return self:UpdateEvent(event, { title = title })
end

function RaidCommands:SetEventStatus(event, status)
  return self:UpdateEvent(event, { status = status })
end

-- `text` is "YYYY-MM-DD HH:MM" in local time.
function RaidCommands:SetEventStart(event, text)
  local startAt = self.platform.ParseDate(text)
  if not startAt then
    return { L("give the start as YYYY-MM-DD HH:MM in your local time, e.g. 2026-10-03 20:30.") }
  end
  return self:UpdateEvent(event, { startAt = startAt })
end

function RaidCommands:SetAttendance(event, characterKey, state)
  local ctx = self:Context()
  local record, reason = ns.EventService.SetAttendance(ctx, event.eventId, characterKey, state)
  if not record then
    return { fail(ctx, reason) }
  end
  return {
    L("%s: %s."):format(characterKey, record.state),
    sentNote(self.comm:SendAttendance(event.eventId, characterKey, record)),
  }
end

local function sortedAssignments(event)
  local list = {}
  for _, assignment in pairs(event.assignments) do
    list[#list + 1] = assignment
  end
  table.sort(list, function(a, b)
    if a.encounter ~= b.encounter then
      return a.encounter < b.encounter
    end
    if a.characterKey ~= b.characterKey then
      return a.characterKey < b.characterKey
    end
    return a.assignmentId < b.assignmentId
  end)
  return list
end

RaidCommands.SortedAssignments = sortedAssignments

function RaidCommands:AddAssignment(event, characterKey, encounter)
  local ctx = self:Context()
  local assignment, reason = ns.EventService.AddAssignment(ctx, event.eventId, {
    characterKey = characterKey,
    encounter = encounter,
  })
  if not assignment then
    return { fail(ctx, reason) }
  end
  return {
    L("assigned %s to %s."):format(characterKey, encounter),
    sentNote(self.comm:SendAssignment(event.eventId, assignment)),
  }
end

function RaidCommands:RemoveAssignment(event, assignment)
  local ctx = self:Context()
  local ok, reason = ns.EventService.RemoveAssignment(ctx, event.eventId, assignment.assignmentId)
  if not ok then
    return { fail(ctx, reason) }
  end
  return {
    L("removed %s from %s."):format(assignment.characterKey, assignment.encounter),
    sentNote(self.comm:SendDeleteAssignment(event.eventId, assignment.assignmentId)),
  }
end

ns.RaidCommands = RaidCommands
