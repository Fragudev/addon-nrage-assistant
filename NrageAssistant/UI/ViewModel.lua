local _, ns = ...

-- Pure presentation logic for the window: turns state into lines of text. No frames, no client API,
-- so it is unit tested. Received data is escaped again here as a second line of defence.
local ViewModel = {}

local L = ns.L

-- "|" starts colour codes, links and textures in the client's text renderer.
function ViewModel.Escape(text)
  return (tostring(text):gsub("|", "||"))
end

-- How the states that the lists show are written (event status, attendance, session status, loot response,
-- readiness). The code keeps comparing and sending the English words; only what is shown changes.
local WORDS = {
  planned = L("planned"),
  open = L("open"),
  closed = L("closed"),
  cancelled = L("cancelled"),
  invited = L("invited"),
  confirmed = L("confirmed"),
  present = L("present"),
  late = L("late"),
  leftEarly = L("leftEarly"),
  absent = L("absent"),
  excused = L("excused"),
  unknown = L("unknown"),
  main = L("main"),
  off = L("off"),
  other = L("other"),
  member = L("member"),
  rl = L("raid leader"),
  council = L("loot council"),
  admin = L("admin"),
}

function ViewModel.Word(value)
  return WORDS[value] or value
end

-- The own guild rank and addon role, for the Home tab.
function ViewModel.RoleLine(identityKey, rank, role)
  return L("%s - guild rank: %s - addon role: %s"):format(
    ViewModel.Escape(identityKey),
    ViewModel.Escape(rank or "?"),
    role and ViewModel.Escape(ViewModel.Word(role)) or L("none")
  )
end

-- Why a declared profile field was not saved.
ViewModel.PROFILE_SET_ERRORS = {
  unknown_field = L("unknown field. Allowed: role, main, notes."),
  too_long = L("value is too long."),
  invalid_value = L("invalid value."),
}

-- Why the PvP counters of a member could not be reset (Comm:ResetPvP).
ViewModel.PVP_RESET_ERRORS = {
  forbidden = L("only an admin can reset PvP counters."),
  stale = L("that member was already reset (or a later reset is known)."),
  limit = L("too many resets are remembered."),
  bad_target = L("that is not a valid member name."),
}

-- args: version, syncLines (Comm:Status()), readinessText (summary.text)
function ViewModel.Home(args)
  local lines = { ("Nrage Assistant %s"):format(args.version), "" }
  lines[#lines + 1] = L("Your readiness: ") .. args.readinessText
  lines[#lines + 1] = ""
  lines[#lines + 1] = L("Sync:")
  for _, line in ipairs(args.syncLines) do
    lines[#lines + 1] = "  " .. ViewModel.Escape(line)
  end
  return lines
end

local function classText(entry)
  return ("%s %s"):format(ViewModel.Escape(entry.class), ViewModel.Escape(entry.level))
end

-- Received profiles, sorted by name. Data older than ROSTER_STALE_SECONDS is labelled stale
-- instead of verified-looking; nothing received is ever shown as verified.
function ViewModel.Roster(roster, now)
  local names = {}
  for name in pairs(roster) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    return { L("No profiles received yet. Members appear here once they publish theirs.") }
  end

  local lines = { L("%d profile(s) received:"):format(#names) }
  for _, name in ipairs(names) do
    local entry = roster[name]
    local age = now - (entry.receivedAt or 0)
    local label = age > ns.Constants.ROSTER_STALE_SECONDS and L("stale") or L("received")

    local text = ("%s - %s"):format(ViewModel.Escape(name), classText(entry))
    if entry.ilvl then
      text = text .. L(", ilvl %s"):format(ViewModel.Escape(entry.ilvl))
    end
    local role = entry.fields and entry.fields.role
    if role then
      text = text .. L(", role %s"):format(ViewModel.Escape(role))
    end
    lines[#lines + 1] = ("  %s [%s]"):format(text, label)
  end
  return lines
end

local PUBLISH_ERRORS = {
  missing_data = L("class or level is unknown, nothing to share yet."),
  cooldown = L("you published a moment ago, wait a little."),
  full = L("the send queue is full, try again shortly."),
  too_large = L("the profile is too large to send."),
  encode_failed = L("the profile could not be encoded."),
}

function ViewModel.PublishError(reason)
  return PUBLISH_ERRORS[reason] or tostring(reason)
end

-- One event as lines: title, status and start, the attendance counts and the assignments. `index` is its
-- number in the list. `formatDate(timestamp)` renders the start time. Everything shown is escaped.
function ViewModel.RaidEventLines(event, index, formatDate)
  local lines = {}
  local when = event.startAt and (" - " .. formatDate(event.startAt)) or ""
  lines[#lines + 1] = ("%d. %s [%s]%s"):format(
    index,
    ViewModel.Escape(event.title),
    ViewModel.Escape(ViewModel.Word(event.status)),
    when
  )

  local counts, states = {}, {}
  for _, record in pairs(event.attendance) do
    if not counts[record.state] then
      states[#states + 1] = record.state
      counts[record.state] = 0
    end
    counts[record.state] = counts[record.state] + 1
  end
  table.sort(states)
  if #states == 0 then
    lines[#lines + 1] = "    " .. L("Attendance: none recorded")
  else
    local parts = {}
    for _, state in ipairs(states) do
      parts[#parts + 1] = ("%d %s"):format(counts[state], ViewModel.Escape(ViewModel.Word(state)))
    end
    lines[#lines + 1] = "    " .. L("Attendance: ") .. table.concat(parts, ", ")
  end

  local assignments = {}
  for _, assignment in pairs(event.assignments) do
    assignments[#assignments + 1] = assignment
  end
  table.sort(assignments, function(a, b)
    if a.encounter ~= b.encounter then
      return a.encounter < b.encounter
    end
    return a.characterKey < b.characterKey
  end)
  for _, assignment in ipairs(assignments) do
    local task = assignment.task and (" - " .. ViewModel.Escape(assignment.task)) or ""
    lines[#lines + 1] = ("    %s: %s%s"):format(
      ViewModel.Escape(assignment.encounter),
      ViewModel.Escape(assignment.characterKey),
      task
    )
  end
  return lines
end

-- Events with their attendance summary and assignments, in the order of the list.
function ViewModel.Raid(events, formatDate)
  local list = ns.EventService.List({ events = events })
  if #list == 0 then
    return { L("No events yet. A raid leader creates them in the Raid tab.") }
  end

  local lines = {}
  for index, event in ipairs(list) do
    for _, line in ipairs(ViewModel.RaidEventLines(event, index, formatDate)) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  return lines
end

-- The attendance and loot reports, for `event` only or for every event in `events`, as lines.
function ViewModel.ReportLines(events, event, allEvents)
  local scope = allEvents and events or { [event.eventId] = event }
  local lines = {}
  local rows, held = ns.ReportService.Attendance(scope)
  for _, line in ipairs(ns.ReportService.DescribeAttendance(rows, held)) do
    lines[#lines + 1] = ViewModel.Escape(line)
  end
  lines[#lines + 1] = ""
  local lootRows, totals = ns.ReportService.Loot(scope)
  for _, line in ipairs(ns.ReportService.DescribeLoot(lootRows, totals)) do
    lines[#lines + 1] = ViewModel.Escape(line)
  end
  return lines
end

-- The sub-tabs of the Raid tab for a role (ViewModel.RaidActions): everyone gets the summary, and each
-- group of controls gets its own tab only when the role may use it.
function ViewModel.RaidSubTabs(actions)
  local tabs = { { value = "summary", text = L("Summary") } }
  if actions.events then
    tabs[#tabs + 1] = { value = "details", text = L("Details") }
  end
  if actions.attendance then
    tabs[#tabs + 1] = { value = "attendance", text = L("Attendance") }
  end
  if actions.assignments then
    tabs[#tabs + 1] = { value = "assignments", text = L("Assignments") }
    tabs[#tabs + 1] = { value = "templates", text = L("Templates") }
  end
  tabs[#tabs + 1] = { value = "reports", text = L("Reports") }
  return tabs
end

-- "Rank: Knight (512 honourable kills) - 288 to Knight-Lieutenant", or the top rank, or no rank yet.
function ViewModel.PvPRankLine(kills, ranks)
  local rank = ns.PvPService.RankFor(kills, ranks)
  local current = rank.name and L("%s (%d honourable kills)"):format(rank.name, kills) or L("none yet")
  if rank.next then
    return L("Rank: %s - %d to %s"):format(current, rank.next.remaining, rank.next.name)
  end
  if rank.name then
    return L("Rank: %s, the highest rank"):format(current)
  end
  return L("Rank: none (no ranks are configured)")
end

-- The period selector of the ranking.
ViewModel.PVP_PERIODS = { total = L("Total"), today = L("Today") }
ViewModel.PVP_PERIOD_ORDER = { "total", "today" }

-- The sub-tabs of the PvP tab: the own counters, the guild ranking and the own recent kills.
function ViewModel.PvPSubTabs()
  return {
    { value = "mine", text = L("My stats") },
    { value = "ranking", text = L("Ranking") },
    { value = "feed", text = L("Recent kills") },
  }
end

local FEED_PLACES = { world = L("open world"), bg = L("battleground") }

-- The own recent kills, newest first (the order of `entries`): "12:04  Ann, Bob killed Zed (open world,
-- killing blow)". `options` = { available = boolean (the client can give a victim name), formatTime =
-- function(seconds) -> text }. Names are escaped.
function ViewModel.PvPFeed(entries, options)
  local lines = {}
  if not options.available then
    lines[1] = L("The kill feed is not available on this client: the name of a killed player cannot be read.")
    lines[2] = ""
  end
  if #entries == 0 then
    lines[#lines + 1] = L("No kills yet. Your kills show up here.")
    return lines
  end
  for _, entry in ipairs(entries) do
    local names = {}
    for index, killer in ipairs(entry.killers) do
      names[index] = ViewModel.Escape(killer)
    end
    local place = FEED_PLACES[entry.where] or "?"
    if entry.blow then
      place = place .. L(", killing blow")
    end
    local time = options.formatTime and options.formatTime(entry.time) or "--:--"
    lines[#lines + 1] = L("%s  %s killed %s (%s)"):format(
      ViewModel.Escape(time),
      table.concat(names, ", "),
      ViewModel.Escape(entry.victim),
      place
    )
  end
  return lines
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

-- `honor` and `blows` are the counters shown (all time or today); `rankKills` is the all-time total of
-- honourable kills, because the rank never depends on the period shown.
local function rankRow(name, honor, blows, rankKills, updatedAt, mine, options, ranks)
  local total = honor.world + honor.bg
  local rank = ns.PvPService.RankFor(rankKills, ranks)
  return {
    name = name,
    label = ViewModel.Escape(name),
    rank = ViewModel.Escape(rank.name or "-"),
    rankIndex = rank.index or 0,
    rankKills = rankKills,
    world = honor.world,
    bg = honor.bg,
    total = total,
    blows = blows and (blows.world + blows.bg) or nil,
    updatedAt = updatedAt,
    updated = (mine and L("now"))
      or (updatedAt and options.now and ageText(math.max(0, options.now - updatedAt)))
      or "-",
    mine = mine,
  }
end

local PVP_SORT_KEYS = { name = true, rank = true, world = true, bg = true, total = true, blows = true, updated = true }
-- The columns that sort highest first on the first click.
ViewModel.PVP_FIRST_DESCENDING = { rank = true, world = true, bg = true, total = true, blows = true, updated = true }

local function validPair(pair)
  return type(pair) == "table" and type(pair.world) == "number" and type(pair.bg) == "number"
end

local ZERO_PAIR = { world = 0, bg = 0 }

-- Today's counters of a received record: its `today` block when it is for `day`, else zeros (the member has not
-- sent anything today). Killing blows stay nil when the member never sent any.
local function todayOf(record, day, hasBlows)
  local block = record.today
  if type(block) ~= "table" or block.day ~= day or type(day) ~= "string" or not validPair(block.honor) then
    return ZERO_PAIR, hasBlows and ZERO_PAIR or nil
  end
  local blows = validPair(block.blows) and block.blows or (hasBlows and ZERO_PAIR or nil)
  return block.honor, blows
end

-- The guild ranking of the PvP tab: one row per member with counters, most honourable kills first. `records` is
-- db.global.pvpStats (received); `options`:
--   own = { name, stats }     this character, always listed, from the local counters (not from the synced copy)
--   rosterNames               set of the names in the guild roster now; received records of anyone else are hidden
--   ranks                     default Constants.PVP_RANKS
--   blowsAvailable            this client reads killing blows (the own row has them)
--   now                       server time, for the "last update" text
--   period                    "total" (default) or "today": which counters the columns show; the rank is always
--                             the all-time one
--   day                       today as "YYYY-MM-DD" (server date), for period "today": a record whose day is
--                             another one counts as zero
--   sort = { key, descending }  key: "name" | "rank" | "world" | "bg" | "total" | "blows" | "updated"
--                             (default: total, highest first). Ties fall back to the name.
-- Returns the rows and { blows = boolean }: the killing blows column is only worth showing when this client reads
-- them or somebody sent them. Text is escaped.
function ViewModel.PvPRanking(records, options)
  local ranks = options.ranks or ns.Constants.PVP_RANKS
  local roster = options.rosterNames or {}
  local own = options.own
  local today = options.period == "today"
  local rows = {}

  for name, record in pairs(records or {}) do
    if type(name) == "string" and roster[name] and not (own and own.name == name) then
      if type(record) == "table" and validPair(record.honor) then
        local blows = validPair(record.blows) and record.blows or nil
        local updatedAt = type(record.updatedAt) == "number" and record.updatedAt or nil
        local rankKills = record.honor.world + record.honor.bg
        local honor = record.honor
        if today then
          honor, blows = todayOf(record, options.day, blows ~= nil)
        end
        rows[#rows + 1] = rankRow(name, honor, blows, rankKills, updatedAt, false, options, ranks)
      end
    end
  end
  if own then
    local totals = ns.PvPService.Totals(own.stats)
    local shown = today and ns.PvPService.Today(own.stats, options.day) or totals
    local blows = options.blowsAvailable and shown.blows or nil
    rows[#rows + 1] = rankRow(own.name, shown.honor, blows, totals.honor.total, nil, true, options, ranks)
  end

  local showBlows = options.blowsAvailable and true or false
  for _, row in ipairs(rows) do
    showBlows = showBlows or row.blows ~= nil
  end

  local sort = options.sort or { key = "total", descending = true }
  local key, descending = sort.key, sort.descending
  if not PVP_SORT_KEYS[key] then
    key, descending = "total", true
  end
  table.sort(rows, function(a, b)
    local left, right
    if key == "name" then
      left, right = a.name:lower(), b.name:lower()
    elseif key == "rank" then
      left, right = a.rankKills, b.rankKills
    elseif key == "world" or key == "bg" or key == "total" then
      left, right = a[key], b[key]
    elseif key == "blows" then
      left, right = a.blows or -1, b.blows or -1
    else -- "updated"
      -- The own row is the freshest there is.
      left, right = a.mine and math.huge or (a.updatedAt or -1), b.mine and math.huge or (b.updatedAt or -1)
    end
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.name < b.name
  end)
  return rows, { blows = showBlows }
end

-- The lines of "My stats": honourable kills and killing blows split into open world and battleground, with
-- the total and today, after the PvP rank. `options` = { day = "YYYY-MM-DD" (today, server date),
-- honorAvailable, blowsAvailable, ranks (default Constants.PVP_RANKS) }.
-- The killing blows are left out when this client does not allow reading them.
function ViewModel.PvPStats(stats, options)
  local totals = ns.PvPService.Totals(stats)
  local today = ns.PvPService.Today(stats, options.day)
  local lines = { ViewModel.PvPRankLine(totals.honor.total, options.ranks or ns.Constants.PVP_RANKS), "" }

  local function section(title, all, day)
    lines[#lines + 1] = title
    lines[#lines + 1] = "  " .. L("Open world: %d"):format(all.world)
    lines[#lines + 1] = "  " .. L("Battleground: %d"):format(all.bg)
    lines[#lines + 1] = "  " .. L("Total: %d"):format(all.total)
    lines[#lines + 1] = "  " .. L("Today: %d (open world %d, battleground %d)"):format(day.total, day.world, day.bg)
  end

  section(L("Honourable kills"), totals.honor, today.honor)
  if not options.honorAvailable then
    lines[#lines + 1] = L("Honourable kills are not available on this client.")
  end
  if options.blowsAvailable then
    lines[#lines + 1] = ""
    section(L("Killing blows"), totals.blows, today.blows)
  end
  return lines
end

-- Loot council sessions per event: what is open, what was awarded and why. Only aggregate vote
-- counts are shown here (never who voted for whom), and everything from the guild is escaped.
function ViewModel.Loot(events)
  local lines = {}
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    local sessions = ns.LootService.Sessions(event)
    if #sessions > 0 then
      lines[#lines + 1] = ViewModel.Escape(event.title)
      for _, session in ipairs(sessions) do
        local outcome
        if session.award then
          outcome = L("awarded to %s - %s"):format(
            ViewModel.Escape(session.award.characterKey),
            ViewModel.Escape(session.award.reason)
          )
        elseif session.status == "closed" then
          outcome = L("closed, not awarded")
        else
          local candidates, votes = 0, 0
          for _ in pairs(session.candidates) do
            candidates = candidates + 1
          end
          for _ in pairs(session.votes) do
            votes = votes + 1
          end
          outcome = L("%d candidate(s), %d vote(s) cast"):format(candidates, votes)
        end
        lines[#lines + 1] = ("  %s [%s] - %s"):format(
          ViewModel.Escape(session.itemName),
          ViewModel.Escape(ViewModel.Word(session.status)),
          outcome
        )
      end
      lines[#lines + 1] = ""
    end
  end
  if #lines == 0 then
    lines[1] = L("No loot sessions yet. The council opens one in the Loot tab after an encounter.")
  end
  lines[#lines + 1] = L("Addon messages are not private: anyone with the addon can read votes.")
  return lines
end

ViewModel.EVENT_STATUSES = { "planned", "open", "closed", "cancelled" }
ViewModel.ATTENDANCE_STATES = { "invited", "confirmed", "present", "late", "leftEarly", "absent", "excused", "unknown" }

-- What the Raid tab offers a role. These are the same checks the commands make (EventService repeats
-- them on every change), so a hidden control is never the only thing standing between a member and a change.
function ViewModel.RaidActions(role)
  local can = ns.PermissionService.Can
  return {
    events = can(role, "manage_events"),
    attendance = can(role, "record_attendance"),
    assignments = can(role, "manage_assignments"),
  }
end

-- Dropdown entries for the events, in the order of the list: list[eventId] = label, plus the ids in order.
function ViewModel.EventChoices(events)
  local list, order = {}, {}
  for index, event in ipairs(ns.EventService.List({ events = events })) do
    list[event.eventId] = ("%d. %s [%s]"):format(
      index,
      ViewModel.Escape(event.title),
      ViewModel.Escape(ViewModel.Word(event.status))
    )
    order[#order + 1] = event.eventId
  end
  return list, order
end

-- The attendance tab: who is already recorded for the event (sorted, with their state), and, for a typed
-- `filter` (case-insensitive part of a name), the members of `memberNames` not recorded yet that match, cut at
-- `limit`. Nothing is listed for an empty filter, so a guild of hundreds never turns into hundreds of rows.
-- Returns recorded = { { name, label, state } }, matches = { { name, label } } and how many matched before the cut.
function ViewModel.AttendanceView(event, memberNames, filter, limit)
  local recorded = {}
  for name, record in pairs(event.attendance) do
    recorded[#recorded + 1] = { name = name, label = ViewModel.Escape(name), state = record.state }
  end
  table.sort(recorded, function(a, b)
    return a.name < b.name
  end)

  local matches, matched = {}, 0
  local needle = (filter or ""):lower()
  if needle ~= "" then
    local names = {}
    for _, name in ipairs(memberNames) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      if not event.attendance[name] and name:lower():find(needle, 1, true) then
        matched = matched + 1
        if matched <= limit then
          matches[#matches + 1] = { name = name, label = ViewModel.Escape(name) }
        end
      end
    end
  end
  return recorded, matches, matched
end

-- What the Loot tab offers a role: the same checks as the commands (LootService repeats them on every change).
function ViewModel.LootActions(role)
  local can = ns.PermissionService.Can
  return {
    open = can(role, "loot_open"),
    apply = can(role, "loot_apply"),
    vote = can(role, "loot_vote"),
    award = can(role, "loot_award"),
  }
end

ViewModel.LOOT_NEEDS = { "main", "off", "other" }

-- One loot session as lines: item, candidates, votes and decision. Vote counts follow the session's
-- visibility policy (hidden while open unless configured otherwise); everything is escaped.
function ViewModel.LootSession(session)
  local lines = {
    ("%s [%s]"):format(ViewModel.Escape(session.itemName), ViewModel.Escape(ViewModel.Word(session.status))),
  }

  local keys = {}
  for key in pairs(session.candidates) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if #keys == 0 then
    lines[#lines + 1] = "  " .. L("no candidates yet")
  end
  for _, key in ipairs(keys) do
    local candidate = session.candidates[key]
    local upgrade = candidate.upgrade and (" - " .. ViewModel.Escape(candidate.upgrade)) or ""
    lines[#lines + 1] = ("  %s: %s, %s%s"):format(
      ViewModel.Escape(key),
      ViewModel.Escape(candidate.spec),
      ViewModel.Escape(ViewModel.Word(candidate.need)),
      upgrade
    )
  end

  if ns.LootService.VotesVisible(session) then
    local parts = {}
    for _, entry in ipairs(ns.LootService.Tally(session)) do
      parts[#parts + 1] = ("%s %d"):format(ViewModel.Escape(entry.characterKey), entry.count)
    end
    lines[#lines + 1] = "  " .. (#parts > 0 and (L("votes: ") .. table.concat(parts, ", ")) or L("no votes yet"))
  else
    local voters = 0
    for _ in pairs(session.votes) do
      voters = voters + 1
    end
    lines[#lines + 1] = "  " .. L("%d vote(s) cast (hidden until the session closes)"):format(voters)
  end

  if session.award then
    lines[#lines + 1] = "  "
      .. L("awarded to %s by %s: %s"):format(
        ViewModel.Escape(session.award.characterKey),
        ViewModel.Escape(session.award.awardedBy),
        ViewModel.Escape(session.award.reason)
      )
  elseif session.status == "closed" then
    lines[#lines + 1] = "  " .. L("closed, not awarded")
  end
  return lines
end

-- Dropdown entries for the candidates of a session: list[characterKey] = label, plus the keys sorted.
function ViewModel.CandidateChoices(session)
  local list, order = {}, {}
  for key in pairs(session.candidates) do
    order[#order + 1] = key
  end
  table.sort(order)
  for _, key in ipairs(order) do
    local candidate = session.candidates[key]
    list[key] = ("%s (%s, %s)"):format(
      ViewModel.Escape(key),
      ViewModel.Escape(candidate.spec),
      ViewModel.Escape(ViewModel.Word(candidate.need))
    )
  end
  return list, order
end

-- What a player may set by hand on a readiness item (ReadinessService.SetManual accepts the same four).
ViewModel.READY_STATUSES = { "met", "missing", "waived", "unknown" }

ViewModel.READY_SET_ERRORS = {
  unknown_rule = L("unknown item."),
  not_manual = L("that item is measured automatically and cannot be set by hand."),
  invalid_status = L("status must be met, missing, waived or unknown."),
}

-- The items the player confirms by hand, with their current status: { ruleId, label, status } in rule order.
-- `results` is what ReadinessService.Evaluate returned for the same `rules`.
function ViewModel.ManualItems(rules, results)
  local items = {}
  for index, rule in ipairs(rules) do
    if rule.check == "confirm" and results[index] then
      items[#items + 1] = {
        ruleId = rule.id,
        label = ViewModel.Escape(rule.label),
        status = results[index].status,
      }
    end
  end
  return items
end

-- The event to put first in the minimap tooltip: among the planned or open events, the one starting soonest that
-- has not started yet (an open event is kept even after its start); undated ones come last. nil when none.
function ViewModel.NextEvent(events, now)
  local best
  for _, event in ipairs(ns.EventService.List({ events = events })) do
    local active = event.status == "planned" or event.status == "open"
    local upcoming = event.startAt == nil or event.startAt >= now or event.status == "open"
    if active and upcoming then
      best = best or event
      if event.startAt then
        return event
      end
    end
  end
  return best
end

-- Lines for the minimap tooltip. It reads only what the addon already holds: no game API is called, so it is
-- safe during an encounter lockdown.
-- args: events, now, formatDate(timestamp), readinessText, pending (queued messages), paused (queue held back)
function ViewModel.MinimapTooltip(args)
  local lines = {}
  local event = ViewModel.NextEvent(args.events, args.now)
  if event then
    local when = event.startAt and (" - " .. args.formatDate(event.startAt)) or ""
    lines[#lines + 1] = L("Next event: %s%s"):format(ViewModel.Escape(event.title), when)
  else
    lines[#lines + 1] = L("Next event: none planned")
  end
  lines[#lines + 1] = L("Readiness: ") .. args.readinessText
  if args.pending == 0 then
    lines[#lines + 1] = L("Sync queue: empty")
  else
    local held = args.paused and L(" (held back: encounter in progress)") or ""
    lines[#lines + 1] = L("Sync queue: %d message(s) waiting%s"):format(args.pending, held)
  end
  return lines
end

-- Right-click menu of the minimap button: a shortcut to each tab, then a sync request.
function ViewModel.MinimapMenu()
  local entries = {}
  for _, tab in ipairs(ViewModel.TABS) do
    entries[#entries + 1] = { text = tab.text, action = "tab", value = tab.value }
  end
  entries[#entries + 1] = { text = L("Request a sync"), action = "sync" }
  return entries
end

ViewModel.SYNC_REQUEST_ERRORS = {
  cooldown = L("you asked a moment ago, wait a little."),
  full = L("the send queue is full, try again shortly."),
}

-- The line to print after asking the guild for the latest raid data.
function ViewModel.SyncRequestResult(ok, reason)
  if ok then
    return L("asked the guild for the latest raid data; leaders answer by whisper.")
  end
  return L("not requested: ") .. (ViewModel.SYNC_REQUEST_ERRORS[reason] or tostring(reason))
end

-- Lines for the minimap tooltip when the silent self test found failures (Diagnostics.Failures).
function ViewModel.SelfTestFailures(failures)
  local lines = { L("Self test: %d check(s) failed"):format(#failures) }
  for _, entry in ipairs(failures) do
    local detail = entry.detail and (" - " .. ViewModel.Escape(entry.detail)) or ""
    lines[#lines + 1] = ("  [%s] %s%s"):format(ViewModel.Escape(entry.status), ViewModel.Escape(entry.name), detail)
  end
  lines[#lines + 1] = L("Type /nrage debug selftest for the full result.")
  return lines
end

-- The loot sessions waiting for an answer from `actor`: open, no candidacy of theirs yet, and not passed on or
-- dismissed (`dismissed[sessionId] = true`). Sorted by event title, item name, then id so the popup is stable.
-- Returns { eventId, sessionId, eventTitle, itemName } entries, text unescaped (escape when drawing).
function ViewModel.PendingLoot(events, actor, dismissed)
  local pending = {}
  for _, event in pairs(events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      if session.status == "open" and not session.candidates[actor] and not dismissed[session.sessionId] then
        pending[#pending + 1] = {
          eventId = event.eventId,
          sessionId = session.sessionId,
          eventTitle = event.title,
          itemId = session.itemId,
          itemName = session.itemName,
        }
      end
    end
  end
  table.sort(pending, function(a, b)
    if a.eventTitle ~= b.eventTitle then
      return a.eventTitle < b.eventTitle
    end
    if a.itemName ~= b.itemName then
      return a.itemName < b.itemName
    end
    return a.sessionId < b.sessionId
  end)
  return pending
end

-- The spec put on a candidacy made with one click: the declared role, else the class, else a placeholder.
function ViewModel.DefaultSpec(profile)
  local role = profile.fields and profile.fields.role and profile.fields.role.value
  if type(role) == "string" and role:match("%S") then
    return role
  end
  if type(profile.class) == "string" and profile.class:match("%S") then
    return profile.class
  end
  return "unknown"
end

ViewModel.LOOT_NEED_LABELS = { main = L("Main spec"), off = L("Off spec"), other = L("Other") }

-- The items the voting window can switch between: every open session, plus the selected one even if it has
-- closed (so the decision stays visible). Entries are { eventId, sessionId, itemName, eventTitle, selected },
-- text escaped, ordered by event title, item name, then id.
function ViewModel.VotingSessions(events, selectedId)
  local list = {}
  for _, event in pairs(events) do
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      if session.status == "open" or session.sessionId == selectedId then
        list[#list + 1] = {
          eventId = event.eventId,
          sessionId = session.sessionId,
          itemId = session.itemId,
          itemName = ViewModel.Escape(session.itemName),
          eventTitle = ViewModel.Escape(event.title),
          selected = session.sessionId == selectedId,
          sort = event.title .. "\n" .. session.itemName .. "\n" .. session.sessionId,
        }
      end
    end
  end
  table.sort(list, function(a, b)
    return a.sort < b.sort
  end)
  return list
end

-- One line on where a session stands.
function ViewModel.VotingStatus(session)
  if session.award then
    return L("Awarded to %s by %s: %s"):format(
      ViewModel.Escape(session.award.characterKey),
      ViewModel.Escape(session.award.awardedBy),
      ViewModel.Escape(session.award.reason)
    )
  end
  if session.status == "closed" then
    return L("Closed without an award")
  end
  local candidates, votes = 0, 0
  for _ in pairs(session.candidates) do
    candidates = candidates + 1
  end
  for _ in pairs(session.votes) do
    votes = votes + 1
  end
  return L("Voting is open: %d candidate(s), %d vote(s) cast"):format(candidates, votes)
end

-- "ilvl 213 - Two-Hand" from Platform.GetItemDetails, or nil when the client told us nothing.
function ViewModel.ItemDetailsLine(details)
  if not details then
    return nil
  end
  local parts = {}
  if details.level then
    parts[#parts + 1] = L("ilvl %d"):format(details.level)
  end
  if details.slot then
    parts[#parts + 1] = ViewModel.Escape(details.slot)
  end
  return #parts > 0 and table.concat(parts, " - ") or nil
end

-- The items `name` has won, newest first: { itemName, eventTitle, reason } (not escaped). `limit` caps the list.
-- Read from the awards already stored, so it shows exactly what this client knows.
function ViewModel.WonItems(events, name, limit)
  local won = {}
  for _, event in pairs(events) do
    for _, session in pairs(event.loot or {}) do
      local award = session.award
      if award and award.characterKey == name then
        won[#won + 1] = {
          itemName = session.itemName,
          eventTitle = event.title,
          reason = award.reason,
          at = award.at or 0,
        }
      end
    end
  end
  table.sort(won, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.itemName < b.itemName
  end)
  while #won > limit do
    table.remove(won)
  end
  return won
end

ViewModel.VOTING_SORTS = { "name", "rank", "response", "votes" }

-- The sort after clicking the header `key`: the same column flips its direction, another column starts in its
-- natural one (votes high to low, the rest A to Z; `firstDescending` = set of keys that start high to low
-- instead, default only "votes"). `current` = { key, descending } or nil.
function ViewModel.NextSort(current, key, firstDescending)
  if current and current.key == key then
    return { key = key, descending = not current.descending }
  end
  return { key = key, descending = (firstDescending or { votes = true })[key] == true }
end

local NEED_ORDER = { main = 1, off = 2, other = 3 }

-- The table of the voting window: one row per candidate. `votes` is nil while the visibility policy hides
-- them. `mine` marks the candidate `actor` voted for. `rankOf(name)` gives the guild rank name or nil. Text is
-- escaped. `options` (all optional): sort = { key = "name"|"rank"|"response"|"votes", descending = boolean }
-- (default: most votes first), need = "main"|"off"|"other" to show only that response. Ties fall back to the
-- name, and sorting by votes falls back to the name while they are hidden.
function ViewModel.VotingRows(session, actor, rankOf, options)
  options = options or {}
  local counts = {}
  local visible = ns.LootService.VotesVisible(session)
  for _, entry in ipairs(ns.LootService.Tally(session)) do
    counts[entry.characterKey] = entry.count
  end
  local myVote = session.votes[actor] and session.votes[actor].target

  local rows = {}
  for name, candidate in pairs(session.candidates) do
    if not options.need or candidate.need == options.need then
      local rank = rankOf(name)
      rows[#rows + 1] = {
        name = name,
        label = ViewModel.Escape(name),
        rank = ViewModel.Escape(rank or "?"),
        need = candidate.need,
        response = ("%s (%s)"):format(
          ViewModel.Escape(ViewModel.LOOT_NEED_LABELS[candidate.need] or candidate.need),
          ViewModel.Escape(candidate.spec)
        ),
        upgrade = candidate.upgrade and ViewModel.Escape(candidate.upgrade) or "",
        votes = visible and (counts[name] or 0) or nil,
        mine = myVote == name,
        sortRank = (rank or ""):lower(),
        sortResponse = ("%d %s"):format(NEED_ORDER[candidate.need] or 9, candidate.spec:lower()),
      }
    end
  end

  local sort = options.sort or { key = "votes", descending = true }
  local key, descending = sort.key, sort.descending
  if key == "votes" and not visible then
    key, descending = "name", false
  end
  table.sort(rows, function(a, b)
    local left, right
    if key == "votes" then
      left, right = a.votes, b.votes
    elseif key == "rank" then
      left, right = a.sortRank, b.sortRank
    elseif key == "response" then
      left, right = a.sortResponse, b.sortResponse
    else
      left, right = a.name:lower(), b.name:lower()
    end
    if left ~= right then
      if descending then
        return left > right
      end
      return left < right
    end
    return a.name < b.name
  end)
  return rows
end

-- The rows of the blacklist tab: the entries sorted by name, with the text already escaped. `options` =
-- { canRemove = boolean (the own role may remove entries), formatDate = function(timestamp) -> text }.
function ViewModel.BlacklistRows(entries, options)
  options = options or {}
  local rows = {}
  for _, entry in ipairs(ns.BlacklistService.List(entries)) do
    rows[#rows + 1] = {
      key = entry.key,
      name = ViewModel.Escape(entry.name),
      reason = ViewModel.Escape(entry.reason or "-"),
      addedBy = ViewModel.Escape(entry.addedBy or "-"),
      added = type(entry.addedAt) == "number" and options.formatDate and options.formatDate(entry.addedAt) or "-",
      canRemove = options.canRemove == true,
    }
  end
  return rows
end

-- What the group alert says about a match of BlacklistService.Match. An approximate match is a guess: the client
-- gives only the first word of a multi-word name.
function ViewModel.BlacklistAlertLine(match)
  local reason = ViewModel.Escape(match.entry.reason)
  if match.approximate then
    return L("%s may be %s, who is on the blacklist: %s"):format(
      ViewModel.Escape(match.member),
      ViewModel.Escape(match.entry.name),
      reason
    )
  end
  return L("%s is on the blacklist: %s"):format(ViewModel.Escape(match.entry.name), reason)
end

ViewModel.TABS = {
  { value = "home", text = L("Home") },
  { value = "profile", text = L("Profile") },
  { value = "ready", text = L("Readiness") },
  { value = "raid", text = L("Raid") },
  { value = "loot", text = L("Loot") },
  { value = "pvp", text = "PvP" },
  { value = "blacklist", text = L("Blacklist") },
  { value = "roster", text = L("Roster") },
}

-- The admin-only tab where the guild's readiness rules are edited.
ViewModel.RULES_TAB = { value = "rules", text = L("Rules") }

-- The tabs for a player with `role`: everyone's, plus the rules editor for who may edit the rules.
function ViewModel.TabsFor(role)
  local tabs = {}
  for index, tab in ipairs(ViewModel.TABS) do
    tabs[index] = tab
  end
  if ns.PermissionService.Can(role, "rules_edit") then
    tabs[#tabs + 1] = ViewModel.RULES_TAB
  end
  return tabs
end

-- The kinds of rule an admin can add, in the order of the dropdown, and what each one needs typed in "Details".
ViewModel.RULE_CHECKS = { "level", "ilvl", "enchants", "buff", "profession", "field", "confirm" }
ViewModel.RULE_CHECK_TEXT = {
  level = L("Minimum level"),
  ilvl = L("Minimum item level"),
  enchants = L("Enchanted slots"),
  buff = L("Active buff (flask, food...)"),
  profession = L("Profession"),
  field = L("Declared profile field"),
  confirm = L("Confirmed by hand"),
}
ViewModel.RULE_DETAIL_HINTS = {
  level = L("a number, e.g. 60"),
  ilvl = L("a number, e.g. 60"),
  enchants = L("slots by name or number: mainhand, chest, back, 16"),
  buff = L("spell ids and/or names, separated by commas"),
  profession = L("name and minimum skill, e.g. Alchemy 300"),
  field = "role",
  confirm = L("nothing needed"),
}

-- Equipment slot names an admin may type instead of the number (the slots that can carry an enchant).
ViewModel.ENCHANT_SLOTS = {
  head = 1,
  shoulders = 3,
  chest = 5,
  wrist = 9,
  hands = 10,
  legs = 7,
  feet = 8,
  back = 15,
  mainhand = 16,
  offhand = 17,
  ranged = 18,
}

ViewModel.RULE_ERRORS = {
  forbidden = L("only the guild master and officers can change the rules."),
  empty = L("keep at least one rule."),
  too_many = L("there is room for 30 rules at most."),
  bad_id = L("that rule name cannot be used."),
  bad_label = L("the name is empty, too long or has unsupported characters."),
  bad_category = L("that rule category cannot be used."),
  bad_check = L("that kind of rule is not supported."),
  bad_details = L("the details do not fit this kind of rule (see the hint under Details)."),
  duplicate_id = L("two rules would have the same name."),
  bad_rules = L("those rules are not valid."),
  last_rule = L("keep at least one rule; add another before removing this one."),
  unknown_rule = L("that rule no longer exists."),
}

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function splitList(text)
  local items = {}
  for piece in text:gmatch("[^,]+") do
    local item = trim(piece)
    if item ~= "" then
      items[#items + 1] = item
    end
  end
  return items
end

-- A name for the rule, from its label, that no other rule in `rules` has.
local function uniqueRuleId(label, rules)
  local base = label:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  base = base:sub(1, 24)
  if base == "" then
    base = "rule"
  end
  local taken = {}
  for _, rule in ipairs(rules) do
    taken[rule.id] = true
  end
  local id, counter = base, 1
  while taken[id] do
    counter = counter + 1
    id = base .. "_" .. counter
  end
  return id
end

-- Reads what the admin typed into the rule it describes. Returns the rule (already clean, ready to add to `rules`),
-- or nil plus a reason from RULE_ERRORS.
function ViewModel.RuleFromInput(check, label, details, rules)
  label, details = trim(label), trim(details)
  if label == "" then
    return nil, "bad_label"
  end
  local rule = { id = uniqueRuleId(label, rules), label = label, check = check }

  if check == "level" or check == "ilvl" then
    rule.min = tonumber(details)
  elseif check == "profession" then
    local name, skill = details:match("^(.-)%s+(%d+)$")
    rule.profession = name or details
    rule.min = skill and tonumber(skill) or nil
  elseif check == "enchants" then
    rule.slots = {}
    for _, token in ipairs(splitList(details)) do
      local slot = tonumber(token) or ViewModel.ENCHANT_SLOTS[token:lower():gsub("%s", "")]
      if not slot then
        return nil, "bad_details"
      end
      rule.slots[#rule.slots + 1] = slot
    end
  elseif check == "buff" then
    for _, token in ipairs(splitList(details)) do
      local id = tonumber(token)
      local key = id and "spellIds" or "names"
      rule[key] = rule[key] or {}
      rule[key][#rule[key] + 1] = id or token
    end
  elseif check == "field" then
    rule.field = details:lower()
  end

  return ns.ReadinessRules.ValidateRule(rule)
end

-- A copy of `rules` with `rule` added, or without the rule called `id`.
function ViewModel.WithRule(rules, rule)
  local list = {}
  for index, existing in ipairs(rules) do
    list[index] = existing
  end
  list[#list + 1] = rule
  return list
end

-- Returns the new list, or nil plus "unknown_rule" | "last_rule".
function ViewModel.WithoutRule(rules, id)
  local list, found = {}, false
  for _, rule in ipairs(rules) do
    if rule.id == id then
      found = true
    else
      list[#list + 1] = rule
    end
  end
  if not found then
    return nil, "unknown_rule"
  end
  if #list == 0 then
    return nil, "last_rule"
  end
  return list
end

-- What a rule asks for, in a few words, for the list in the editor.
function ViewModel.RuleSummary(rule)
  local check = rule.check
  if check == "level" or check == "ilvl" then
    return L("%s %d or more"):format(check == "level" and L("level") or L("item level"), rule.min)
  elseif check == "profession" then
    return rule.min and L("%s %d or more"):format(rule.profession, rule.min) or rule.profession
  elseif check == "enchants" then
    return L("enchanted slots: ") .. table.concat(rule.slots, ", ")
  elseif check == "buff" then
    local parts = {}
    for _, id in ipairs(rule.spellIds or {}) do
      parts[#parts + 1] = tostring(id)
    end
    for _, name in ipairs(rule.names or {}) do
      parts[#parts + 1] = name
    end
    return L("any buff of: ") .. table.concat(parts, ", ")
  elseif check == "field" then
    return L("declared: ") .. rule.field
  end
  return L("confirmed by the player")
end

function ViewModel.HelpLines()
  return {
    L("/nrage               open the window, where everything else is done"),
    L("/nrage help          this list"),
    L("/nrage debug         diagnostics (debug selftest | info | identity | roster | senders | lockdown | pvp)"),
  }
end

ns.ViewModel = ViewModel
