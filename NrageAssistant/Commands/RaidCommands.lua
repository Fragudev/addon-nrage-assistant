local _, ns = ...

-- Text commands for raid events, attendance and assignments. Each method takes the words after the
-- command and returns the lines to print, so the whole thing is testable without a client.
-- Every change is applied locally through EventService (which checks the rank-derived role) and then
-- sent to the guild through Comm.
--   deps: events, tombstones, platform, comm
local RaidCommands = {}
RaidCommands.__index = RaidCommands

function RaidCommands.New(deps)
  return setmetatable({
    events = deps.events,
    tombstones = deps.tombstones,
    platform = deps.platform,
    comm = deps.comm,
  }, RaidCommands)
end

function RaidCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    tombstones = self.tombstones,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
  }
end

local function fail(ctx, reason)
  if reason == "forbidden" then
    return ("not allowed: your guild rank gives the role '%s', which cannot do this."):format(tostring(ctx.role))
  end
  local field = tostring(reason):match("^invalid:(.+)$")
  if field then
    return ("invalid %s."):format(field)
  end
  local messages = {
    not_found = "not found.",
    limit = "limit reached.",
    invalid_state = "unknown state. Use invited, confirmed, present, late, leftEarly, absent, excused or unknown.",
  }
  return messages[reason] or tostring(reason)
end

-- Adds a note when the change was saved here but could not be queued for the guild.
local function sentNote(ok, reason)
  if ok then
    return nil
  end
  return ("saved here, but not sent to the guild (%s)."):format(tostring(reason))
end

function RaidCommands:Resolve(token)
  local index = tonumber(token)
  if not index or index % 1 ~= 0 then
    return nil, "give the event number from /nrage event."
  end
  local event = ns.EventService.List({ events = self.events })[index]
  if not event then
    return nil, ("no event number %s."):format(token)
  end
  return event
end

local EVENT_STATUS_HELP = "status must be planned, open, closed or cancelled."
local EVENT_DATE_HELP = "give the start as YYYY-MM-DD HH:MM in your local time, e.g. 2026-10-03 20:30."

function RaidCommands:ListEvents()
  local list = ns.EventService.List({ events = self.events })
  if #list == 0 then
    return { "No events yet. Create one with /nrage event new <title>." }
  end
  local lines = { ("%d event(s):"):format(#list) }
  for index, event in ipairs(list) do
    local when = event.startAt and (" - " .. self.platform.FormatDate(event.startAt)) or ""
    lines[#lines + 1] = ("  %d. %s [%s]%s"):format(index, event.title, event.status, when)
  end
  return lines
end

function RaidCommands:Event(rest)
  local sub, args = rest:match("^(%S*)%s*(.-)$")
  if sub == "" or sub == "list" then
    return self:ListEvents()
  end

  local ctx = self:Context()
  if sub == "new" then
    local event, reason = ns.EventService.Create(ctx, { title = args })
    if not event then
      return { fail(ctx, reason) }
    end
    local lines = { ("created event '%s'."):format(event.title) }
    lines[#lines + 1] = sentNote(self.comm:SendEvent(event))
    return lines
  end

  if sub == "rename" or sub == "status" or sub == "delete" or sub == "start" then
    local token, value = args:match("^(%S*)%s*(.-)$")
    local event, problem = self:Resolve(token)
    if not event then
      return { problem }
    end

    if sub == "delete" then
      local ok, reason = ns.EventService.Delete(ctx, event.eventId)
      if not ok then
        return { fail(ctx, reason) }
      end
      return { ("deleted '%s'."):format(event.title), sentNote(self.comm:SendDeleteEvent(event.eventId)) }
    end

    local fields
    if sub == "rename" then
      fields = { title = value }
    elseif sub == "status" then
      fields = { status = value }
    else
      local startAt = self.platform.ParseDate(value)
      if not startAt then
        return { EVENT_DATE_HELP }
      end
      fields = { startAt = startAt }
    end
    local updated, reason = ns.EventService.Update(ctx, event.eventId, fields)
    if not updated then
      if reason == "invalid:status" then
        return { EVENT_STATUS_HELP }
      end
      return { fail(ctx, reason) }
    end
    return { ("updated '%s' [%s]."):format(updated.title, updated.status), sentNote(self.comm:SendEvent(updated)) }
  end

  return {
    "usage: /nrage event [list] | new <title> | rename <n> <title> | status <n> <status>"
      .. " | start <n> <YYYY-MM-DD HH:MM> | delete <n>",
  }
end

local function listAttendance(event)
  local keys = {}
  for key in pairs(event.attendance) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if #keys == 0 then
    return { ("No attendance recorded for '%s' yet."):format(event.title) }
  end
  local lines = { ("Attendance for '%s':"):format(event.title) }
  for _, key in ipairs(keys) do
    local record = event.attendance[key]
    lines[#lines + 1] = ("  %s - %s [%s]"):format(key, record.state, record.source)
  end
  return lines
end

function RaidCommands:Attendance(rest)
  local token, remainder = rest:match("^(%S*)%s*(.-)$")
  local event, problem = self:Resolve(token)
  if not event then
    return { problem, "usage: /nrage attendance <n> [<name> <state>]" }
  end
  if remainder == "" then
    return listAttendance(event)
  end

  -- The state is the last word; the name (which may have several) is everything before it.
  local name, state = remainder:match("^(.-)%s+(%S+)$")
  local characterKey = name and ns.Args.Unquote(name) or ""
  if characterKey == "" then
    return { "usage: /nrage attendance <n> [<name> <state>]" }
  end

  local ctx = self:Context()
  local record, reason = ns.EventService.SetAttendance(ctx, event.eventId, characterKey, state)
  if not record then
    return { fail(ctx, reason) }
  end
  return {
    ("%s: %s."):format(characterKey, record.state),
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

local function listAssignments(event)
  local list = sortedAssignments(event)
  if #list == 0 then
    return { ("No assignments for '%s' yet."):format(event.title) }
  end
  local lines = { ("Assignments for '%s':"):format(event.title) }
  for index, assignment in ipairs(list) do
    local task = assignment.task and (" - " .. assignment.task) or ""
    lines[#lines + 1] = ("  %d. %s: %s%s"):format(index, assignment.encounter, assignment.characterKey, task)
  end
  return lines
end

function RaidCommands:Assign(rest)
  local token, sub, args = rest:match("^(%S*)%s*(%S*)%s*(.-)$")
  local event, problem = self:Resolve(token)
  if not event then
    return { problem, "usage: /nrage assign <n> [add <name> <encounter> | remove <k>]" }
  end
  if sub == "" or sub == "list" then
    return listAssignments(event)
  end

  local ctx = self:Context()
  if sub == "add" then
    -- A name with spaces goes in double quotes: assign 1 add "Yonemon Gg" Ragnaros
    local characterKey, encounter = ns.Args.TakeName(args)
    if not characterKey or encounter == "" then
      return { 'usage: /nrage assign <n> add <name> <encounter>   (put a name with spaces in "quotes")' }
    end
    local assignment, reason = ns.EventService.AddAssignment(ctx, event.eventId, {
      characterKey = characterKey,
      encounter = encounter,
    })
    if not assignment then
      return { fail(ctx, reason) }
    end
    return {
      ("assigned %s to %s."):format(characterKey, encounter),
      sentNote(self.comm:SendAssignment(event.eventId, assignment)),
    }
  end

  if sub == "remove" then
    local target = sortedAssignments(event)[tonumber(args) or 0]
    if not target then
      return { "give the assignment number from /nrage assign <n>." }
    end
    local ok, reason = ns.EventService.RemoveAssignment(ctx, event.eventId, target.assignmentId)
    if not ok then
      return { fail(ctx, reason) }
    end
    return {
      ("removed %s from %s."):format(target.characterKey, target.encounter),
      sentNote(self.comm:SendDeleteAssignment(event.eventId, target.assignmentId)),
    }
  end

  return { "usage: /nrage assign <n> [list | add <name> <encounter> | remove <k>]" }
end

ns.RaidCommands = RaidCommands
