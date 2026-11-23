local _, ns = ...

-- PvP counters of one character, kept on this client only. Pure: it never touches the client API, so every
-- rule is tested with plain tables.
--
--   stats = { honor = { world, bg }, blows = { world, bg },
--             daily = { ["YYYY-MM-DD"] = { honor = { world, bg }, blows = { world, bg } } } }
--
-- Besides the totals there are the season counters: stats.season = { id, world, bg } holds the honourable kills made
-- while season `id` was the active one (PvPSeasonService). They restart from zero when another season begins; the
-- all-time totals never do. Saved data without them keeps loading.
--
-- "honor" is honourable kills (yours and group credit), "blows" are killing blows; "world" is anywhere
-- outside a battleground and "bg" is inside one. Days are server dates in UTC (Platform.ServerDay).
local PvPService = {}

local WHERE = { world = true, bg = true }

-- Season points from kills: one per world kill and one per BG_KILLS_PER_POINT battleground kills (rounded down).
local BG_KILLS_PER_POINT = 5

local function count(value)
  if type(value) == "number" and value >= 0 and value % 1 == 0 and value < math.huge then
    return value
  end
  return 0
end

local function ensurePair(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end
  local pair = parent[key]
  pair.world = count(pair.world)
  pair.bg = count(pair.bg)
  return pair
end

local function ensureDay(bucket)
  ensurePair(bucket, "honor")
  ensurePair(bucket, "blows")
  return bucket
end

local function isDay(text)
  return type(text) == "string" and text:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

-- Fills in whatever is missing and repairs what is not a count (old or damaged saved data). Returns `stats`,
-- or a new table when it is not one.
function PvPService.Ensure(stats)
  if type(stats) ~= "table" then
    stats = {}
  end
  ensurePair(stats, "honor")
  ensurePair(stats, "blows")
  if type(stats.daily) ~= "table" then
    stats.daily = {}
  end
  local season = stats.season
  if type(season) == "table" and type(season.id) == "string" and season.id ~= "" then
    season.world = count(season.world)
    season.bg = count(season.bg)
  else
    stats.season = nil
  end
  for day, bucket in pairs(stats.daily) do
    if isDay(day) and type(bucket) == "table" then
      ensureDay(bucket)
    else
      stats.daily[day] = nil
    end
  end
  return stats
end

-- Sets every counter back to zero, in place (an admin reset). The tracker's baseline is not touched, so the
-- session kills already counted are not counted again.
function PvPService.Reset(stats)
  stats.honor = { world = 0, bg = 0 }
  stats.blows = { world = 0, bg = 0 }
  stats.daily = {}
  stats.season = nil
  return stats
end

local function dailyBucket(stats, day)
  if not isDay(day) then
    return nil
  end
  if type(stats.daily[day]) ~= "table" then
    stats.daily[day] = {}
  end
  return ensureDay(stats.daily[day])
end

-- The season counters for `seasonId`, started from zero when they belong to another season.
local function seasonCounters(stats, seasonId)
  if type(stats.season) ~= "table" or stats.season.id ~= seasonId then
    stats.season = { id = seasonId, world = 0, bg = 0 }
  end
  return stats.season
end

-- Adds `delta` honourable kills to the `where` ("world" | "bg") counters, in the total and in the bucket of
-- `day`, and, when `seasonId` is given, in the counters of that season (which start from zero when the saved ones
-- are of another season). Returns true when something was counted; a delta that is not a positive whole number is
-- ignored.
function PvPService.RecordHonorKills(stats, delta, where, day, seasonId)
  if not WHERE[where] or count(delta) <= 0 then
    return false
  end
  PvPService.Ensure(stats)
  stats.honor[where] = stats.honor[where] + delta
  if type(seasonId) == "string" and seasonId ~= "" then
    local season = seasonCounters(stats, seasonId)
    season[where] = season[where] + delta
  end
  local bucket = dailyBucket(stats, day)
  if bucket then
    bucket.honor[where] = bucket.honor[where] + delta
  end
  return true
end

function PvPService.RecordKillingBlow(stats, where, day)
  if not WHERE[where] then
    return false
  end
  PvPService.Ensure(stats)
  stats.blows[where] = stats.blows[where] + 1
  local bucket = dailyBucket(stats, day)
  if bucket then
    bucket.blows[where] = bucket.blows[where] + 1
  end
  return true
end

-- The world and battleground kills counted for season `seasonId`: zeros when the counters are of another season.
function PvPService.SeasonKills(stats, seasonId)
  stats = PvPService.Ensure(stats)
  local season = stats.season
  if season and season.id == seasonId then
    return season.world, season.bg
  end
  return 0, 0
end

-- The season points that `world` and `bg` kills are worth.
function PvPService.SeasonPoints(world, bg)
  return count(world) + math.floor(count(bg) / BG_KILLS_PER_POINT)
end

-- Raises the local counters to the ones of `record` (what the guild holds for this character: the shape of a
-- PVP_STATS record) when those are higher, never lowering anything. This is how a character whose saved counters were
-- lost (a new key, a reinstall) gets its kills back from the guild. Returns true when something changed.
function PvPService.Adopt(stats, record)
  stats = PvPService.Ensure(stats)
  if type(record) ~= "table" then
    return false
  end
  local changed = false
  local function raise(mine, theirs)
    if type(theirs) ~= "table" then
      return
    end
    for where in pairs(WHERE) do
      local value = count(theirs[where])
      if value > mine[where] then
        mine[where] = value
        changed = true
      end
    end
  end
  raise(stats.honor, record.honor)
  raise(stats.blows, record.blows)
  local season = record.season
  if type(season) == "table" and type(season.id) == "string" and season.id ~= "" then
    local mine = stats.season
    if mine == nil or mine.id ~= season.id then
      -- Only a character with no counters of that season takes it over; one already in another season keeps its own.
      if mine == nil then
        stats.season = { id = season.id, world = count(season.world), bg = count(season.bg) }
        changed = true
      end
    else
      raise(mine, season)
    end
  end
  return changed
end

local function summarize(honor, blows)
  return {
    honor = { world = honor.world, bg = honor.bg, total = honor.world + honor.bg },
    blows = { world = blows.world, bg = blows.bg, total = blows.world + blows.bg },
  }
end

-- { honor = { world, bg, total }, blows = { world, bg, total } } over all time.
function PvPService.Totals(stats)
  stats = PvPService.Ensure(stats)
  return summarize(stats.honor, stats.blows)
end

-- The same shape for one day; zeros when nothing was counted that day.
function PvPService.Today(stats, day)
  stats = PvPService.Ensure(stats)
  local bucket = isDay(day) and stats.daily[day] or { honor = { world = 0, bg = 0 }, blows = { world = 0, bg = 0 } }
  return summarize(bucket.honor, bucket.blows)
end

-- Days since a fixed origin for "YYYY-MM-DD" (proleptic Gregorian calendar), or nil for anything else. Only
-- used to compare days, so the origin does not matter.
local function dayNumber(day)
  if not isDay(day) then
    return nil
  end
  local year, month, date = day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, date = tonumber(year), tonumber(month), tonumber(date)
  if year < 1 or month < 1 or month > 12 or date < 1 or date > 31 then
    return nil
  end
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local yearOfEra = year - era * 400
  local shifted = month > 2 and month - 3 or month + 9
  local dayOfYear = math.floor((153 * shifted + 2) / 5) + date - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra
end

-- Drops the buckets older than `keepDays` days counting `today` as the first (keepDays = 30 keeps today and the
-- 29 days before it). The totals are not touched. Does nothing when `today` or `keepDays` is unusable.
function PvPService.Prune(stats, today, keepDays)
  PvPService.Ensure(stats)
  local current = dayNumber(today)
  if not current or type(keepDays) ~= "number" or keepDays < 1 then
    return
  end
  local oldest = current - keepDays + 1
  for day in pairs(stats.daily) do
    local number = dayNumber(day)
    if not number or number < oldest then
      stats.daily[day] = nil
    end
  end
end

-- The rank for `kills` honourable kills in `ranks` (Constants.PVP_RANKS: lowest first):
--   { index, name, next = { name, kills, remaining } }, with next = nil at the top rank.
-- Below the first threshold there is no rank yet: { next = ... } without index or name. Entries that are not a
-- { name, kills } pair are skipped, so a typo in the constants never breaks the tab.
function PvPService.RankFor(kills, ranks)
  kills = count(kills)
  local result = {}
  for _, rank in ipairs(type(ranks) == "table" and ranks or {}) do
    if type(rank) == "table" and type(rank.name) == "string" and type(rank.kills) == "number" then
      if kills >= rank.kills then
        result.index, result.name = (result.index or 0) + 1, rank.name
      else
        result.next = { name = rank.name, kills = rank.kills, remaining = rank.kills - kills }
        return result
      end
    end
  end
  return result
end

ns.PvPService = PvPService
