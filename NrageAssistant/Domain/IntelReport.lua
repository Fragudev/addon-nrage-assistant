local _, ns = ...

-- The reports of Intel (docs/PVP_INTEL_PLAN.md section 3.3): contacts, wins, losses, new Kill On Sight entries, the
-- enemy met most often, the nemesis (the one who killed the player most) and the hottest map. Pure: it reads an
-- IntelService and returns plain tables, plus the lines to show.
--
--   * Session(service) reads the counters kept in memory since login (or the last reset).
--   * Season(service, season) reads the saved records: the players last seen inside the dates of the season. The
--     records keep no per-season counters, so the wins and losses are the lifetime totals of those players and the
--     report says so (`approximate = true`).
-- A report is { scope, contacts, wins, losses, newKos, mostSeen = { name, count }, nemesis = { name, count },
-- hottestZone = { map, count }, approximate }. The three highlights are nil when there is nothing to show.
local IntelReport = {}

local L = ns.L

-- The key with the highest count in `counts` (`names[key]` gives the name to show); ties go to the smaller name.
local function top(counts, names)
  local bestKey, bestCount
  for key, count in pairs(counts) do
    if count > 0 then
      local better = not bestKey or count > bestCount
      if not better and count == bestCount then
        better = tostring(names and names[key] or key):lower() < tostring(names and names[bestKey] or bestKey):lower()
      end
      if better then
        bestKey, bestCount = key, count
      end
    end
  end
  return bestKey, bestCount
end

local function highlight(counts, names)
  local key, count = top(counts, names)
  if not key then
    return nil
  end
  return { name = names and names[key] or nil, map = not names and key or nil, count = count }
end

function IntelReport.Session(service)
  local session = service.session
  return {
    scope = "session",
    contacts = session.contacts,
    wins = session.wins,
    losses = session.losses,
    newKos = session.newKos,
    mostSeen = highlight(session.seen, session.names),
    nemesis = highlight(session.lostTo, session.names),
    hottestZone = highlight(session.zones),
    approximate = false,
  }
end

local function within(at, season)
  return type(at) == "number" and at >= season.startsAt and at <= season.endsAt
end

local function newKosIn(list, season)
  local count = 0
  for _, entry in pairs(list) do
    if type(entry) == "table" and within(entry.addedAt, season) then
      count = count + 1
    end
  end
  return count
end

-- `season` = { name, startsAt, endsAt } (server time). Nil plus "no_season" when it is not a season.
function IntelReport.Season(service, season)
  if type(season) ~= "table" or type(season.startsAt) ~= "number" or type(season.endsAt) ~= "number" then
    return nil, "no_season"
  end
  local report = {
    scope = "season",
    name = season.name,
    contacts = 0,
    wins = 0,
    losses = 0,
    newKos = newKosIn(service.intel.kos, season) + newKosIn(service.guildKos, season),
    approximate = true,
  }
  local seen, lost, zones, names = {}, {}, {}, {}
  for key, record in pairs(service.intel.players) do
    if type(record) == "table" and type(record.name) == "string" and within(record.lastSeen, season) then
      report.contacts = report.contacts + 1
      report.wins = report.wins + (record.wins or 0)
      report.losses = report.losses + (record.losses or 0)
      seen[key], lost[key], names[key] = record.seen or 0, record.losses or 0, record.name
      if type(record.lastMap) == "number" then
        zones[record.lastMap] = (zones[record.lastMap] or 0) + 1
      end
    end
  end
  report.mostSeen = highlight(seen, names)
  report.nemesis = highlight(lost, names)
  report.hottestZone = highlight(zones)
  return report
end

-- The lines of a report. `zoneName(map)` (optional) gives the name of a map.
function IntelReport.Lines(report, zoneName)
  local title = report.scope == "season"
      and L("Intel report of the season '%s'"):format(ns.IntelModel.Plain(report.name) or "?")
    or L("Intel report of this session")
  local lines = {
    title,
    L("Enemy players met: %d. Wins: %d. Losses: %d. New Kill on Sight: %d."):format(
      report.contacts,
      report.wins,
      report.losses,
      report.newKos
    ),
  }
  if report.mostSeen then
    lines[#lines + 1] = L("Most seen: %s (%d times)"):format(report.mostSeen.name, report.mostSeen.count)
  end
  if report.nemesis then
    lines[#lines + 1] = L("Nemesis: %s (%d losses)"):format(report.nemesis.name, report.nemesis.count)
  end
  if report.hottestZone then
    local map = report.hottestZone.map
    local name = zoneName and zoneName(map) or nil
    name = name or L("map %d"):format(map)
    lines[#lines + 1] = L("Hottest zone: %s (%d contacts)"):format(name, report.hottestZone.count)
  end
  if report.approximate then
    lines[#lines + 1] = L("The records keep no seasons: this counts the players last seen in the season.")
  end
  return lines
end

ns.IntelReport = IntelReport
