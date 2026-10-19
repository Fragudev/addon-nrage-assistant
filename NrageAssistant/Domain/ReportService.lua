local _, ns = ...

-- Attendance and loot reports over the data the addon already holds.
--
-- Attendance: only definite outcomes count towards the rate.
--   attended = present + late + leftEarly      missed = absent
--   The rate is attended / (attended + missed) and always shown with its denominator. States that
--   say nothing about turning up (invited, confirmed, unknown) and excused absences stay out of the
--   rate but are listed, so `unknown` can never make anyone look better or worse.
-- Only events that were actually held count: planned and cancelled events are ignored.
local ReportService = {}

local L = ns.L

-- How the attendance states are written in the report; the data keeps the English words.
local STATE_TEXT = ns.Locale.Table(function()
  return {
    present = L("present"),
    late = L("late"),
    leftEarly = L("leftEarly"),
    absent = L("absent"),
    excused = L("excused"),
    invited = L("invited"),
    confirmed = L("confirmed"),
    unknown = L("unknown"),
  }
end)

local ATTENDED = { present = true, late = true, leftEarly = true }
local MISSED = { absent = true }
local COUNTED_STATUSES = { open = true, closed = true }

local STATE_ORDER = { "present", "late", "leftEarly", "absent", "excused", "invited", "confirmed", "unknown" }

local function countedEvents(events)
  local list = {}
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    if COUNTED_STATUSES[event.status] then
      list[#list + 1] = event
    end
  end
  return list
end

-- Returns rows sorted by rate (best first, members without an outcome last), then name, and the number
-- of events that were counted. Each row: characterKey, attended, outcomes, rate (nil without outcomes),
-- counts (per state) and other (records that are not a definite outcome).
function ReportService.Attendance(events)
  local held = countedEvents(events)
  local byCharacter = {}

  for _, event in ipairs(held) do
    for characterKey, record in pairs(event.attendance) do
      local row = byCharacter[characterKey]
      if not row then
        row = { characterKey = characterKey, attended = 0, missed = 0, outcomes = 0, other = 0, counts = {} }
        byCharacter[characterKey] = row
      end
      row.counts[record.state] = (row.counts[record.state] or 0) + 1
      if ATTENDED[record.state] then
        row.attended = row.attended + 1
        row.outcomes = row.outcomes + 1
      elseif MISSED[record.state] then
        row.missed = row.missed + 1
        row.outcomes = row.outcomes + 1
      else
        row.other = row.other + 1
      end
    end
  end

  local rows = {}
  for _, row in pairs(byCharacter) do
    row.rate = row.outcomes > 0 and row.attended / row.outcomes or nil
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    if (a.rate ~= nil) ~= (b.rate ~= nil) then
      return a.rate ~= nil
    end
    if a.rate ~= b.rate then
      return a.rate > b.rate
    end
    return a.characterKey < b.characterKey
  end)
  return rows, #held
end

function ReportService.DescribeAttendance(rows, eventCount)
  if eventCount == 0 then
    return { L("No events held yet: only open or closed events count towards attendance.") }
  end
  if #rows == 0 then
    return { L("%d event(s) held, but no attendance recorded yet."):format(eventCount) }
  end

  local lines = { L("Attendance over %d event(s) held:"):format(eventCount) }
  for _, row in ipairs(rows) do
    local parts = {}
    for _, state in ipairs(STATE_ORDER) do
      if row.counts[state] then
        parts[#parts + 1] = ("%s %d"):format(STATE_TEXT[state] or state, row.counts[state])
      end
    end
    local rate = row.rate and ("%d/%d (%d%%)"):format(row.attended, row.outcomes, math.floor(row.rate * 100 + 0.5))
      or L("no outcome recorded")
    lines[#lines + 1] = ("  %s: %s - %s"):format(row.characterKey, rate, table.concat(parts, ", "))
  end
  return lines
end

-- Returns rows sorted by number of awards (most first), then name, and totals { sessions, awarded,
-- notAwarded, open }. Each row: characterKey, awards, items (item names, oldest first).
function ReportService.Loot(events)
  local totals = { sessions = 0, awarded = 0, notAwarded = 0, open = 0 }
  local byCharacter = {}

  for _, event in ipairs(ns.EventService.List({ events = events })) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      totals.sessions = totals.sessions + 1
      if session.status ~= "closed" then
        totals.open = totals.open + 1
      elseif session.award then
        totals.awarded = totals.awarded + 1
      else
        totals.notAwarded = totals.notAwarded + 1
      end
    end
    for _, entry in ipairs(ns.LootService.Acta(event)) do
      if entry.awardedTo then
        local row = byCharacter[entry.awardedTo]
        if not row then
          row = { characterKey = entry.awardedTo, awards = 0, items = {} }
          byCharacter[entry.awardedTo] = row
        end
        row.awards = row.awards + 1
        row.items[#row.items + 1] = entry.itemName
      end
    end
  end

  local rows = {}
  for _, row in pairs(byCharacter) do
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    if a.awards ~= b.awards then
      return a.awards > b.awards
    end
    return a.characterKey < b.characterKey
  end)
  return rows, totals
end

function ReportService.DescribeLoot(rows, totals)
  if totals.sessions == 0 then
    return { L("No loot sessions yet.") }
  end
  local lines = {
    L("Loot: %d session(s), %d awarded, %d closed without an award, %d still open."):format(
      totals.sessions,
      totals.awarded,
      totals.notAwarded,
      totals.open
    ),
  }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = ("  %s: %d - %s"):format(row.characterKey, row.awards, table.concat(row.items, ", "))
  end
  return lines
end

ns.ReportService = ReportService
