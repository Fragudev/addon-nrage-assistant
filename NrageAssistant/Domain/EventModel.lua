local _, ns = ...

-- Shape and validation of raid events, attendance states and assignments (plan section 10).
-- Used for local edits now and for received messages later, so both are held to the same rules.
local EventModel = {}

local V = ns.Validate

EventModel.EVENT_STATUSES = { planned = true, open = true, closed = true, cancelled = true }
EventModel.ATTENDANCE_STATES = {
  invited = true,
  confirmed = true,
  present = true,
  late = true,
  leftEarly = true,
  absent = true,
  excused = true,
  unknown = true,
}

-- A player's own answer to "are you coming?" (plan 3.4.1). No entry means not answered.
EventModel.SIGNUP_STATUSES = { yes = true, no = true }

local MAX_TITLE = 60
local MAX_INSTANCE = 40
local MAX_ENCOUNTER = 60
local MAX_CHARACTER_KEY = 64
local MAX_TASK = 60
local MAX_NOTE = 100
local MAX_TIMESTAMP = 4102444800 -- 2100-01-01

-- Validates event fields. With `partial` only the fields that are present are checked, for updates.
-- Returns the clean fields, or nil plus "invalid:<field>". Unknown fields are dropped.
function EventModel.ValidateEvent(fields, partial)
  if type(fields) ~= "table" then
    return nil, "invalid:fields"
  end

  local clean = {}
  if fields.title ~= nil or not partial then
    if not V.Text(fields.title, MAX_TITLE) then
      return nil, "invalid:title"
    end
    clean.title = fields.title
  end
  if fields.instance ~= nil then
    if not V.Text(fields.instance, MAX_INSTANCE) then
      return nil, "invalid:instance"
    end
    clean.instance = fields.instance
  end
  if fields.startAt ~= nil then
    if not V.Int(fields.startAt, 0, MAX_TIMESTAMP) then
      return nil, "invalid:startAt"
    end
    clean.startAt = fields.startAt
  end
  if fields.status ~= nil then
    if not (type(fields.status) == "string" and EventModel.EVENT_STATUSES[fields.status]) then
      return nil, "invalid:status"
    end
    clean.status = fields.status
  end
  -- The roster the event belongs to (protocol 1.5). Optional: an event with none is a legacy one.
  if fields.rosterId ~= nil then
    if not V.Id(fields.rosterId) then
      return nil, "invalid:rosterId"
    end
    clean.rosterId = fields.rosterId
  end
  return clean
end

function EventModel.ValidateAssignment(fields)
  if type(fields) ~= "table" then
    return nil, "invalid:fields"
  end
  if not V.Text(fields.encounter, MAX_ENCOUNTER) then
    return nil, "invalid:encounter"
  end
  if not V.Text(fields.characterKey, MAX_CHARACTER_KEY) then
    return nil, "invalid:characterKey"
  end

  local clean = { encounter = fields.encounter, characterKey = fields.characterKey }
  if fields.group ~= nil then
    if not V.Int(fields.group, 1, 8) then
      return nil, "invalid:group"
    end
    clean.group = fields.group
  end
  if fields.task ~= nil then
    if not V.Text(fields.task, MAX_TASK) then
      return nil, "invalid:task"
    end
    clean.task = fields.task
  end
  if fields.note ~= nil then
    if not V.Text(fields.note, MAX_NOTE) then
      return nil, "invalid:note"
    end
    clean.note = fields.note
  end
  return clean
end

function EventModel.IsAttendanceState(state)
  return type(state) == "string" and EventModel.ATTENDANCE_STATES[state] == true
end

function EventModel.IsSignupStatus(status)
  return type(status) == "string" and EventModel.SIGNUP_STATUSES[status] == true
end

function EventModel.IsCharacterKey(key)
  return V.Text(key, MAX_CHARACTER_KEY)
end

ns.EventModel = EventModel
