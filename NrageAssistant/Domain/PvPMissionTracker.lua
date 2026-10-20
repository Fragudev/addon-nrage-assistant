local _, ns = ...
local L = ns.L

-- How far a character is in a PvP mission (docs/PVP_MISSIONS_PLAN.md, 2.4). Pure: it only reads the kill log it is
-- given, so the rules are tested without a client.
--
-- A log row is `{ at, victim, mapId?, place, class?, race? }` for a kill and `{ at, bgWin = true, mapId? }` for a
-- battleground win. The rules, in order:
--   1. The per-victim cap (D14) is applied to the whole log first, before any mission filter: a victim counts at
--      most PVP_VICTIM_DAILY_CAP times per server day (UTC), across all missions.
--   2. A row counts for a mission when it is inside the season dates and the current period of the mission, matches
--      its zones (a row without a map id never matches a zone) and its place (kills), and is of the right kind.
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
      local key = ns.PvPSeasonModel.DayKey(row.at) .. "|" .. row.victim:lower()
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

local function evidenceRow(row)
  if row.bgWin then
    return { at = row.at, bgWin = true, mapId = row.mapId }
  end
  return { at = row.at, victim = row.victim, mapId = row.mapId, place = row.place, class = row.class, race = row.race }
end

-- The first PVP_CLAIM_EVIDENCE_MAX rows of `rows` (already in time order) as evidence.
local function evidenceOf(rows)
  local evidence = {}
  for _, row in ipairs(rows) do
    if #evidence >= ns.Constants.PVP_CLAIM_EVIDENCE_MAX then
      break
    end
    evidence[#evidence + 1] = evidenceRow(row)
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
local function mergedEvidence(lists)
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
  return evidenceOf(merged)
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
-- (char.pvpMissions.claims: { [claimId] = { claim, state } }), which says how many claims the period already has;
-- `season` (optional) gives the dates.
--
-- Returns { bars = { { label, done, total } }, unknown, complete, couldComplete, claimable, periodKey, evidence,
-- nextN } where `nextN` is the claim number the next claim would use (n of the claim id) and `claimable` says whether
-- a claim is allowed now (complete, or able to complete once the approver counts the unknown ones; the mission is
-- active; the season is running; the period still has a free claim).
function PvPMissionTracker.Progress(mission, kills, now, claims, season)
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
  local rows = {}
  if goal.kind ~= "manual" then
    for _, row in ipairs(PvPMissionTracker.CapVictims(kills or {})) do
      local kindOk = wantsWins and row.bgWin == true or (not wantsWins and row.victim ~= nil and not row.bgWin)
      local placeOk = wantsWins or goal.place == "any" or goal.place == nil or row.place == goal.place
      local seasonOk = not season or ns.PvPSeasonModel.Contains(season, row.at)
      if
        kindOk
        and placeOk
        and seasonOk
        and ns.PvPSeasonModel.PeriodKey(mission.repeatKind, row.at) == periodKey
        and inZones(goal.zones, row)
      then
        rows[#rows + 1] = row
      end
    end
  end

  local constants = ns.Constants
  if goal.kind == "manual" then
    result.complete = true
    result.couldComplete = true
  elseif wantsWins then
    result.bars[1] = { label = "Victories", done = math.min(#rows, goal.count), total = goal.count }
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
    result.evidence = evidenceOf(firsts)
  elseif goal.distinct == "class" or goal.distinct == "race" or goal.distinct == "class_race" then
    local dimensions = {}
    if goal.distinct ~= "race" then
      dimensions[#dimensions + 1] = { label = "Classes", field = "class", tokens = constants.PVP_ENEMY_CLASSES }
    end
    if goal.distinct ~= "class" then
      dimensions[#dimensions + 1] = { label = "Races", field = "race", tokens = constants.PVP_ENEMY_RACES }
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
    result.evidence = mergedEvidence(lists)
  else
    result.bars[1] = { label = "Kills", done = math.min(#rows, goal.count), total = goal.count }
    result.complete = #rows >= goal.count
    result.evidence = evidenceOf(rows)
  end
  result.couldComplete = result.couldComplete or result.complete

  local running = mission.active ~= false
    and (not season or (season.state == "active" and now >= season.startsAt and now <= season.endsAt))
  result.claimable = running and result.couldComplete and result.nextN <= (mission.perPlayer or 1)
  return result
end

ns.PvPMissionTracker = PvPMissionTracker
