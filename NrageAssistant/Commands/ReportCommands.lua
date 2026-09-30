local _, ns = ...

-- /nrage report attendance [event] and /nrage report loot [event]. Returns the lines to print.
-- With an event number the report covers only that event; without one, every event held.
local ReportCommands = {}
ReportCommands.__index = ReportCommands

local USAGE = { "usage: /nrage report attendance [event] | report loot [event]" }

function ReportCommands.New(deps)
  return setmetatable({ events = deps.events }, ReportCommands)
end

-- The events a report covers: all of them, or just the one with that number.
function ReportCommands:Scope(token)
  if token == "" then
    return self.events
  end
  local index = tonumber(token)
  local event = index and index % 1 == 0 and ns.EventService.List({ events = self.events })[index] or nil
  if not event then
    return nil, "give the event number from /nrage event, or nothing for every event."
  end
  return { [event.eventId] = event }
end

function ReportCommands:Report(rest)
  local kind, token = rest:match("^(%S*)%s*(%S*)")
  if kind ~= "attendance" and kind ~= "loot" then
    return USAGE
  end

  local scope, problem = self:Scope(token)
  if not scope then
    return { problem }
  end

  if kind == "attendance" then
    local rows, held = ns.ReportService.Attendance(scope)
    return ns.ReportService.DescribeAttendance(rows, held)
  end
  local rows, totals = ns.ReportService.Loot(scope)
  return ns.ReportService.DescribeLoot(rows, totals)
end

ns.ReportCommands = ReportCommands
