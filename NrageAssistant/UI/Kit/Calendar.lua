local _, ns = ...

-- Date arithmetic for the date picker, kept apart from the frames so it can be tested. Weeks start on Monday.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Calendar = {}
Kit.Calendar = Calendar

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function Calendar.IsLeap(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

function Calendar.DaysInMonth(year, month)
  if month == 2 and Calendar.IsLeap(year) then
    return 29
  end
  return DAYS[month]
end

-- 0 = Monday .. 6 = Sunday (Sakamoto's method, so it does not depend on the client's time zone).
function Calendar.Weekday(year, month, day)
  local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if month < 3 then
    year = year - 1
  end
  local sunday = (year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400) + offsets[month] + day)
    % 7
  return (sunday + 6) % 7
end

-- year, month moved by `delta` months (negative goes back).
function Calendar.AddMonths(year, month, delta)
  local index = year * 12 + (month - 1) + delta
  return math.floor(index / 12), index % 12 + 1
end

-- Six weeks of seven cells for the month, starting on Monday: { year, month, day, inMonth } for each cell, so the
-- days of the neighbouring months fill the first and last rows.
function Calendar.MonthGrid(year, month)
  local first = Calendar.Weekday(year, month, 1)
  local previousYear, previousMonth = Calendar.AddMonths(year, month, -1)
  local nextYear, nextMonth = Calendar.AddMonths(year, month, 1)
  local previousDays = Calendar.DaysInMonth(previousYear, previousMonth)
  local days = Calendar.DaysInMonth(year, month)
  local weeks = {}
  for week = 1, 6 do
    local row = {}
    for column = 1, 7 do
      local offset = (week - 1) * 7 + column - first
      local cell
      if offset < 1 then
        cell = { year = previousYear, month = previousMonth, day = previousDays + offset, inMonth = false }
      elseif offset > days then
        cell = { year = nextYear, month = nextMonth, day = offset - days, inMonth = false }
      else
        cell = { year = year, month = month, day = offset, inMonth = true }
      end
      row[column] = cell
    end
    weeks[week] = row
  end
  return weeks
end

-- A local date and time -> a timestamp, or nil plus "invalid" (not a real date) or "does_not_exist" (the clock
-- skips that time on that day: the clocks go forward). `clock` = { time, date } (the client's own by default), so
-- the clock change can be tested with a fake. An hour that happens twice (the clocks go back) gives the first one.
function Calendar.ToTimestamp(year, month, day, hour, minute, clock)
  clock = clock or { time = time, date = date }
  if not (month >= 1 and month <= 12 and day >= 1 and day <= Calendar.DaysInMonth(year, month)) then
    return nil, "invalid"
  end
  if not (hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59) then
    return nil, "invalid"
  end
  local timestamp = clock.time({ year = year, month = month, day = day, hour = hour, min = minute })
  if not timestamp then
    return nil, "invalid"
  end
  local expected = ("%04d-%02d-%02d %02d:%02d"):format(year, month, day, hour, minute)
  if clock.date("%Y-%m-%d %H:%M", timestamp) ~= expected then
    return nil, "does_not_exist"
  end
  return timestamp
end

-- year, month, day, hour, minute of a timestamp in local time.
function Calendar.Parts(timestamp, clock)
  clock = clock or { date = date }
  local parts = clock.date("*t", timestamp)
  return parts.year, parts.month, parts.day, parts.hour, parts.min
end

-- The minute choices of the picker, and the nearest one at or before a minute (so an event typed by hand at 20:07
-- shows 20:00 in the picker instead of failing).
Calendar.MINUTE_CHOICES = { 0, 15, 30, 45 }

function Calendar.SnapMinute(minute)
  local snapped = 0
  for _, choice in ipairs(Calendar.MINUTE_CHOICES) do
    if minute >= choice then
      snapped = choice
    end
  end
  return snapped
end
