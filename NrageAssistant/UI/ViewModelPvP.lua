local _, ns = ...

-- Structured rows for the PvP seasons (docs/PVP_MISSIONS_PLAN.md, phases 4 and 5): the season card, the standings, the
-- mission cards, the admin forms and the history. Everything here is pure: the tab reads the service and the mission
-- tracker, and hands the plain data to these functions; nothing here touches the client.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

local DAY = 86400

-- Positions 1 to PRIZE_POSITIONS win a prize; the standings table draws a dashed line below them.
local PRIZE_POSITIONS = 10

-- How many evidence rows an approver sees before "and N more".
local EVIDENCE_SHOWN = 8

-- ---------------------------------------------------------------------------------------------------------------
-- Sub-tabs

-- The sub-tabs of the PvP tab. The admin views are their own tab (UI/Tabs/PvPAdmin.lua).
function ViewModel.PvPSubTabs()
  local tabs = {
    { value = "season", text = L("Season") },
    { value = "missions", text = L("Missions") },
    { value = "stats", text = L("Stats") },
    { value = "feed", text = L("Recent kills") },
    { value = "history", text = L("History") },
    { value = "intel", text = L("Intel") },
  }
  -- The Intel sub-tab belongs to the intel module (Domain/ModuleRegistry); without the module it is not offered.
  if ns.modules and not ns.modules:IsEnabled("intel") then
    for index, tab in ipairs(tabs) do
      if tab.value == "intel" then
        table.remove(tabs, index)
      end
    end
  end
  return tabs
end

-- The views of the Stats sub-tab (the two screens PvP had before the seasons).
function ViewModel.PvPStatsViews()
  return {
    { value = "mine", text = L("My stats") },
    { value = "ranking", text = L("Kill ranking") },
  }
end

-- The history views.
function ViewModel.PvPHistoryViews()
  return {
    { value = "season", text = L("By season") },
    { value = "total", text = L("Cumulative") },
  }
end

-- The sections of the Admin sub-tab. An admin (gm or cogm) sees all six.
-- `options` = { manage = boolean (admin), pending = number of claims waiting }.
function ViewModel.PvPAdminSections(options)
  local pending = options.pending or 0
  local sections = {
    { value = "approvals", text = pending > 0 and L("Approvals (%d)"):format(pending) or L("Approvals") },
    { value = "progress", text = L("Progress") },
  }
  if options.manage then
    sections[#sections + 1] = { value = "missions", text = L("Missions") }
    sections[#sections + 1] = { value = "season", text = L("Season") }
    sections[#sections + 1] = { value = "prizes", text = L("Prizes") }
  end
  sections[#sections + 1] = { value = "deliveries", text = L("Deliveries") }
  return sections
end

-- The section to show: the one asked for when it exists, else the first.
function ViewModel.PvPPick(items, value)
  for _, item in ipairs(items) do
    if item.value == value then
      return value
    end
  end
  return items[1] and items[1].value or nil
end

-- Why a season action was refused, in words (the reasons of PvPSeasonService and PvPSeasonSync.Apply).
ViewModel.PVP_ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("you are not allowed to do that."),
    no_season = L("no season is running."),
    closed = L("the season is closed."),
    not_found = L("that record is not there any more."),
    decided = L("it was decided already."),
    unknown_mission = L("that mission does not exist."),
    unknown_player = L("that player is not in the guild."),
    roster_not_ready = L("the guild roster is still loading: try again in a moment."),
    unchanged = L("nothing changed."),
    inactive = L("the mission is paused."),
    out_of_season = L("that is outside the season dates."),
    limit = L("the limit was reached."),
    active_exists = L("a season is running already."),
    stale = L("a newer version exists."),
  }
end)

-- "Not saved: <why>" for a reason code such as "forbidden" or "invalid:points".
function ViewModel.PvPError(reason)
  reason = tostring(reason)
  local text = ViewModel.PVP_ERRORS[reason]
  if not text then
    local field = reason:match("^invalid:(.+)$")
    text = field and L("the value of '%s' is not valid."):format(field) or reason
  end
  return L("Not saved: ") .. text
end

-- ---------------------------------------------------------------------------------------------------------------
-- Dates

-- "1 Oct" from a timestamp. `clock` (optional, for tests) = { date }.
local function shortDate(timestamp, clock)
  local _, month, day = ns.Kit.Calendar.Parts(timestamp, clock)
  return ("%d %s"):format(day, ViewModel.MONTHS[month])
end
ViewModel.PvPShortDate = shortDate

-- "1 Oct - 31 Oct".
local function dateRange(from, to, clock)
  return ("%s \226\128\147 %s"):format(shortDate(from, clock), shortDate(to, clock))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Rewards and tiers

ViewModel.PVP_TIER_LABELS = ns.Locale.Table(function()
  return {
    ["1"] = L("1st"),
    ["2"] = L("2nd"),
    ["3"] = L("3rd"),
    ["4-6"] = L("4th-6th"),
    ["7-10"] = L("7th-10th"),
  }
end)

-- The color token of a tier chip: the podium colors, then the accent and a quiet one.
local TIER_TOKENS = { ["1"] = "gold", ["2"] = "silver", ["3"] = "bronze", ["4-6"] = "accent", ["7-10"] = "muted" }

function ViewModel.PvPTierToken(tier)
  return TIER_TOKENS[tier] or "muted"
end

-- "500 gold", "Flask of Titans x1".
function ViewModel.PvPRewardText(reward)
  if reward.kind == "gold" then
    return L("%d gold"):format(reward.amount)
  end
  local name = Escape(reward.name or "?")
  if (reward.count or 1) > 1 then
    return ("%s \195\151%d"):format(name, reward.count)
  end
  return name
end

local function rewardsText(rewards)
  local parts = {}
  for _, reward in ipairs(rewards or {}) do
    parts[#parts + 1] = ViewModel.PvPRewardText(reward)
  end
  if #parts == 0 then
    return "-"
  end
  return table.concat(parts, " + ")
end
ViewModel.PvPRewardsText = rewardsText

-- The prizes of a season as one row per tier: { tier, label, token, rewards, text }. `tiers` = prizes.tiers or nil.
function ViewModel.PvPPrizeRows(tiers)
  local rows = {}
  for _, tier in ipairs(ns.Constants.PVP_PRIZE_TIERS) do
    local rewards = tiers and tiers[tier] or {}
    rows[#rows + 1] = {
      tier = tier,
      label = ViewModel.PVP_TIER_LABELS[tier],
      token = ViewModel.PvPTierToken(tier),
      rewards = rewards,
      text = rewardsText(rewards),
    }
  end
  return rows
end

-- A copy of a `tiers` map with every tier present (so the editor can add to an empty one).
function ViewModel.PvPTiersCopy(tiers)
  local copy = {}
  for _, tier in ipairs(ns.Constants.PVP_PRIZE_TIERS) do
    copy[tier] = {}
    for index, reward in ipairs(tiers and tiers[tier] or {}) do
      local entry = {}
      for key, value in pairs(reward) do
        entry[key] = value
      end
      copy[tier][index] = entry
    end
  end
  return copy
end

-- A new `tiers` map with `reward` added to `tier`; nil plus "invalid:limit" when the tier is full.
function ViewModel.PvPAddReward(tiers, tier, reward)
  local copy = ViewModel.PvPTiersCopy(tiers)
  if not copy[tier] then
    return nil, "invalid:tiers"
  end
  if #copy[tier] >= ns.Constants.PVP_PRIZE_ENTRIES_MAX then
    return nil, "invalid:limit"
  end
  copy[tier][#copy[tier] + 1] = reward
  return copy
end

-- A new `tiers` map without the reward at `index` of `tier`.
function ViewModel.PvPRemoveReward(tiers, tier, index)
  local copy = ViewModel.PvPTiersCopy(tiers)
  if copy[tier] then
    table.remove(copy[tier], index)
  end
  return copy
end

-- A gold reward from what was typed ("500"), or nil plus "invalid:gold".
function ViewModel.PvPGoldReward(text)
  local amount = tonumber((tostring(text or ""):gsub("%s", "")))
  if not amount or amount < 1 or amount ~= math.floor(amount) or amount > ns.Constants.PVP_PRIZE_GOLD_MAX then
    return nil, "invalid:gold"
  end
  return { kind = "gold", amount = amount }
end

-- An item reward from a pasted item link ("|cff...|Hitem:19019:0:...|h[Thunderfury]|h|r") and a count. The link itself
-- is not kept (the wire does not take "|"): only the item id and the name. nil plus a reason when the text is no link.
function ViewModel.PvPItemReward(link, count)
  local itemId, name = tostring(link or ""):match("|Hitem:(%d+)[^|]*|h%[(.-)%]|h")
  if not itemId then
    return nil, "invalid:item"
  end
  count = count == nil and 1 or tonumber(count)
  if not count or count < 1 or count ~= math.floor(count) or count > ns.Constants.PVP_PRIZE_ITEM_COUNT_MAX then
    return nil, "invalid:count"
  end
  name = name:gsub("|", ""):sub(1, ns.Constants.PVP_PRIZE_ITEM_NAME_MAX)
  return { kind = "item", itemId = tonumber(itemId), name = name, count = count }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Season and standings

-- The season card. `args` = { season, standings, player, now, clock }. Returns { name, range, status, ended, ownPos,
-- ownPoints, stats = { { caption, value, color } ... } }; the third stat is what the player lacks for the podium.
function ViewModel.PvPSeasonSummary(args)
  local season = args.season
  local own
  for _, row in ipairs(args.standings or {}) do
    if row.player == args.player then
      own = row
    end
  end
  local ended = args.now > season.endsAt
  local status
  if ended then
    status = L("ended, waiting to be closed")
  elseif args.now < season.startsAt then
    status = L("starts in %d day(s)"):format(math.ceil((season.startsAt - args.now) / DAY))
  elseif season.endsAt - args.now < DAY then
    status = L("ends today")
  else
    status = L("ends in %d day(s)"):format(math.ceil((season.endsAt - args.now) / DAY))
  end

  local toThird, toThirdColor
  if own and own.pos <= 3 then
    toThird, toThirdColor = L("On the podium"), "success"
  else
    local third = args.standings and args.standings[3]
    local needed = third and (third.points - (own and own.points or 0) + 1) or ns.Constants.PVP_MIN_POINTS
    toThird = "+" .. tostring(math.max(needed, ns.Constants.PVP_MIN_POINTS))
  end
  return {
    name = Escape(season.name),
    range = dateRange(season.startsAt, season.endsAt, args.clock),
    status = status,
    ended = ended,
    ownPos = own and own.pos or nil,
    ownPoints = own and own.points or 0,
    stats = {
      { caption = L("Your position"), value = own and L("#%d"):format(own.pos) or "-" },
      { caption = L("Your points"), value = tostring(own and own.points or 0) },
      { caption = L("To the 3rd place"), value = toThird, color = toThirdColor },
    },
  }
end

-- How many grants each player has that count: a map player -> number, from PvPSeasonService:Grants.
function ViewModel.PvPGrantCounts(grants)
  local counts = {}
  for _, grant in ipairs(grants or {}) do
    if grant.counts and not grant.voided then
      counts[grant.player] = (counts[grant.player] or 0) + 1
    end
  end
  return counts
end

-- The standings as table rows. `standings` = PvPSeasonService:Standings. `options` = { player (the own name), missions
-- (player -> number of grants), now, limit }. Between position 10 and 11 comes a row with `separator = true` (the line
-- under the last prize). Returns { rows, shown, total }.
function ViewModel.PvPStandingRows(standings, options)
  local rows = {}
  local total = #standings
  for index, standing in ipairs(standings) do
    if options.limit and index > options.limit then
      break
    end
    if index == PRIZE_POSITIONS + 1 then
      rows[#rows + 1] = { separator = true }
    end
    local tier = standing.tier
    rows[#rows + 1] = {
      pos = standing.pos,
      positionToken = ns.Kit.Theme.PositionToken(standing.pos),
      name = Escape(standing.player),
      tier = tier and { text = ViewModel.PVP_TIER_LABELS[tier], color = ViewModel.PvPTierToken(tier) } or nil,
      missions = tostring(options.missions and options.missions[standing.player] or 0),
      points = tostring(standing.points),
      last = (standing.lastAt and options.now) and ViewModel.AgeText(math.max(0, options.now - standing.lastAt)) or "-",
      mine = standing.player == options.player,
    }
  end
  local shown = 0
  for _, row in ipairs(rows) do
    if not row.separator then
      shown = shown + 1
    end
  end
  return { rows = rows, shown = shown, total = total }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Missions

ViewModel.PVP_GOAL_KINDS = ns.Locale.Table(function()
  return {
    kills = L("Player kills"),
    kos = L("Kill on Sight kills"),
    bg_wins = L("Battleground wins"),
    manual = L("Manual"),
    bg_played = L("Battlegrounds played"),
  }
end)

ViewModel.PVP_BATTLEGROUNDS = ns.Locale.Table(function()
  return { wsg = L("Warsong Gulch"), ab = L("Arathi Basin"), av = L("Alterac Valley") }
end)

ViewModel.PVP_PLACES = ns.Locale.Table(function()
  return { any = L("Anywhere"), world = L("Open world"), bg = L("Battleground") }
end)

ViewModel.PVP_DISTINCT = ns.Locale.Table(function()
  return {
    none = L("None"),
    name = L("Distinct names"),
    class = L("Distinct classes"),
    race = L("Distinct races"),
    class_race = L("Distinct classes and races"),
  }
end)

ViewModel.PVP_REPEATS = ns.Locale.Table(function()
  return { once = L("Once"), daily = L("Daily"), weekly = L("Weekly") }
end)

local GOAL_ORDER = { "kills", "kos", "bg_wins", "manual", "bg_played" }
local BG_ORDER = { "wsg", "ab", "av" }
local PLACE_ORDER = { "any", "world", "bg" }
local DISTINCT_ORDER = { "none", "name", "class", "race", "class_race" }
local REPEAT_ORDER = { "once", "daily", "weekly" }

local function choices(order, words, skip)
  local items = {}
  for _, value in ipairs(order) do
    if not (skip and skip[value]) then
      items[#items + 1] = { value = value, text = words[value] }
    end
  end
  return items
end

-- The goal kinds the form offers: battleground wins only when the client can tell (`availability.bgWins ~= false`).
function ViewModel.PvPGoalChoices(availability)
  local skip = {}
  if availability and availability.bgWins == false then
    skip.bg_wins = true
    skip.bg_played = true
  end
  return choices(GOAL_ORDER, ViewModel.PVP_GOAL_KINDS, skip)
end

-- The battlegrounds of the Advanced section as chip items.
function ViewModel.PvPBattlegroundChoices()
  local items = {}
  for _, token in ipairs(BG_ORDER) do
    items[#items + 1] = { value = token, text = ViewModel.PVP_BATTLEGROUNDS[token] }
  end
  return items
end

-- The enemy classes and races of the other side as chip items, for a player of `faction` (nil: an Alliance guild).
function ViewModel.PvPEnemyChoices(faction)
  local classTokens, raceTokens = ns.PvPMissionTracker.EnemySets(faction)
  local classes, races = {}, {}
  for _, token in ipairs(classTokens) do
    classes[#classes + 1] = { value = token, text = ViewModel.ClassText(token) or token }
  end
  for _, token in ipairs(raceTokens) do
    races[#races + 1] = { value = token, text = ViewModel.PvPRaceText(token) }
  end
  return classes, races
end

function ViewModel.PvPPlaceChoices()
  return choices(PLACE_ORDER, ViewModel.PVP_PLACES)
end

function ViewModel.PvPDistinctChoices()
  return choices(DISTINCT_ORDER, ViewModel.PVP_DISTINCT)
end

function ViewModel.PvPRepeatChoices()
  return choices(REPEAT_ORDER, ViewModel.PVP_REPEATS)
end

function ViewModel.PvPActiveChoices()
  return {
    { value = true, text = L("Active") },
    { value = false, text = L("Paused") },
  }
end

-- The criteria of a mission as short chips: zones, what to do, how often. `zoneName(mapId)` (optional) names a zone.
function ViewModel.PvPCriteriaChips(mission, zoneName)
  local goal = mission.goal
  local chips = {}
  local function add(text)
    chips[#chips + 1] = text
  end
  if goal.kind == "manual" then
    add(L("Manual"))
  else
    local zones = goal.zones or {}
    if #zones > 0 then
      local names = {}
      for _, mapId in ipairs(zones) do
        names[#names + 1] = Escape(zoneName and zoneName(mapId) or tostring(mapId))
      end
      add((#names == 1 and L("Zone: %s") or L("Zones: %s")):format(table.concat(names, ", ")))
    end
    if goal.kind == "bg_wins" or goal.kind == "bg_played" then
      add(L("Battleground"))
      add((goal.kind == "bg_wins" and L("%d wins") or L("%d played")):format(goal.count))
      if #(goal.bgs or {}) > 0 then
        local names = {}
        for _, token in ipairs(goal.bgs) do
          names[#names + 1] = ViewModel.PVP_BATTLEGROUNDS[token] or token
        end
        add(table.concat(names, ", "))
      end
    else
      if goal.kind == "kos" then
        add(goal.target and L("Bounty: %s"):format(Escape(goal.target)) or L("Kill on Sight"))
      end
      local distinct = goal.distinct or "none"
      if distinct ~= "none" then
        add(ViewModel.PVP_DISTINCT[distinct])
      end
      if distinct == "none" or distinct == "name" then
        add(L("%d kills"):format(goal.count))
      end
      if goal.place == "world" or goal.place == "bg" then
        add(ViewModel.PVP_PLACES[goal.place])
      end
      if #(goal.victimClasses or {}) > 0 then
        local names = {}
        for _, token in ipairs(goal.victimClasses) do
          names[#names + 1] = Escape(ViewModel.ClassText(token) or token)
        end
        add(L("Classes: %s"):format(table.concat(names, ", ")))
      end
      if #(goal.victimRaces or {}) > 0 then
        local names = {}
        for _, token in ipairs(goal.victimRaces) do
          names[#names + 1] = Escape(ViewModel.PvPRaceText(token))
        end
        add(L("Races: %s"):format(table.concat(names, ", ")))
      end
      if goal.victimCapPerDay ~= nil then
        add(
          goal.victimCapPerDay == 0 and L("No cap per victim")
            or L("Max %d per victim per day"):format(goal.victimCapPerDay)
        )
      end
      if (goal.minGuildInGroup or 0) > 0 then
        add(L("%d+ guildmates in the group"):format(goal.minGuildInGroup))
      end
    end
    if goal.window then
      add(L("Event window"))
    end
    if goal.maxCompletions then
      add(L("Max %d completions"):format(goal.maxCompletions))
    end
    if goal.autoClaim then
      add(L("Auto-claim"))
    end
  end
  add(ViewModel.PVP_REPEATS[mission.repeatKind] or mission.repeatKind)
  if (mission.perPlayer or 1) > 1 then
    add(L("%d times each"):format(mission.perPlayer))
  end
  return chips
end

-- Which detection the client needs for a mission goal: a list of availability keys.
local function requirements(goal)
  local needs = {}
  if goal.kind == "bg_wins" or goal.kind == "bg_played" then
    needs[#needs + 1] = "bgWins"
  elseif goal.kind == "kills" or goal.kind == "kos" then
    needs[#needs + 1] = "kills"
    if #(goal.zones or {}) > 0 then
      needs[#needs + 1] = "zones"
    end
    local distinct = goal.distinct
    if
      distinct == "class"
      or distinct == "race"
      or distinct == "class_race"
      or #(goal.victimClasses or {}) > 0
      or #(goal.victimRaces or {}) > 0
    then
      needs[#needs + 1] = "classRace"
    end
  end
  return needs
end

-- Can this client detect what the goal asks? `availability` = ns.pvpMissions:Availability() (nil: assume it can).
function ViewModel.PvPGoalAvailable(goal, availability)
  if not availability then
    return true
  end
  for _, key in ipairs(requirements(goal)) do
    if availability[key] == false then
      return false
    end
  end
  return true
end

-- When the current period of a mission starts (UTC): the day, the ISO week or the season, and not before the start of
-- its event window. Nil without a clock.
function ViewModel.PvPCountsFrom(mission, now, season)
  if type(now) ~= "number" then
    return nil
  end
  local days = math.floor(now / DAY)
  local start
  if mission.repeatKind == "daily" then
    start = days * DAY
  elseif mission.repeatKind == "weekly" then
    -- 1970-01-01 was a Thursday: (days + 3) % 7 is the number of days since Monday.
    start = (days - (days + 3) % 7) * DAY
  else
    start = season and season.startsAt or nil
  end
  local window = mission.goal and mission.goal.window
  if window and (not start or window.startsAt > start) then
    start = window.startsAt
  end
  if not start then
    return nil
  end
  return L("Counts from %s"):format(ViewModel.DateText(start) or tostring(start))
end

-- The cards of the Missions sub-tab. `options` = {
--   tracker      true when the mission tracker exists on this client (false: no progress, no claims),
--   progressOf   function(missionId) -> progress | nil,       claimStateOf function(missionId) -> state,
--   availability the tracker's Availability() or nil,         ended true when the season date has passed,
--   labelText    function(label) -> text (the tracker's translation of a bar label, optional),
--   zoneName     function(mapId) -> text | nil,
--   now          the server time, and season the active season (both optional: with them a card says since when it
--                counts) }
-- A card = { id, title, desc, points, chips, rules, countsFrom, bars = { { label, text, ratio, complete } },
-- status = { text, color } | nil, note, canClaim, noteRequired, unavailable }.
function ViewModel.PvPMissionCards(missions, options)
  local cards = {}
  for _, mission in ipairs(missions) do
    local goal = mission.goal
    local unavailable
    if not options.tracker or not ViewModel.PvPGoalAvailable(goal, options.availability) then
      unavailable = L("Not available on this client")
    end
    local progress = (options.tracker and not unavailable) and options.progressOf(mission.id) or nil
    local state = (options.tracker and not unavailable) and options.claimStateOf(mission.id) or "none"
    local bars = {}
    for _, bar in ipairs(progress and progress.bars or {}) do
      bars[#bars + 1] = {
        label = Escape(options.labelText and options.labelText(bar.label) or bar.label),
        text = ("%d / %d"):format(bar.done, bar.total),
        ratio = bar.total > 0 and math.min(1, bar.done / bar.total) or 0,
        complete = bar.done >= bar.total,
      }
    end
    local status
    if state == "pending" then
      status = { text = L("Pending approval"), color = "warning" }
    elseif state == "approved" then
      status = { text = L("Approved"), color = "success" }
    elseif state == "rejected" then
      status = { text = L("Rejected"), color = "danger" }
    elseif progress and progress.complete and progress.claimable and goal.kind ~= "manual" then
      status = { text = L("Ready to claim"), color = "accent" }
    elseif progress and #bars > 0 and not progress.complete then
      status = { text = L("In progress"), color = "muted" }
    end
    local manual = goal.kind == "manual"
    local claimable = progress == nil and manual or (progress ~= nil and progress.claimable == true)
    local canClaim = options.tracker
      and not unavailable
      and not options.ended
      and claimable
      and state ~= "pending"
      and state ~= "approved"
    local note
    if progress and (progress.unknown or 0) > 0 then
      note = L("%d kill(s) without a known class: you never had the victim as a target."):format(progress.unknown)
        .. " "
        .. L("When you claim, the approver decides whether they count.")
    end
    cards[#cards + 1] = {
      id = mission.id,
      title = Escape(mission.title),
      desc = Escape(mission.desc or ""),
      points = L("+%d pts"):format(mission.points),
      chips = ViewModel.PvPCriteriaChips(mission, options.zoneName),
      rules = Escape(
        ViewModel.PvPMissionSummary(mission, { zoneName = options.zoneName, dateText = ViewModel.DateText })
      ),
      countsFrom = ViewModel.PvPCountsFrom(mission, options.now, options.season),
      bars = bars,
      status = status,
      note = note,
      canClaim = canClaim == true,
      noteRequired = manual,
      unavailable = unavailable,
    }
  end
  return cards
end

-- The missions of the admin table: { id, title, criteria, points, status, token, active }.
function ViewModel.PvPMissionRows(missions, zoneName)
  local rows = {}
  for _, mission in ipairs(missions) do
    rows[#rows + 1] = {
      id = mission.id,
      title = Escape(mission.title),
      criteria = table.concat(ViewModel.PvPCriteriaChips(mission, zoneName), " \194\183 "),
      points = tostring(mission.points),
      status = mission.active and L("Active") or L("Paused"),
      token = mission.active and "success" or "muted",
      active = mission.active,
    }
  end
  return rows
end

-- ---------------------------------------------------------------------------------------------------------------
-- The mission form

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A whole number from typed text, or nil.
local function wholeNumber(text)
  local number = tonumber(trim(text))
  if number and number == math.floor(number) then
    return number
  end
  return nil
end

-- Map ids typed as "1454, 1453" -> { 1454, 1453 }; nil when a piece is no number. Empty text is an empty list.
function ViewModel.PvPParseZones(text)
  local zones = {}
  for piece in tostring(text or ""):gmatch("[^,;%s]+") do
    local mapId = wholeNumber(piece)
    if not mapId then
      return nil
    end
    zones[#zones + 1] = mapId
  end
  return zones
end

local function copyList(list)
  local copy = {}
  for index, value in ipairs(list or {}) do
    copy[index] = value
  end
  return copy
end

-- Adds or takes out `token` of the list `draft[field]` (the chips of the advanced options). Returns the list.
function ViewModel.PvPToggleToken(draft, field, token, on)
  local kept = {}
  for _, value in ipairs(draft[field] or {}) do
    if value ~= token then
      kept[#kept + 1] = value
    end
  end
  if on then
    kept[#kept + 1] = token
  end
  draft[field] = kept
  return kept
end

-- The values the form starts with (a new mission), or those of `mission` (to edit it). Numbers are text, as typed.
function ViewModel.PvPMissionDraft(mission)
  if not mission then
    return {
      title = "",
      desc = "",
      kind = "kills",
      count = "10",
      points = "10",
      zones = "",
      place = "any",
      distinct = "none",
      target = "",
      repeatKind = "once",
      perPlayer = "1",
      active = true,
      bgs = {},
      victimClasses = {},
      victimRaces = {},
      victimCap = "",
      minGuild = "",
      windowOn = false,
      windowStart = nil,
      windowEnd = nil,
      maxCompletions = "",
      autoClaim = false,
    }
  end
  local goal = mission.goal
  return {
    id = mission.id,
    title = mission.title,
    desc = mission.desc or "",
    kind = goal.kind,
    count = tostring(goal.count or 1),
    points = tostring(mission.points),
    zones = table.concat(goal.zones or {}, ", "),
    place = goal.place or "any",
    distinct = goal.distinct or "none",
    target = goal.target or "",
    repeatKind = mission.repeatKind,
    perPlayer = tostring(mission.perPlayer or 1),
    active = mission.active ~= false,
    bgs = copyList(goal.bgs),
    victimClasses = copyList(goal.victimClasses),
    victimRaces = copyList(goal.victimRaces),
    victimCap = goal.victimCapPerDay ~= nil and tostring(goal.victimCapPerDay) or "",
    minGuild = goal.minGuildInGroup and tostring(goal.minGuildInGroup) or "",
    windowOn = goal.window ~= nil,
    windowStart = goal.window and goal.window.startsAt or nil,
    windowEnd = goal.window and goal.window.endsAt or nil,
    maxCompletions = goal.maxCompletions and tostring(goal.maxCompletions) or "",
    autoClaim = goal.autoClaim == true,
  }
end

-- A number typed in an optional box: nil when it is empty, false when it is not a whole number.
local function optionalNumber(text)
  if trim(text) == "" then
    return nil
  end
  return wholeNumber(text) or false
end

-- The optional goal fields of a draft (the Advanced section): only what the draft sets and what applies to its kind.
-- Returns the table, or nil plus "invalid:<field>" for a number that is not one or a window that is incomplete.
function ViewModel.PvPAdvancedFields(draft)
  local fields = {}
  local kind = draft.kind
  local kills = kind == "kills" or kind == "kos"
  local battlegrounds = kind == "bg_wins" or kind == "bg_played"
  if battlegrounds and #(draft.bgs or {}) > 0 then
    fields.bgs = copyList(draft.bgs)
  end
  if kills then
    if #(draft.victimClasses or {}) > 0 then
      fields.victimClasses = copyList(draft.victimClasses)
    end
    if #(draft.victimRaces or {}) > 0 then
      fields.victimRaces = copyList(draft.victimRaces)
    end
    local cap = optionalNumber(draft.victimCap)
    if cap == false then
      return nil, "invalid:victimCapPerDay"
    end
    fields.victimCapPerDay = cap
    local guild = optionalNumber(draft.minGuild)
    if guild == false then
      return nil, "invalid:minGuildInGroup"
    end
    fields.minGuildInGroup = guild
  end
  if kind ~= "manual" and draft.windowOn then
    if not (draft.windowStart and draft.windowEnd) then
      return nil, "invalid:window"
    end
    fields.window = { startsAt = draft.windowStart, endsAt = draft.windowEnd }
  end
  local completions = optionalNumber(draft.maxCompletions)
  if completions == false then
    return nil, "invalid:maxCompletions"
  end
  fields.maxCompletions = completions
  if draft.autoClaim == true and kind ~= "manual" then
    fields.autoClaim = true
  end
  return fields
end

-- Does the draft set anything of the Advanced section? (The form opens it then.)
function ViewModel.PvPHasAdvanced(draft)
  local fields = ViewModel.PvPAdvancedFields(draft)
  return fields ~= nil and next(fields) ~= nil
end

-- The fields PvPSeasonService:UpsertMission takes, from a draft; or nil plus "invalid:<field>" for a number or a zone
-- list that is not one. The rest (ranges, lengths) is checked by the service.
function ViewModel.PvPMissionFields(draft)
  local points = wholeNumber(draft.points)
  if not points then
    return nil, "invalid:points"
  end
  local perPlayer = wholeNumber(draft.perPlayer)
  if not perPlayer then
    return nil, "invalid:perPlayer"
  end
  local goal = { kind = draft.kind, count = 1, zones = {}, place = "any", distinct = "none" }
  if draft.kind ~= "manual" then
    local count = wholeNumber(draft.count)
    if not count then
      return nil, "invalid:count"
    end
    goal.count = count
    local zones = ViewModel.PvPParseZones(draft.zones)
    if not zones then
      return nil, "invalid:zones"
    end
    goal.zones = zones
    if draft.kind == "kills" then
      goal.place = draft.place or "any"
      goal.distinct = draft.distinct or "none"
    elseif draft.kind == "kos" then
      goal.place = draft.place or "any"
      local target = type(draft.target) == "string" and draft.target:match("^%s*(.-)%s*$") or ""
      if target ~= "" then
        goal.target = target
      end
    end
  end
  local advanced, reason = ViewModel.PvPAdvancedFields(draft)
  if not advanced then
    return nil, reason
  end
  for key, value in pairs(advanced) do
    goal[key] = value
  end
  return {
    id = draft.id,
    title = draft.title,
    desc = draft.desc,
    points = points,
    goal = goal,
    repeatKind = draft.repeatKind,
    perPlayer = perPlayer,
    active = draft.active ~= false,
  }
end

-- The built-in templates of the form: { id, name, set } where `set` gives the draft values that differ from a new
-- mission. Every one is a mission the detection of this client can follow.
local PRESETS = {
  {
    id = "weekly_wsg",
    name = function()
      return L("Weekly Warsong Gulch wins")
    end,
    set = function()
      return {
        title = L("Warsong Gulch wins"),
        kind = "bg_wins",
        count = "3",
        points = "50",
        repeatKind = "weekly",
        bgs = { "wsg" },
      }
    end,
  },
  {
    id = "daily_20",
    name = function()
      return L("Daily 20 kills")
    end,
    set = function()
      return { title = L("Daily hunt"), kind = "kills", count = "20", points = "20", repeatKind = "daily" }
    end,
  },
  {
    id = "kos_bounty",
    name = function()
      return L("Kill on Sight bounty")
    end,
    set = function()
      return { title = L("Kill on Sight bounty"), kind = "kos", count = "1", points = "30", repeatKind = "daily" }
    end,
  },
  {
    id = "group_up",
    name = function()
      return L("Group up: 5 kills with 3 guildmates")
    end,
    set = function()
      return {
        title = L("Group up"),
        kind = "kills",
        count = "5",
        points = "30",
        repeatKind = "daily",
        minGuild = "3",
      }
    end,
  },
  {
    id = "av_veteran",
    name = function()
      return L("Alterac Valley veteran")
    end,
    set = function()
      return {
        title = L("Alterac Valley veteran"),
        kind = "bg_played",
        count = "5",
        points = "100",
        repeatKind = "once",
        bgs = { "av" },
      }
    end,
  },
}

-- The templates as dropdown items.
function ViewModel.PvPPresetChoices()
  local items = {}
  for _, preset in ipairs(PRESETS) do
    items[#items + 1] = { value = preset.id, text = preset.name() }
  end
  return items
end

-- Fills `draft` (a new mission) from a template: it starts again from the blank form, so nothing of the previous
-- choices is left behind. Returns true, or false for an unknown template.
function ViewModel.PvPApplyPreset(draft, id)
  for _, preset in ipairs(PRESETS) do
    if preset.id == id then
      local fresh = ViewModel.PvPMissionDraft(nil)
      for key, value in pairs(preset.set()) do
        fresh[key] = value
      end
      for key in pairs(draft) do
        draft[key] = nil
      end
      for key, value in pairs(fresh) do
        draft[key] = value
      end
      return true
    end
  end
  return false
end

-- A sentence that says what the mission counts, from the fields PvPMissionFields gives (the live line under the form):
-- "Counts honourable kills in Arathi Basin, 10 times, max 1 per victim per day, 50 points, weekly."
-- `options` = { zoneName = function(mapId) -> text | nil, dateText = function(timestamp) -> text }.
function ViewModel.PvPMissionSummary(fields, options)
  options = options or {}
  local goal = fields.goal
  local parts = {}
  local function add(text)
    parts[#parts + 1] = text
  end
  if goal.kind == "manual" then
    add(L("Counts nothing by itself: the member claims it with a note"))
  else
    local what = {
      kills = L("Counts honourable kills"),
      kos = L("Counts Kill on Sight kills"),
      bg_wins = L("Counts battleground wins"),
      bg_played = L("Counts battlegrounds played"),
    }
    local places = {}
    for _, mapId in ipairs(goal.zones or {}) do
      places[#places + 1] = options.zoneName and options.zoneName(mapId) or tostring(mapId)
    end
    for _, token in ipairs(goal.bgs or {}) do
      places[#places + 1] = ViewModel.PVP_BATTLEGROUNDS[token] or token
    end
    if goal.place == "world" or goal.place == "bg" then
      places[#places + 1] = ViewModel.PVP_PLACES[goal.place]
    end
    local first = what[goal.kind] or what.kills
    if goal.target then
      first = first .. " " .. L("of %s"):format(goal.target)
    end
    if #places > 0 then
      first = first .. " " .. L("in %s"):format(table.concat(places, ", "))
    end
    add(first)
    if goal.distinct and goal.distinct ~= "none" then
      add(L("distinct by %s"):format(ViewModel.PVP_DISTINCT[goal.distinct]:lower()))
    else
      add(L("%d times"):format(goal.count))
    end
    if #(goal.victimClasses or {}) > 0 then
      local names = {}
      for _, token in ipairs(goal.victimClasses) do
        names[#names + 1] = ViewModel.ClassText(token) or token
      end
      add(L("victims of class %s"):format(table.concat(names, ", ")))
    end
    if #(goal.victimRaces or {}) > 0 then
      local names = {}
      for _, token in ipairs(goal.victimRaces) do
        names[#names + 1] = ViewModel.PvPRaceText(token)
      end
      add(L("victims of race %s"):format(table.concat(names, ", ")))
    end
    if goal.victimCapPerDay ~= nil then
      add(
        goal.victimCapPerDay == 0 and L("no cap per victim")
          or L("max %d per victim per day"):format(goal.victimCapPerDay)
      )
    end
    if (goal.minGuildInGroup or 0) > 0 then
      add(L("with at least %d guildmates in the group"):format(goal.minGuildInGroup))
    end
    if goal.window and options.dateText then
      add(L("only from %s to %s"):format(options.dateText(goal.window.startsAt), options.dateText(goal.window.endsAt)))
    end
  end
  add(L("%d points"):format(fields.points))
  add(ViewModel.PVP_REPEATS[fields.repeatKind]:lower())
  if (fields.perPlayer or 1) > 1 then
    add(L("%d times each"):format(fields.perPlayer))
  end
  if goal.maxCompletions then
    add(L("at most %d completions per member"):format(goal.maxCompletions))
  end
  if goal.autoClaim then
    add(L("claimed automatically"))
  end
  return table.concat(parts, ", ") .. "."
end

-- The Progress section of the admin: one block per mission with how far each member says they are.
-- `board` = PvPSeasonService:ProgressBoard(seasonId), `missions` = the missions of the season, `options` = { now }.
-- A block = { id, title, goal, rows = { { player, text, ratio, status = { text, color }, updated } } }, blocks by
-- title;
-- missions nobody reported on are left out.
function ViewModel.PvPProgressBlocks(board, missions, options)
  local blocks = {}
  for _, mission in ipairs(missions) do
    local list = board[mission.id]
    if list and #list > 0 then
      local rows = {}
      for _, entry in ipairs(list) do
        local status
        if entry.claimed then
          status = { text = L("Claimed"), color = "warning" }
        elseif entry.ready then
          status = { text = L("Ready to claim"), color = "accent" }
        else
          status = { text = L("In progress"), color = "muted" }
        end
        rows[#rows + 1] = {
          player = Escape(entry.player),
          text = ("%d / %d"):format(entry.count, entry.goal),
          ratio = entry.goal > 0 and math.min(1, entry.count / entry.goal) or 0,
          status = status,
          updated = options and options.now and ViewModel.AgeText(math.max(0, options.now - entry.at)) or "",
        }
      end
      blocks[#blocks + 1] = { id = mission.id, title = Escape(mission.title), goal = mission.goal, rows = rows }
    end
  end
  return blocks
end

-- The keys (IntelModel.Key) of the players an open bounty names: the active missions of kind "kos" with a target.
-- `missions` is PvPSeasonService:Missions(seasonId) (paused ones are not in it).
function ViewModel.PvPBountyKeys(missions)
  local keys = {}
  for _, mission in ipairs(missions or {}) do
    local goal = mission.goal
    if mission.active ~= false and goal and goal.kind == "kos" and goal.target then
      local key = ns.IntelModel.Key(goal.target)
      if key then
        keys[key] = true
      end
    end
  end
  return keys
end

-- The seasons a mission set can be cloned from: the ones other than `activeId` that hold missions, newest first, as
-- dropdown items. `seasons` = PvPSeasonService:Seasons(), `countOf(seasonId)` = how many missions it holds.
function ViewModel.PvPCloneChoices(seasons, activeId, countOf)
  local items = {}
  for _, season in ipairs(seasons) do
    local count = season.id ~= activeId and countOf(season.id) or 0
    if count > 0 then
      items[#items + 1] = { value = season.id, text = ("%s (%d)"):format(Escape(season.name), count) }
    end
  end
  return items
end

-- ---------------------------------------------------------------------------------------------------------------
-- Approvals

local RACE_NAMES = ns.Locale.Table(function()
  return {
    Human = L("Human"),
    Dwarf = L("Dwarf"),
    NightElf = L("Night Elf"),
    Gnome = L("Gnome"),
    Draenei = L("Draenei"),
    Orc = L("Orc"),
    Scourge = L("Undead"),
    Tauren = L("Tauren"),
    Troll = L("Troll"),
    BloodElf = L("Blood Elf"),
  }
end)

-- The race file tokens the interface sees upper-cased (the log keeps them like that), as text.
local RACE_NAMES_UPPER = ns.Locale.Table(function()
  return {
    HUMAN = L("Human"),
    DWARF = L("Dwarf"),
    NIGHTELF = L("Night Elf"),
    GNOME = L("Gnome"),
    DRAENEI = L("Draenei"),
    ORC = L("Orc"),
    SCOURGE = L("Undead"),
    TAUREN = L("Tauren"),
    TROLL = L("Troll"),
    BLOODELF = L("Blood Elf"),
  }
end)

-- A race file token as text (the token itself when it is not a known one).
function ViewModel.PvPRaceText(token)
  return RACE_NAMES[token] or RACE_NAMES_UPPER[token] or tostring(token)
end

local SUMMARY_PARTS = {
  {
    "done",
    "total",
    function(done, total)
      return L("%d of %d kills"):format(done, total)
    end,
  },
  {
    "classes",
    "classesTotal",
    function(done, total)
      return L("%d of %d classes"):format(done, total)
    end,
  },
  {
    "races",
    "racesTotal",
    function(done, total)
      return L("%d of %d races"):format(done, total)
    end,
  },
}

-- What a claim says it counted: "10 of 10 kills", "8 of 8 classes · 4 of 4 races · 1 without a known class".
local function summaryText(claim)
  local summary = claim.summary or {}
  local parts = {}
  for _, part in ipairs(SUMMARY_PARTS) do
    local done, total = summary[part[1]], summary[part[2]]
    if done and total then
      parts[#parts + 1] = part[3](done, total)
    end
  end
  if (summary.unknown or 0) > 0 then
    parts[#parts + 1] = L("%d without a known class"):format(summary.unknown)
  end
  if #parts == 0 then
    return L("Manual mission")
  end
  return table.concat(parts, " \194\183 ")
end

-- The evidence of a claim as rows: { time, victim, zone, info, unknown }. A kill whose class or race the claimant's
-- client never saw has `unknown = true` (drawn in amber).
local function evidenceRows(claim, options)
  local rows = {}
  for index, entry in ipairs(claim.evidence or {}) do
    if index > EVIDENCE_SHOWN then
      break
    end
    local zone
    if entry.mapId and options.zoneName then
      zone = options.zoneName(entry.mapId)
    end
    zone = zone
      or (entry.mapId and L("Zone %d"):format(entry.mapId))
      or ViewModel.PVP_PLACES[entry.place or "any"]
      or "-"
    local info, unknown
    if entry.bgWin ~= nil then
      info = entry.bgWin and L("Battleground win") or L("Battleground loss")
    elseif entry.class or entry.race then
      local parts = {}
      if entry.class then
        parts[#parts + 1] = ViewModel.ClassText(entry.class)
      end
      if entry.race then
        parts[#parts + 1] = ViewModel.PvPRaceText(entry.race)
      end
      info = table.concat(parts, " \194\183 ")
    else
      info, unknown = L("Unknown class"), true
    end
    rows[#rows + 1] = {
      time = options.formatClock and options.formatClock(entry.at) or tostring(entry.at),
      victim = entry.bgWin ~= nil and "-" or Escape(entry.victim or "?"),
      zone = Escape(zone),
      info = Escape(info),
      unknown = unknown == true,
    }
  end
  return rows
end

-- The claims waiting for a decision as rows: { id, who, mission, points, summary, when, note, evidence, more }.
-- `options` = { missionOf(id), now, formatClock, zoneName }.
function ViewModel.PvPClaimRows(claims, options)
  local rows = {}
  for _, claim in ipairs(claims) do
    local mission = options.missionOf(claim.missionId)
    local total = #(claim.evidence or {})
    rows[#rows + 1] = {
      id = claim.id,
      who = Escape(claim.player),
      mission = Escape(mission and mission.title or "?"),
      points = mission and L("+%d pts"):format(mission.points) or "",
      summary = summaryText(claim),
      when = ViewModel.AgeText(math.max(0, options.now - claim.at)),
      note = (claim.note and claim.note ~= "") and Escape(claim.note) or nil,
      evidence = evidenceRows(claim, options),
      more = total > EVIDENCE_SHOWN and L("and %d more"):format(total - EVIDENCE_SHOWN) or nil,
    }
  end
  return rows
end

-- ---------------------------------------------------------------------------------------------------------------
-- Closing, deliveries and history

-- What closing the season warns about: the number of claims that will expire, or nil.
function ViewModel.PvPCloseWarning(pending)
  if pending > 0 then
    return L("%d claim(s) are still pending and will expire when you close."):format(pending)
      .. " "
      .. L("The ranking is frozen and the delivery list is made.")
  end
  return L("The ranking is frozen and the delivery list is made.")
end

-- "Delivered - GM - 1 Oct" or nil when not delivered.
local function deliveredText(row, clock)
  if not row.delivered then
    return nil
  end
  local parts = { L("Delivered") }
  if row.updatedBy then
    parts[#parts + 1] = Escape(row.updatedBy)
  end
  if row.updatedAt then
    parts[#parts + 1] = shortDate(row.updatedAt, clock)
  end
  return table.concat(parts, " \194\183 ")
end

-- The delivery list as rows: { pos, positionToken, player, tier, tierText, reward, delivered }; `delivered` is the
-- status text, or nil when the prize is still to hand over. Returns { rows, delivered, total }.
function ViewModel.PvPDeliveryRows(deliveries, clock)
  local rows, done = {}, 0
  for _, delivery in ipairs(deliveries) do
    if delivery.delivered then
      done = done + 1
    end
    rows[#rows + 1] = {
      pos = delivery.pos,
      positionToken = ns.Kit.Theme.PositionToken(delivery.pos),
      player = Escape(delivery.player),
      raw = delivery.player,
      tier = { text = ViewModel.PVP_TIER_LABELS[delivery.tier], color = ViewModel.PvPTierToken(delivery.tier) },
      reward = rewardsText(delivery.rewards),
      delivered = deliveredText(delivery, clock),
    }
  end
  return { rows = rows, delivered = done, total = #rows }
end

-- The closed seasons as dropdown items, newest first. `finals` = PvPSeasonService:Finals().
function ViewModel.PvPFinalChoices(finals)
  local items = {}
  for _, final in ipairs(finals) do
    items[#items + 1] = { value = final.seasonId, text = Escape(final.name) }
  end
  return items
end

-- "Closed on 30 Sep - 7 of 10 delivered".
function ViewModel.PvPDeliveryHeader(final, delivered, total, clock)
  return L("Closed on %s, %d of %d delivered"):format(shortDate(final.closedAt, clock), delivered, total)
end

-- The "by season" cards of the history. `finals` = PvPSeasonService:Finals(); `deliveriesOf(seasonId)` = its delivery
-- rows. A card = { seasonId, name, dates, podium = { { pos, token, name, points } },
-- delivery = { text, color } | nil }.
function ViewModel.PvPHistoryCards(finals, deliveriesOf, clock)
  local cards = {}
  for _, final in ipairs(finals) do
    local podium = {}
    for index = 1, math.min(3, #final.standings) do
      local standing = final.standings[index]
      podium[index] = {
        pos = L("#%d"):format(standing.pos),
        token = ns.Kit.Theme.PositionToken(standing.pos),
        name = Escape(standing.player),
        points = L("%d pts"):format(standing.points),
      }
    end
    local deliveries = ViewModel.PvPDeliveryRows(deliveriesOf(final.seasonId), clock)
    local delivery
    if deliveries.total > 0 then
      delivery = {
        text = L("Deliveries %d / %d"):format(deliveries.delivered, deliveries.total),
        color = deliveries.delivered >= deliveries.total and "success" or "warning",
      }
    end
    cards[#cards + 1] = {
      seasonId = final.seasonId,
      name = Escape(final.name),
      dates = dateRange(final.startsAt, final.endsAt, clock),
      podium = podium,
      delivery = delivery,
    }
  end
  return cards
end

-- The full final standing of a season as table rows: { pos, positionToken, name, tier, points }.
function ViewModel.PvPFinalRows(final)
  local rows = {}
  for _, standing in ipairs(final.standings) do
    local tier = ns.PvPSeasonModel.TierOf(standing.pos)
    rows[#rows + 1] = {
      pos = standing.pos,
      positionToken = ns.Kit.Theme.PositionToken(standing.pos),
      name = Escape(standing.player),
      tier = tier and { text = ViewModel.PVP_TIER_LABELS[tier], color = ViewModel.PvPTierToken(tier) } or nil,
      points = tostring(standing.points),
    }
  end
  return rows
end

-- The all-time ranking as table rows. `cumulative` = PvPSeasonService:Cumulative(); `player` flags the own row.
function ViewModel.PvPCumulativeRows(cumulative, player)
  local rows = {}
  for _, row in ipairs(cumulative) do
    rows[#rows + 1] = {
      pos = row.pos,
      positionToken = ns.Kit.Theme.PositionToken(row.pos),
      name = Escape(row.player),
      seasons = tostring(row.seasons),
      podiums = tostring(row.podiums),
      points = tostring(row.points),
      mine = row.player == player,
    }
  end
  return rows
end
