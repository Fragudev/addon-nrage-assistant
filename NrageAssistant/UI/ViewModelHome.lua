local _, ns = ...

-- Structured rows for the Profile, Readiness and Members tabs, and the next-event row that the Events tab reuses
-- (plan 3.4): functions that return tables of values, not lines of text, so the frames only draw them and every
-- decision is tested here.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- ---------------------------------------------------------------------------------------------------------------
-- Dates

ViewModel.WEEKDAYS = ns.Locale.Table(function()
  return {
    L("Mon"),
    L("Tue"),
    L("Wed"),
    L("Thu"),
    L("Fri"),
    L("Sat"),
    L("Sun"),
  }
end)

ViewModel.MONTHS = ns.Locale.Table(function()
  return {
    L("Jan"),
    L("Feb"),
    L("Mar"),
    L("Apr"),
    L("May"),
    L("Jun"),
    L("Jul"),
    L("Aug"),
    L("Sep"),
    L("Oct"),
    L("Nov"),
    L("Dec"),
  }
end)

ViewModel.MONTHS_LONG = ns.Locale.Table(function()
  return {
    L("January"),
    L("February"),
    L("March"),
    L("April"),
    L("May"),
    L("June"),
    L("July"),
    L("August"),
    L("September"),
    L("October"),
    L("November"),
    L("December"),
  }
end)

-- "Thu 23 Oct · 20:30" in local time, from a timestamp. `clock` (optional, for tests) = { date }.
function ViewModel.DateText(timestamp, clock)
  if type(timestamp) ~= "number" then
    return nil
  end
  local Calendar = ns.Kit.Calendar
  local year, month, day, hour, minute = Calendar.Parts(timestamp, clock)
  local weekday = Calendar.Weekday(year, month, day) + 1
  return ("%s %d %s \194\183 %02d:%02d"):format(ViewModel.WEEKDAYS[weekday], day, ViewModel.MONTHS[month], hour, minute)
end

local function ageText(seconds)
  if seconds < 60 then
    return L("just now")
  elseif seconds < 3600 then
    return L("%d min ago"):format(math.floor(seconds / 60))
  elseif seconds < 86400 then
    return L("%d h ago"):format(math.floor(seconds / 3600))
  end
  return L("%d d ago"):format(math.floor(seconds / 86400))
end
ViewModel.AgeText = ageText

-- "Last published: 3 min ago", or "Not published yet" when there is no publication.
function ViewModel.LastPublished(at, now)
  if type(at) ~= "number" then
    return L("Not published yet")
  end
  return L("Last published: %s"):format(ageText(math.max(0, now - at)))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Home

-- The nearest upcoming event for the Home card: { eventId, title, when, status, statusText } or nil when none is
-- planned. Past and cancelled events are ignored (an open event is kept until it is closed). `events` is what the
-- viewer sees (RosterService.FilterEvents).
function ViewModel.NextEventCard(events, now)
  -- The soonest dated one; an undated event only when nothing is dated.
  local best = ViewModel.NextEvent(events, now)
  if not best then
    return nil
  end
  return {
    eventId = best.eventId,
    title = Escape(best.title),
    when = ViewModel.DateText(best.startAt),
    status = best.status,
    statusText = ViewModel.Word(best.status),
    statusToken = ns.Kit.Theme.StatusToken(best.status),
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Profile

-- The character name without the ruleset suffix ("Name-ClassicBetaPvP" -> "Name"); a multi-word name stays whole.
function ViewModel.CharacterName(identityKey)
  if type(identityKey) ~= "string" then
    return "?"
  end
  return (identityKey:gsub("%-[^%-]*$", ""))
end

-- A class token ("DEATHKNIGHT") as text: the client's own name when it has one, else the token written like a name.
function ViewModel.ClassText(token)
  if type(token) ~= "string" or token == "" then
    return nil
  end
  local names = _G.LOCALIZED_CLASS_NAMES_MALE
  if type(names) == "table" and type(names[token]) == "string" then
    return names[token]
  end
  return token:sub(1, 1) .. token:sub(2):lower()
end

-- The first line of the Profile tab: name, class (in the class color), level and item level.
function ViewModel.IdentityStats(profile, identityKey)
  local function value(text)
    return text ~= nil and tostring(text) or L("unknown")
  end
  return {
    { caption = L("Name"), value = Escape(ViewModel.CharacterName(identityKey)) },
    {
      caption = L("Class"),
      value = Escape(value(ViewModel.ClassText(profile.class))),
      classToken = profile.class,
      color = profile.class and "class" or "muted",
    },
    { caption = L("Level"), value = value(profile.level) },
    { caption = L("Item level"), value = value(profile.ilvl) },
  }
end

-- The icon of a profession: its own (a profile read on this client) or the one this client saw for that name (a
-- profile received from a member). nil when unknown. Icons stay local; they are never published.
function ViewModel.ProfessionIcon(profession)
  if profession.icon ~= nil then
    return profession.icon
  end
  local platform = ns.Platform
  return platform and platform.ProfessionIcon and platform.ProfessionIcon(profession.name) or nil
end

-- The professions in two groups, primary first:
-- { primary = { { name, icon, skill, max, text } }, secondary = { ... } }. A
-- profession flagged `secondary` is secondary; a list with no flags (an older client) counts its first two as primary.
function ViewModel.ProfessionGroups(professions)
  local groups = { primary = {}, secondary = {} }
  local flagged = false
  for _, profession in ipairs(professions or {}) do
    flagged = flagged or profession.secondary ~= nil
  end
  for index, profession in ipairs(professions or {}) do
    local secondary = profession.secondary == true or (not flagged and index > 2)
    local skill = profession.max and ("%d/%d"):format(profession.skill, profession.max) or tostring(profession.skill)
    local entry = {
      name = Escape(profession.name),
      icon = ViewModel.ProfessionIcon(profession),
      skill = profession.skill,
      max = profession.max,
      text = skill,
    }
    local group = secondary and groups.secondary or groups.primary
    group[#group + 1] = entry
  end
  return groups
end

-- ---------------------------------------------------------------------------------------------------------------
-- Readiness

-- The page of the Readiness tab: a summary badge and one row per rule. A manual rule (confirmed by hand) carries its
-- status for the dropdown; failing values are danger, pending ones warning. `rules`, `results` and `summary` are what
-- ReadinessService.Evaluate worked with.
function ViewModel.ReadinessRows(rules, results, summary)
  local rows = {}
  for index, rule in ipairs(rules) do
    local outcome = results[index]
    local token = outcome.status == "met" and "success" or (outcome.status == "missing" and "danger" or "warning")
    if outcome.status == "waived" or outcome.status == "notApplicable" then
      token = "muted"
    end
    rows[#rows + 1] = {
      ruleId = rule.id,
      status = outcome.status,
      title = Escape(outcome.label),
      detail = Escape(outcome.detail or ""),
      valueText = Escape(ns.ReadinessService.StatusText(outcome.status)),
      valueToken = token,
      manual = rule.check == "confirm" and { status = outcome.status } or nil,
    }
  end
  local failing = false
  for _, outcome in ipairs(results) do
    failing = failing or outcome.status == "missing"
  end
  local badge = "info"
  if summary.countable > 0 and summary.met == summary.countable then
    badge = "success"
  elseif failing then
    badge = "danger"
  elseif summary.met < summary.countable then
    badge = "warning"
  end
  return {
    badge = { text = L("%d of %d met"):format(summary.met, summary.countable), color = badge },
    rows = rows,
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Members

ViewModel.MEMBER_COLUMNS = { "name", "class", "level", "ilvl", "spec", "spec2", "roster", "role", "updated" }
local MEMBER_SORTABLE =
  { name = true, class = true, level = true, ilvl = true, spec = true, roster = true, role = true, updated = true }
ViewModel.MEMBER_FIRST_DESCENDING = { level = true, ilvl = true, updated = true }

-- Every guild member, merged with the profiles received from them. `args`:
--   entries     the guild roster (name -> { rankName, rankIndex, level, class, online }), ns.guildRoster.entries
--   received    db.global.roster (name -> profile)
--   rosters, members   db.global.rosters and db.global.members
--   now         server time (for the stale flag and the age)
--   ownKey      the own name, to flag the own row
--   viewer      RosterService.Viewer: a roster leader / member only lists what they may see? (see below)
--   onlyRoster  a roster id: only its members and the ones with no roster are listed (a raid leader's view)
--   search      part of a name; roster = rosterId | "none" | nil; spec = "Tank" | "Dps" | "Heal" | nil; addonOnly
--   sort        { key, descending } (default: name)
-- Every guild member is listed (the whole guild is the point of the tab); `viewer.mode == "roster"` for a raid leader
-- only affects the roster filter chips, not the rows. Nothing received is ever shown as verified: a profile older
-- than ROSTER_STALE_SECONDS is flagged stale. Returns rows and the total before the filters.
function ViewModel.MemberRows(args)
  local constants = ns.Constants
  local rows = {}
  local names = {}
  for name in pairs(args.entries or {}) do
    names[#names + 1] = name
  end
  -- Before the guild roster has loaded, the members that sent a profile are all there is.
  if #names == 0 then
    for name in pairs(args.received or {}) do
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(names) do
    local guild = (args.entries or {})[name] or {}
    local profile = (args.received or {})[name]
    local assignment = args.members and args.members[name]
    local rosterId = ns.RosterService.RosterOf(args.members or {}, args.rosters or {}, name)
    local fields = profile and profile.fields or {}
    local spec = fields.role
    -- The role is the guild rank, as the guild roster has it.
    local role = ns.PermissionService.RoleOfEntry(guild) or "alter"
    local classToken = (profile and profile.class) or guild.class
    local level = (profile and profile.level) or guild.level
    local receivedAt = profile and profile.receivedAt or nil
    rows[#rows + 1] = {
      key = name,
      name = Escape(name),
      sortName = name:lower(),
      noAddon = profile == nil,
      classToken = classToken,
      class = Escape(ViewModel.ClassText(classToken) or "-"),
      level = level,
      ilvl = profile and profile.ilvl or nil,
      spec = spec and Escape(spec) or nil,
      spec2 = fields.role2 and Escape(fields.role2) or nil,
      specKey = ns.ProfileService.NormalizeRole(spec),
      spec2Key = ns.ProfileService.NormalizeRole(fields.role2),
      rosterId = rosterId,
      rosterName = rosterId and Escape(ns.RosterService.NameOf(args.rosters, rosterId)) or nil,
      role = role,
      roleText = Escape(ViewModel.Word(role)),
      assigned = assignment ~= nil,
      isGuildMaster = ns.PermissionService.IsGuildMasterIndex(guild.rankIndex),
      mine = args.ownKey ~= nil and args.ownKey == name,
      receivedAt = receivedAt,
      stale = receivedAt ~= nil and args.now ~= nil and (args.now - receivedAt) > constants.ROSTER_STALE_SECONDS,
      updated = receivedAt and args.now and ageText(math.max(0, args.now - receivedAt)) or nil,
      professions = profile and profile.professions or nil,
      main = fields.main and Escape(fields.main) or nil,
    }
  end

  local total = #rows
  local needle = (args.search or ""):lower()
  local filtered = {}
  for _, row in ipairs(rows) do
    local keep = needle == "" or row.sortName:find(needle, 1, true) ~= nil
    if keep and args.onlyRoster then
      keep = row.rosterId == nil or row.rosterId == args.onlyRoster
    end
    if keep and args.addonOnly and row.noAddon then
      keep = false
    end
    if keep and args.roster then
      if args.roster == "none" then
        keep = row.rosterId == nil
      else
        keep = row.rosterId == args.roster
      end
    end
    if keep and args.spec then
      keep = row.specKey == args.spec or row.spec2Key == args.spec
    end
    if keep then
      filtered[#filtered + 1] = row
    end
  end

  local sort = args.sort or { key = "name", descending = false }
  local key, descending = sort.key, sort.descending
  if not MEMBER_SORTABLE[key] then
    key, descending = "name", false
  end
  local function value(row)
    if key == "name" then
      return row.sortName
    elseif key == "class" then
      return row.class:lower()
    elseif key == "spec" then
      return (row.spec or ""):lower()
    elseif key == "roster" then
      return (row.rosterName or ""):lower()
    elseif key == "role" then
      -- By authority (gm first), not by the name of the role.
      return ns.PermissionService.Rank(row.role) or math.huge
    elseif key == "updated" then
      -- Members with no profile sort as the oldest.
      return row.receivedAt or -math.huge
    end
    return row[key] or -1
  end
  table.sort(filtered, function(a, b)
    local left, right = value(a), value(b)
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.sortName < b.sortName
  end)
  return filtered, total
end

-- The filter chips of the roster column: one per roster plus "No roster", each with how many of the guild it holds.
-- `counts` is RosterService.Counts. Whoever sees every roster in Members (gm, cogm, officer) gets all of them; an rl
-- only its own roster's chip; the other ranks none.
function ViewModel.RosterChips(rosters, counts, role, ownRosterId)
  local chips = {}
  local scope = ns.PermissionService.Scope(role, "members_view", ownRosterId)
  if scope == "none" then
    return chips
  end
  for _, roster in ipairs(ns.RosterService.List(rosters)) do
    if scope == "all" or roster.id == ownRosterId then
      chips[#chips + 1] = { value = roster.id, text = ("%s (%d)"):format(Escape(roster.name), counts[roster.id] or 0) }
    end
  end
  if scope == "all" then
    chips[#chips + 1] = { value = "none", text = L("No roster (%d)"):format(counts.none or 0) }
  end
  return chips
end

-- What the expanded row shows: the professions in two groups, the main character and when the profile arrived.
function ViewModel.MemberDetail(row)
  local groups = ViewModel.ProfessionGroups(row.professions)
  local function listOf(group)
    local parts = {}
    for _, entry in ipairs(group) do
      parts[#parts + 1] = ("%s %s"):format(entry.name, entry.text)
    end
    return #parts > 0 and table.concat(parts, ", ") or L("none")
  end
  return {
    primary = listOf(groups.primary),
    secondary = listOf(groups.secondary),
    main = row.main or L("not declared"),
    updated = row.updated or L("No profile received"),
    hasProfile = not row.noAddon,
  }
end

-- The roster dropdown of a member row, or nil when the player may not change it (the row shows the roster as text).
-- gm and cogm: every roster or none, on any member but the guild master. rl: only its own roster or none, and only on a
-- member who is in it or in no roster. Everybody else (officer included): read-only. `row` = a MemberRows row.
function ViewModel.MemberRosterChoices(role, ownRosterId, row, rosters)
  if row.isGuildMaster then
    return nil
  end
  if ns.PermissionService.CanAll(role, "members_manage") then
    return ViewModel.RosterChoices(rosters, true)
  end
  if ns.RosterService.MayAssign(role, ownRosterId, row.rosterId, ownRosterId) ~= nil then
    return nil
  end
  local items = { { value = false, text = L("No roster") } }
  items[#items + 1] = { value = ownRosterId, text = Escape(rosters[ownRosterId].name) }
  return items
end

-- The rosters as dropdown items with a "No roster" first entry (value false).
function ViewModel.RosterChoices(rosters, includeNone)
  local items = {}
  if includeNone then
    items[#items + 1] = { value = false, text = L("No roster") }
  end
  for _, roster in ipairs(ns.RosterService.List(rosters)) do
    items[#items + 1] = { value = roster.id, text = Escape(roster.name) }
  end
  return items
end
