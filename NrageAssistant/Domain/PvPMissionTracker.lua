local _, ns = ...
local L = ns.L

-- How far a character is in a PvP mission (docs/PVP_MISSIONS_PLAN.md, 2.4). Pure: it only reads the kill log it is
-- given, so the rules are tested without a client.
--
-- A log row is `{ kind = "kill", at, victim, mapId?, place, class?, race?, kos? }` for a kill and
-- `{ kind = "duel", at, victim, mapId? }` for a duel the player won (a kill goal never counts it, a `duel_wins` goal
-- counts nothing else) and
-- `{ kind = "bg", result = "win" | "loss", at, mapId?, bg? }` for a battleground result (rows saved before schema 18
-- carry no `kind`, and a win is `{ at, bgWin = true }`: they still read the same). The rules, in order:
--   1. The per-victim cap (D14) is applied to the whole log first, before any mission filter: a victim counts at
--      most PVP_VICTIM_DAILY_CAP times per server day (UTC), across all missions.
--      A goal with its own `victimCapPerDay` replaces that: the cap is applied per mission, over the rows that match
--      the mission (0 = no cap).
--   2. A row counts for a mission when it is inside the season dates and the current period of the mission, matches
--      its zones (a row without a map id never matches a zone) and its place (kills), and is of the right kind. The
--      optional goal fields narrow it further: `window` (an event inside the season), `victimClasses` / `victimRaces`
--      (a victim whose class or race is unknown does not match), `minGuildInGroup` (the guild members in the group at
--      the kill, `guildInGroup` of the row, 0 when absent) and `bgs` (the battleground type of a result).
--   3. `distinct` turns the rows into a count of distinct names, or into the set of enemy classes and/or races. A
--      kill whose class or race is unknown does not fill a bar: it is counted in `unknown` and listed in the
--      evidence, and the claim stays possible when the known ones plus the unknown victims could fill the bars (the
--      approver decides).
local PvPMissionTracker = {}

-- The bar labels are English keys; the interface shows them with LabelText.
function PvPMissionTracker.LabelText(label)
  local texts = {
    ["Kills"] = L("Kills"),
    ["Classes"] = L("Classes"),
    ["Races"] = L("Races"),
    ["Distinct players"] = L("Distinct players"),
    ["Victories"] = L("Victories"),
    ["Duels won"] = L("Duels won"),
    ["Battlegrounds"] = L("Battlegrounds"),
  }
  return texts[label] or label
end

-- The name of a zone of PVP_MISSION_ZONES in the language of the client, or nil for a map id that is not in the list.
function PvPMissionTracker.ZoneName(mapId)
  local names = {
    ["Orgrimmar"] = L("Orgrimmar"),
    ["Stormwind City"] = L("Stormwind City"),
    ["Ironforge"] = L("Ironforge"),
    ["Darnassus"] = L("Darnassus"),
    ["Thunder Bluff"] = L("Thunder Bluff"),
    ["Undercity"] = L("Undercity"),
    ["Stranglethorn Vale"] = L("Stranglethorn Vale"),
    ["Hillsbrad Foothills"] = L("Hillsbrad Foothills"),
    ["Alterac Mountains"] = L("Alterac Mountains"),
    ["Ashenvale"] = L("Ashenvale"),
    ["Arathi Highlands"] = L("Arathi Highlands"),
  }
  for _, zone in ipairs(ns.Constants.PVP_MISSION_ZONES) do
    if zone.mapId == mapId then
      return names[zone.nameKey] or zone.nameKey
    end
  end
  return nil
end

-- The rows of `log` in time order (a copy), without the ones over the per-victim daily cap.
function PvPMissionTracker.CapVictims(log, cap)
  cap = cap or ns.Constants.PVP_VICTIM_DAILY_CAP
  local ordered = {}
  for index, row in ipairs(log) do
    ordered[#ordered + 1] = { row = row, index = index }
  end
  table.sort(ordered, function(a, b)
    if a.row.at ~= b.row.at then
      return a.row.at < b.row.at
    end
    return a.index < b.index
  end)
  local seen, kept = {}, {}
  for _, item in ipairs(ordered) do
    local row = item.row
    if row.victim then
      -- Duels and kills of the same opponent are capped apart: a duel never uses up a kill.
      local key = (row.kind == "duel" and "duel|" or "kill|")
        .. ns.PvPSeasonModel.DayKey(row.at)
        .. "|"
        .. row.victim:lower()
      seen[key] = (seen[key] or 0) + 1
      if seen[key] <= cap then
        kept[#kept + 1] = row
      end
    else
      kept[#kept + 1] = row
    end
  end
  return kept
end

local function inZones(zones, row)
  if not zones or #zones == 0 then
    return true
  end
  for _, mapId in ipairs(zones) do
    if row.mapId == mapId then
      return true
    end
  end
  return false
end

-- Is `row` a kill that counts for a bounty ("kos" goal)? The victim was on the guild KOS when the kill was logged, and
-- is the named target when the goal has one.
local function kosOk(goal, row)
  if goal.kind ~= "kos" then
    return true
  end
  if row.kos ~= true then
    return false
  end
  if goal.target == nil then
    return true
  end
  return ns.Validate.NameKey(row.victim) == ns.Validate.NameKey(goal.target)
end

-- Is `row` a battleground win of the log?
local function isWin(row)
  return row.bgWin == true or (row.kind == "bg" and row.result == "win")
end

local function isBg(row)
  return row.bgWin ~= nil or row.kind == "bg"
end

local function evidenceRow(row, withGuild)
  if row.kind == "duel" then
    return { at = row.at, victim = row.victim, mapId = row.mapId, duel = true }
  end
  if isBg(row) then
    return { at = row.at, bgWin = isWin(row), mapId = row.mapId, bg = row.bg }
  end
  return {
    at = row.at,
    victim = row.victim,
    mapId = row.mapId,
    place = row.place,
    class = row.class,
    race = row.race,
    kos = row.kos,
    guild = withGuild and (row.guildInGroup or 0) or nil,
  }
end

-- The first PVP_CLAIM_EVIDENCE_MAX rows of `rows` (already in time order) as evidence. `withGuild` adds the guild
-- members in the group to a kill (for a mission that asks for them).
local function evidenceOf(rows, withGuild)
  local evidence = {}
  for _, row in ipairs(rows) do
    if #evidence >= ns.Constants.PVP_CLAIM_EVIDENCE_MAX then
      break
    end
    evidence[#evidence + 1] = evidenceRow(row, withGuild)
  end
  return evidence
end

local function setOf(list)
  local set = {}
  for _, token in ipairs(list) do
    set[token] = true
  end
  return set
end

-- One dimension (class or race) of the rows: how many of the `tokens` were seen, the first row of each, and the rows
-- and distinct victims whose value is unknown.
local function dimension(rows, field, tokens)
  local set = setOf(tokens)
  local known, firsts, unknownRows, unknownVictims, victimSeen = 0, {}, {}, 0, {}
  local seen = {}
  for _, row in ipairs(rows) do
    local token = row[field]
    if token == nil then
      unknownRows[#unknownRows + 1] = row
      local key = row.victim:lower()
      if not victimSeen[key] then
        victimSeen[key] = true
        unknownVictims = unknownVictims + 1
        firsts[#firsts + 1] = row
      end
    elseif set[token] and not seen[token] then
      seen[token] = true
      known = known + 1
      firsts[#firsts + 1] = row
    end
  end
  return { known = known, total = #tokens, unknownVictims = unknownVictims, unknownRows = unknownRows, firsts = firsts }
end

-- Evidence made of the rows `lists` hold, each row once, in time order.
local function mergedEvidence(lists, withGuild)
  local seen, merged = {}, {}
  for _, list in ipairs(lists) do
    for _, row in ipairs(list) do
      if not seen[row] then
        seen[row] = true
        merged[#merged + 1] = row
      end
    end
  end
  table.sort(merged, function(a, b)
    return a.at < b.at
  end)
  return evidenceOf(merged, withGuild)
end

-- The enemy class and race tokens a distinct mission counts, for a player of `faction` ("Alliance" | "Horde"). Any
-- other value (an unreadable faction) gives the lists of an Alliance guild.
function PvPMissionTracker.EnemySets(faction)
  local constants = ns.Constants
  return constants.PVP_ENEMY_CLASSES_BY_FACTION[faction] or constants.PVP_ENEMY_CLASSES,
    constants.PVP_ENEMY_RACES_BY_FACTION[faction] or constants.PVP_ENEMY_RACES
end

-- Is `value` in the list `list` (nil or empty: no filter, everything is)?
local function inList(list, value)
  if not list or #list == 0 then
    return true
  end
  if value == nil then
    return false
  end
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function inWindow(window, row)
  return not window or (row.at >= window.startsAt and row.at <= window.endsAt)
end

-- The claims of the mission over the whole season that still count against `maxCompletions` (a rejected one does
-- not).
local function seasonClaims(claims, missionId)
  local used = 0
  for _, entry in pairs(claims or {}) do
    local claim = entry.claim
    if claim and claim.missionId == missionId and entry.state ~= "rejected" then
      used = used + 1
    end
  end
  return used
end

local function periodClaims(claims, missionId, periodKey)
  local used = 0
  for _, entry in pairs(claims or {}) do
    local claim = entry.claim
    if claim and claim.missionId == missionId and claim.periodKey == periodKey then
      used = used + 1
    end
  end
  return used
end

-- The progress of `mission` for the log `kills` at server time `now`. `claims` is the local claim table
-- (char.pvpClaims[seasonId]: { [claimId] = { claim, state } }), which says how many claims the period already has;
-- `season` (optional) gives the dates and `faction` (optional) the side of the player, which decides the enemy classes
-- and races of a class or race mission.
--
-- Returns { bars = { { label, done, total } }, unknown, complete, couldComplete, claimable, periodKey, evidence,
-- nextN, completions, maxedOut } where `nextN` is the claim number the next claim would use (n of the claim id),
-- `completions` the claims of the mission this season that still count and `maxedOut` whether `maxCompletions` is
-- reached, and `claimable` says whether a claim is allowed now (complete, or able to complete once the approver counts
-- the unknown ones; the mission is active; the season is running; the period still has a free claim; the season
-- limit of completions is not reached).
function PvPMissionTracker.Progress(mission, kills, now, claims, season, faction)
  local goal = mission.goal
  local periodKey = ns.PvPSeasonModel.PeriodKey(mission.repeatKind, now)
  local result = {
    bars = {},
    unknown = 0,
    complete = false,
    couldComplete = false,
    claimable = false,
    periodKey = periodKey,
    evidence = {},
    nextN = periodClaims(claims, mission.id, periodKey) + 1,
  }

  local wantsWins = goal.kind == "bg_wins"
  local wantsBg = wantsWins or goal.kind == "bg_played"
  local wantsDuels = goal.kind == "duel_wins"
  local rows = {}
  if goal.kind ~= "manual" then
    -- Without a cap of its own the mission reads the log after the global per-victim cap; with one, every row is read
    -- (sorted) and the cap is applied to the rows that match.
    local source = PvPMissionTracker.CapVictims(kills or {}, goal.victimCapPerDay ~= nil and math.huge or nil)
    for _, row in ipairs(source) do
      local kindOk
      if wantsBg then
        kindOk = isBg(row) and (not wantsWins or isWin(row)) and inList(goal.bgs, row.bg)
      elseif wantsDuels then
        kindOk = row.kind == "duel" and row.victim ~= nil
      else
        kindOk = row.victim ~= nil
          and row.kind ~= "duel"
          and not isBg(row)
          and inList(goal.victimClasses, row.class)
          and inList(goal.victimRaces, row.race)
          and (row.guildInGroup or 0) >= (goal.minGuildInGroup or 0)
      end
      local placeOk = wantsBg or wantsDuels or goal.place == "any" or goal.place == nil or row.place == goal.place
      local seasonOk = not season or ns.PvPSeasonModel.Contains(season, row.at)
      if
        kindOk
        and placeOk
        and seasonOk
        and ns.PvPSeasonModel.PeriodKey(mission.repeatKind, row.at) == periodKey
        and inWindow(goal.window, row)
        and inZones(goal.zones, row)
        and kosOk(goal, row)
      then
        rows[#rows + 1] = row
      end
    end
    if not wantsBg and (goal.victimCapPerDay or 0) > 0 then
      rows = PvPMissionTracker.CapVictims(rows, goal.victimCapPerDay)
    end
  end
  local withGuild = (goal.minGuildInGroup or 0) > 0

  if goal.kind == "manual" then
    result.complete = true
    result.couldComplete = true
  elseif wantsBg then
    result.bars[1] = {
      label = wantsWins and "Victories" or "Battlegrounds",
      done = math.min(#rows, goal.count),
      total = goal.count,
    }
    result.complete = #rows >= goal.count
    result.evidence = evidenceOf(rows)
  elseif goal.distinct == "name" then
    local seen, firsts = {}, {}
    for _, row in ipairs(rows) do
      local key = row.victim:lower()
      if not seen[key] then
        seen[key] = true
        firsts[#firsts + 1] = row
      end
    end
    result.bars[1] = { label = "Distinct players", done = math.min(#firsts, goal.count), total = goal.count }
    result.complete = #firsts >= goal.count
    result.evidence = evidenceOf(firsts, withGuild)
  elseif not wantsDuels and (goal.distinct == "class" or goal.distinct == "race" or goal.distinct == "class_race") then
    local dimensions = {}
    local enemyClasses, enemyRaces = PvPMissionTracker.EnemySets(faction)
    if goal.distinct ~= "race" then
      dimensions[#dimensions + 1] = { label = "Classes", field = "class", tokens = enemyClasses }
    end
    if goal.distinct ~= "class" then
      dimensions[#dimensions + 1] = { label = "Races", field = "race", tokens = enemyRaces }
    end
    local complete, could, lists, unknownRows = true, true, {}, {}
    for _, spec in ipairs(dimensions) do
      local found = dimension(rows, spec.field, spec.tokens)
      result.bars[#result.bars + 1] = { label = spec.label, done = found.known, total = found.total }
      complete = complete and found.known >= found.total
      could = could and found.known + found.unknownVictims >= found.total
      lists[#lists + 1] = found.firsts
      for _, row in ipairs(found.unknownRows) do
        unknownRows[row] = true
      end
    end
    for _ in pairs(unknownRows) do
      result.unknown = result.unknown + 1
    end
    result.complete = complete
    result.couldComplete = could
    result.evidence = mergedEvidence(lists, withGuild)
  else
    result.bars[1] = {
      label = wantsDuels and "Duels won" or "Kills",
      done = math.min(#rows, goal.count),
      total = goal.count,
    }
    result.complete = #rows >= goal.count
    result.evidence = evidenceOf(rows, withGuild)
  end
  result.couldComplete = result.couldComplete or result.complete

  local running = mission.active ~= false
    and (not season or (season.state == "active" and now >= season.startsAt and now <= season.endsAt))
  -- `maxCompletions` caps the claims of one member over the whole season, whatever the period.
  result.completions = seasonClaims(claims, mission.id)
  result.maxedOut = (goal.maxCompletions or 0) > 0 and result.completions >= goal.maxCompletions
  result.claimable = running
    and result.couldComplete
    and result.nextN <= (mission.perPlayer or 1)
    and not result.maxedOut
  return result
end

ns.PvPMissionTracker = PvPMissionTracker
